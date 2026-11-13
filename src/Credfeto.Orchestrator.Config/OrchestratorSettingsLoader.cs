using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Credfeto.Orchestrator.Config;

// The lib/globals defaults the ported code reads, resolved from the environment the same way:
// ${VAR:-default} treats an empty value as unset, and a timeout that is not a positive integer
// falls back to its default.
public static partial class OrchestratorSettingsLoader
{
    public const string HomeVariable = "HOME";
    public const string StateHomeVariable = "XDG_STATE_HOME";
    public const string ProjectsVariable = "XDG_PROJECTS_DIR";
    public const string CiCheckTimeoutVariable = "CI_CHECK_TIMEOUT_MINUTES";
    public const string UnknownMergeStateTimeoutVariable = "UNKNOWN_MERGE_STATE_TIMEOUT_MINUTES";

    public const int DefaultCiCheckTimeoutMinutes = 1440;
    public const int DefaultUnknownMergeStateTimeoutMinutes = 60;

    private const int MATCH_TIMEOUT_MILLISECONDS = 1000;

    public static OrchestratorSettings FromProcess()
    {
        return Load(Environment.GetEnvironmentVariable);
    }

    public static OrchestratorSettings Load(Func<string, string?> getVariable)
    {
        string home = getVariable(HomeVariable) ?? string.Empty;
        string stateHome = OrDefault(value: getVariable(StateHomeVariable), fallback: home + "/.local/state");

        return new(
            StateDirectory: stateHome + "/orchestrator",
            WorkDirectory: OrDefault(value: getVariable(ProjectsVariable), fallback: home + "/work"),
            CiCheckTimeoutMinutes: PositiveMinutes(
                value: getVariable(CiCheckTimeoutVariable),
                fallback: DefaultCiCheckTimeoutMinutes
            ),
            UnknownMergeStateTimeoutMinutes: PositiveMinutes(
                value: getVariable(UnknownMergeStateTimeoutVariable),
                fallback: DefaultUnknownMergeStateTimeoutMinutes
            )
        );
    }

    private static string OrDefault(string? value, string fallback)
    {
        return string.IsNullOrEmpty(value) ? fallback : value;
    }

    private static int PositiveMinutes(string? value, int fallback)
    {
        if (string.IsNullOrEmpty(value) || !PositiveInteger().IsMatch(value))
        {
            return fallback;
        }

        return int.TryParse(
            s: value,
            style: NumberStyles.None,
            provider: CultureInfo.InvariantCulture,
            result: out int minutes
        )
            ? minutes
            : fallback;
    }

    [GeneratedRegex(
        pattern: @"\A[1-9][0-9]*\z",
        options: RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS
    )]
    private static partial Regex PositiveInteger();
}
