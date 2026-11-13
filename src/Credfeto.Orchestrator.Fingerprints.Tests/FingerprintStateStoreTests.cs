using System;
using System.Globalization;
using System.IO;
using System.Runtime.Versioning;
using System.Threading.Tasks;
using FunFair.Test.Common;
using FunFair.Test.Infrastructure.Mocks;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Credfeto.Orchestrator.Fingerprints.Tests;

public sealed class FingerprintStateStoreTests : LoggingFolderCleanupTestBase
{
    private const string ITEM = "42";
    private const int TIMEOUT_MINUTES = 60;
    private const string PENDING_CI =
        """{"headRefOid":"abc123","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":null}]}""";

    private readonly string _sessionDirectory;
    private readonly FakeTimeProvider _timeProvider;
    private readonly IFingerprintStateStore _store;

    public FingerprintStateStoreTests(ITestOutputHelper output)
        : base(output)
    {
        this._sessionDirectory = Path.Combine(path1: this.TempFolder, path2: "sessions");
        this._timeProvider = new(MockDateTimeSources.Past.GetUtcNow());
        this._store = new FingerprintStateStore(
            sessionDirectory: this._sessionDirectory,
            timeProvider: this._timeProvider
        );
    }

    private long Now => this._timeProvider.GetUtcNow().ToUnixTimeSeconds();

    [Fact]
    public void PathsMatchTheShellFileNames()
    {
        Assert.Equal(
            expected: this._sessionDirectory + "/PullRequest_42.fingerprint",
            actual: this._store.PullRequestFingerprintPath(ITEM)
        );
        Assert.Equal(
            expected: this._sessionDirectory + "/Issue_42.fingerprint",
            actual: this._store.IssueFingerprintPath(ITEM)
        );
        Assert.Equal(
            expected: this._sessionDirectory + "/PullRequest_42.pending_ci",
            actual: this._store.PullRequestHeadOidPath(ITEM)
        );
        Assert.Equal(
            expected: this._sessionDirectory + "/PullRequest_42.unknown_merge_state",
            actual: this._store.PullRequestUnknownMergeStatePath(ITEM)
        );
        Assert.Equal(
            expected: this._sessionDirectory + "/PullRequest_42.last-agent-comment-seen",
            actual: this._store.PullRequestLastAgentCommentPath(ITEM)
        );
    }

    [Fact]
    public async Task MissingStateReadsAsEmptyAsync()
    {
        Assert.Equal(
            expected: string.Empty,
            actual: await this._store.LoadPullRequestFingerprintAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.Equal(
            expected: string.Empty,
            actual: await this._store.LoadIssueFingerprintAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.Equal(
            expected: string.Empty,
            actual: await this._store.LoadPullRequestHeadOidAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.Equal(
            expected: string.Empty,
            actual: await this._store.LoadPullRequestLastAgentCommentSeenAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task FingerprintsRoundTripAsLinesAsync()
    {
        await this._store.SavePullRequestFingerprintAsync(
            itemId: ITEM,
            fingerprint: "2:pr",
            cancellationToken: this.CancellationToken()
        );
        await this._store.SaveIssueFingerprintAsync(
            itemId: ITEM,
            fingerprint: "2:issue",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: "2:pr",
            actual: await this._store.LoadPullRequestFingerprintAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.Equal(
            expected: "2:issue",
            actual: await this._store.LoadIssueFingerprintAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.Equal(
            expected: "2:pr\n",
            actual: await File.ReadAllTextAsync(
                path: this._store.PullRequestFingerprintPath(ITEM),
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task HeadOidAndTimestampRoundTripAsync()
    {
        await this._store.SavePullRequestHeadOidAsync(
            itemId: ITEM,
            oid: "deadbeef",
            timestamp: 1_700_000_000,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: "deadbeef 1700000000",
            actual: await this._store.LoadPullRequestHeadOidAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task LastAgentCommentSeenRoundTripsAsync()
    {
        await this._store.SavePullRequestLastAgentCommentSeenAsync(
            itemId: ITEM,
            timestamp: "2026-08-12T10:05:07Z",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(
            expected: "2026-08-12T10:05:07Z",
            actual: await this._store.LoadPullRequestLastAgentCommentSeenAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task AStateFileThatIsNotAFileReadsAsEmptyAsync()
    {
        Directory.CreateDirectory(this._store.PullRequestFingerprintPath(ITEM));

        Assert.Equal(
            expected: string.Empty,
            actual: await this._store.LoadPullRequestFingerprintAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public void ClearingStateThatDoesNotExistSucceeds()
    {
        this._store.ClearPullRequestCiPendingState(ITEM);
        this._store.ClearPullRequestUnknownMergeState(ITEM);

        Assert.False(
            File.Exists(this._store.PullRequestHeadOidPath(ITEM)),
            userMessage: "No state file should be created"
        );
    }

    [Fact]
    public async Task CiChecksStartTheClockForANewHeadAsync()
    {
        bool timedOut = await this._store.CiChecksTimedOutAsync(
            itemId: ITEM,
            pullRequestJson: PENDING_CI,
            timeoutMinutes: TIMEOUT_MINUTES,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(timedOut, userMessage: "A head seen for the first time has not timed out");
        Assert.Equal(
            expected: Invariant($"abc123 {this.Now}"),
            actual: await this._store.LoadPullRequestHeadOidAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task CiChecksHaveNotTimedOutWithinTheTimeoutAsync()
    {
        await this._store.SavePullRequestHeadOidAsync(
            itemId: ITEM,
            oid: "abc123",
            timestamp: this.Now,
            cancellationToken: this.CancellationToken()
        );
        this._timeProvider.Advance(TimeSpan.FromMinutes(TIMEOUT_MINUTES - 1));

        Assert.False(
            await this._store.CiChecksTimedOutAsync(
                itemId: ITEM,
                pullRequestJson: PENDING_CI,
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "CI pending for less than the timeout has not timed out"
        );
    }

    [Fact]
    public async Task CiChecksTimeOutOnceTheTimeoutHasPassedAsync()
    {
        await this._store.SavePullRequestHeadOidAsync(
            itemId: ITEM,
            oid: "abc123",
            timestamp: this.Now - 7200,
            cancellationToken: this.CancellationToken()
        );

        Assert.True(
            await this._store.CiChecksTimedOutAsync(
                itemId: ITEM,
                pullRequestJson: PENDING_CI,
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "CI pending for two hours has timed out after an hour"
        );
    }

    [Fact]
    public async Task ANewHeadRestartsTheCiClockAsync()
    {
        await this._store.SavePullRequestHeadOidAsync(
            itemId: ITEM,
            oid: "old-oid",
            timestamp: this.Now - 7200,
            cancellationToken: this.CancellationToken()
        );

        bool timedOut = await this._store.CiChecksTimedOutAsync(
            itemId: ITEM,
            pullRequestJson: """{"headRefOid":"new-oid"}""",
            timeoutMinutes: TIMEOUT_MINUTES,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(timedOut, userMessage: "A new head restarts the clock");
        Assert.Equal(
            expected: Invariant($"new-oid {this.Now}"),
            actual: await this._store.LoadPullRequestHeadOidAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Theory]
    [InlineData("""{"statusCheckRollup":[]}""")]
    [InlineData("""{"headRefOid":null}""")]
    [InlineData("""{"headRefOid":""}""")]
    [InlineData("""not json""")]
    [InlineData("""[]""")]
    public async Task NoHeadMeansNoClockAsync(string pullRequestJson)
    {
        bool timedOut = await this._store.CiChecksTimedOutAsync(
            itemId: ITEM,
            pullRequestJson: pullRequestJson,
            timeoutMinutes: TIMEOUT_MINUTES,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(timedOut, userMessage: "Without a head there is nothing to time");
        Assert.False(
            File.Exists(this._store.PullRequestHeadOidPath(ITEM)),
            userMessage: "No state is written without a head"
        );
    }

    [Theory]
    [InlineData("abc123")]
    [InlineData("abc123 soon")]
    public async Task ACorruptCiStateFileRestartsTheClockAsync(string content)
    {
        await this.WriteStateAsync(path: this._store.PullRequestHeadOidPath(ITEM), content: content);

        bool timedOut = await this._store.CiChecksTimedOutAsync(
            itemId: ITEM,
            pullRequestJson: PENDING_CI,
            timeoutMinutes: TIMEOUT_MINUTES,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(timedOut, userMessage: "A corrupt state file restarts the clock");
        Assert.Equal(
            expected: Invariant($"abc123 {this.Now}"),
            actual: await this._store.LoadPullRequestHeadOidAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Theory]
    [InlineData("abc123 089", false)]
    [InlineData("abc123 01", true)]
    public async Task ALeadingZeroTimestampIsReadAsOctalAsInBashAsync(string content, bool expected)
    {
        await this.WriteStateAsync(path: this._store.PullRequestHeadOidPath(ITEM), content: content);

        bool timedOut = await this._store.CiChecksTimedOutAsync(
            itemId: ITEM,
            pullRequestJson: PENDING_CI,
            timeoutMinutes: TIMEOUT_MINUTES,
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: expected, actual: timedOut);
        Assert.Equal(
            expected: content,
            actual: await this._store.LoadPullRequestHeadOidAsync(
                itemId: ITEM,
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task ClearingCiStateRemovesTheFileAsync()
    {
        await this._store.SavePullRequestHeadOidAsync(
            itemId: ITEM,
            oid: "abc123",
            timestamp: this.Now,
            cancellationToken: this.CancellationToken()
        );

        this._store.ClearPullRequestCiPendingState(ITEM);

        Assert.False(
            File.Exists(this._store.PullRequestHeadOidPath(ITEM)),
            userMessage: "The CI state file is removed"
        );
    }

    [Fact]
    public async Task TheFirstUnknownMergeStateStartsTheClockAsync()
    {
        bool timedOut = await this._store.PullRequestUnknownMergeStateTimedOutAsync(
            itemId: ITEM,
            mergeState: "UNKNOWN",
            timeoutMinutes: TIMEOUT_MINUTES,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(timedOut, userMessage: "The first UNKNOWN only starts the clock");
        Assert.Equal(
            expected: Invariant($"{this.Now}\n"),
            actual: await File.ReadAllTextAsync(
                path: this._store.PullRequestUnknownMergeStatePath(ITEM),
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task AnUnknownMergeStateYoungerThanTheTimeoutHasNotTimedOutAsync()
    {
        await this._store.SavePullRequestUnknownMergeStateSinceAsync(
            itemId: ITEM,
            timestamp: this.Now - 60,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(
            await this._store.PullRequestUnknownMergeStateTimedOutAsync(
                itemId: ITEM,
                mergeState: "UNKNOWN",
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "A minute of UNKNOWN has not timed out"
        );
    }

    [Fact]
    public async Task AnUnknownMergeStateTimesOutOnceAndRestartsTheClockAsync()
    {
        long old = this.Now - 7200;
        await this._store.SavePullRequestUnknownMergeStateSinceAsync(
            itemId: ITEM,
            timestamp: old,
            cancellationToken: this.CancellationToken()
        );

        Assert.True(
            await this._store.PullRequestUnknownMergeStateTimedOutAsync(
                itemId: ITEM,
                mergeState: "UNKNOWN",
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "Two hours of UNKNOWN has timed out after an hour"
        );
        Assert.Equal(
            expected: Invariant($"{this.Now}\n"),
            actual: await File.ReadAllTextAsync(
                path: this._store.PullRequestUnknownMergeStatePath(ITEM),
                cancellationToken: this.CancellationToken()
            )
        );
        Assert.False(
            await this._store.PullRequestUnknownMergeStateTimedOutAsync(
                itemId: ITEM,
                mergeState: "UNKNOWN",
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "The restarted clock has not timed out yet"
        );
    }

    [Fact]
    public async Task AnyOtherMergeStateClearsTheClockAsync()
    {
        await this._store.SavePullRequestUnknownMergeStateSinceAsync(
            itemId: ITEM,
            timestamp: this.Now - 7200,
            cancellationToken: this.CancellationToken()
        );

        Assert.False(
            await this._store.PullRequestUnknownMergeStateTimedOutAsync(
                itemId: ITEM,
                mergeState: "CLEAN",
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "CLEAN is not UNKNOWN"
        );
        Assert.False(
            File.Exists(this._store.PullRequestUnknownMergeStatePath(ITEM)),
            userMessage: "The clock is cleared"
        );
    }

    [Theory]
    [InlineData("garbage")]
    [InlineData("")]
    public async Task AnUnreadableUnknownMergeStateRestartsTheClockAsync(string content)
    {
        await this.WriteStateAsync(path: this._store.PullRequestUnknownMergeStatePath(ITEM), content: content);

        Assert.False(
            await this._store.PullRequestUnknownMergeStateTimedOutAsync(
                itemId: ITEM,
                mergeState: "UNKNOWN",
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "An unreadable clock restarts"
        );
        Assert.Equal(
            expected: Invariant($"{this.Now}\n"),
            actual: await File.ReadAllTextAsync(
                path: this._store.PullRequestUnknownMergeStatePath(ITEM),
                cancellationToken: this.CancellationToken()
            )
        );
    }

    [Fact]
    public async Task AnOctalUnknownMergeStateThatBashCannotReadIsNotTimedOutAsync()
    {
        await this.WriteStateAsync(path: this._store.PullRequestUnknownMergeStatePath(ITEM), content: "089");

        Assert.False(
            await this._store.PullRequestUnknownMergeStateTimedOutAsync(
                itemId: ITEM,
                mergeState: "UNKNOWN",
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "bash cannot do arithmetic on 089"
        );
    }

    [Fact]
    [SupportedOSPlatform("linux")]
    public async Task AStateFileThatCannotBeReadReadsAsEmptyAsync()
    {
        await this._store.SavePullRequestFingerprintAsync(
            itemId: ITEM,
            fingerprint: "2:pr",
            cancellationToken: this.CancellationToken()
        );
        File.SetUnixFileMode(path: this._store.PullRequestFingerprintPath(ITEM), mode: UnixFileMode.None);

        try
        {
            Assert.Equal(
                expected: string.Empty,
                actual: await this._store.LoadPullRequestFingerprintAsync(
                    itemId: ITEM,
                    cancellationToken: this.CancellationToken()
                )
            );
        }
        finally
        {
            File.SetUnixFileMode(
                path: this._store.PullRequestFingerprintPath(ITEM),
                mode: UnixFileMode.UserRead | UnixFileMode.UserWrite
            );
        }
    }

    [Fact]
    [SupportedOSPlatform("linux")]
    public async Task AStateFileThatCannotBeRemovedIsLeftQuietlyAsync()
    {
        await this._store.SavePullRequestHeadOidAsync(
            itemId: ITEM,
            oid: "abc123",
            timestamp: this.Now,
            cancellationToken: this.CancellationToken()
        );
        UnixFileMode original = File.GetUnixFileMode(this._sessionDirectory);
        File.SetUnixFileMode(path: this._sessionDirectory, mode: UnixFileMode.UserRead | UnixFileMode.UserExecute);

        try
        {
            this._store.ClearPullRequestCiPendingState(ITEM);

            Assert.True(
                File.Exists(this._store.PullRequestHeadOidPath(ITEM)),
                userMessage: "The file stays when its directory is read-only"
            );
        }
        finally
        {
            File.SetUnixFileMode(path: this._sessionDirectory, mode: original);
        }
    }

    [Fact]
    public async Task AnOctalTimestampTooLargeForBashIsNotTimedOutAsync()
    {
        await this.WriteStateAsync(
            path: this._store.PullRequestHeadOidPath(ITEM),
            content: "abc123 07777777777777777777777"
        );

        Assert.False(
            await this._store.CiChecksTimedOutAsync(
                itemId: ITEM,
                pullRequestJson: PENDING_CI,
                timeoutMinutes: TIMEOUT_MINUTES,
                cancellationToken: this.CancellationToken()
            ),
            userMessage: "An octal value that overflows is not a usable timestamp"
        );
    }

    private Task WriteStateAsync(string path, string content)
    {
        Directory.CreateDirectory(this._sessionDirectory);

        return File.WriteAllTextAsync(
            path: path,
            contents: content + "\n",
            cancellationToken: this.CancellationToken()
        );
    }

    private static string Invariant(FormattableString text)
    {
        return text.ToString(CultureInfo.InvariantCulture);
    }
}
