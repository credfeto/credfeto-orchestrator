using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.Git;

// Each query runs the git commands its lib/git function runs, in the same order, and returns what the function prints
// and its status
public sealed class GitQueries : IGitQueries
{
    private const string ORIGIN_PREFIX = "origin/";

    private static readonly Encoding StrictUtf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: true
    );

    private readonly IGitRunner _git;

    public GitQueries(IGitRunner git)
    {
        this._git = git;
    }

    // git rev-parse --verify -q HEAD
    public ValueTask<GitResult> HeadShaAsync(string repository, CancellationToken cancellationToken)
    {
        return this._git.RunAsync(
            repository: repository,
            arguments: ["rev-parse", "--verify", "-q", "HEAD"],
            cancellationToken: cancellationToken
        );
    }

    // git branch --show-current
    public ValueTask<GitResult> CurrentBranchAsync(string repository, CancellationToken cancellationToken)
    {
        return this._git.RunAsync(
            repository: repository,
            arguments: ["branch", "--show-current"],
            cancellationToken: cancellationToken
        );
    }

    // ! git diff --quiet || ! git diff --cached --quiet: any failure counts as changes, and the second only runs when
    // the first finds none
    public async ValueTask<GitResult> UncommittedChangesAsync(string repository, CancellationToken cancellationToken)
    {
        GitResult unstaged = await this._git.RunAsync(
            repository: repository,
            arguments: ["diff", "--quiet"],
            cancellationToken: cancellationToken
        );

        if (unstaged.ExitCode != 0)
        {
            return new(ExitCode: 0, Output: unstaged.Output);
        }

        GitResult staged = await this._git.RunAsync(
            repository: repository,
            arguments: ["diff", "--cached", "--quiet"],
            cancellationToken: cancellationToken
        );

        return new(
            ExitCode: staged.ExitCode == 0 ? 1 : 0,
            Output: Concat(first: unstaged.Output, second: staged.Output)
        );
    }

    // git rev-parse --verify -q refs/remotes/origin/<branch> > /dev/null
    public async ValueTask<GitResult> OriginBranchExistsAsync(
        string repository,
        string branch,
        CancellationToken cancellationToken
    )
    {
        GitResult result = await this._git.RunAsync(
            repository: repository,
            arguments: ["rev-parse", "--verify", "-q", "refs/remotes/origin/" + branch],
            cancellationToken: cancellationToken
        );

        return new(ExitCode: result.ExitCode, Output: ReadOnlyMemory<byte>.Empty);
    }

    // git rev-list --count ref..upstream, answered only when it succeeds and prints nothing but ASCII digits
    public async ValueTask<GitResult> CommitsBehindAsync(
        string repository,
        string reference,
        string upstream,
        CancellationToken cancellationToken
    )
    {
        GitResult result = await this._git.RunAsync(
            repository: repository,
            arguments: ["rev-list", "--count", reference + ".." + upstream],
            cancellationToken: cancellationToken
        );

        if (result.ExitCode != 0)
        {
            return No();
        }

        ReadOnlyMemory<byte> count = BashCapture(result.Output);

        if (IsAsciiNumber(count.Span))
        {
            return new(ExitCode: 0, Output: count);
        }

        // [0-9] takes other digits in some locales; git only ever prints ASCII ones
        return count.Span.ContainsAnyInRange(lowInclusive: (byte)0x80, highInclusive: (byte)0xFF)
            ? throw new GitRefusedException("the count git printed is not ASCII")
            : No();
    }

    public async ValueTask<GitResult> StaleIssueBranchAsync(
        string repository,
        string issue,
        CancellationToken cancellationToken
    )
    {
        if (!IssueBranchPattern.IsIssueNumber(issue))
        {
            throw new GitRefusedException($"the issue '{issue}' is not a number, so the branch regex is not about one");
        }

        GitResult branches = await this._git.RunAsync(
            repository: repository,
            arguments: ["branch", "-r", "--format=%(refname:short)"],
            cancellationToken: cancellationToken
        );

        byte[] number = Encoding.ASCII.GetBytes(issue);

        // Bash reads the list whatever git's status (the loop reads a process substitution)
        foreach (ReadOnlyMemory<byte> line in BashLines(branches.Output))
        {
            ReadOnlyMemory<byte>? found = await this.CandidateAsync(
                repository: repository,
                line: line,
                issue: number,
                cancellationToken: cancellationToken
            );

            if (found is not null)
            {
                return new(ExitCode: 0, Output: found.Value);
            }
        }

        return No();
    }

    // One line of the loop: candidate="${full_branch#origin/}", then the regex, then commits ahead of origin/main
    private async ValueTask<ReadOnlyMemory<byte>?> CandidateAsync(
        string repository,
        ReadOnlyMemory<byte> line,
        byte[] issue,
        CancellationToken cancellationToken
    )
    {
        ReadOnlyMemory<byte> candidate = line.Span.StartsWith(Encoding.ASCII.GetBytes(ORIGIN_PREFIX))
            ? line[ORIGIN_PREFIX.Length..]
            : line;

        StaleBranchMatch match = IssueBranchPattern.Match(branch: candidate.Span, issue: issue);

        if (match == StaleBranchMatch.LOCALE_DEPENDENT)
        {
            throw new GitRefusedException("a branch name has a non-ASCII character where bash matches by the locale");
        }

        if (match == StaleBranchMatch.NO_MATCH)
        {
            return null;
        }

        GitResult ahead = await this._git.RunAsync(
            repository: repository,
            arguments: ["rev-list", "--count", "origin/main.." + Text(line)],
            cancellationToken: cancellationToken
        );

        if (ahead.ExitCode != 0)
        {
            return null;
        }

        ReadOnlyMemory<byte> count = BashCapture(ahead.Output);

        // [ "${ahead}" -gt 0 ] fails with an error message on anything but an integer: leave that to bash
        if (!IsAsciiNumber(count.Span))
        {
            throw new GitRefusedException("the count git printed is not a number");
        }

        // Not a ternary with null: null would convert to an empty ReadOnlyMemory<byte> through byte[], not to no answer
        if (count.Span.ContainsAnyExcept((byte)'0'))
        {
            return candidate;
        }

        return null;
    }

    // The lines bash's while IFS= read -r reads: a last line with no newline ends the loop unread, and empty lines are
    // skipped by the [ -n ] check. Bash drops NUL bytes, which no ref name holds, so a NUL is refused
    private static IEnumerable<ReadOnlyMemory<byte>> BashLines(ReadOnlyMemory<byte> output)
    {
        if (output.Span.Contains((byte)0))
        {
            throw new GitRefusedException("git printed a NUL byte");
        }

        ReadOnlyMemory<byte> rest = output;

        for (int end = rest.Span.IndexOf((byte)'\n'); end >= 0; end = rest.Span.IndexOf((byte)'\n'))
        {
            if (end > 0)
            {
                yield return rest[..end];
            }

            rest = rest[(end + 1)..];
        }
    }

    // What $(...) keeps: the output without its trailing newlines (NUL bytes, which bash also drops, are refused)
    private static ReadOnlyMemory<byte> BashCapture(ReadOnlyMemory<byte> output)
    {
        if (output.Span.Contains((byte)0))
        {
            throw new GitRefusedException("git printed a NUL byte");
        }

        ReadOnlySpan<byte> span = output.Span;
        int length = span.Length;

        while (length > 0 && span[length - 1] == (byte)'\n')
        {
            length--;
        }

        return output[..length];
    }

    private static bool IsAsciiNumber(ReadOnlySpan<byte> text)
    {
        return !text.IsEmpty && !text.ContainsAnyExceptInRange(lowInclusive: (byte)'0', highInclusive: (byte)'9');
    }

    // A branch name as an argument: .NET passes arguments as UTF-8, so a name that is not UTF-8 is refused
    private static string Text(ReadOnlyMemory<byte> name)
    {
        try
        {
            return StrictUtf8.GetString(name.Span);
        }
        catch (DecoderFallbackException exception)
        {
            throw new GitRefusedException(message: "a branch name is not UTF-8", innerException: exception);
        }
    }

    private static ReadOnlyMemory<byte> Concat(ReadOnlyMemory<byte> first, ReadOnlyMemory<byte> second)
    {
        return second.IsEmpty ? first : (byte[])[.. first.Span, .. second.Span];
    }

    private static GitResult No()
    {
        return new(ExitCode: 1, Output: ReadOnlyMemory<byte>.Empty);
    }
}
