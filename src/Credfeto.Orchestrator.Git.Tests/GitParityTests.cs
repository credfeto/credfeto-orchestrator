using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Git.Tests;

// Every fixture case the tool is asked, run with the real git command line over the fixture's repositories: the query
// must print and return what the shell function did, or refuse the cases marked "refuses"
public sealed class GitParityTests : TestBase, IClassFixture<GitParityRepositories>
{
    private readonly GitParityRepositories _repositories;

    public GitParityTests(GitParityRepositories repositories)
    {
        this._repositories = repositories;
    }

    public static Task<TheoryData<int, string>> CasesAsync()
    {
        return GitParityFixture.ToolCaseNamesAsync();
    }

    [Theory]
    [MemberData(nameof(CasesAsync))]
    public async Task TheQueryMatchesTheShellFunctionAsync(int index, string name)
    {
        GitParityCase parity = await GitParityFixture.CaseAsync(
            index: index,
            cancellationToken: this.CancellationToken()
        );
        string scenario = Path.Combine(path1: this._repositories.Root, path2: parity.Scenario);
        GitQueries queries = new(
            new GitProcessRunner(
                executable: "git",
                workingDirectory: scenario,
                environment: this._repositories.Environment,
                discardErrors: true
            )
        );

        if (StringComparer.Ordinal.Equals(x: parity.Tool, y: "refuses"))
        {
            await Assert.ThrowsAsync<GitRefusedException>(() =>
                this.AskAsync(queries: queries, parity: parity, scenario: scenario)
            );

            return;
        }

        GitResult result = await this.AskAsync(queries: queries, parity: parity, scenario: scenario);

        Assert.Equal(
            expected: Describe(name: name, status: parity.Status, stdout: parity.Stdout),
            actual: Describe(name: name, status: result.ExitCode, stdout: Encoding.UTF8.GetString(result.Output.Span))
        );
    }

    private static string Describe(string name, int status, string stdout)
    {
        return $"{name}: status {status.ToString(CultureInfo.InvariantCulture)}, printed [{stdout}]";
    }

    private async Task<GitResult> AskAsync(GitQueries queries, GitParityCase parity, string scenario)
    {
        CancellationToken cancellationToken = this.CancellationToken();
        string repository =
            parity.Repository.Length == 0 ? string.Empty : Path.Combine(path1: scenario, path2: parity.Repository);
        string[] arguments =
        [
            .. parity.Arguments.Select(argument =>
                argument.Replace(
                    oldValue: GitParityFixture.ROOT_PLACEHOLDER,
                    newValue: scenario,
                    comparisonType: StringComparison.Ordinal
                )
            ),
        ];

        return parity.Function switch
        {
            "checkout_head_sha" => await queries.HeadShaAsync(
                repository: repository,
                cancellationToken: cancellationToken
            ),
            "checkout_current_branch" => await queries.CurrentBranchAsync(
                repository: repository,
                cancellationToken: cancellationToken
            ),
            "checkout_has_uncommitted_changes" => await queries.UncommittedChangesAsync(
                repository: repository,
                cancellationToken: cancellationToken
            ),
            "origin_branch_exists" => await queries.OriginBranchExistsAsync(
                repository: repository,
                branch: arguments[0],
                cancellationToken: cancellationToken
            ),
            "git_commits_behind" => await queries.CommitsBehindAsync(
                repository: arguments[0],
                reference: arguments[1],
                upstream: arguments[2],
                cancellationToken: cancellationToken
            ),
            "find_stale_issue_branch" => await queries.StaleIssueBranchAsync(
                repository: repository,
                issue: arguments[0],
                cancellationToken: cancellationToken
            ),
            _ => throw new InvalidOperationException("No query for " + parity.Function),
        };
    }
}
