using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Credfeto.Orchestrator.Predicates;

namespace Credfeto.Orchestrator.Commands;

// checks required-check-names --repo <owner/repo> --pr <number>
// checks has-running-check-runs --repo <owner/repo> --sha <commit>
// The checks reads that ask GitHub through the cfwf MCP server; the other checks queries answer from their arguments
// alone (ChecksCommandParser). Both options are required, once, in either order; --repo and --sha may be empty, as
// the shell function's arguments may be
public static class ChecksReadCommandParser
{
    public const string Verb = ChecksCommandParser.Verb;

    private const string REPO = "repo";
    private const string PR = "pr";
    private const string SHA = "sha";

    private const string READS = "required-check-names or has-running-check-runs";

    // Every read name Parse accepts; the tool's --capabilities lists them (Names)
    private static readonly IReadOnlyDictionary<string, ChecksRead> ByName = new Dictionary<string, ChecksRead>(
        StringComparer.Ordinal
    )
    {
        ["required-check-names"] = ChecksRead.REQUIRED_CHECK_NAMES,
        ["has-running-check-runs"] = ChecksRead.HAS_RUNNING_CHECK_RUNS,
    };

    public static IReadOnlyList<string> Names { get; } = [.. ByName.Keys.Order(StringComparer.Ordinal)];

    // Whether args name one of these reads, which the tool runs with its GitHub reader
    public static bool IsRead(IReadOnlyList<string> args)
    {
        return args.Count > 1 && ChecksCommandParser.IsVerb(args) && ByName.ContainsKey(args[1]);
    }

    public static ChecksReadCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (!IsRead(args))
        {
            error =
                $"expected: checks <read> --repo <owner/repo> --pr <number>|--sha <commit>, the read one of {READS}";

            return null;
        }

        ChecksRead read = ByName[args[1]];
        string other = read == ChecksRead.REQUIRED_CHECK_NAMES ? PR : SHA;
        Dictionary<string, string> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index + 1 < args.Count; index += 2)
        {
            string name = args[index].StartsWith("--", StringComparison.Ordinal) ? args[index][2..] : string.Empty;

            if (
                !(StringComparer.Ordinal.Equals(x: name, y: REPO) || StringComparer.Ordinal.Equals(x: name, y: other))
                || !options.TryAdd(key: name, value: args[index + 1])
            )
            {
                break;
            }
        }

        if (args.Count != 6 || options.Count != 2)
        {
            error = $"checks {args[1]} needs --{REPO} <owner/repo> and --{other} <value>, each once, and nothing else";

            return null;
        }

        return read == ChecksRead.REQUIRED_CHECK_NAMES
            ? PullRequestRead(read: read, options: options, error: out error)
            : Complete(new(Read: read, Repository: options[REPO], PullRequest: 0, Sha: options[SHA]), error: out error);
    }

    private static ChecksReadCommand? PullRequestRead(
        ChecksRead read,
        Dictionary<string, string> options,
        out string error
    )
    {
        if (
            !int.TryParse(
                s: options[PR],
                style: NumberStyles.None,
                provider: CultureInfo.InvariantCulture,
                result: out int pullRequest
            )
            || pullRequest <= 0
        )
        {
            error = $"checks required-check-names needs --{PR} to be a pull request number, not '{options[PR]}'";

            return null;
        }

        return Complete(
            new(Read: read, Repository: options[REPO], PullRequest: pullRequest, Sha: string.Empty),
            error: out error
        );
    }

    private static ChecksReadCommand Complete(ChecksReadCommand command, out string error)
    {
        error = string.Empty;

        return command;
    }
}
