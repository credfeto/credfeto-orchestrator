using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

public sealed class PodmanCommandRunnerTests : TestBase
{
    private const string ENVIRONMENT = "inspect --format {{range .Config.Env}}{{println .}}{{end}} img";

    [Fact]
    public async Task TheAnswerIsWrittenByteForByteAndItsStatusReturnedAsync()
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: ENVIRONMENT,
            exitCode: 0,
            output: "PATH=/bin\nIMAGE_SHA_DEVELOPMENT_AGENT=café\n"
        );

        (int status, string output, string error) = await this.RunAsync(
            podman: podman,
            args: "podman|image-sha|--image|img"
        );

        Assert.Equal(expected: 0, actual: status);
        Assert.Equal(expected: "café", actual: output);
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("podman|container-exists|--name|c", "inspect c", 0, 0)]
    [InlineData("podman|container-exists|--name|c", "inspect c", 125, 1)]
    [InlineData("podman|container-running|--name|c", "inspect --format {{.State.Running}} c", 0, 1)]
    [InlineData("podman|image-exists|--image|img", "image exists img", 0, 0)]
    [InlineData("podman|image-exists|--image|img", "image exists img", 1, 1)]
    public async Task EachQueryRunsItsPodmanCommandAsync(string args, string command, int podmanStatus, int status)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(command: command, exitCode: podmanStatus, output: "");

        (int exitCode, string output, string _) = await this.RunAsync(podman: podman, args: args);

        Assert.Equal(expected: status, actual: exitCode);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.Equal(expected: [command], actual: podman.Ran);
    }

    [Fact]
    public async Task AUsageErrorPrintsTheUsageAsync()
    {
        (int status, string output, string error) = await this.RunAsync(podman: new(), args: "podman|image-sha");

        Assert.Equal(expected: PodmanCommandRunner.Usage, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: podman image-sha needs --image <value>",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator podman",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ARefusedQueryExitsThreeAsync()
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: ENVIRONMENT,
            exitCode: 0,
            output: Convert.FromHexString("6100")
        );

        (int status, string output, string error) = await this.RunAsync(
            podman: podman,
            args: "podman|image-sha|--image|img"
        );

        Assert.Equal(expected: PodmanCommandRunner.Refused, actual: status);
        Assert.Equal(expected: string.Empty, actual: output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: podman: podman printed a NUL byte",
            actualString: error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task APodmanThatCannotRunExits125Async()
    {
        FakePodmanRunner podman = new() { Failure = new PodmanException("podman could not be started: missing") };

        (int status, string _, string error) = await this.RunAsync(
            podman: podman,
            args: "podman|image-exists|--image|i"
        );

        Assert.Equal(expected: PodmanCommandRunner.Failed, actual: status);
        Assert.Equal(expected: "credfeto-orchestrator: podman: podman could not be started: missing\n", actual: error);
    }

    [Fact]
    public async Task AnAnswerThatCannotBeWrittenExits125Async()
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(command: "image exists i", exitCode: 0, output: "x");
        await using StringWriter error = new();
        await using FailingStream output = new();

        int status = await new PodmanCommandRunner(new PodmanQueries(podman)).RunAsync(
            args: ["podman", "image-exists", "--image", "i"],
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: PodmanCommandRunner.Failed, actual: status);
        Assert.Equal(expected: "credfeto-orchestrator: podman: broken pipe\n", actual: error.ToString());
    }

    [Fact]
    public async Task ACancelledQueryExits130Async()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();
        await using MemoryStream output = new();
        await using StringWriter error = new();

        int status = await new PodmanCommandRunner(new PodmanQueries(new FakePodmanRunner())).RunAsync(
            args: ["podman", "container-exists", "--name", "c"],
            output: output,
            error: error,
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: PodmanCommandRunner.Cancelled, actual: status);
    }

    private async Task<(int Status, string Output, string Error)> RunAsync(FakePodmanRunner podman, string args)
    {
        await using MemoryStream output = new();
        await using StringWriter error = new();

        int status = await new PodmanCommandRunner(new PodmanQueries(podman)).RunAsync(
            args: args.Split('|'),
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (status, Encoding.UTF8.GetString(output.ToArray()), error.ToString());
    }
}
