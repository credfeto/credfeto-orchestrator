using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Prompts.Tests;

// The exact texts are pinned by the parity fixture (Credfeto.Orchestrator.Commands.Tests); these cover the rules
public sealed class PromptBuilderTests : TestBase
{
    private static readonly BoardSettings Board = new(Repository: "o/r", HasBoard: true, Statuses: ["A", "B"]);

    [Fact]
    public async Task ALaunchPromptNamesTheItemRepositoryAndCheckoutAsync()
    {
        IPromptBuilder builder = await this.BuilderAsync();

        string prompt = builder.IssueLaunchPrompt(new(Repository: "o/r", ItemId: "7", RepositoryPath: "/w"));

        Assert.Equal(expected: "Work on issue #7 in o/r.\nThe repository is checked out at /w.\n", actual: prompt);
    }

    [Fact]
    public async Task AValueIsNeverSearchedForPlaceholdersAsync()
    {
        IPromptBuilder builder = await this.BuilderAsync();

        string prompt = builder.PullRequestLaunchPrompt(
            new(Repository: "{{repo_path}}", ItemId: "{{item_id}}", RepositoryPath: "{{x}}")
        );

        Assert.Equal(
            expected: "Work on pull request #{{item_id}} in {{repo_path}}.\nThe repository is checked out at {{x}}.\n",
            actual: prompt
        );
    }

    [Fact]
    public async Task AnIssueClaudeMdWithABoardListsItsStatusesInOrderAsync()
    {
        IPromptBuilder builder = await this.BuilderAsync();

        string text = builder.IssueClaudeMd(Issue(trustedLogins: "[\"a\",2]"));

        Assert.Contains(
            expectedSubstring: "Its Status values, in order: A, B.\n",
            actualString: text,
            comparisonType: System.StringComparison.Ordinal
        );
        Assert.Contains(
            expectedSubstring: "ignore all others:\n- a\n- 2\n",
            actualString: text,
            comparisonType: System.StringComparison.Ordinal
        );
    }

    [Theory]
    [InlineData("{\"a\":\"b\"}")]
    [InlineData("[")]
    [InlineData("[\"a\"] [\"b\"]")]
    [InlineData("[\"nul\\u0000\"]")]
    public async Task TrustedLoginsJqWouldNotPrintInFullAreRefusedAsync(string trustedLogins)
    {
        IPromptBuilder builder = await this.BuilderAsync();

        Assert.Throws<PromptException>(() => builder.IssueClaudeMd(Issue(trustedLogins)));
    }

    [Theory]
    [InlineData("\"me\"")]
    [InlineData("3")]
    [InlineData(" null")]
    public async Task TrustedLoginsJqCannotIterateGiveTheHeaderAloneAsync(string trustedLogins)
    {
        IPromptBuilder builder = await this.BuilderAsync();

        string text = builder.IssueClaudeMd(Issue(trustedLogins));

        Assert.Contains(
            expectedSubstring: "ignore all others:\nGit transport",
            actualString: text,
            comparisonType: System.StringComparison.Ordinal
        );
    }

    [Fact]
    public async Task APrecheckSectionWithoutALogLeavesTheLogLineOutAsync()
    {
        IPromptBuilder builder = await this.BuilderAsync();

        string text = builder.PrecheckSection(
            new(
                SummaryLines: "10",
                TimeoutMinutes: "20",
                Kind: "pr",
                Sha: "abc",
                Status: "fail",
                Summary: "  hook",
                Error: string.Empty,
                ContainerLog: string.Empty
            )
        );

        Assert.DoesNotContain(
            expectedSubstring: "Full log",
            actualString: text,
            comparisonType: System.StringComparison.Ordinal
        );
        Assert.EndsWith(
            expectedEndString: "re-run only the checks that cover your change.\n",
            actualString: text,
            comparisonType: System.StringComparison.Ordinal
        );
    }

    private static IssueClaudeMdRequest Issue(string trustedLogins)
    {
        return new(
            Board: Board,
            ItemId: "1",
            AiInstructions: "/ai",
            RepositoryPath: "/w",
            PlanApproved: "false",
            TrustedLogins: trustedLogins,
            Tree: new(DirtyBranch: string.Empty, StaleBranch: string.Empty),
            BackgroundStall: "false",
            PrecheckSection: string.Empty
        );
    }

    private async Task<IPromptBuilder> BuilderAsync()
    {
        return new PromptBuilder(await PromptTemplateSet.LoadAsync(this.CancellationToken()));
    }
}
