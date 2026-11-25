using System;
using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Commands.Tests;

public sealed class GitCommandParserTests : TestBase
{
    [Theory]
    [InlineData("git|head-sha|--repo|/r", GitQuery.HEAD_SHA, "/r", "", "")]
    [InlineData("git|current-branch|--repo|", GitQuery.CURRENT_BRANCH, "", "", "")]
    [InlineData("git|uncommitted-changes|--repo|/r", GitQuery.UNCOMMITTED_CHANGES, "/r", "", "")]
    [InlineData(
        "git|origin-branch-exists|--branch|feat/1|--repo|/r",
        GitQuery.ORIGIN_BRANCH_EXISTS,
        "/r",
        "feat/1",
        ""
    )]
    [InlineData("git|origin-branch-exists|--repo|/r|--branch|", GitQuery.ORIGIN_BRANCH_EXISTS, "/r", "", "")]
    [InlineData(
        "git|commits-behind|--repo|/r|--ref|HEAD|--upstream|origin/main",
        GitQuery.COMMITS_BEHIND,
        "/r",
        "HEAD",
        "origin/main"
    )]
    [InlineData("git|stale-issue-branch|--repo|/r|--issue|12", GitQuery.STALE_ISSUE_BRANCH, "/r", "12", "")]
    [InlineData("git|head-sha|--repo|/a|--repo|/b", GitQuery.HEAD_SHA, "/b", "", "")]
    [InlineData("git|porcelain-status|--repo|/r", GitQuery.PORCELAIN_STATUS, "/r", "", "")]
    [InlineData("git|changed-file-count|--repo|/r", GitQuery.CHANGED_FILE_COUNT, "/r", "", "")]
    [InlineData("git|stash-head|--repo|", GitQuery.STASH_HEAD, "", "", "")]
    public static void EachQueryIsParsedWithItsOptions(
        string args,
        GitQuery query,
        string repository,
        string name,
        string upstream
    )
    {
        GitCommand? command = GitCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Equal(
            expected: new GitCommand(Query: query, Repository: repository, Name: name, Upstream: upstream),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("git|autostashes-beyond-keep|--keep|20|--repo|/r|--prefix|a b", "/r", "a b", "20")]
    [InlineData("git|autostashes-beyond-keep|--repo|/r|--prefix||--keep|", "/r", "", "")]
    public static void TheAutostashQueryIsParsedWithItsPrefixAndKeep(
        string args,
        string repository,
        string prefix,
        string keep
    )
    {
        GitCommand? command = GitCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Equal(
            expected: new GitCommand(
                Query: GitQuery.AUTOSTASHES_BEYOND_KEEP,
                Repository: repository,
                Name: prefix,
                Keep: keep
            ),
            actual: command
        );
        Assert.Equal(expected: string.Empty, actual: error);
    }

    [Theory]
    [InlineData("git", "expected: git <query>")]
    [InlineData("github|head-sha", "expected: git <query>")]
    [InlineData("git|status", "unknown git query 'status'")]
    [InlineData("git|head-sha", "git head-sha needs --repo")]
    [InlineData("git|head-sha|--repo", "--repo needs a value")]
    [InlineData("git|head-sha|--repo|/r|--branch|x", "unknown option '--branch'")]
    [InlineData("git|origin-branch-exists|--repo|/r", "git origin-branch-exists needs --branch")]
    [InlineData("git|commits-behind|--repo|/r|--ref|HEAD", "git commits-behind needs --upstream")]
    [InlineData("git|stale-issue-branch|--repo|/r", "git stale-issue-branch needs --issue")]
    [InlineData("git|autostashes-beyond-keep|--repo|/r|--keep|1", "git autostashes-beyond-keep needs --prefix")]
    [InlineData("git|autostashes-beyond-keep|--repo|/r|--prefix|p", "git autostashes-beyond-keep needs --keep")]
    [InlineData("git|stash-head|--repo|/r|--keep|1", "unknown option '--keep'")]
    public static void AnIncompleteOrUnknownCommandIsRefused(string args, string expected)
    {
        GitCommand? command = GitCommandParser.Parse(args: args.Split('|'), error: out string error);

        Assert.Null(command);
        Assert.StartsWith(expectedStartString: expected, actualString: error, comparisonType: StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("git|head-sha", true)]
    [InlineData("git", true)]
    [InlineData("github|open-prs", false)]
    [InlineData("", false)]
    public static void TheGitVerbIsRecognised(string args, bool expected)
    {
        string[] arguments = args.Length == 0 ? [] : args.Split('|');

        Assert.Equal(expected: expected, actual: GitCommandParser.IsVerb(arguments));
    }
}
