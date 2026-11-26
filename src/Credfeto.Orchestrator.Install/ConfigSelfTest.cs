using System;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Config;

namespace Credfeto.Orchestrator.Install;

// The lib/globals directories and timeouts resolve from a HOME alone, as lib/globals resolves them
public sealed class ConfigSelfTest : ISelfTestCheck
{
    private const string HOME = "/self-test";

    public string Name => "config";

    public ValueTask RunAsync(CancellationToken cancellationToken)
    {
        OrchestratorSettings settings = OrchestratorSettingsLoader.Load(static name =>
            StringComparer.Ordinal.Equals(x: name, y: OrchestratorSettingsLoader.HomeVariable) ? HOME : null
        );

        OrchestratorSettings expected = new(
            StateDirectory: HOME + "/.local/state/orchestrator",
            WorkDirectory: HOME + "/work",
            CiCheckTimeoutMinutes: OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes,
            UnknownMergeStateTimeoutMinutes: OrchestratorSettingsLoader.DefaultUnknownMergeStateTimeoutMinutes
        );

        SelfTestExpect.Same(what: "settings", expected: expected.ToString(), actual: settings.ToString());

        return ValueTask.CompletedTask;
    }
}
