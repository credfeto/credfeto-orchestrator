using System.Text.RegularExpressions;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Fingerprints;

// _JQ_DEF_AUTOMATED_SUMMARY (lib/globals): a comment that opens with a <!-- ...-summary --> or
// <!-- ...-summary-comment --> marker is an automated CI summary, not human activity
internal static partial class AutomatedSummary
{
    private const int MATCH_TIMEOUT_MILLISECONDS = 1000;

    public static bool IsAutomatedSummary(JqValue body)
    {
        JqValue text = JqOps.Alternative(value: body, fallback: string.Empty);

        if (text.Kind != JqKind.TEXT)
        {
            throw new JqException($"{text.TypeName()} cannot be matched, as it is not a string");
        }

        return SummaryMarker().IsMatch(text.Text);
    }

    [GeneratedRegex(
        pattern: @"^\s*<!--\s*[A-Za-z0-9._-]*-summary(-comment)?([^A-Za-z0-9_-]|$)",
        options: RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex SummaryMarker();
}
