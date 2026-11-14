using System;
using System.Collections.Generic;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Config.Tests;

public sealed class OrchestratorSettingsLoaderTests : TestBase
{
    [Fact]
    public static void DefaultsFollowTheShellWhenOnlyHomeIsSet()
    {
        OrchestratorSettings settings = Load((OrchestratorSettingsLoader.HomeVariable, "/home/user"));

        Assert.Equal(expected: "/home/user/.local/state/orchestrator", actual: settings.StateDirectory);
        Assert.Equal(expected: "/home/user/work", actual: settings.WorkDirectory);
        Assert.Equal(
            expected: OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes,
            actual: settings.CiCheckTimeoutMinutes
        );
        Assert.Equal(
            expected: OrchestratorSettingsLoader.DefaultUnknownMergeStateTimeoutMinutes,
            actual: settings.UnknownMergeStateTimeoutMinutes
        );
    }

    [Fact]
    public static void XdgDirectoriesAreUsedWhenSet()
    {
        OrchestratorSettings settings = Load(
            (OrchestratorSettingsLoader.HomeVariable, "/home/user"),
            (OrchestratorSettingsLoader.StateHomeVariable, "/state"),
            (OrchestratorSettingsLoader.ProjectsVariable, "/projects")
        );

        Assert.Equal(expected: "/state/orchestrator", actual: settings.StateDirectory);
        Assert.Equal(expected: "/projects", actual: settings.WorkDirectory);
    }

    [Fact]
    public static void AnEmptyVariableCountsAsUnset()
    {
        OrchestratorSettings settings = Load(
            (OrchestratorSettingsLoader.HomeVariable, "/home/user"),
            (OrchestratorSettingsLoader.StateHomeVariable, string.Empty),
            (OrchestratorSettingsLoader.ProjectsVariable, string.Empty),
            (OrchestratorSettingsLoader.CiCheckTimeoutVariable, string.Empty)
        );

        Assert.Equal(expected: "/home/user/.local/state/orchestrator", actual: settings.StateDirectory);
        Assert.Equal(expected: "/home/user/work", actual: settings.WorkDirectory);
        Assert.Equal(
            expected: OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes,
            actual: settings.CiCheckTimeoutMinutes
        );
    }

    [Fact]
    public static void AMissingHomeExpandsToNothingAsInBash()
    {
        OrchestratorSettings settings = Load();

        Assert.Equal(expected: "/.local/state/orchestrator", actual: settings.StateDirectory);
        Assert.Equal(expected: "/work", actual: settings.WorkDirectory);
    }

    [Theory]
    [InlineData("45", 45)]
    [InlineData("1", 1)]
    [InlineData("0", OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes)]
    [InlineData("-5", OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes)]
    [InlineData("07", OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes)]
    [InlineData("ten", OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes)]
    [InlineData("10 ", OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes)]
    [InlineData("99999999999", OrchestratorSettingsLoader.DefaultCiCheckTimeoutMinutes)]
    public static void CiCheckTimeoutMustBeAPositiveInteger(string value, int expected)
    {
        OrchestratorSettings settings = Load((OrchestratorSettingsLoader.CiCheckTimeoutVariable, value));

        Assert.Equal(expected: expected, actual: settings.CiCheckTimeoutMinutes);
    }

    [Theory]
    [InlineData("90", 90)]
    [InlineData("0", OrchestratorSettingsLoader.DefaultUnknownMergeStateTimeoutMinutes)]
    [InlineData("1.5", OrchestratorSettingsLoader.DefaultUnknownMergeStateTimeoutMinutes)]
    public static void UnknownMergeStateTimeoutMustBeAPositiveInteger(string value, int expected)
    {
        OrchestratorSettings settings = Load((OrchestratorSettingsLoader.UnknownMergeStateTimeoutVariable, value));

        Assert.Equal(expected: expected, actual: settings.UnknownMergeStateTimeoutMinutes);
    }

    [Fact]
    public static void TheSessionDirectoryIsPerOwnerAndRepository()
    {
        OrchestratorSettings settings = Load((OrchestratorSettingsLoader.StateHomeVariable, "/state"));

        Assert.Equal(
            expected: "/state/orchestrator/credfeto/credfeto-orchestrator",
            actual: settings.SessionDirectory(owner: "credfeto", repository: "credfeto-orchestrator")
        );
    }

    [Fact]
    public static void TheProcessEnvironmentLoads()
    {
        OrchestratorSettings settings = OrchestratorSettingsLoader.FromProcess();

        Assert.EndsWith(
            expectedEndString: "/orchestrator",
            actualString: settings.StateDirectory,
            comparisonType: StringComparison.Ordinal
        );
    }

    private static OrchestratorSettings Load(params (string Name, string Value)[] variables)
    {
        Dictionary<string, string> values = [with(StringComparer.Ordinal)];

        foreach ((string name, string value) in variables)
        {
            values[name] = value;
        }

        return OrchestratorSettingsLoader.Load(name => values.GetValueOrDefault(name));
    }
}
