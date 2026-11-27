using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Credfeto.Orchestrator.Commands;

// prompt issue-claude-md|pr-claude-md|issue-launch|pr-launch|precheck-section
// prompt check-length --max <n>
public static class PromptCommandParser
{
    public const string Verb = "prompt";

    private const string MAX = "--max";

    // Every kind name Parse accepts; the tool's --capabilities lists them (Names)
    private static readonly IReadOnlyDictionary<string, PromptKind> ByName = new Dictionary<string, PromptKind>(
        StringComparer.Ordinal
    )
    {
        ["issue-claude-md"] = PromptKind.ISSUE_CLAUDE_MD,
        ["pr-claude-md"] = PromptKind.PULL_REQUEST_CLAUDE_MD,
        ["issue-launch"] = PromptKind.ISSUE_LAUNCH,
        ["pr-launch"] = PromptKind.PULL_REQUEST_LAUNCH,
        ["precheck-section"] = PromptKind.PRECHECK_SECTION,
        ["check-length"] = PromptKind.CHECK_LENGTH,
    };

    public static IReadOnlyList<string> Names { get; } = [.. ByName.Keys.Order(StringComparer.Ordinal)];

    public static bool IsVerb(IReadOnlyList<string> args)
    {
        return args.Count > 0 && StringComparer.Ordinal.Equals(x: args[0], y: Verb);
    }

    public static PromptCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = "expected: prompt <kind>";

            return null;
        }

        PromptKind? kind = ParseKind(args[1]);

        if (kind is null)
        {
            error =
                $"unknown prompt kind '{args[1]}': expected issue-claude-md, pr-claude-md, issue-launch, pr-launch, precheck-section or check-length";

            return null;
        }

        if (kind == PromptKind.CHECK_LENGTH)
        {
            return ParseMaxLength(args: args, error: out error);
        }

        if (args.Count != 2)
        {
            error = $"prompt {args[1]} takes no options: its inputs are name=value records on stdin";

            return null;
        }

        error = string.Empty;

        return new(Kind: kind.Value, MaxLength: 0);
    }

    private static PromptKind? ParseKind(string kind)
    {
        return ByName.TryGetValue(key: kind, value: out PromptKind value) ? value : null;
    }

    private static PromptCommand? ParseMaxLength(IReadOnlyList<string> args, out string error)
    {
        if (args.Count != 4 || !StringComparer.Ordinal.Equals(x: args[2], y: MAX))
        {
            error = $"prompt check-length needs {MAX} <n>";

            return null;
        }

        if (
            int.TryParse(
                s: args[3],
                style: NumberStyles.None,
                provider: CultureInfo.InvariantCulture,
                result: out int max
            )
        )
        {
            error = string.Empty;

            return new(Kind: PromptKind.CHECK_LENGTH, MaxLength: max);
        }

        error = $"{MAX} must be a non-negative integer, not '{args[3]}'";

        return null;
    }
}
