using System;
using System.Collections.Generic;
using System.Globalization;
using Credfeto.Orchestrator.Fingerprints;

namespace Credfeto.Orchestrator.Commands;

// fingerprint pr|issue [--trusted-file <file>] [--review-comments-file <file>] [--plan-approved <value>] [--schema-version <n>]
public static class FingerprintCommandParser
{
    public const string Verb = "fingerprint";

    private const string TRUSTED_FILE = "--trusted-file";
    private const string REVIEW_COMMENTS_FILE = "--review-comments-file";
    private const string PLAN_APPROVED = "--plan-approved";
    private const string SCHEMA_VERSION = "--schema-version";

    public static FingerprintCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        error = string.Empty;

        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = "expected: fingerprint pr|issue [options]";

            return null;
        }

        FingerprintKind? kind = ParseKind(args[1]);

        if (kind is null)
        {
            error = $"unknown fingerprint kind '{args[1]}': expected pr or issue";

            return null;
        }

        return ParseOptions(args: args, kind: kind.Value, error: out error);
    }

    private static FingerprintKind? ParseKind(string kind)
    {
        return kind switch
        {
            "pr" => FingerprintKind.PULL_REQUEST,
            "issue" => FingerprintKind.ISSUE,
            _ => null,
        };
    }

    private static FingerprintCommand? ParseOptions(IReadOnlyList<string> args, FingerprintKind kind, out string error)
    {
        error = string.Empty;
        FingerprintCommand command = new(
            Kind: kind,
            TrustedFile: null,
            ReviewCommentsFile: null,
            PlanApproved: null,
            SchemaVersion: FingerprintSchema.Version
        );

        for (int index = 2; index < args.Count; index += 2)
        {
            string option = args[index];

            if (index + 1 >= args.Count)
            {
                error = $"{option} needs a value";

                return null;
            }

            FingerprintCommand? updated = Apply(
                command: command,
                option: option,
                value: args[index + 1],
                error: out error
            );

            if (updated is null)
            {
                return null;
            }

            command = updated;
        }

        return command;
    }

    private static FingerprintCommand? Apply(FingerprintCommand command, string option, string value, out string error)
    {
        error = string.Empty;

        switch (option)
        {
            case TRUSTED_FILE:
                return command with { TrustedFile = value };
            case REVIEW_COMMENTS_FILE when command.Kind == FingerprintKind.PULL_REQUEST:
                return command with { ReviewCommentsFile = value };
            case PLAN_APPROVED when command.Kind == FingerprintKind.ISSUE:
                return command with { PlanApproved = value };
            case SCHEMA_VERSION:
                return ApplySchemaVersion(command: command, value: value, error: out error);
            default:
                error = $"unknown option '{option}'";

                return null;
        }
    }

    private static FingerprintCommand? ApplySchemaVersion(FingerprintCommand command, string value, out string error)
    {
        if (
            int.TryParse(
                s: value,
                style: NumberStyles.None,
                provider: CultureInfo.InvariantCulture,
                result: out int version
            )
            && version > 0
        )
        {
            error = string.Empty;

            return command with
            {
                SchemaVersion = version,
            };
        }

        error = $"{SCHEMA_VERSION} must be a positive integer, not '{value}'";

        return null;
    }
}
