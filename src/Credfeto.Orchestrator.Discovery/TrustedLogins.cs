using System;
using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discovery;

public static class TrustedLogins
{
    // GitHub's own Copilot reviewer and Advanced Security (code scanning) bots, which get_trusted_logins always trusts
    public static readonly IReadOnlyList<string> GitHubBots =
    [
        "copilot-pull-request-reviewer",
        "github-advanced-security[bot]",
    ];

    // get_trusted_logins' list: owner (when not empty), the collaborators, the GitHub bots and the whitelisted users,
    // less creator (the pull request bot, which is never trusted), sorted and unique, printed as jq prints the JSON
    // array (two-space indented). The shell prints every login on its own line and splits the text on newlines, so a
    // login holding a newline is split here too
    public static string Build(string owner, IReadOnlyList<string> collaborators, string whitelist, string creator)
    {
        IEnumerable<string> logins = (owner.Length == 0 ? [] : new[] { owner })
            .Concat(collaborators.Where(static login => login.Length != 0))
            .Concat(GitHubBots)
            .Concat(Whitelisted(whitelist));

        IReadOnlyList<string> trusted =
        [
            .. logins
                .SelectMany(static login => login.Split('\n'))
                .Where(login => login.Length != 0 && !StringComparer.Ordinal.Equals(x: login, y: creator))
                .Distinct(StringComparer.Ordinal)
                .Order(JqStringComparer.Instance),
        ];

        return Pretty(trusted);
    }

    // WHITELISTED_USERS: comma-separated, each entry with its leading and trailing spaces removed, empty entries
    // skipped
    public static IReadOnlyList<string> Whitelisted(string whitelist)
    {
        return [.. whitelist.Split(',').Select(static user => user.Trim(' ')).Where(static user => user.Length != 0)];
    }

    // jq's indented array; the list is never empty, since the creator can be at most one of the two GitHub bots
    private static string Pretty(IReadOnlyList<string> logins)
    {
        return "[\n"
            + string.Join(
                separator: ",\n",
                values: logins.Select(static login => "  " + JqFormatter.ToJson(JqValue.FromString(login)))
            )
            + "\n]";
    }
}
