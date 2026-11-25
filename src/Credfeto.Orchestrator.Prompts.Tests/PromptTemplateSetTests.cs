using System;
using System.Linq;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Prompts.Tests;

public sealed class PromptTemplateSetTests : TestBase
{
    [Fact]
    public async Task EveryTemplateLoadsWithoutItsLintMarkerOrFinalNewlineAsync()
    {
        PromptTemplateSet templates = await PromptTemplateSet.LoadAsync(this.CancellationToken());

        Assert.NotEmpty(templates.Names);

        foreach (string name in templates.Names)
        {
            string text = templates.Text(name);

            Assert.False(condition: text.Contains("markdownlint", StringComparison.Ordinal), userMessage: name);
            Assert.False(condition: text.Length > 0 && text[^1] == '\n', userMessage: name);
        }
    }

    [Fact]
    public async Task PlaceholdersAreNamedInLowerCaseAsync()
    {
        PromptTemplateSet templates = await PromptTemplateSet.LoadAsync(this.CancellationToken());

        Assert.Equal(
            expected: ["item_id", "repo_full", "repo_path"],
            actual: templates.Placeholders("IssueLaunchPrompt").Order(StringComparer.Ordinal),
            comparer: StringComparer.Ordinal
        );
    }

    [Fact]
    public async Task AMissingTemplateFailsAsync()
    {
        PromptTemplateSet templates = await PromptTemplateSet.LoadAsync(this.CancellationToken());

        PromptException exception = Assert.Throws<PromptException>(() => templates.Text("NoSuchTemplate"));

        Assert.Equal(expected: "Missing prompt template NoSuchTemplate", actual: exception.Message);
    }
}
