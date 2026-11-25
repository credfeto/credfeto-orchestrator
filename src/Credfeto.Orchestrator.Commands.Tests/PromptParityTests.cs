using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class PromptParityTests : TestBase
{
    public static Task<TheoryData<int, string>> IssueClaudeMdCasesAsync()
    {
        return PromptParityFixture.CaseNamesAsync(PromptParityFixture.IssueClaudeMd);
    }

    public static Task<TheoryData<int, string>> PullRequestClaudeMdCasesAsync()
    {
        return PromptParityFixture.CaseNamesAsync(PromptParityFixture.PullRequestClaudeMd);
    }

    public static Task<TheoryData<int, string>> LaunchPromptCasesAsync()
    {
        return PromptParityFixture.CaseNamesAsync(PromptParityFixture.LaunchPrompts);
    }

    public static Task<TheoryData<int, string>> PrecheckSectionCasesAsync()
    {
        return PromptParityFixture.CaseNamesAsync(PromptParityFixture.PrecheckSections);
    }

    public static Task<TheoryData<int, string>> CheckLengthCasesAsync()
    {
        return PromptParityFixture.CaseNamesAsync(PromptParityFixture.CheckLength);
    }

    [Theory]
    [MemberData(nameof(IssueClaudeMdCasesAsync))]
    public Task IssueClaudeMdMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(collection: PromptParityFixture.IssueClaudeMd, index: index, name: name);
    }

    [Theory]
    [MemberData(nameof(PullRequestClaudeMdCasesAsync))]
    public Task PullRequestClaudeMdMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(collection: PromptParityFixture.PullRequestClaudeMd, index: index, name: name);
    }

    [Theory]
    [MemberData(nameof(LaunchPromptCasesAsync))]
    public Task LaunchPromptMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(collection: PromptParityFixture.LaunchPrompts, index: index, name: name);
    }

    [Theory]
    [MemberData(nameof(PrecheckSectionCasesAsync))]
    public Task PrecheckSectionMatchesTheShellVersionAsync(int index, string name)
    {
        return this.CheckAsync(collection: PromptParityFixture.PrecheckSections, index: index, name: name);
    }

    [Theory]
    [MemberData(nameof(CheckLengthCasesAsync))]
    public async Task CheckLengthMatchesTheShellVersionAsync(int index, string name)
    {
        PromptLengthParityCase parity = await PromptParityFixture.LengthCaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );
        Dictionary<string, string> environment = new(StringComparer.Ordinal) { ["LC_ALL"] = parity.Locale };

        (int exitCode, string output) = await this.RunAsync(
            environment: environment,
            stdin: parity.Prompt,
            "prompt",
            "check-length",
            "--max",
            parity.Max
        );

        Assert.Equal(
            expected: name + ": " + parity.Length + "\n" + (parity.TooLong ? "too long" : "fits"),
            actual: name + ": " + output + (exitCode == PromptCommandRunner.TooLong ? "too long" : "fits")
        );
    }

    private async Task CheckAsync(string collection, int index, string name)
    {
        PromptParityCase parity = await PromptParityFixture.CaseAsync(
            collection: collection,
            index: index,
            cancellationToken: this.CancellationToken()
        );

        (int exitCode, string output) = await this.RunAsync(
            environment: new Dictionary<string, string>(StringComparer.Ordinal),
            stdin: parity.Records,
            "prompt",
            parity.Kind
        );

        if (parity.Refuses)
        {
            Assert.Equal(
                expected: name + ": refused",
                actual: name + ": " + (exitCode == ExitCodes.Failure ? "refused" : output)
            );
            Assert.Equal(expected: string.Empty, actual: output);

            return;
        }

        Assert.Equal(expected: name + ": " + parity.Expected, actual: name + ": " + output);
        Assert.Equal(expected: ExitCodes.Success, actual: exitCode);
    }

    private async Task<(int ExitCode, string Output)> RunAsync(
        IReadOnlyDictionary<string, string> environment,
        byte[] stdin,
        params string[] args
    )
    {
        PromptCommandRunner runner = new(name =>
            environment.TryGetValue(key: name, value: out string? value) ? value : null
        );
        using MemoryStream input = new(stdin);
        await using StringWriter output = new();
        await using StringWriter error = new();

        int exitCode = await runner.RunAsync(
            args: args,
            input: input,
            output: output,
            error: error,
            cancellationToken: this.CancellationToken()
        );

        return (exitCode, output.ToString());
    }
}
