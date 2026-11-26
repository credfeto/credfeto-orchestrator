using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Podman.Tests;

// The cases the fixture cannot hold: files that are not there or cannot be read, and names that are not UTF-8. Every
// one is refused, so bash runs jq, which prints nothing and exits 2.
public sealed class ClaudeResultQueriesTests : TestBase
{
    [Fact]
    public async Task AMissingFileIsRefusedAsync()
    {
        using ResultFiles files = new();

        PodmanRefusedException refused = await Assert.ThrowsAsync<PodmanRefusedException>(() =>
            new ClaudeResultQueries()
                .DenialsSummaryAsync(
                    resultFile: Path.Combine(path1: files.Directory, path2: "missing.json"),
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.StartsWith(
            expectedStartString: "cannot read the result file: ",
            actualString: refused.Message,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task ADirectoryIsRefusedAsync()
    {
        using ResultFiles files = new();

        await Assert.ThrowsAsync<PodmanRefusedException>(() =>
            new ClaudeResultQueries()
                .DeniedCommandNamesAsync(resultFile: files.Directory, cancellationToken: this.CancellationToken())
                .AsTask()
        );
    }

    [Theory]
    [InlineData("result\uFFFD.json")]
    [InlineData("result\0.json")]
    public async Task ANameThatIsNotUtf8IsRefusedAsync(string name)
    {
        using ResultFiles files = new();

        PodmanRefusedException refused = await Assert.ThrowsAsync<PodmanRefusedException>(() =>
            new ClaudeResultQueries()
                .DeniedCommandNamesAsync(
                    resultFile: Path.Combine(path1: files.Directory, path2: name),
                    cancellationToken: this.CancellationToken()
                )
                .AsTask()
        );

        Assert.Equal(
            expected: "the result file name is not valid UTF-8, so the tool cannot open the file bash would",
            actual: refused.Message
        );
    }

    [Fact]
    public async Task TheAnswerIsUtf8Async()
    {
        using ResultFiles files = new();
        string resultFile = await files.WriteAsync(
            content: Encoding.UTF8.GetBytes("""{"permission_denials":[{"tool_name":"Réad","tool_input":"x"}]}"""),
            cancellationToken: this.CancellationToken()
        );

        PodmanResult result = await new ClaudeResultQueries().DenialsSummaryAsync(
            resultFile: resultFile,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: 0, actual: result.ExitCode);
        Assert.Equal(expected: "2D2052C3A961643A20780A", actual: Convert.ToHexString(result.Output.Span));
    }
}
