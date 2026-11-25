using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discovery;

// github_incident_open's jq program (lib/github-health), line for line
public static class GitHubIncidentEvaluator
{
    private static readonly JqValue NoText = JqValue.FromString(string.Empty);

    // Throws JqException where the jq program fails: a body that is not one JSON value, or not an object with an
    // incidents array. A missing or malformed components list only means no live component status is known
    public static GitHubIncident Evaluate(string json, GitHubHealthRules rules)
    {
        JqValue summary = JqParser.Parse(json);
        JqValue incidents =
            summary.Kind == JqKind.DICTIONARY ? JqOps.Field(value: summary, name: "incidents") : JqValue.Null;

        if (incidents.Kind != JqKind.ARRAY)
        {
            throw new JqException("unexpected status JSON");
        }

        IReadOnlyDictionary<string, string> live = LiveStatuses(summary);
        IReadOnlyList<Candidate> candidates =
        [
            .. incidents
                .Items.Where(static incident => incident.Kind == JqKind.DICTIONARY)
                .Select(incident => Assess(incident: incident, live: live, rules: rules))
                .OfType<Candidate>(),
        ];

        Candidate? serious = candidates.FirstOrDefault(static candidate => candidate.Serious);

        if (serious is not null)
        {
            return new(Kind: GitHubIncidentKind.SERIOUS, Line: $"{serious.Name}\t{serious.Created}");
        }

        return candidates.Count == 0 ? new(Kind: GitHubIncidentKind.NONE, Line: string.Empty) : Minor(candidates[0]);
    }

    private static GitHubIncident Minor(Candidate minor)
    {
        return new(
            Kind: GitHubIncidentKind.MINOR,
            Line: $"{minor.Name}\t{minor.Created}\t{minor.Component}: {minor.State}"
        );
    }

    // (.components // []) as $c | if ($c | type) == "array" then [ $c[] | select(type == "object") | {key: ((.name //
    // "") | tostring), value: ((.status // "") | tostring)} ] | from_entries else {} end
    private static Dictionary<string, string> LiveStatuses(JqValue summary)
    {
        Dictionary<string, string> live = [with(StringComparer.Ordinal)];
        JqValue components = JqOps.Alternative(
            value: JqOps.Field(value: summary, name: "components"),
            fallback: JqValue.EmptyArray
        );

        if (components.Kind != JqKind.ARRAY)
        {
            return live;
        }

        foreach (JqValue component in components.Items.Where(static item => item.Kind == JqKind.DICTIONARY))
        {
            live[TextOf(value: component, name: "name", fallback: NoText)] = TextOf(
                value: component,
                name: "status",
                fallback: NoText
            );
        }

        return live;
    }

    private static Candidate? Assess(
        JqValue incident,
        IReadOnlyDictionary<string, string> live,
        GitHubHealthRules rules
    )
    {
        IReadOnlyList<string> hit = UsedComponents(incident: incident, rules: rules);

        if (hit.Count == 0)
        {
            return null;
        }

        string impact = TextOf(value: incident, name: "impact", fallback: NoText);
        bool serious =
            IsMember(value: impact, list: rules.SeriousImpacts)
            || hit.Any(component =>
                IsMember(
                    value: live.GetValueOrDefault(key: component, defaultValue: string.Empty),
                    list: rules.OutageStatuses
                )
            );
        string state = live.GetValueOrDefault(key: hit[0], defaultValue: "unknown");

        return new(
            Name: Flat(TextOf(value: incident, name: "name", fallback: JqValue.FromString("unnamed incident"))),
            Created: Flat(TextOf(value: incident, name: "created_at", fallback: JqValue.FromString("unknown time"))),
            Serious: serious,
            Component: Flat(hit[0]),
            State: Flat(state.Length == 0 ? "unknown" : state)
        );
    }

    // [ (.components // [])[]? | (.name? // "") | select(type == "string") | select(member($used)) ]: an array's
    // items or an object's values, where anything but an object names no component
    private static IReadOnlyList<string> UsedComponents(JqValue incident, GitHubHealthRules rules)
    {
        JqValue components = JqOps.Alternative(
            value: JqOps.Field(value: incident, name: "components"),
            fallback: JqValue.EmptyArray
        );
        IEnumerable<JqValue> entries = components.Kind switch
        {
            JqKind.ARRAY => components.Items,
            JqKind.DICTIONARY => components.Properties.Select(static property => property.Value),
            _ => [],
        };

        return
        [
            .. entries
                .Select(static entry =>
                    entry.Kind == JqKind.DICTIONARY
                        ? JqOps.Alternative(value: JqOps.Field(value: entry, name: "name"), fallback: NoText)
                        : NoText
                )
                .Where(name => name.Kind == JqKind.TEXT && IsMember(value: name.Text, list: rules.Components))
                .Select(static name => name.Text),
        ];
    }

    // (.<name> // fallback) | tostring
    private static string TextOf(JqValue value, string name, JqValue fallback)
    {
        return JqOps.ToText(JqOps.Alternative(value: JqOps.Field(value: value, name: name), fallback: fallback));
    }

    private static bool IsMember(string value, IReadOnlyList<string> list)
    {
        return list.Contains(value: value, comparer: StringComparer.Ordinal);
    }

    // def flat: tostring | gsub("[\t\r\n]"; " ")
    private static string Flat(string value)
    {
        return value
            .Replace(oldChar: '\t', newChar: ' ')
            .Replace(oldChar: '\r', newChar: ' ')
            .Replace(oldChar: '\n', newChar: ' ');
    }

    [DebuggerDisplay("{Name}: {Serious}")]
    private sealed record Candidate(string Name, string Created, bool Serious, string Component, string State);
}
