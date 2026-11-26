using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// credfeto-orchestrator discord payload ...: prints the webhook payload a lib/discord builder prints, byte for byte as
// jq --null-input prints it; posting it, and every dedup marker, stays in bash. discord item-status, item-status-log,
// no-work-breakdown and truncate print what the lib/discord text function of that name prints.
public static class DiscordCommandRunner
{
    public const int Usage = 2;

    // The payload cannot be built exactly as bash would build it, so lib/discord builds it in bash
    public const int Refused = 3;

    // The payload could not be written
    public const int Failed = 125;

    // Stopped by SIGINT or SIGTERM
    public const int Cancelled = 130;

    private const string PROGRAM = "credfeto-orchestrator";

    private const string USAGE = """
        Usage: credfeto-orchestrator discord payload <kind> --<option> <value> ...
               credfeto-orchestrator discord item-status --type <t> --id <i> --repo <r> --reason <text>
               credfeto-orchestrator discord item-status-log < entries
               credfeto-orchestrator discord no-work-breakdown --default-repo <r> --length-unit <unit> < items
               credfeto-orchestrator discord truncate --max-length <n> < text

        Prints the Discord webhook payload the lib/discord builder of that kind prints, as jq prints it, given the
        values the builder hands to jq as options, each once:
          work-item                 --color --title --url --repository --type --priority --status --substatus
                                    --progress --overall
          no-work                   --title --description
          low-disk-space            --title --available --minimum
          host-health               --title --message
          slow-pull                 --title --duration --baseline
          item-error                --title --url --error
          board-conversion-failed   --title --step
          self-update-stale         --title --head-sha --behind
          priorities-unreachable    --title --url --attempts
          blocked-item              --title --url --repository --type --priority --substatus --reason
          blocked-issue-replanning  --title --url
          pr-needs-approval         --title --url --repository
          permission-denials        --title --url --summary
          rate-limited              --title --url --error --reset
          session-stalled           --repository --item --url --count --commands --message
          daily-digest              --owner --day --summary --previous
        --color, --available, --minimum, --duration, --baseline, --behind and --attempts are the builder's --argjson
        numbers; daily-digest's --summary and --previous are its --argjson JSON (null, or a summary as jq -c prints
        it); every other option is text. session-stalled masks tokens and path-like runs in --message as the jq
        program does, before cutting it.

        The text commands print what the lib/discord function prints: item-status the compact item-status object
        (record_item_status), item-status-log the entries on stdin as one compact array (serialize_item_status_log),
        no-work-breakdown the no-work notice's item lines for the items JSON on stdin (_build_no_work_item_breakdown,
        --default-repo being REPO_FULL and --length-unit characters or bytes, as bash's ${#var} counts in its locale)
        and truncate the text on stdin cut to --max-length code points with the truncation notice
        (truncate_for_display). Their stdin is what the function hands jq, followed by the one newline a here-string
        adds, which is dropped.

        Exit codes: 0 printed; 2 a usage error; 3 the text cannot be built exactly as bash would build it (an
        argument or input that is not UTF-8, a number that is not a plain JSON integer, JSON jq might read
        differently or would fail on, a summary that is not compact JSON or that the jq program would fail on, or a
        message that takes too long to mask), so lib/discord builds it; 125 the text could not be written.
        """;

    public static ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        return RunAsync(
            args: args,
            input: Console.OpenStandardInput,
            output: output,
            error: error,
            cancellationToken: cancellationToken
        );
    }

    public static async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        Func<Stream> input,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        try
        {
            (string? text, string problem) = DiscordTextCommandParser.IsTextCommand(args)
                ? await BuildTextAsync(args: args, input: input, cancellationToken: cancellationToken)
                : BuildPayload(args);

            if (text is null)
            {
                await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
                await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

                return Usage;
            }

            await output.WriteAsync(text.AsMemory(), cancellationToken);
            await output.FlushAsync(cancellationToken);

            return 0;
        }
        catch (DiscordRefusedException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Refused, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return Cancelled;
        }
        catch (IOException exception)
        {
            return await FailAsync(error: error, message: exception.Message, status: Failed, cancellationToken);
        }
    }

    // The payload as jq prints it, or no text and the usage problem
    private static (string? Text, string Problem) BuildPayload(IReadOnlyList<string> args)
    {
        DiscordCommand? command = DiscordCommandParser.Parse(args: args, error: out string problem);

        return command is null
            ? (null, problem)
            : (JqFormatter.ToIndentedJson(DiscordPayloads.Build(command)) + "\n", string.Empty);
    }

    // The text the function prints, reading stdin first for the commands that take it, or no text and the usage
    // problem
    private static async ValueTask<(string? Text, string Problem)> BuildTextAsync(
        IReadOnlyList<string> args,
        Func<Stream> input,
        CancellationToken cancellationToken
    )
    {
        DiscordTextCommand? command = DiscordTextCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            return (null, problem);
        }

        if (!command.ReadsInput)
        {
            return (DiscordTexts.Build(command: command, input: []), string.Empty);
        }

        await using Stream stream = input();
        await using MemoryStream buffer = new();
        await stream.CopyToAsync(destination: buffer, cancellationToken: cancellationToken);

        return (DiscordTexts.Build(command: command, input: buffer.ToArray()), string.Empty);
    }

    private static async ValueTask<int> FailAsync(
        TextWriter error,
        string message,
        int status,
        CancellationToken cancellationToken
    )
    {
        await error.WriteLineAsync($"{PROGRAM}: discord: {message}".AsMemory(), cancellationToken);

        return status;
    }
}
