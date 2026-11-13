using System;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Fingerprints;

// A port of the file-backed helpers in lib/fingerprints: the same file names, contents and
// clock rules, so the shell and the tool can share one session directory.
public sealed partial class FingerprintStateStore : IFingerprintStateStore
{
    private const int SECONDS_PER_MINUTE = 60;
    private const int OCTAL = 8;
    private const int MATCH_TIMEOUT_MILLISECONDS = 1000;
    private const string UNKNOWN_MERGE_STATE = "UNKNOWN";

    private readonly string _sessionDirectory;
    private readonly TimeProvider _timeProvider;

    public FingerprintStateStore(string sessionDirectory, TimeProvider timeProvider)
    {
        this._sessionDirectory = sessionDirectory;
        this._timeProvider = timeProvider;
    }

    public string PullRequestFingerprintPath(string itemId)
    {
        return this.PathFor($"PullRequest_{itemId}.fingerprint");
    }

    public string IssueFingerprintPath(string itemId)
    {
        return this.PathFor($"Issue_{itemId}.fingerprint");
    }

    public string PullRequestHeadOidPath(string itemId)
    {
        return this.PathFor($"PullRequest_{itemId}.pending_ci");
    }

    public string PullRequestUnknownMergeStatePath(string itemId)
    {
        return this.PathFor($"PullRequest_{itemId}.unknown_merge_state");
    }

    public string PullRequestLastAgentCommentPath(string itemId)
    {
        return this.PathFor($"PullRequest_{itemId}.last-agent-comment-seen");
    }

    public ValueTask SavePullRequestFingerprintAsync(
        string itemId,
        string fingerprint,
        CancellationToken cancellationToken
    )
    {
        return this.WriteLineAsync(
            path: this.PullRequestFingerprintPath(itemId),
            line: fingerprint,
            cancellationToken: cancellationToken
        );
    }

    public ValueTask<string> LoadPullRequestFingerprintAsync(string itemId, CancellationToken cancellationToken)
    {
        return ReadAsync(path: this.PullRequestFingerprintPath(itemId), cancellationToken: cancellationToken);
    }

    public ValueTask SaveIssueFingerprintAsync(string itemId, string fingerprint, CancellationToken cancellationToken)
    {
        return this.WriteLineAsync(
            path: this.IssueFingerprintPath(itemId),
            line: fingerprint,
            cancellationToken: cancellationToken
        );
    }

    public ValueTask<string> LoadIssueFingerprintAsync(string itemId, CancellationToken cancellationToken)
    {
        return ReadAsync(path: this.IssueFingerprintPath(itemId), cancellationToken: cancellationToken);
    }

    public ValueTask SavePullRequestHeadOidAsync(
        string itemId,
        string oid,
        long timestamp,
        CancellationToken cancellationToken
    )
    {
        return this.WriteLineAsync(
            path: this.PullRequestHeadOidPath(itemId),
            line: string.Create(provider: CultureInfo.InvariantCulture, $"{oid} {timestamp}"),
            cancellationToken: cancellationToken
        );
    }

    public ValueTask<string> LoadPullRequestHeadOidAsync(string itemId, CancellationToken cancellationToken)
    {
        return ReadAsync(path: this.PullRequestHeadOidPath(itemId), cancellationToken: cancellationToken);
    }

    // ci_checks_timed_out: true once CI for the current head has been pending for timeoutMinutes;
    // a new head (or an unreadable state file) restarts the clock
    public async ValueTask<bool> CiChecksTimedOutAsync(
        string itemId,
        string pullRequestJson,
        int timeoutMinutes,
        CancellationToken cancellationToken
    )
    {
        string currentOid = HeadRefOid(pullRequestJson);

        if (currentOid.Length == 0)
        {
            return false;
        }

        long now = this.Now();
        string savedState = await this.LoadPullRequestHeadOidAsync(
            itemId: itemId,
            cancellationToken: cancellationToken
        );

        int firstSpace = savedState.IndexOf(' ', StringComparison.Ordinal);
        string savedOid = firstSpace < 0 ? savedState : savedState[..firstSpace];
        string savedTimestamp = savedState[(savedState.AsSpan().LastIndexOf(' ') + 1)..];

        if (
            savedState.Length == 0
            || !StringComparer.Ordinal.Equals(x: currentOid, y: savedOid)
            || !TryParseTimestamp(text: savedTimestamp, out long? since)
        )
        {
            await this.SavePullRequestHeadOidAsync(
                itemId: itemId,
                oid: currentOid,
                timestamp: now,
                cancellationToken: cancellationToken
            );

            return false;
        }

        return since is not null && ElapsedMinutes(now: now, since: since.Value) >= timeoutMinutes;
    }

    public void ClearPullRequestCiPendingState(string itemId)
    {
        Delete(this.PullRequestHeadOidPath(itemId));
    }

    public ValueTask SavePullRequestUnknownMergeStateSinceAsync(
        string itemId,
        long timestamp,
        CancellationToken cancellationToken
    )
    {
        return this.WriteLineAsync(
            path: this.PullRequestUnknownMergeStatePath(itemId),
            line: timestamp.ToString(CultureInfo.InvariantCulture),
            cancellationToken: cancellationToken
        );
    }

    public void ClearPullRequestUnknownMergeState(string itemId)
    {
        Delete(this.PullRequestUnknownMergeStatePath(itemId));
    }

    // pr_unknown_merge_state_timed_out: any other merge state clears the clock, the first UNKNOWN
    // starts it, and reaching the timeout restarts it so the follow-up runs once per window
    public async ValueTask<bool> PullRequestUnknownMergeStateTimedOutAsync(
        string itemId,
        string mergeState,
        int timeoutMinutes,
        CancellationToken cancellationToken
    )
    {
        if (!StringComparer.Ordinal.Equals(x: mergeState, y: UNKNOWN_MERGE_STATE))
        {
            this.ClearPullRequestUnknownMergeState(itemId);

            return false;
        }

        long now = this.Now();
        string saved = await ReadAsync(
            path: this.PullRequestUnknownMergeStatePath(itemId),
            cancellationToken: cancellationToken
        );

        if (!TryParseTimestamp(text: saved, out long? since))
        {
            await this.SavePullRequestUnknownMergeStateSinceAsync(
                itemId: itemId,
                timestamp: now,
                cancellationToken: cancellationToken
            );

            return false;
        }

        if (since is null || ElapsedMinutes(now: now, since: since.Value) < timeoutMinutes)
        {
            return false;
        }

        await this.SavePullRequestUnknownMergeStateSinceAsync(
            itemId: itemId,
            timestamp: now,
            cancellationToken: cancellationToken
        );

        return true;
    }

    public ValueTask SavePullRequestLastAgentCommentSeenAsync(
        string itemId,
        string timestamp,
        CancellationToken cancellationToken
    )
    {
        return this.WriteLineAsync(
            path: this.PullRequestLastAgentCommentPath(itemId),
            line: timestamp,
            cancellationToken: cancellationToken
        );
    }

    public ValueTask<string> LoadPullRequestLastAgentCommentSeenAsync(
        string itemId,
        CancellationToken cancellationToken
    )
    {
        return ReadAsync(path: this.PullRequestLastAgentCommentPath(itemId), cancellationToken: cancellationToken);
    }

    private string PathFor(string fileName)
    {
        return this._sessionDirectory + "/" + fileName;
    }

    private long Now()
    {
        return this._timeProvider.GetUtcNow().ToUnixTimeSeconds();
    }

    // bash integer division truncates towards zero, as C# does
    private static long ElapsedMinutes(long now, long since)
    {
        return (now - since) / SECONDS_PER_MINUTE;
    }

    // jq -r '.headRefOid // empty' read through a command substitution: empty when jq fails
    private static string HeadRefOid(string pullRequestJson)
    {
        try
        {
            JqValue oid = JqOps.Field(value: JqParser.Parse(pullRequestJson), name: "headRefOid");

            return oid.IsTruthy ? JqFormatter.Raw(oid).TrimEnd('\n') : string.Empty;
        }
        catch (JqException)
        {
            return string.Empty;
        }
    }

    // False when the saved text is not all digits (the shell restarts the clock). True with a null
    // value when the digits are not valid for bash arithmetic (a leading 0 makes them octal): the
    // shell's comparison then fails, which reads as "not timed out" without restarting the clock.
    private static bool TryParseTimestamp(string text, out long? value)
    {
        value = null;

        if (!AllDigits().IsMatch(text))
        {
            return false;
        }

        if (text.Length > 1 && text[0] == '0')
        {
            try
            {
                value = Convert.ToInt64(value: text, fromBase: OCTAL);
            }
            catch (FormatException)
            {
                value = null;
            }
            catch (OverflowException)
            {
                value = null;
            }

            return true;
        }

        if (
            long.TryParse(
                s: text,
                style: NumberStyles.None,
                provider: CultureInfo.InvariantCulture,
                result: out long parsed
            )
        )
        {
            value = parsed;
        }

        return true;
    }

    private async ValueTask WriteLineAsync(string path, string line, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(this._sessionDirectory);
        await File.WriteAllTextAsync(path: path, contents: line + "\n", cancellationToken: cancellationToken);
    }

    // [ -f file ] && cat file, through a command substitution: missing or unreadable reads as empty
    private static async ValueTask<string> ReadAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            return string.Empty;
        }

        try
        {
            string content = await File.ReadAllTextAsync(path: path, cancellationToken: cancellationToken);

            return content
                .Replace(oldValue: "\0", newValue: string.Empty, comparisonType: StringComparison.Ordinal)
                .TrimEnd('\n');
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    private static void Delete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // rm -f ... 2>/dev/null || true
        }
    }

    [GeneratedRegex(
        pattern: @"\A[0-9]+\z",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex AllDigits();
}
