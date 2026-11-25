using System;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

public sealed class PodmanQueriesTests : TestBase
{
    private const string IMAGE = "ghcr.io/credfeto/development-agent:latest";
    private const string ENVIRONMENT = "inspect --format {{range .Config.Env}}{{println .}}{{end}} " + IMAGE;
    private const string RUNNING = "inspect --format {{.State.Running}} orchestrator-org";

    [Theory]
    [InlineData("PATH=/bin\nIMAGE_SHA_DEVELOPMENT_AGENT=abc\nHOME=/home\n", 0, "abc")]
    [InlineData("IMAGE_SHA_DEVELOPMENT_AGENT=abc", 0, "abc")]
    [InlineData("IMAGE_SHA_DEVELOPMENT_AGENT=a\nIMAGE_SHA_DEVELOPMENT_AGENT=b\n", 0, "a\nb")]
    [InlineData("IMAGE_SHA_DEVELOPMENT_AGENT=\nIMAGE_SHA_DEVELOPMENT_AGENT=b\n", 0, "\nb")]
    [InlineData("IMAGE_SHA_DEVELOPMENT_AGENT=a\nIMAGE_SHA_DEVELOPMENT_AGENT=\n\n", 0, "a")]
    [InlineData("IMAGE_SHA_DEVELOPMENT_AGENT=abc\r\n", 0, "abc\r")]
    [InlineData("IMAGE_SHA_DEVELOPMENT_AGENT=\n", 1, "")]
    [InlineData(" IMAGE_SHA_DEVELOPMENT_AGENT=abc\nXIMAGE_SHA_DEVELOPMENT_AGENT=abc\n", 1, "")]
    [InlineData("", 1, "")]
    public async Task ImageShaPrintsTheShaLinesAsSedDoesAsync(string environment, int status, string expected)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: ENVIRONMENT,
            exitCode: 0,
            output: environment
        );

        PodmanResult result = await new PodmanQueries(podman).ImageShaAsync(
            image: IMAGE,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
        Assert.Equal(expected: expected, actual: Encoding.UTF8.GetString(result.Output.Span));
        Assert.Equal(expected: [ENVIRONMENT], actual: podman.Ran);
    }

    [Fact]
    public async Task ImageShaIgnoresPodmansStatusAsync()
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: ENVIRONMENT,
            exitCode: 125,
            output: "IMAGE_SHA_DEVELOPMENT_AGENT=abc\n"
        );

        PodmanResult result = await new PodmanQueries(podman).ImageShaAsync(
            image: IMAGE,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: "abc", actual: Encoding.UTF8.GetString(result.Output.Span));
    }

    [Theory]
    [InlineData("494d4147455f5348415f444556454c4f504d454e545f4147454e543d61ff0a")]
    [InlineData("504154483dff0a494d4147455f5348415f444556454c4f504d454e545f4147454e543d610a")]
    [InlineData("504154483d00")]
    public Task ImageShaRefusesOutputThatIsNotUtf8OrHoldsANulAsync(string hex)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: ENVIRONMENT,
            exitCode: 0,
            output: Convert.FromHexString(hex)
        );

        return Assert.ThrowsAsync<PodmanRefusedException>(() =>
            new PodmanQueries(podman).ImageShaAsync(image: IMAGE, cancellationToken: this.CancellationToken()).AsTask()
        );
    }

    [Theory]
    [InlineData("bad\uFFFDname")]
    [InlineData("nul\0name")]
    public async Task AnArgumentBashCouldNotHaveSentIsRefusedBeforePodmanRunsAsync(string argument)
    {
        FakePodmanRunner podman = new();
        PodmanQueries queries = new(podman);

        await Assert.ThrowsAsync<PodmanRefusedException>(async () =>
            await queries.ImageShaAsync(image: argument, cancellationToken: this.CancellationToken())
        );
        await Assert.ThrowsAsync<PodmanRefusedException>(async () =>
            await queries.ContainerExistsAsync(name: argument, cancellationToken: this.CancellationToken())
        );
        await Assert.ThrowsAsync<PodmanRefusedException>(async () =>
            await queries.ContainerRunningAsync(name: argument, cancellationToken: this.CancellationToken())
        );
        await Assert.ThrowsAsync<PodmanRefusedException>(async () =>
            await queries.ImageExistsAsync(image: argument, cancellationToken: this.CancellationToken())
        );
        Assert.Empty(podman.Ran);
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(1, 1)]
    [InlineData(2, 1)]
    [InlineData(125, 1)]
    public async Task ContainerExistsIsPodmanInspectsSuccessAsync(int podmanStatus, int status)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: "inspect orchestrator-org",
            exitCode: podmanStatus,
            output: "[{}]\n"
        );

        PodmanResult result = await new PodmanQueries(podman).ContainerExistsAsync(
            name: "orchestrator-org",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
        Assert.Equal(expected: 0, actual: result.Output.Length);
    }

    [Theory]
    [InlineData("true\n", 0, 0)]
    [InlineData("true", 0, 0)]
    [InlineData("true\n\n", 0, 0)]
    [InlineData("true\n", 125, 0)]
    [InlineData("false\n", 0, 1)]
    [InlineData("True\n", 0, 1)]
    [InlineData("true\r\n", 0, 1)]
    [InlineData(" true\n", 0, 1)]
    [InlineData("true\ntrue\n", 0, 1)]
    [InlineData("", 125, 1)]
    public async Task ContainerRunningIsExactlyTrueAsync(string output, int podmanStatus, int status)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: RUNNING,
            exitCode: podmanStatus,
            output: output
        );

        PodmanResult result = await new PodmanQueries(podman).ContainerRunningAsync(
            name: "orchestrator-org",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
        Assert.Equal(expected: 0, actual: result.Output.Length);
    }

    [Fact]
    public async Task ContainerRunningTakesOutputThatIsNotUtf8ButRefusesANulAsync()
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: RUNNING,
            exitCode: 0,
            output: Convert.FromHexString("74727565ff0a")
        );
        PodmanQueries queries = new(podman);

        PodmanResult result = await queries.ContainerRunningAsync(
            name: "orchestrator-org",
            cancellationToken: this.CancellationToken()
        );
        podman.Returns(command: RUNNING, exitCode: 0, output: Convert.FromHexString("7472007565"));

        Assert.Equal(expected: 1, actual: result.ExitCode);
        await Assert.ThrowsAsync<PodmanRefusedException>(() =>
            queries
                .ContainerRunningAsync(name: "orchestrator-org", cancellationToken: this.CancellationToken())
                .AsTask()
        );
    }

    [Theory]
    [InlineData(0, "", 0)]
    [InlineData(1, "", 1)]
    [InlineData(125, "note\n\n", 1)]
    public async Task ImageExistsPassesPodmansOutputThroughAsync(int podmanStatus, string output, int status)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: "image exists " + IMAGE,
            exitCode: podmanStatus,
            output: output
        );

        PodmanResult result = await new PodmanQueries(podman).ImageExistsAsync(
            image: IMAGE,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: status, actual: result.ExitCode);
        Assert.Equal(expected: output, actual: Encoding.UTF8.GetString(result.Output.Span));
    }

    [Theory]
    [InlineData("61ff0a")]
    [InlineData("610062")]
    public Task ImageExistsRefusesOutputThatIsNotUtf8OrHoldsANulAsync(string hex)
    {
        FakePodmanRunner podman = new FakePodmanRunner().Returns(
            command: "image exists " + IMAGE,
            exitCode: 0,
            output: Convert.FromHexString(hex)
        );

        return Assert.ThrowsAsync<PodmanRefusedException>(() =>
            new PodmanQueries(podman)
                .ImageExistsAsync(image: IMAGE, cancellationToken: this.CancellationToken())
                .AsTask()
        );
    }
}
