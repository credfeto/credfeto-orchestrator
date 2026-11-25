using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.GitHub;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class PredicateCommandTests : TestBase
{
    private const string GREEN_ARMED =
        """{"isDraft":false,"autoMergeRequest":{"enabledAt":"t"},"statusCheckRollup":[{"name":"b","status":"COMPLETED","conclusion":"SUCCESS"}]}""";
    private const string PLAN_APPROVED =
        """{"comments":[{"author":{"login":"planner"},"body":"## Implementation Plan"},{"author":{"login":"owner"},"authorAssociation":"OWNER","body":"Approved"}]}""";
    private const string COMMENTED =
        """{"comments":[{"author":{"login":"owner"},"body":"hi","createdAt":"2026-01-02T00:00:00Z"}]}""";

    private readonly FakeFileContentReader _files;
    private readonly CommandRunner _runner;

    public PredicateCommandTests()
    {
        this._files = new();
        this._runner = new(
            fingerprints: new FingerprintCalculator(),
            files: this._files,
            github: new GitHubReader(new FakeMcpToolCaller(result: null, error: "not expected")),
            discovery: DiscoveryFakes.NotExpected(
                new GitHubReader(new FakeMcpToolCaller(result: null, error: "not expected"))
            )
        );
    }

    [Theory]
    [InlineData("pr-is-terminal", GREEN_ARMED, ExitCodes.Success, "true\n")]
    [InlineData("pr-is-terminal", """{"isDraft":true}""", ExitCodes.No, "false\n")]
    [InlineData("pr-has-only-passed-checks", GREEN_ARMED, ExitCodes.Success, "true\n")]
    [InlineData("pr-has-placeholder-file", """{"files":[{"path":".deleteme.now"}]}""", ExitCodes.Success, "true\n")]
    [InlineData("pr-has-failed-required-check", GREEN_ARMED, ExitCodes.No, "false\n")]
    [InlineData("pr-has-failed-check-of-unknown-requiredness", GREEN_ARMED, ExitCodes.No, "false\n")]
    [InlineData("pr-has-pending-ci-checks", """{"requiredChecksNotYetReported":true}""", ExitCodes.Success, "true\n")]
    [InlineData(
        "pr-has-unaddressed-review-request",
        """{"reviewDecision":"CHANGES_REQUESTED"}""",
        ExitCodes.Success,
        "true\n"
    )]
    [InlineData("pr-needs-review-approval", """{"reviewDecision":"APPROVED"}""", ExitCodes.No, "false\n")]
    [InlineData("issue-has-plan-comment", PLAN_APPROVED, ExitCodes.Success, "true\n")]
    [InlineData(
        "pr-env-block-image-sha",
        """{"comments":[{"body":"<!-- orchestrator:env-block image-sha=ab12 -->"}]}""",
        ExitCodes.Success,
        "ab12"
    )]
    [InlineData("pr-env-block-image-sha", """{"comments":[]}""", ExitCodes.No, "")]
    public async Task APredicateAnswersFromStdinAsync(string name, string input, int exitCode, string printed)
    {
        Result result = await this.RunAsync(input, "predicate", name);

        Assert.Equal(expected: new(ExitCode: exitCode, Output: printed, Error: string.Empty), actual: result);
    }

    [Fact]
    public async Task InputJqWouldFailOnExitsOneWithTheProblemAsync()
    {
        Result result = await this.RunAsync("""{"statusCheckRollup":"x"}""", "predicate", "pr-has-pending-ci-checks");

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: ",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task TerminalTakesTheReviewPipelineFinishedValueAsync()
    {
        const string notArmed = """{"isDraft":false,"autoMergeRequest":null}""";

        Result finished = await this.RunAsync(
            notArmed,
            "predicate",
            "pr-is-terminal",
            "--review-pipeline-finished",
            "true"
        );
        Result notFinished = await this.RunAsync(notArmed, "predicate", "pr-is-terminal");
        Result broken = await this.RunAsync(
            notArmed,
            "predicate",
            "pr-is-terminal",
            "--review-pipeline-finished",
            "yes"
        );

        Assert.Equal(expected: ExitCodes.Success, actual: finished.ExitCode);
        Assert.Equal(expected: ExitCodes.No, actual: notFinished.ExitCode);
        Assert.Equal(expected: ExitCodes.Failure, actual: broken.ExitCode);
    }

    [Fact]
    public async Task PlanApprovalReadsTheTrustedLoginsFileAsync()
    {
        this._files.Add(path: "trusted.json", content: """["Owner"]""");
        this._files.Add(path: "nobody.json", content: "[]");

        Result approved = await this.RunAsync(
            PLAN_APPROVED,
            "predicate",
            "issue-has-human-plan-approval",
            "--me",
            "steward-warden",
            "--trusted-file",
            "trusted.json"
        );
        Result untrusted = await this.RunAsync(
            PLAN_APPROVED,
            "predicate",
            "issue-has-human-plan-approval",
            "--trusted-file",
            "nobody.json"
        );
        Result nobodyByDefault = await this.RunAsync(PLAN_APPROVED, "predicate", "issue-has-human-plan-approval");
        Result itself = await this.RunAsync(
            PLAN_APPROVED,
            "predicate",
            "issue-has-human-plan-approval",
            "--me",
            "OWNER",
            "--trusted-file",
            "trusted.json"
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: "true\n", Error: string.Empty),
            actual: approved
        );
        Assert.Equal(expected: ExitCodes.No, actual: untrusted.ExitCode);
        Assert.Equal(expected: ExitCodes.No, actual: nobodyByDefault.ExitCode);
        Assert.Equal(expected: ExitCodes.No, actual: itself.ExitCode);
    }

    [Fact]
    public async Task TheLatestTrustedCommentTimestampReadsItsFilesAndDefaultsAsync()
    {
        this._files.Add(path: "trusted.json", content: """["owner"]""");
        this._files.Add(
            path: "review.json",
            content: """[{"user":{"login":"owner"},"updated_at":"2026-03-01T00:00:00Z"}]"""
        );
        this._files.Add(path: "issue.json", content: "[]");

        Result withFiles = await this.RunAsync(
            COMMENTED,
            "predicate",
            "pr-latest-trusted-comment-timestamp",
            "--trusted-file",
            "trusted.json",
            "--review-comments-file",
            "review.json",
            "--issue-comments-file",
            "issue.json"
        );
        Result defaults = await this.RunAsync(COMMENTED, "predicate", "pr-latest-trusted-comment-timestamp");
        Result excluded = await this.RunAsync(
            COMMENTED,
            "predicate",
            "pr-latest-trusted-comment-timestamp",
            "--exclude-login",
            "owner"
        );

        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: "2026-03-01T00:00:00Z", Error: string.Empty),
            actual: withFiles
        );
        Assert.Equal(expected: "2026-01-02T00:00:00Z", actual: defaults.Output);
        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: string.Empty, Error: string.Empty),
            actual: excluded
        );
    }

    [Fact]
    public async Task TheUnaddressedCommentsAreQuotedAndClippedAsync()
    {
        Result result = await this.RunAsync(
            COMMENTED,
            "predicate",
            "pr-unaddressed-trusted-comments",
            "--last-seen",
            "2026-01-01T00:00:00Z",
            "--per-comment-max",
            "1"
        );
        Result nothingNewer = await this.RunAsync(
            COMMENTED,
            "predicate",
            "pr-unaddressed-trusted-comments",
            "--last-seen",
            "2026-01-03T00:00:00Z",
            "--per-comment-max",
            "1"
        );

        Assert.Equal(
            expected: new(
                ExitCode: ExitCodes.Success,
                Output: "- owner (comment, 2026-01-02T00:00:00Z):\nh [truncated]",
                Error: string.Empty
            ),
            actual: result
        );
        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: string.Empty, Error: string.Empty),
            actual: nothingNewer
        );
    }

    [Fact]
    public async Task AFailedCommentReadExitsOneAsync()
    {
        this._files.Add(path: "bad.json", content: "nope");

        Result result = await this.RunAsync(
            COMMENTED,
            "predicate",
            "pr-latest-trusted-comment-timestamp",
            "--trusted-file",
            "bad.json"
        );

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
    }

    [Fact]
    public async Task AnnotationPrintsCompactJsonOrTheInputUnchangedAsync()
    {
        const string pullRequest = """{ "statusCheckRollup": [ {"name": "build"} ] }""";
        this._files.Add(path: "required.json", content: """["build"]""");

        Result annotated = await this.RunAsync(
            pullRequest,
            "predicate",
            "pr-annotate-required-checks",
            "--required-file",
            "required.json"
        );
        Result unchanged = await this.RunAsync(pullRequest, "predicate", "pr-annotate-required-checks");
        Result baseRequires = await this.RunAsync(
            pullRequest,
            "predicate",
            "pr-annotate-required-checks",
            "--base-requires-checks",
            "true",
            "--required-file",
            "required.json"
        );

        Assert.Equal(
            expected: "{\"statusCheckRollup\":[{\"name\":\"build\",\"isRequired\":true}]}\n",
            actual: annotated.Output
        );
        Assert.Equal(
            expected: new(ExitCode: ExitCodes.Success, Output: pullRequest, Error: string.Empty),
            actual: unchanged
        );
        Assert.Equal(expected: annotated.Output, actual: baseRequires.Output);
    }

    [Fact]
    public async Task TheLowestClosingIssueIsInTheRepositoryAsync()
    {
        const string pullRequest =
            """{"closingIssuesReferences":[{"number":9,"repository":{"owner":{"login":"Org"},"name":"Repo"}},{"number":4,"repository":{"owner":{"login":"other"},"name":"repo"}}]}""";

        Result found = await this.RunAsync(pullRequest, "predicate", "pr-lowest-closing-issue", "--repo", "org/repo");
        Result none = await this.RunAsync(pullRequest, "predicate", "pr-lowest-closing-issue", "--repo", "org/other");
        Result broken = await this.RunAsync(
            """{"closingIssuesReferences":"x"}""",
            "predicate",
            "pr-lowest-closing-issue",
            "--repo",
            "org/repo"
        );

        Assert.Equal(expected: new(ExitCode: ExitCodes.Success, Output: "9", Error: string.Empty), actual: found);
        Assert.Equal(expected: new(ExitCode: ExitCodes.No, Output: string.Empty, Error: string.Empty), actual: none);
        Assert.Equal(expected: ExitCodes.Failure, actual: broken.ExitCode);
    }

    [Fact]
    public async Task AMissingFileExitsOneAsync()
    {
        Result result = await this.RunAsync(
            PLAN_APPROVED,
            "predicate",
            "issue-has-human-plan-approval",
            "--trusted-file",
            "missing.json"
        );

        Assert.Equal(expected: ExitCodes.Failure, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.Contains(
            expectedSubstring: "Not found",
            actualString: result.Error,
            comparisonType: StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("predicate", "expected: predicate <name> [options]")]
    [InlineData("predicate|pr-is-green", "unknown predicate 'pr-is-green'")]
    [InlineData("predicate|pr-is-terminal|--me|x", "unknown option '--me'")]
    [InlineData("predicate|pr-is-terminal|--review-pipeline-finished", "--review-pipeline-finished needs a value")]
    [InlineData("predicate|pr-lowest-closing-issue", "pr-lowest-closing-issue needs --repo")]
    [InlineData("predicate|pr-unaddressed-trusted-comments", "pr-unaddressed-trusted-comments needs --per-comment-max")]
    [InlineData(
        "predicate|pr-unaddressed-trusted-comments|--per-comment-max|-1",
        "--per-comment-max must be a whole number, not '-1'"
    )]
    public async Task AUsageErrorExitsTwoAsync(string arguments, string problem)
    {
        Result result = await this.RunAsync(string.Empty, arguments.Split('|'));

        Assert.Equal(expected: ExitCodes.Usage, actual: result.ExitCode);
        Assert.Equal(expected: string.Empty, actual: result.Output);
        Assert.StartsWith(
            expectedStartString: "credfeto-orchestrator: " + problem + "\n",
            actualString: result.Error.Replace(
                oldValue: "\r\n",
                newValue: "\n",
                comparisonType: StringComparison.Ordinal
            ),
            comparisonType: StringComparison.Ordinal
        );
    }

    [Fact]
    public void EveryPredicateNameIsListed()
    {
        Assert.Equal(expected: Enum.GetValues<PredicateKind>().Length, actual: PredicateCommandParser.Names.Count);
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
