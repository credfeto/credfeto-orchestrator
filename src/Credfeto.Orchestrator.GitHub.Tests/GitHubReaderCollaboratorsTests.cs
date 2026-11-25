using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.GitHub.Tests;

public sealed class GitHubReaderCollaboratorsTests : TestBase
{
    [Fact]
    public async Task CollaboratorsAreAskedOfRepoCollaboratorsAndReturnedInTheServersOrderAsync()
    {
        FakeMcpToolCaller tools = new(
            result: """{"repository":"org/repo","collaborators":[{"login":"alice","role":"admin"},{"login":"bob","role":"write"}]}""",
            error: null
        );

        IReadOnlyList<string> logins = await new GitHubReader(tools).RepositoryCollaboratorsAsync(
            repository: "org/repo",
            cancellationToken: this.CancellationToken()
        );

        Assert.Equal(expected: ["alice", "bob"], actual: logins);
        Assert.Equal(expected: "repo_collaborators", actual: tools.Tool);
        Assert.Equal(
            expected: new Dictionary<string, string>(StringComparer.Ordinal) { ["repo"] = "org/repo" },
            actual: tools.Arguments
        );
    }

    [Fact]
    public async Task NoCollaboratorIsAnEmptyListAsync()
    {
        IReadOnlyList<string> logins = await ReadAsync(
            result: """{"repository":"org/repo","collaborators":[]}""",
            cancellationToken: this.CancellationToken()
        );

        Assert.Empty(logins);
    }

    [Theory]
    [InlineData("""{"repository":"org/repo"}""")]
    [InlineData("""{"collaborators":null}""")]
    [InlineData("""{"collaborators":[null]}""")]
    [InlineData("""{"collaborators":[{"role":"write"}]}""")]
    [InlineData("""{"collaborators":[{"login":""}]}""")]
    [InlineData("""{"collaborators":[{"login":"alice"},{"login":null}]}""")]
    [InlineData("null")]
    public async Task ACollaboratorListInAnotherShapeIsAFailedReadAsync(string result)
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            ReadAsync(result: result, cancellationToken: this.CancellationToken())
        );

        Assert.Equal(
            expected: "the cfwf MCP server's repo_collaborators result is not in the expected shape",
            actual: exception.Message
        );
    }

    [Fact]
    public async Task ACollaboratorListThatIsNotJsonIsAFailedReadAsync()
    {
        GitHubReadException exception = await Assert.ThrowsAsync<GitHubReadException>(() =>
            ReadAsync(result: "not json", cancellationToken: this.CancellationToken())
        );

        Assert.Equal(
            expected: "the cfwf MCP server's repo_collaborators result is not valid JSON",
            actual: exception.Message
        );
    }

    private static async Task<IReadOnlyList<string>> ReadAsync(string result, CancellationToken cancellationToken)
    {
        return await new GitHubReader(new FakeMcpToolCaller(result: result, error: null)).RepositoryCollaboratorsAsync(
            repository: "org/repo",
            cancellationToken: cancellationToken
        );
    }
}
