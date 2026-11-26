using System;
using System.Text;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

public sealed class ClaudeTextQueriesTests : TestBase
{
    private const string MENTION = "Bash( tool)? (is|are) denied";
    private const string GIVE_UP = "(cannot|can not) continue";
    private const string WORKAROUND = "(^|[^a-z])(pushed|completed)([^a-z]|$)";
    private const string NEGATED =
        "([a-z]n[^a-z ]{1,3}t|(^|[^a-z])(not|no))( yet)? (pushed|completed)"
        + "|(^|[^a-z])(nothing|no)( [a-z]+){0,3} (was|were) (pushed|completed)";

    [Theory]
    [InlineData("Bash is denied. I cannot continue.", 0)]
    [InlineData("Bash is denied. I cannot continue. I pushed it.", 1)]
    [InlineData("Bash is denied. I cannot continue. Nothing was pushed.", 0)]
    [InlineData("Bash is denied. I cannot continue. no pushed was pushed", 0)]
    [InlineData("Bash is denied. I cannot continue. Not pushed. I pushed.", 1)]
    [InlineData("Bash is denied.", 1)]
    [InlineData("I cannot continue.", 1)]
    public static void ToolDeniedQuitRemovesEachNegatedPhraseBeforeTheWorkaroundTest(string message, int status)
    {
        PodmanResult result = ClaudeTextQueries.Answer(
            command: Quit(locale: "C.UTF-8"),
            input: Encoding.ASCII.GetBytes(message + "\n")
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
        Assert.Equal(expected: 0, actual: result.Output.Length);
    }

    [Theory]
    [InlineData("REVIEW RESULT: CLEAN", "CLEAN")]
    [InlineData("done\n  review result: clean\t\r\n", "CLEAN")]
    [InlineData("done\n\vReview Result: Findings\f", "FINDINGS")]
    [InlineData("REVIEW RESULT: CLEAN\nREVIEW RESULT: FINDINGS", "FINDINGS")]
    [InlineData("The REVIEW RESULT: CLEAN line", "")]
    [InlineData("", "")]
    public static void TheMarkerIsAWholeLineWithSpaceAndCaseIgnored(string message, string expected)
    {
        PodmanResult result = ClaudeTextQueries.Answer(
            command: Marker(locale: "en_GB.UTF-8"),
            input: Encoding.ASCII.GetBytes(message + "\n")
        );

        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: expected, actual: Encoding.ASCII.GetString(result.Output.Span));
    }

    [Fact]
    public static void TheCLocaleTakesAnyByteAsOneCharacter()
    {
        byte[] input = [.. "Bash is deniedX. I cannot continue."u8, (byte)'\n'];
        input[14] = 0xFF;

        Assert.Equal(expected: 0, actual: ClaudeTextQueries.Answer(command: Quit(locale: "C"), input: input).ExitCode);
        Assert.Equal(
            expected: 0,
            actual: ClaudeTextQueries.Answer(command: Quit(locale: "POSIX"), input: input).ExitCode
        );
        Assert.Equal(expected: 0, actual: ClaudeTextQueries.Answer(command: Quit(locale: ""), input: input).ExitCode);
    }

    [Theory]
    [InlineData("C.UTF-8")]
    [InlineData("en_GB.UTF-8")]
    [InlineData("en_US.utf8")]
    public static void AMessageThatIsNotAsciiIsRefusedOutsideTheCLocale(string locale)
    {
        byte[] input = [.. "can\u2019t continue\n"u8];

        Assert.Throws<PodmanRefusedException>(() =>
            ClaudeTextQueries.Answer(command: Quit(locale: locale), input: input)
        );
    }

    [Theory]
    [InlineData("tr_TR.UTF-8", "tr_TR.UTF-8")]
    [InlineData("C", "et_EE.UTF-8")]
    [InlineData("en_GB.ISO-8859-1", "C")]
    [InlineData("en_GB", "en_GB")]
    [InlineData("en_gb.UTF-8", "C")]
    [InlineData("C.UTF-8@x", "C")]
    public static void AnotherLocaleIsRefused(string ctype, string collate)
    {
        PodmanTextCommand command = Parse(
            "podman",
            "background-stall",
            "--ctype",
            ctype,
            "--collate",
            collate,
            "--pattern",
            "x"
        );

        Assert.Throws<PodmanRefusedException>(() => ClaudeTextQueries.Answer(command: command, input: "x\n"u8));
    }

    [Theory]
    [InlineData("x")]
    [InlineData("")]
    [InlineData("x\0y\n")]
    public static void InputThatIsNotAHereStringOfABashValueIsRefused(string input)
    {
        Assert.Throws<PodmanRefusedException>(() =>
            ClaudeTextQueries.Answer(command: Quit(locale: "C"), input: Encoding.ASCII.GetBytes(input))
        );
    }

    [Theory]
    [InlineData("x*")]
    [InlineData(" ")]
    public static void ANegatedPatternThatWouldLoopForEverIsRefused(string negated)
    {
        PodmanTextCommand command = Parse(
            "podman",
            "tool-denied-quit",
            "--ctype",
            "C",
            "--collate",
            "C",
            "--mention",
            "denied",
            "--give-up",
            "continue",
            "--workaround",
            "pushed",
            "--negated",
            negated
        );

        Assert.Throws<PodmanRefusedException>(() =>
            ClaudeTextQueries.Answer(command: command, input: "denied, cannot continue x\n"u8)
        );
    }

    [Fact]
    public static void AMarkerThatIsNotPrintableAsciiIsRefused()
    {
        PodmanTextCommand command = Parse(
            "podman",
            "review-result-marker",
            "--ctype",
            "C",
            "--collate",
            "C",
            "--clean-marker",
            "a\tb",
            "--findings-marker",
            "c"
        );

        Assert.Throws<PodmanRefusedException>(() => ClaudeTextQueries.Answer(command: command, input: "x\n"u8));
    }

    [Theory]
    [InlineData("Code review: no findings.", 0)]
    [InlineData("Code review: no findings. Nothing was fixed.", 0)]
    [InlineData("Code review: no findings. I fixed one.", 1)]
    [InlineData("I fixed it.\nREVIEW RESULT: CLEAN", 0)]
    [InlineData("Code review: no findings.\nREVIEW RESULT: FINDINGS", 1)]
    [InlineData("All good.", 1)]
    [InlineData("", 1)]
    public static void CleanReviewTakesTheMarkerFirstThenThePatterns(string message, int status)
    {
        PodmanTextCommand command = Parse(
            "podman",
            "clean-review",
            "--ctype",
            "C.utf8",
            "--collate",
            "C.utf8",
            "--clean-marker",
            "REVIEW RESULT: CLEAN",
            "--findings-marker",
            "REVIEW RESULT: FINDINGS",
            "--clean",
            "review: no findings",
            "--findings",
            "(^|[^a-z])(fixed|pushed)([^a-z]|$)",
            "--negated",
            "(^|[^a-z])(nothing|no)( [a-z]+){0,3} (was|were) fixed"
        );

        PodmanResult result = ClaudeTextQueries.Answer(
            command: command,
            input: Encoding.ASCII.GetBytes(message + "\n")
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
    }

    private static PodmanTextCommand Quit(string locale)
    {
        return Parse(
            "podman",
            "tool-denied-quit",
            "--ctype",
            locale,
            "--collate",
            locale,
            "--mention",
            MENTION,
            "--give-up",
            GIVE_UP,
            "--workaround",
            WORKAROUND,
            "--negated",
            NEGATED
        );
    }

    private static PodmanTextCommand Marker(string locale)
    {
        return Parse(
            "podman",
            "review-result-marker",
            "--ctype",
            locale,
            "--collate",
            locale,
            "--clean-marker",
            "REVIEW RESULT: CLEAN",
            "--findings-marker",
            "REVIEW RESULT: FINDINGS"
        );
    }

    private static PodmanTextCommand Parse(params string[] args)
    {
        return PodmanTextCommandParser.Parse(args: args, error: out string error)
            ?? throw new InvalidOperationException(error);
    }
}
