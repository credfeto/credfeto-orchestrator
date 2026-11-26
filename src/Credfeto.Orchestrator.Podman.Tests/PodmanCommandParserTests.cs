using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

public sealed class PodmanCommandParserTests : TestBase
{
    [Theory]
    [InlineData("podman|image-sha|--image|img:latest", PodmanQuery.IMAGE_SHA, "img:latest")]
    [InlineData("podman|container-exists|--name|orchestrator-org", PodmanQuery.CONTAINER_EXISTS, "orchestrator-org")]
    [InlineData("podman|container-running|--name|a name", PodmanQuery.CONTAINER_RUNNING, "a name")]
    [InlineData("podman|image-exists|--image|--image", PodmanQuery.IMAGE_EXISTS, "--image")]
    [InlineData("podman|image-exists|--image|", PodmanQuery.IMAGE_EXISTS, "")]
    [InlineData("podman|denials-summary|--result|/tmp/r.json", PodmanQuery.DENIALS_SUMMARY, "/tmp/r.json")]
    [InlineData("podman|denied-command-names|--result|r", PodmanQuery.DENIED_COMMAND_NAMES, "r")]
    public static void EachQueryTakesItsOneOption(string args, PodmanQuery query, string argument)
    {
        PodmanCommand? command = PodmanCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Equal(expected: new PodmanCommand(Query: query, Argument: argument), actual: command);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("podman", "expected: podman <query> <option> <value>")]
    [InlineData("git|head-sha", "expected: podman <query> <option> <value>")]
    [InlineData("podman|pull|--image|img", "unknown podman query 'pull'")]
    [InlineData("podman|image-sha", "podman image-sha needs --image <value>, and nothing else")]
    [InlineData("podman|image-sha|--image", "podman image-sha needs --image <value>, and nothing else")]
    [InlineData("podman|image-sha|--name|img", "podman image-sha needs --image <value>, and nothing else")]
    [InlineData("podman|container-exists|--image|c", "podman container-exists needs --name <value>, and nothing else")]
    [InlineData("podman|container-running|--name|c|--name|d", "podman container-running needs --name <value>")]
    [InlineData("podman|denials-summary|--name|r", "podman denials-summary needs --result <value>, and nothing else")]
    [InlineData("podman|denied-command-names", "podman denied-command-names needs --result <value>")]
    public static void AnythingElseIsAUsageError(string args, string expected)
    {
        PodmanCommand? command = PodmanCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(
            expectedStartString: expected,
            actualString: error,
            comparisonType: System.StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("podman|image-sha", true)]
    [InlineData("podman", true)]
    [InlineData("git|head-sha", false)]
    [InlineData("", false)]
    public static void TheVerbIsPodman(string args, bool expected)
    {
        Assert.Equal(expected: expected, actual: PodmanCommandParser.IsVerb(args.Length == 0 ? [] : args.Split('|')));
    }
}
