using System.Reflection;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Install.Tests;

public sealed class ToolVersionTests : TestBase
{
    [Fact]
    public static void TheVersionIsTheInformationalVersion()
    {
        Assembly assembly = typeof(ToolVersionTests).Assembly;

        Assert.Equal(
            expected: assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
            actual: ToolVersion.Of(assembly)
        );
    }
}
