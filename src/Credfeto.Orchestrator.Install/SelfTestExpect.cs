using System;

namespace Credfeto.Orchestrator.Install;

internal static class SelfTestExpect
{
    public static void Same(string what, string expected, string actual)
    {
        if (!StringComparer.Ordinal.Equals(x: expected, y: actual))
        {
            throw new SelfTestFailedException($"{what}: expected {expected}, got {actual}");
        }
    }
}
