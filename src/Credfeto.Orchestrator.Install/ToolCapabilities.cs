using System;
using System.Collections.Generic;
using System.Linq;
using Credfeto.Orchestrator.Agents;
using Credfeto.Orchestrator.Commands;
using Credfeto.Orchestrator.Discord;
using Credfeto.Orchestrator.Podman;
using Credfeto.Orchestrator.State;

namespace Credfeto.Orchestrator.Install;

// What --capabilities prints (#2095): the header, then one line for each command the tool accepts, "<verb> <command>"
// ("discord payload <kind>" for the payload kinds), in ordinal order, each taken from the name table its parser
// parses with, so the list cannot drift from what the tool accepts. oneshot (lib/self-install) reads it once a run
// and asks the installed binary only for the commands it lists, so a bash checkout newer than the binary never makes
// it print a usage error. src/Credfeto.Orchestrator.Install/capabilities.txt holds this build's list for oneshot.
public static class ToolCapabilities
{
    public const string Header = "credfeto-orchestrator capabilities 1";

    private const string SEPARATOR = " ";

    public static IReadOnlyList<string> Lines { get; } = Build();

    // The header and every line, each ended by a newline, as --capabilities prints them
    public static string Text { get; } = string.Concat(Lines.Prepend(Header).Select(line => line + "\n"));

    private static string[] Build()
    {
        IEnumerable<string> lines =
        [
            .. Prefixed(verb: AgentCommandParser.Verb, names: AgentCommandParser.Names),
            .. Prefixed(verb: DiscordCommandParser.Verb, names: DiscordTextCommandParser.Names),
            .. Prefixed(
                verb: DiscordCommandParser.Verb + SEPARATOR + DiscordCommandParser.Payload,
                names: DiscordCommandParser.Names
            ),
            .. Prefixed(verb: DiscoveryCommandParser.Verb, names: DiscoveryCommandParser.Names),
            .. Prefixed(verb: FingerprintCommandParser.Verb, names: FingerprintCommandParser.Names),
            .. Prefixed(verb: GitCommandParser.Verb, names: GitCommandParser.Names),
            .. Prefixed(verb: GitHubCommandParser.Verb, names: GitHubCommandParser.Names),
            .. Prefixed(verb: PodmanCommandParser.Verb, names: PodmanCommandParser.Names),
            .. Prefixed(verb: PodmanCommandParser.Verb, names: PodmanTextCommandParser.Names),
            .. Prefixed(verb: PredicateCommandParser.Verb, names: PredicateCommandParser.Names),
            .. Prefixed(verb: PromptCommandParser.Verb, names: PromptCommandParser.Names),
            .. Prefixed(verb: StateCommandParser.Verb, names: StateCommandParser.Names),
        ];

        return [.. lines.Order(StringComparer.Ordinal)];
    }

    private static IEnumerable<string> Prefixed(string verb, IReadOnlyList<string> names)
    {
        return names.Select(name => verb + SEPARATOR + name);
    }
}
