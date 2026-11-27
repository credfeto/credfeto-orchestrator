using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Agents;
using Credfeto.Orchestrator.Commands;
using Credfeto.Orchestrator.Discord;
using Credfeto.Orchestrator.Podman;
using Credfeto.Orchestrator.Predicates;
using Credfeto.Orchestrator.State;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Install.Tests;

public sealed partial class ToolCapabilitiesTests : TestBase
{
    private const string REGENERATE =
        "src/Credfeto.Orchestrator.Install/capabilities.txt is what oneshot reads as this checkout's list: "
        + "regenerate it with `dotnet run --project src/Credfeto.Orchestrator.Cmd -- --capabilities "
        + "> src/Credfeto.Orchestrator.Install/capabilities.txt`";

    [Fact]
    public async Task TheCommittedListIsThisBuildsListAsync()
    {
        await using Stream? stream = typeof(ToolCapabilitiesTests).Assembly.GetManifestResourceStream(
            "capabilities.txt"
        );
        Assert.NotNull(stream);
        using StreamReader reader = new(stream);
        string committed = await reader.ReadToEndAsync(this.CancellationToken());

        Assert.True(
            StringComparer.Ordinal.Equals(x: committed, y: ToolCapabilities.Text),
            userMessage: REGENERATE
                + "; differs at line "
                + FirstDifference(committed).ToString(CultureInfo.InvariantCulture)
        );
    }

    [Fact]
    public static void TheLinesAreSortedUniqueVerbAndCommandWords()
    {
        IReadOnlyList<string> lines = ToolCapabilities.Lines;

        Assert.NotEmpty(lines);
        Assert.Equal(expected: lines.Order(StringComparer.Ordinal), actual: lines, comparer: StringComparer.Ordinal);
        Assert.Equal(expected: lines.Count, actual: lines.Distinct(StringComparer.Ordinal).Count());
        Assert.All(collection: lines, action: line => Assert.Matches(expectedRegex: LinePattern(), actualString: line));
    }

    [Fact]
    public static void EveryParserIsListed()
    {
        string[] verbs =
        [
            .. ToolCapabilities
                .Lines.Select(line => line[..line.IndexOf(value: ' ', comparisonType: StringComparison.Ordinal)])
                .Distinct(StringComparer.Ordinal),
        ];

        Assert.Equal(
            expected: "agent|checks|discord|discovery|fingerprint|git|github|podman|predicate|prompt|state".Split('|'),
            actual: verbs
        );
    }

    [Fact]
    public static void EveryLineIsACommandItsParserKnows()
    {
        Assert.All(collection: ToolCapabilities.Lines, action: line =>
        {
            string error = ParseError(line.Split(' '));

            Assert.False(
                condition: error.StartsWith(value: "unknown", comparisonType: StringComparison.Ordinal),
                userMessage: line + ": " + error
            );
        });
    }

    [Theory]
    [InlineData("discord payload work-item")]
    [InlineData("discord truncate")]
    [InlineData("podman denials-summary")]
    [InlineData("podman background-stall")]
    [InlineData("podman clean-review")]
    [InlineData("podman diagnostic-refusal")]
    [InlineData("podman review-result-marker")]
    [InlineData("podman tool-denied-quit")]
    public static void ACommandFromEachOfAVerbsParsersIsListed(string line)
    {
        Assert.Contains(expected: line, collection: ToolCapabilities.Lines, comparer: StringComparer.Ordinal);
    }

    [Theory]
    [InlineData("agent|no-such-command")]
    [InlineData("checks|no-such-command")]
    [InlineData("discord|payload|no-such-command")]
    [InlineData("discovery|no-such-command")]
    [InlineData("fingerprint|no-such-command")]
    [InlineData("git|no-such-command")]
    [InlineData("github|no-such-command")]
    [InlineData("podman|no-such-command")]
    [InlineData("predicate|no-such-command")]
    [InlineData("prompt|no-such-command")]
    [InlineData("state|no-such-command")]
    public static void AnUnlistedCommandIsUnknownToItsParser(string args)
    {
        Assert.StartsWith(
            expectedStartString: "unknown",
            actualString: ParseError(args.Split('|')),
            comparisonType: StringComparison.Ordinal
        );
    }

    // What the verb's parser says of the bare command: an "unknown ..." error for a name it does not take, a missing
    // option or nothing for one it does
    private static string ParseError(IReadOnlyList<string> args)
    {
        string error;

        switch (args[0])
        {
            case AgentCommandParser.Verb:
                _ = AgentCommandParser.Parse(args: args, error: out error);

                return error;
            case DiscordCommandParser.Verb when DiscordTextCommandParser.IsTextCommand(args):
                _ = DiscordTextCommandParser.Parse(args: args, error: out error);

                return error;
            case DiscordCommandParser.Verb:
                _ = DiscordCommandParser.Parse(args: args, error: out error);

                return error;
            case DiscoveryCommandParser.Verb:
                _ = DiscoveryCommandParser.Parse(args: args, error: out error);

                return error;
            case FingerprintCommandParser.Verb:
                _ = FingerprintCommandParser.Parse(args: args, error: out error);

                return error;
            case GitCommandParser.Verb:
                _ = GitCommandParser.Parse(args: args, error: out error);

                return error;
            case GitHubCommandParser.Verb:
                _ = GitHubCommandParser.Parse(args: args, error: out error);

                return error;
            default:
                return OtherParseError(args);
        }
    }

    private static string OtherParseError(IReadOnlyList<string> args)
    {
        string error;

        switch (args[0])
        {
            case ChecksCommandParser.Verb:
                _ = ChecksCommandParser.Parse(args: args, error: out error);

                return error;
            case PodmanCommandParser.Verb when PodmanTextCommandParser.IsQuery(args):
                _ = PodmanTextCommandParser.Parse(args: args, error: out error);

                return error;
            case PodmanCommandParser.Verb:
                _ = PodmanCommandParser.Parse(args: args, error: out error);

                return error;
            case PredicateCommandParser.Verb:
                _ = PredicateCommandParser.Parse(args: args, error: out error);

                return error;
            case PromptCommandParser.Verb:
                _ = PromptCommandParser.Parse(args: args, error: out error);

                return error;
            case StateCommandParser.Verb:
                _ = StateCommandParser.Parse(args: args, error: out error);

                return error;
            default:
                throw new InvalidOperationException("no parser for " + args[0]);
        }
    }

    private static int FirstDifference(string committed)
    {
        string[] expected = ToolCapabilities.Text.Split('\n');
        string[] actual = committed.Split('\n');
        int index = 0;

        while (
            index < expected.Length
            && index < actual.Length
            && StringComparer.Ordinal.Equals(x: expected[index], y: actual[index])
        )
        {
            ++index;
        }

        return index + 1;
    }

    [GeneratedRegex(
        pattern: "^[a-z]+( [a-z0-9]+(-[a-z0-9]+)*){1,2}$",
        options: RegexOptions.ExplicitCapture,
        matchTimeoutMilliseconds: 1000
    )]
    private static partial Regex LinePattern();
}
