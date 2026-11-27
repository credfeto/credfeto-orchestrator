using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

// Each case runs `checks <query>` as the shell function asks it (lib/github-status's _checks_tool_answers: the
// function's arguments as options, after its own defaults, and the JSON on stdin as a here-string), and expects what
// the shell function printed and returned, or, for a case the tool must refuse, exit 3
public sealed class ChecksParityTests : TestBase
{
    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return ChecksParityFixture.CaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task MatchesTheShellVersionAsync(int index, string name)
    {
        ChecksParityCase parity = await ChecksParityFixture.CaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );
        (string[] args, string input) = Request(parity);
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await ChecksCommandRunner.RunAsync(
            args: args,
            input: () => new MemoryStream(Encoding.UTF8.GetBytes(input + "\n")),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        if (parity.Refused)
        {
            Assert.Equal(
                expected: name + ": exit " + ChecksCommandRunner.Refused.ToString(CultureInfo.InvariantCulture),
                actual: name + ": exit " + exitCode.ToString(CultureInfo.InvariantCulture)
            );

            return;
        }

        Assert.Equal(
            expected: Describe(name: name, status: parity.Status, output: parity.Output),
            actual: Describe(name: name, status: FunctionStatus(parity: parity, exitCode: exitCode), output.ToString())
        );
    }

    // The query and options the shell function sends, and its stdin
    private static (string[] Args, string Input) Request(ChecksParityCase parity)
    {
        IReadOnlyList<string> args = parity.Arguments;

        return parity.Function switch
        {
            "pr_next_phase_for_board_status" => (
                [
                    "checks",
                    "next-phase",
                    "--board-status",
                    Raw(args: args, index: 0),
                    "--required-checks-unknown",
                    OrDefault(args: args, index: 2, fallback: "false"),
                ],
                Raw(args: args, index: 1)
            ),
            "pr_merge_state_allows_settled" => (
                ["checks", "merge-state-allows-settled", "--merge-state", Raw(args: args, index: 1)],
                Raw(args: args, index: 0)
            ),
            "pr_session_progress_reason" => (
                [
                    "checks",
                    "session-progress-reason",
                    "--pre-board",
                    Raw(args: args, index: 0),
                    "--post-board",
                    Raw(args: args, index: 1),
                    "--pre-comment-ts",
                    Raw(args: args, index: 2),
                    "--post-comment-ts",
                    Raw(args: args, index: 3),
                    "--pre-head",
                    Raw(args: args, index: 4),
                    "--post-head",
                    Raw(args: args, index: 5),
                ],
                string.Empty
            ),
            "pr_clean_review_status_comment" => (
                ["checks", "clean-review-comment", "--status", Raw(args: args, index: 0)],
                string.Empty
            ),
            "pr_json_has_blocked_label" or "issue_json_has_blocked_label" => (
                ["checks", "has-blocked-label"],
                Raw(args: args, index: 0)
            ),
            "priority_for_labels" => (["checks", "priority-for-labels"], Raw(args: args, index: 0)),
            _ => throw new InvalidOperationException("No .NET port for " + parity.Function),
        };
    }

    // The status the shell function returns for the tool's exit code
    private static int FunctionStatus(ChecksParityCase parity, int exitCode)
    {
        return
            exitCode == ChecksCommandRunner.No
            && StringComparer.Ordinal.Equals(x: parity.Function, y: "pr_next_phase_for_board_status")
            ? 2
            : exitCode;
    }

    // ${n:-fallback}
    private static string OrDefault(IReadOnlyList<string> args, int index, string fallback)
    {
        string value = Raw(args: args, index: index);

        return value.Length == 0 ? fallback : value;
    }

    private static string Raw(IReadOnlyList<string> args, int index)
    {
        return index < args.Count ? args[index] : string.Empty;
    }

    private static string Describe(string name, int status, string output)
    {
        return name
            + ": status "
            + status.ToString(CultureInfo.InvariantCulture)
            + ", output "
            + output
                .Replace(oldValue: "\n", newValue: "\\n", comparisonType: StringComparison.Ordinal)
                .Replace(oldValue: "\r", newValue: "\\r", comparisonType: StringComparison.Ordinal);
    }
}
