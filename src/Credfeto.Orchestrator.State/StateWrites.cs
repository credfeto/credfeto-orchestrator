using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.State;

// The lib/state writes: each writes the bytes its shell function writes, to the file it writes, through
// StateFileWriter. Anything the tool cannot be sure to leave as bash would is refused, and bash writes it.
public static class StateWrites
{
    private const byte NEWLINE = (byte)'\n';

    public static bool Handles(StateQuery query)
    {
        return query
            is StateQuery.SAVE_INFRA_FAILURES
                or StateQuery.SAVE_INVOCATIONS
                or StateQuery.SAVE_ENV_UNBLOCK_ATTEMPTS
                or StateQuery.SAVE_RATE_LIMIT
                or StateQuery.SAVE_PRECHECK_RESULT
                or StateQuery.SAVE_LAST_DIAGNOSTIC;
    }

    // input is only read by save-last-diagnostic
    public static async ValueTask WriteAsync(StateCommand command, Stream input, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsLinux())
        {
            throw new StateRefusedException("the state files are only written on Linux");
        }

        (string path, byte[] content) =
            command.Query == StateQuery.SAVE_LAST_DIAGNOSTIC
                ? await LastDiagnosticAsync(command: command, input: input, cancellationToken: cancellationToken)
                : FileAndContent(command);

        await StateFileWriter.ReplaceAsync(
            path: path,
            content: content,
            replacement: command.Query == StateQuery.SAVE_PRECHECK_RESULT
                ? StateReplacement.MOVED
                : StateReplacement.IN_PLACE,
            cancellationToken: cancellationToken
        );
    }

    private static (string Path, byte[] Content) FileAndContent(StateCommand command)
    {
        return command.Query switch
        {
            // save_infra_failure_count: printf '%s\n' "${count}"
            StateQuery.SAVE_INFRA_FAILURES => (
                ItemFile(command: command, suffix: "infra-failures"),
                Line(command.Option(StateCommandParser.Count))
            ),

            // save_pr_invocation_counts / save_issue_invocation_counts: printf '%s %s\n' "${total}" "${idle}"
            StateQuery.SAVE_INVOCATIONS => (
                ItemFile(command: command, suffix: "invocations"),
                Line(command.Option(StateCommandParser.Total) + " " + command.Option(StateCommandParser.Idle))
            ),

            // save_env_unblock_attempts: printf '%s\n' "${total}"
            StateQuery.SAVE_ENV_UNBLOCK_ATTEMPTS => (
                StatePaths.EnvUnblockAttempts(
                    sessionDirectory: command.Option(StateCommandParser.SessionDirectory),
                    itemId: PathPart(command: command, name: StateCommandParser.ItemId)
                ),
                Line(command.Option(StateCommandParser.Total))
            ),

            // save_rate_limit: printf '%s\n' "${reset_unix}"
            StateQuery.SAVE_RATE_LIMIT => (
                StatePaths.RateLimit(
                    stateDirectory: command.Option(StateCommandParser.StateDirectory),
                    owner: PathPart(command: command, name: StateCommandParser.Owner)
                ),
                Line(command.Option(StateCommandParser.Reset))
            ),

            // save_precheck_result: printf '%s\n%s\n' "${sha}" "${status}"
            _ => (
                StatePaths.Precheck(
                    sessionDirectory: command.Option(StateCommandParser.SessionDirectory),
                    key: PathPart(command: command, name: StateCommandParser.Key)
                ),
                Line(command.Option(StateCommandParser.Sha) + "\n" + command.Option(StateCommandParser.Status))
            ),
        };
    }

    // save_last_diagnostic: printf '%s' "${diagnostic_text}", given as a here-string, which ends it with a newline
    private static async ValueTask<(string Path, byte[] Content)> LastDiagnosticAsync(
        StateCommand command,
        Stream input,
        CancellationToken cancellationToken
    )
    {
        await using MemoryStream text = new();
        await input.CopyToAsync(destination: text, cancellationToken: cancellationToken);

        if (text.Length == 0 || text.GetBuffer()[text.Length - 1] != NEWLINE)
        {
            throw new StateRefusedException("the text on stdin does not end with the newline a here-string adds");
        }

        return (ItemFile(command: command, suffix: "last-diagnostic"), text.GetBuffer()[..(int)(text.Length - 1)]);
    }

    private static string ItemFile(StateCommand command, string suffix)
    {
        return StatePaths.ItemFile(
            sessionDirectory: command.Option(StateCommandParser.SessionDirectory),
            itemType: PathPart(command: command, name: StateCommandParser.ItemType),
            itemId: PathPart(command: command, name: StateCommandParser.ItemId),
            suffix: suffix
        );
    }

    // A part of the file name with a slash in it names a file in another directory, which bash may have to make
    private static string PathPart(StateCommand command, string name)
    {
        string value = command.Option(name);

        return value.Contains('/', StringComparison.Ordinal)
            ? throw new StateRefusedException($"--{name} holds a slash")
            : value;
    }

    private static byte[] Line(string text)
    {
        return Encoding.UTF8.GetBytes(text + "\n");
    }
}
