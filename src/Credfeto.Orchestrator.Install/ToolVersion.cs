using System.Reflection;

namespace Credfeto.Orchestrator.Install;

public static class ToolVersion
{
    // The informational version the build stamps (the package version, with any +build metadata)
    public static string Of(Assembly assembly)
    {
        return assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString()
            ?? "unknown";
    }
}
