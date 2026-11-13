using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class CommandRunnerTests : TestBase
{
    private const string PULL_REQUEST =
        """{"title":"T","body":"B","isDraft":false,"labels":[],"headRefOid":"abc","comments":[],"reviews":[],"statusCheckRollup":[]}""";
    private const string ISSUE =
        """{"title":"T","body":"B","state":"OPEN","labels":[],"comments":[],"assignees":[],"milestone":null}""";

    private readonly FakeFileContentReader _files;
    private readonly CommandRunner _runner;

    public CommandRunnerTests()
    {
        this._files = new();
        this._runner = new(fingerprints: new FingerprintCalculator(), files: this._files);
    }

    [Theory]
    [InlineData("--help")]
    [InlineData("-h")]
    public async Task HelpPrintsUsageAsync(string argument)
    {
        Result result = await this.RunAsync(input: string.Empty, argument);

        Assert.Equal(expected: ExitCodes.Success, actual: result.ExitCode);
        Assert.Contains(
            expectedSubstring: "Usage: credfeto-orchestrator fingerprint pr",
            actualString: result.Output,
            comparisonType: StringComparison.Ordinal
        );
        Assert.Equal(expected: string.Empty, actual: result.Error);
    }

    [Fact]
    public async Task AUsageErrorExitsTwoAsync()
    {
        Result result = await this.RunAsync(input: string.Empty, "fingerprint", "commit");

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: unknown fingerprint kind 'commit'",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task APullRequestFingerprintIsPrintedFromStdinAndFilesAsync()
    {
        this._files.Add(path: "t.json", content: "[\"owner\"]");
        this._files.Add(path: "rc.json", content: "[]");
        string expected = new FingerprintCalculator().PullRequest(
            pullRequestJson: PULL_REQUEST,
            trustedLoginsJson: "[\"owner\"]",
            reviewCommentsJson: "[]",
            schemaVersion: FingerprintSchema.Version
        );

        Result result = await this.RunAsync(
            input: PULL_REQUEST,
            "fingerprint",
            "pr",
            "--trusted-file",
            "t.json",
            "--review-comments-file",
            "rc.json"
        );

        Assert.Equal(expected: ExitCodes.Success, actual: result.ExitCode);
        Assert.Equal(expected: expected, actual: result.Output);
        Assert.Equal(expected: string.Empty, actual: result.Error);
        Assert.Equal(expected: ["t.json", "rc.json"], actual: this._files.Read, comparer: StringComparer.Ordinal);
    }

    [Fact]
    public async Task AnIssueFingerprintUsesThePlanApprovalAndSchemaVersionAsync()
    {
        Result result = await this.RunAsync(
            input: ISSUE,
            "fingerprint",
            "issue",
            "--plan-approved",
            "false",
            "--schema-version",
            "2"
        );

        Assert.Equal(expected: ExitCodes.Success, actual: result.ExitCode);
        Assert.Equal(
            expected: "2:36d5acf9d9297f831145e17ec71ce45fcbd20d60b9af5b25ef6773cacbdc5116",
            actual: result.Output
        );
        Assert.Empty(this._files.Read);
    }

    [Fact]
    public async Task InvalidJsonExitsOneWithNothingOnStdoutAsync()
    {
        Result result = await this.RunAsync(input: "not valid json", "fingerprint", "pr");

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: Invalid JSON",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task AnUnreadableFileExitsOneAsync()
    {
        this._files.Fail(path: "missing.json", exception: new FileNotFoundException("missing.json not found"));

        Result result = await this.RunAsync(input: ISSUE, "fingerprint", "issue", "--trusted-file", "missing.json");

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: "credfeto-orchestrator: missing.json not found", actual: result.Error.TrimEnd());
    }

    [Fact]
    public async Task AFileThatCannotBeOpenedExitsOneAsync()
    {
        this._files.Fail(path: "private.json", exception: new UnauthorizedAccessException("denied"));

        Result result = await this.RunAsync(input: ISSUE, "fingerprint", "issue", "--trusted-file", "private.json");

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: "credfeto-orchestrator: denied", actual: result.Error.TrimEnd());
    }

    [Fact]
    public async Task ACancelledCommandExitsWithTheSignalCodeAsync()
    {
        using CancellationTokenSource cancelled = new();
        await cancelled.CancelAsync();
        using MemoryStream input = new(Encoding.UTF8.GetBytes(ISSUE));
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await this._runner.RunAsync(
            args: ["fingerprint", "issue"],
            input: input,
            output: output,
            error: error,
            cancellationToken: cancelled.Token
        );

        Assert.Equal(expected: ExitCodes.Cancelled, actual: exitCode);
    }

    [Fact]
    public async Task TheRealFileReaderReadsAFileAsync()
    {
        string path = Path.GetTempFileName();

        try
        {
            await File.WriteAllTextAsync(
                path: path,
                contents: "[\"owner\"]",
                cancellationToken: this.CancellationToken()
            );

            string content = await new FileContentReader().ReadAllTextAsync(
                path: path,
                cancellationToken: this.CancellationToken()
            );

            Assert.Equal(expected: "[\"owner\"]", actual: content);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private async Task<Result> RunAsync(string input, params string[] args)
    {
        using MemoryStream stdin = new(Encoding.UTF8.GetBytes(input));
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await this._runner.RunAsync(
            args: args,
            input: stdin,
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return new(ExitCode: exitCode, Output: output.ToString(), Error: error.ToString());
    }
}
