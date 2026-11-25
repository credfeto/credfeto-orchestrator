using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Credfeto.Orchestrator.State;

// The read-only lib/state queries: each reads the file its shell function reads and gives back what that function
// prints (or leaves in its global) and returns. Anything the tool cannot be sure to answer as bash would is refused.
public sealed class StateQueries
{
    public const int Answered = 0;

    public const int NotFound = 1;

    // rate-limit: not rate-limited, and the file is stale (expired or not a number), so bash removes it
    public const int Stale = 4;

    // [ "${count}" -ge "${PULL_DURATION_MIN_SAMPLES}" ] and [ "${now}" -ge "${reset}" ] fail on a number bash cannot
    // hold in 64 bits, so a longer one is refused
    private const int LONGEST_SAFE_NUMBER = 18;

    private static readonly byte[] Zero = "0"u8.ToArray();
    private static readonly byte[] ZeroCounts = "0 0"u8.ToArray();
    private static readonly byte[] SpaceZero = " 0"u8.ToArray();
    private static readonly byte[] Null = "null"u8.ToArray();

    private static readonly string[] PrecheckStatuses = ["pass", "fail", "timeout"];

    private readonly TimeProvider _timeProvider;

    public StateQueries(TimeProvider timeProvider)
    {
        this._timeProvider = timeProvider;
    }

    // load_infra_failure_count: INFRA_FAILURE_COUNT
    public static ValueTask<StateResult> InfraFailuresAsync(
        string sessionDirectory,
        string itemType,
        string itemId,
        CancellationToken cancellationToken
    )
    {
        return CounterAsync(
            path: StatePaths.ItemFile(
                sessionDirectory: sessionDirectory,
                itemType: itemType,
                itemId: itemId,
                suffix: "infra-failures"
            ),
            cancellationToken: cancellationToken
        );
    }

    // load_env_unblock_attempts: ENV_UNBLOCK_ATTEMPTS
    public static ValueTask<StateResult> EnvUnblockAttemptsAsync(
        string sessionDirectory,
        string itemId,
        CancellationToken cancellationToken
    )
    {
        return CounterAsync(
            path: StatePaths.EnvUnblockAttempts(sessionDirectory: sessionDirectory, itemId: itemId),
            cancellationToken: cancellationToken
        );
    }

    // load_pr_invocation_counts / load_issue_invocation_counts: "<total> <idle>". An Issue's file also recovers the
    // total from a leading number alone (a pre-#1264 single-token file), idle then 0.
    public static async ValueTask<StateResult> InvocationsAsync(
        string sessionDirectory,
        string itemType,
        string itemId,
        CancellationToken cancellationToken
    )
    {
        string path = StatePaths.ItemFile(
            sessionDirectory: sessionDirectory,
            itemType: itemType,
            itemId: itemId,
            suffix: "invocations"
        );

        if (!StateFile.IsRegularFile(path))
        {
            return new(Output: ZeroCounts, ExitCode: Answered);
        }

        byte[] content = await StateFile.ReadAsync(path: path, cancellationToken: cancellationToken);
        StateText.RefuseNonAscii(content: content, path: path);
        ReadOnlyMemory<byte> line = content.AsMemory(start: 0, length: StateText.CommandSubstitution(content).Length);
        int space = line.Span.IndexOf((byte)' ');

        if (space > 0 && StateText.IsDigits(line.Span[..space]) && StateText.IsDigits(line.Span[(space + 1)..]))
        {
            return new(Output: line, ExitCode: Answered);
        }

        // ${line%% *}: everything before the first space
        ReadOnlyMemory<byte> total = space < 0 ? line : line[..space];

        if (StringComparer.Ordinal.Equals(x: itemType, y: StateCommandParser.Issue) && StateText.IsDigits(total.Span))
        {
            return new(Output: (byte[])[.. total.Span, .. SpaceZero], ExitCode: Answered);
        }

        return new(Output: ZeroCounts, ExitCode: Answered);
    }

    // issue_plan_block_marked, issue_blocked_replan_marked and background_stall_marked: [ -f <marker> ]
    public static StateResult Marker(string sessionDirectory, string itemType, string itemId, string kind)
    {
        string path = StatePaths.ItemFile(
            sessionDirectory: sessionDirectory,
            itemType: itemType,
            itemId: itemId,
            suffix: kind
        );

        return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: StateFile.IsRegularFile(path) ? Answered : NotFound);
    }

    // load_last_diagnostic: cat <file> 2>/dev/null || true, so nothing at all when it cannot be read
    public static async ValueTask<StateResult> LastDiagnosticAsync(
        string sessionDirectory,
        string itemType,
        string itemId,
        CancellationToken cancellationToken
    )
    {
        string path = StatePaths.ItemFile(
            sessionDirectory: sessionDirectory,
            itemType: itemType,
            itemId: itemId,
            suffix: "last-diagnostic"
        );

        if (Directory.Exists(path) || !File.Exists(path))
        {
            return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: Answered);
        }

        byte[] content;

        try
        {
            content = await File.ReadAllBytesAsync(path: path, cancellationToken: cancellationToken);
        }
        catch (FileNotFoundException)
        {
            return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: Answered);
        }
        catch (DirectoryNotFoundException)
        {
            return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: Answered);
        }
        catch (IOException exception)
        {
            throw new StateRefusedException(message: "cannot read " + path, innerException: exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new StateRefusedException(message: "cannot read " + path, innerException: exception);
        }

        StateText.RefuseNul(content: content, path: path);

        return new(Output: content, ExitCode: Answered);
    }

    // load_precheck_result: the status (pass, fail or timeout) when the record's first line is exactly sha, read as
    // IFS= read -r reads two lines, each ended by a newline
    public static async ValueTask<StateResult> PrecheckResultAsync(
        string sessionDirectory,
        string key,
        string sha,
        CancellationToken cancellationToken
    )
    {
        string path = StatePaths.Precheck(sessionDirectory: sessionDirectory, key: key);

        if (!StateFile.IsRegularFile(path))
        {
            return NoAnswer();
        }

        byte[] content = await StateFile.ReadAsync(path: path, cancellationToken: cancellationToken);
        StateText.RefuseNul(content: content, path: path);
        int firstEnd = Array.IndexOf(array: content, value: (byte)'\n');
        int secondEnd = firstEnd < 0 ? -1 : Array.IndexOf(array: content, value: (byte)'\n', startIndex: firstEnd + 1);

        if (secondEnd < 0 || sha.Length == 0)
        {
            return NoAnswer();
        }

        ReadOnlyMemory<byte> status = content.AsMemory(start: firstEnd + 1, length: secondEnd - firstEnd - 1);

        if (
            !content.AsSpan(start: 0, length: firstEnd).SequenceEqual(Encoding.UTF8.GetBytes(sha))
            || !PrecheckStatuses.Any(known => status.Span.SequenceEqual(Encoding.UTF8.GetBytes(known)))
        )
        {
            return NoAnswer();
        }

        return new(Output: status, ExitCode: Answered);
    }

    // pull_duration_baseline: the median of the owner's recorded pull durations (the lines that are only digits), or
    // nothing and status 1 with fewer than minSamples of them
    public static async ValueTask<StateResult> PullDurationBaselineAsync(
        string stateDirectory,
        string owner,
        string minSamples,
        CancellationToken cancellationToken
    )
    {
        long minimum = SafeNumber(text: minSamples, what: "the minimum sample count");
        string path = StatePaths.PullDurations(stateDirectory: stateDirectory, owner: owner);

        if (!StateFile.IsRegularFile(path))
        {
            return NoAnswer();
        }

        byte[] content = await StateFile.ReadAsync(path: path, cancellationToken: cancellationToken);
        StateText.RefuseNonAscii(content: content, path: path);
        List<string> samples =
        [
            .. Encoding.ASCII.GetString(content).Split('\n').Where(line => StateText.IsDigits(line.AsSpan())),
        ];

        if (samples.Count == 0 || samples.Count < minimum)
        {
            return NoAnswer();
        }

        // sort -n, equal numbers in byte order (as the locale orders digits), then awk's a[int((NR+1)/2)]
        samples.Sort(NumericOrder);
        string median = samples[(samples.Count + 1) / 2 - 1];

        return new(Output: Encoding.ASCII.GetBytes(median + "\n"), ExitCode: Answered);
    }

    // is_owner_rate_limited: 0 while the owner's reset time is still ahead, 1 with no rate-limit file, and Stale when
    // it has passed or the file is not a number (bash then removes it)
    public async ValueTask<StateResult> RateLimitAsync(
        string stateDirectory,
        string owner,
        CancellationToken cancellationToken
    )
    {
        string path = StatePaths.RateLimit(stateDirectory: stateDirectory, owner: owner);

        if (!StateFile.IsRegularFile(path))
        {
            return NoAnswer();
        }

        byte[] content = await StateFile.ReadAsync(path: path, cancellationToken: cancellationToken);
        StateText.RefuseNonAscii(content: content, path: path);
        string value = Encoding.ASCII.GetString(StateText.CommandSubstitution(content));

        if (!StateText.IsDigits(value.AsSpan()))
        {
            return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: Stale);
        }

        long reset = SafeNumber(text: value, what: "the rate-limit reset time");
        long now = this._timeProvider.GetUtcNow().ToUnixTimeSeconds();

        return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: now >= reset ? Stale : Answered);
    }

    // summarise_session_denials_day: null with no file, else the day's compact JSON summary and a newline
    public static async ValueTask<StateResult> SessionDenialsSummaryAsync(
        string file,
        CancellationToken cancellationToken
    )
    {
        if (!StateFile.IsRegularFile(file))
        {
            return new(Output: Null, ExitCode: Answered);
        }

        byte[] content = await StateFile.ReadAsync(path: file, cancellationToken: cancellationToken);
        StateText.RefuseNul(content: content, path: file);
        string text = SessionDenialsSummary.DecodeUtf8(content: content, path: file);

        return new(Output: Encoding.UTF8.GetBytes(SessionDenialsSummary.Summarise(text) + "\n"), ExitCode: Answered);
    }

    // load_infra_failure_count / load_env_unblock_attempts: the file's text when it is only digits, else 0
    private static async ValueTask<StateResult> CounterAsync(string path, CancellationToken cancellationToken)
    {
        if (!StateFile.IsRegularFile(path))
        {
            return new(Output: Zero, ExitCode: Answered);
        }

        byte[] content = await StateFile.ReadAsync(path: path, cancellationToken: cancellationToken);
        StateText.RefuseNonAscii(content: content, path: path);
        int length = StateText.CommandSubstitution(content).Length;

        return StateText.IsDigits(content.AsSpan(start: 0, length: length))
            ? new(Output: content.AsMemory(start: 0, length: length), ExitCode: Answered)
            : new(Output: Zero, ExitCode: Answered);
    }

    private static StateResult NoAnswer()
    {
        return new(Output: ReadOnlyMemory<byte>.Empty, ExitCode: NotFound);
    }

    // A whole number bash's [ -ge ] takes the same way: digits only, at most LONGEST_SAFE_NUMBER after leading zeros
    private static long SafeNumber(string text, string what)
    {
        string significant = text.TrimStart('0');

        if (!StateText.IsDigits(text.AsSpan()) || significant.Length > LONGEST_SAFE_NUMBER)
        {
            throw new StateRefusedException(what + " is not a number the tool reads as bash does: " + text);
        }

        return significant.Length == 0 ? 0 : long.Parse(s: significant, provider: CultureInfo.InvariantCulture);
    }

    private static int NumericOrder(string left, string right)
    {
        string leftValue = left.TrimStart('0');
        string rightValue = right.TrimStart('0');
        int compared = leftValue.Length.CompareTo(rightValue.Length);

        if (compared == 0)
        {
            compared = string.CompareOrdinal(strA: leftValue, strB: rightValue);
        }

        return compared != 0 ? compared : string.CompareOrdinal(strA: left, strB: right);
    }
}
