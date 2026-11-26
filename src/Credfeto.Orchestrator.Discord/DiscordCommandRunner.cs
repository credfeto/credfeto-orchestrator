using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discord;

// credfeto-orchestrator discord payload ...: prints the webhook payload a lib/discord builder prints, byte for byte as
// jq --null-input prints it; posting it, and every dedup marker, stays in bash
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

        Exit codes: 0 printed; 2 a usage error; 3 the payload cannot be built exactly as bash would build it (an
        argument that is not UTF-8, a number that is not a plain JSON integer, a summary that is not compact JSON or
        that the jq program would fail on, or a message that takes too long to mask), so lib/discord builds it; 125
        the payload could not be written.
        """;

    public static async ValueTask<int> RunAsync(
        IReadOnlyList<string> args,
        TextWriter output,
        TextWriter error,
        CancellationToken cancellationToken
    )
    {
        DiscordCommand? command = DiscordCommandParser.Parse(args: args, error: out string problem);

        if (command is null)
        {
            await error.WriteLineAsync($"{PROGRAM}: {problem}".AsMemory(), cancellationToken);
            await error.WriteLineAsync(USAGE.AsMemory(), cancellationToken);

            return Usage;
        }

        try
        {
            string payload = JqFormatter.ToIndentedJson(DiscordPayloads.Build(command)) + "\n";
            await output.WriteAsync(payload.AsMemory(), cancellationToken);
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
