using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands;

public sealed class CommandRunner
{
    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator fingerprint pr [--trusted-file <file>] [--review-comments-file <file>] [--schema-version <n>]
               credfeto-orchestrator fingerprint issue [--trusted-file <file>] [--plan-approved <value>] [--schema-version <n>]
               credfeto-orchestrator github open-prs|open-pr-count --repo <owner/repo> --head <branch>
               credfeto-orchestrator github branch-requires-status-checks --repo <owner/repo> --branch <branch>
               credfeto-orchestrator github own-open-prs --repo <owner/repo> --me <login> --creator <login> [--include-blocked true|false]
               credfeto-orchestrator github whoami
               credfeto-orchestrator github open-prs-closing-issues --repo <owner/repo>
               credfeto-orchestrator github pr-commit-authors --repo <owner/repo> --pr <number>
               credfeto-orchestrator github branch-behind-by --repo <owner/repo> --base <branch> --head <branch>
               credfeto-orchestrator discovery priorities --url <url> [--user <login>] [--attempts <n>] [--delay-secs <n>]
               credfeto-orchestrator discovery trusted-logins --repo <owner/repo> [--owner <login>] [--whitelist <logins>]
                   [--creator <login>] [--attempts <n>] [--delay-secs <n>]
               credfeto-orchestrator discovery github-incident --url <url> [--component <name>]...
                   [--serious-impact <impact>]... [--outage-status <status>]...

        fingerprint reads the pull request or issue JSON on stdin and prints its fingerprint, exactly
        as fingerprint_pr_json / fingerprint_issue_json in lib/fingerprints do.

        github asks the cfwf MCP server (ORCHESTRATOR_CFWF_MCP_URL, with the token in
        GH_ENTERPRISE_TOKEN or GH_TOKEN) and prints what the gh call in lib/github it replaces prints:
        open-prs the numbers of the open pull requests on the head branch, newest first, one a line;
        open-pr-count how many there are; branch-requires-status-checks true or false; own-open-prs
        the numbers of the open pull requests authored by --me or --creator, newest first, one a line,
        leaving out those labelled Blocked unless --include-blocked is true; whoami the login the token
        authenticates as; open-prs-closing-issues every open pull request's number, author login, closing
        issue numbers and head branch, newest first, as one line of JSON; pr-commit-authors the login and
        email of each commit author, as one line of JSON; branch-behind-by how many commits --head is
        behind --base.

        discovery prints what the lib/github and lib/github-health function it replaces prints:
        priorities the priorities feed's open and draft items that are not on hold, as compact JSON,
        sending --user as the user query parameter and trying the read up to --attempts times, --delay-secs
        apart (exit 3 when the feed answers with something other than the expected JSON);
        trusted-logins the JSON array of trusted logins: --owner, the repository's collaborators (asked
        of the cfwf MCP server, retried the same way), GitHub's Copilot reviewer and Advanced Security
        bots and the comma-separated --whitelist, less --creator; github-incident the githubstatus.com
        incident a session would be stopped by (exit 0) or warned about (exit 3), judged by the
        --component, --serious-impact and --outage-status lists (lib/globals' lists by default), exit 4
        when there is none and 1 when the status cannot be read.

        Exit codes: 0 printed; 1 the fingerprint could not be computed or the read failed; 2 a usage
        error; 3 and 4 as discovery describes.
        """;

    private static readonly Encoding Utf8 = new UTF8Encoding(
        encoderShouldEmitUTF8Identifier: false,
        throwOnInvalidBytes: false
    );

    private readonly DiscoveryCommandRunner _discovery;
    private readonly IFileContentReader _files;
    private readonly IFingerprintCalculator _fingerprints;
    private readonly IGitHubReader _github;

    public CommandRunner(
        IFingerprintCalculator fingerprints,
        IFileContentReader files,
        IGitHubReader github,
        DiscoveryCommandRunner discovery
    )
    {
        this._fingerprints = fingerprints;
        this._files = files;
        this._github = github;
        this._discovery = discovery;
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        if (args.Count == 1 && IsHelp(args[0]))
        {
            await output.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return ExitCodes.Success;
        }

        if (args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: GitHubCommandParser.Verb))
        {
            return await this.RunGitHubAsync(
                args: args,
                output: output,
                error: error,
                cancellationToken: cancellationToken
            );
        }

        if (args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: DiscoveryCommandParser.Verb))
        {
            return await this.RunDiscoveryAsync(
                args: args,
                output: output,
                error: error,
                cancellationToken: cancellationToken
            );
        }

        return await this.RunFingerprintAsync(
            args: args,
            input: input,
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );
    }

    private async ValueTask<int> RunFingerprintAsync(
        IReadOnlyList<string> args,
        Stream input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        FingerprintCommand? command = FingerprintCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        try
        {
            string fingerprint = await this.FingerprintAsync(
                command: command,
                input: input,
                cancellationToken: cancellationToken
            );
            await output.WriteAsync(fingerprint.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return ExitCodes.Success;
        }
        catch (FingerprintException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (IOException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (UnauthorizedAccessException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private async ValueTask<int> RunGitHubAsync(
        IReadOnlyList<string> args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        GitHubCommand? command = GitHubCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        try
        {
            string printed = await this.ReadGitHubAsync(command: command, cancellationToken: cancellationToken);
            await output.WriteAsync(printed.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return ExitCodes.Success;
        }
        catch (GitHubReadException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private async ValueTask<int> RunDiscoveryAsync(
        IReadOnlyList<string> args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        DiscoveryCommand? command = DiscoveryCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        try
        {
            DiscoveryOutcome outcome = await this._discovery.RunAsync(
                command: command,
                cancellationToken: cancellationToken
            );
            await output.WriteAsync(outcome.Printed.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            if (outcome.Problem is not null)
            {
                await error.WriteLineAsync($"{PROGRAM}: {outcome.Problem}".AsMemory(), cancellationToken);
            }

            return outcome.ExitCode;
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    // Each prints what the gh call it replaces prints: gh's --jq output ends every value with a newline
    private ValueTask<string> ReadGitHubAsync(GitHubCommand command, CancellationToken cancellationToken)
    {
        return command.Read switch
        {
            GitHubRead.BRANCH_REQUIRES_STATUS_CHECKS => this.BranchRequiresStatusChecksAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            GitHubRead.OWN_OPEN_PULL_REQUESTS => this.OwnOpenPullRequestsAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            GitHubRead.CURRENT_LOGIN => this.CurrentLoginAsync(cancellationToken),
            GitHubRead.OPEN_PULL_REQUESTS_WITH_CLOSING_ISSUES => this.OpenPullRequestsWithClosingIssuesAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            GitHubRead.PULL_REQUEST_COMMIT_AUTHORS => this.PullRequestCommitAuthorsAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            GitHubRead.BRANCH_BEHIND_BY => this.BranchBehindByAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            _ => this.OpenPullRequestsOnHeadAsync(command: command, cancellationToken: cancellationToken),
        };
    }

    private async ValueTask<string> BranchRequiresStatusChecksAsync(
        GitHubCommand command,
        CancellationToken cancellationToken
    )
    {
        bool required = await this._github.BranchRequiresStatusChecksAsync(
            repository: command.Repository,
            branch: command.Name,
            cancellationToken: cancellationToken
        );

        return required ? "true\n" : "false\n";
    }

    private async ValueTask<string> OwnOpenPullRequestsAsync(GitHubCommand command, CancellationToken cancellationToken)
    {
        IReadOnlyList<int> numbers = await this._github.OwnOpenPullRequestsAsync(
            repository: command.Repository,
            me: command.Name,
            creator: command.Creator ?? string.Empty,
            includeBlocked: command.IncludeBlocked,
            cancellationToken: cancellationToken
        );

        return string.Concat(numbers.Select(Line));
    }

    private async ValueTask<string> OpenPullRequestsOnHeadAsync(
        GitHubCommand command,
        CancellationToken cancellationToken
    )
    {
        IReadOnlyList<int> numbers = await this._github.OpenPullRequestsOnHeadAsync(
            repository: command.Repository,
            head: command.Name,
            cancellationToken: cancellationToken
        );

        return command.Read == GitHubRead.OPEN_PULL_REQUEST_COUNT
            ? Line(numbers.Count)
            : string.Concat(numbers.Select(Line));
    }

    private async ValueTask<string> CurrentLoginAsync(CancellationToken cancellationToken)
    {
        string login = await this._github.CurrentLoginAsync(cancellationToken);

        return login + "\n";
    }

    private async ValueTask<string> OpenPullRequestsWithClosingIssuesAsync(
        GitHubCommand command,
        CancellationToken cancellationToken
    )
    {
        IReadOnlyList<OpenPullRequestReferences> pullRequests =
            await this._github.OpenPullRequestsWithClosingIssuesAsync(
                repository: command.Repository,
                cancellationToken: cancellationToken
            );

        return GitHubJsonOutput.OpenPullRequests(pullRequests);
    }

    private async ValueTask<string> PullRequestCommitAuthorsAsync(
        GitHubCommand command,
        CancellationToken cancellationToken
    )
    {
        IReadOnlyList<PullRequestCommit> commits = await this._github.PullRequestCommitsAsync(
            repository: command.Repository,
            pullRequest: command.PullRequest,
            cancellationToken: cancellationToken
        );

        return GitHubJsonOutput.Commits(commits);
    }

    private async ValueTask<string> BranchBehindByAsync(GitHubCommand command, CancellationToken cancellationToken)
    {
        int behindBy = await this._github.BranchBehindByAsync(
            repository: command.Repository,
            baseBranch: command.Base ?? string.Empty,
            headBranch: command.Name,
            cancellationToken: cancellationToken
        );

        return Line(behindBy);
    }

    private static string Line(int value)
    {
        return value.ToString(CultureInfo.InvariantCulture) + "\n";
    }

    private async ValueTask<string> FingerprintAsync(
        FingerprintCommand command,
        Stream input,
        CancellationToken cancellationToken
    )
    {
        string? trusted = await this.ReadOptionalAsync(path: command.TrustedFile, cancellationToken: cancellationToken);
        string json = await ReadAllAsync(input: input, cancellationToken: cancellationToken);

        if (command.Kind == FingerprintKind.ISSUE)
        {
            return this._fingerprints.Issue(
                issueJson: json,
                trustedLoginsJson: trusted,
                planApproved: command.PlanApproved,
                schemaVersion: command.SchemaVersion
            );
        }

        string? reviewComments = await this.ReadOptionalAsync(
            path: command.ReviewCommentsFile,
            cancellationToken: cancellationToken
        );

        return this._fingerprints.PullRequest(
            pullRequestJson: json,
            trustedLoginsJson: trusted,
            reviewCommentsJson: reviewComments,
            schemaVersion: command.SchemaVersion
        );
    }

    private async ValueTask<string?> ReadOptionalAsync(string? path, CancellationToken cancellationToken)
    {
        return path is null
            ? null
            : await this._files.ReadAllTextAsync(path: path, cancellationToken: cancellationToken);
    }

    private static async ValueTask<string> ReadAllAsync(Stream input, CancellationToken cancellationToken)
    {
        using MemoryStream buffer = new();
        await input.CopyToAsync(destination: buffer, cancellationToken: cancellationToken);

        return Utf8.GetString(buffer.ToArray());
    }

    private static bool IsHelp(string argument)
    {
        return StringComparer.Ordinal.Equals(x: argument, y: "--help")
            || StringComparer.Ordinal.Equals(x: argument, y: "-h");
    }

    private static async ValueTask<int> UsageAsync(
        TextWriter error,
        string problem,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
        await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

        return ExitCodes.Usage;
    }

    private static async ValueTask<int> FailAsync(TextWriter error, string message, CancellationToken cancellationToken)
    {
        await error.WriteLineAsync($"{PROGRAM}: {message}".AsMemory(), cancellationToken);

        return ExitCodes.Failure;
    }
}
