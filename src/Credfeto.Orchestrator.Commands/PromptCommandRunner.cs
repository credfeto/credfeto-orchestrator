using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Prompts;

namespace Credfeto.Orchestrator.Commands;

// credfeto-orchestrator prompt ...: builds what a lib/prompts function prints, from name=value records on stdin
public sealed class PromptCommandRunner
{
    // check-length: the prompt is longer than --max
    public const int TooLong = 3;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator prompt issue-claude-md|pr-claude-md|issue-launch|pr-launch|precheck-section
               credfeto-orchestrator prompt check-length --max <n>

        The kinds print exactly what build_issue_claude_md, build_pr_claude_md, build_issue_prompt,
        build_pr_prompt and build_precheck_section in lib/prompts print. Their inputs are name=value
        records on stdin, each ended by a NUL byte. check-length reads a prompt on stdin and prints its
        length as bash's ${#prompt} counts it in the caller's locale.

        Exit codes: 0 printed (check-length: no longer than --max); 1 the input cannot be built exactly
        (lib/prompts then builds it in bash); 2 a usage error; 3 check-length: longer than --max.
        """;

    private readonly Func<string, string?> _environment;

    public PromptCommandRunner(Func<string, string?> environment)
    {
        this._environment = environment;
    }

    public async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Stream input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        PromptCommand? command = PromptCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        try
        {
            byte[] stdin = await ReadAllAsync(input: input, cancellationToken: cancellationToken);

            return command.Kind == PromptKind.CHECK_LENGTH
                ? await this.CheckLengthAsync(
                    prompt: stdin,
                    maxLength: command.MaxLength,
                    output: output,
                    cancellationToken: cancellationToken
                )
                : await BuildAsync(
                    kind: command.Kind,
                    stdin: stdin,
                    output: output,
                    error: error,
                    cancellationToken: cancellationToken
                );
        }
        catch (DecoderFallbackException exception)
        {
            return await FailAsync(
                error: error,
                message: "the input is not valid UTF-8: " + exception.Message,
                cancellationToken: cancellationToken
            );
        }
        catch (PromptException exception)
        {
            return await FailAsync(error: error, message: exception.Message, cancellationToken: cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return ExitCodes.Cancelled;
        }
    }

    private async ValueTask<int> CheckLengthAsync(
        byte[] prompt,
        int maxLength,
        TextWriter output,
        CancellationToken cancellationToken
    )
    {
        int length = PromptLength.Count(text: prompt, utf8: PromptLength.IsUtf8Locale(this._environment));
        await WriteAsync(
            output: output,
            text: length.ToString(CultureInfo.InvariantCulture) + "\n",
            cancellationToken: cancellationToken
        );

        return length > maxLength ? TooLong : ExitCodes.Success;
    }

    private static async ValueTask<int> BuildAsync(
        PromptKind kind,
        byte[] stdin,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        PromptRecords? records = PromptRecords.Parse(input: stdin, names: Names(kind), problem: out string problem);

        if (records is null)
        {
            return await UsageAsync(error: error, problem: problem, cancellationToken: cancellationToken);
        }

        IPromptBuilder builder = new PromptBuilder(await PromptTemplateSet.LoadAsync(cancellationToken));
        await WriteAsync(
            output: output,
            text: Build(builder: builder, kind: kind, records: records),
            cancellationToken: cancellationToken
        );

        return ExitCodes.Success;
    }

    private static string Build(IPromptBuilder builder, PromptKind kind, PromptRecords records)
    {
        return kind switch
        {
            PromptKind.ISSUE_CLAUDE_MD => builder.IssueClaudeMd(PromptRequests.Issue(records)),
            PromptKind.PULL_REQUEST_CLAUDE_MD => builder.PullRequestClaudeMd(PromptRequests.PullRequest(records)),
            PromptKind.ISSUE_LAUNCH => builder.IssueLaunchPrompt(PromptRequests.Launch(records)),
            PromptKind.PULL_REQUEST_LAUNCH => builder.PullRequestLaunchPrompt(PromptRequests.Launch(records)),
            _ => builder.PrecheckSection(PromptRequests.Precheck(records)),
        };
    }

    private static IReadOnlyList<string> Names(PromptKind kind)
    {
        return kind switch
        {
            PromptKind.ISSUE_CLAUDE_MD => PromptRecordNames.IssueClaudeMd,
            PromptKind.PULL_REQUEST_CLAUDE_MD => PromptRecordNames.PullRequestClaudeMd,
            PromptKind.ISSUE_LAUNCH or PromptKind.PULL_REQUEST_LAUNCH => PromptRecordNames.Launch,
            _ => PromptRecordNames.PrecheckSection,
        };
    }

    private static async ValueTask WriteAsync(TextWriter output, string text, CancellationToken cancellationToken)
    {
        await output.WriteAsync(text.AsMemory(), cancellationToken);
        await output.FlushAsync(cancellationToken);
    }

    private static async ValueTask<byte[]> ReadAllAsync(Stream input, CancellationToken cancellationToken)
    {
        using MemoryStream buffer = new();
        await input.CopyToAsync(destination: buffer, cancellationToken: cancellationToken);

        return buffer.ToArray();
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
