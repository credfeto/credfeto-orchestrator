using Xunit;

namespace Credfeto.Orchestrator.State.Tests;

// The tests that set the process umask, which every file any test makes meanwhile would take: run alone, one by one
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class UmaskSerial
{
    public const string Name = "umask";
}
