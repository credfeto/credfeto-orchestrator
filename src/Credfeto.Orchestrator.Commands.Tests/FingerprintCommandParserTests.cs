using System.Collections.Generic;
using Credfeto.Orchestrator.Fingerprints;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class FingerprintCommandParserTests : TestBase
{
    [Fact]
    public static void APullRequestCommandParsesEveryOption()
    {
        FingerprintCommand? command = FingerprintCommandParser.Parse(
            args:
            [
                "fingerprint",
                "pr",
                "--trusted-file",
                "t.json",
                "--review-comments-file",
                "rc.json",
                "--schema-version",
                "7",
            ],
            error: out string error
        );

        Assert.Equal(
            expected: new FingerprintCommand(
                Kind: FingerprintKind.PULL_REQUEST,
                TrustedFile: "t.json",
                ReviewCommentsFile: "rc.json",
                PlanApproved: null,
                SchemaVersion: 7
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Fact]
    public static void AnIssueCommandParsesEveryOption()
    {
        FingerprintCommand? command = FingerprintCommandParser.Parse(
            args: ["fingerprint", "issue", "--trusted-file", "t.json", "--plan-approved", "true"],
            error: out _
        );

        Assert.Equal(
            expected: new FingerprintCommand(
                Kind: FingerprintKind.ISSUE,
                TrustedFile: "t.json",
                ReviewCommentsFile: null,
                PlanApproved: "true",
                SchemaVersion: FingerprintSchema.Version
            ),
            actual: command
        );
    }

    [Fact]
    public static void AnEmptyPlanApprovalIsKept()
    {
        FingerprintCommand? command = FingerprintCommandParser.Parse(
            args: ["fingerprint", "issue", "--plan-approved", ""],
            error: out _
        );

        Assert.Equal(expected: string.Empty, actual: command?.PlanApproved);
    }

    public static TheoryData<string, IReadOnlyList<string>> InvalidCommands()
    {
        return new()
        {
            { "expected: fingerprint pr|issue [options]", [] },
            { "expected: fingerprint pr|issue [options]", ["fingerprint"] },
            { "expected: fingerprint pr|issue [options]", ["other", "pr"] },
            { "unknown fingerprint kind 'commit': expected pr or issue", ["fingerprint", "commit"] },
            { "unknown option '--nope'", ["fingerprint", "pr", "--nope", "x"] },
            { "unknown option '--plan-approved'", ["fingerprint", "pr", "--plan-approved", "true"] },
            {
                "unknown option '--review-comments-file'",
                ["fingerprint", "issue", "--review-comments-file", "rc.json"]
            },
            { "--trusted-file needs a value", ["fingerprint", "pr", "--trusted-file"] },
            { "--schema-version must be a positive integer, not '0'", ["fingerprint", "pr", "--schema-version", "0"] },
            {
                "--schema-version must be a positive integer, not 'two'",
                ["fingerprint", "issue", "--schema-version", "two"]
            },
        };
    }

    [Theory]
    [MemberData(nameof(InvalidCommands))]
    public static void InvalidCommandsAreRefused(string expected, IReadOnlyList<string> args)
    {
        FingerprintCommand? command = FingerprintCommandParser.Parse(args: args, error: out string error);

        Assert.Null(command);
        Assert.Equal(expected: expected, actual: error);
    }
}
