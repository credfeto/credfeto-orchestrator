using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Credfeto.Orchestrator.Discovery;

namespace Credfeto.Orchestrator.Commands;

// discovery priorities --url <url> [--user <login>] [--attempts <n>] [--delay-secs <n>]
// discovery trusted-logins --repo <owner/repo> [--owner <login>] [--whitelist <logins>] [--creator <login>]
//     [--attempts <n>] [--delay-secs <n>]
// discovery github-incident --url <url> [--component <name>]... [--serious-impact <impact>]...
//     [--outage-status <status>]...
// A single-valued option given more than once takes its last value; a list option given at all replaces its default
public static class DiscoveryCommandParser
{
    public const string Verb = "discovery";

    private const string URL = "--url";
    private const string USER = "--user";
    private const string ATTEMPTS = "--attempts";
    private const string DELAY_SECS = "--delay-secs";
    private const string REPO = "--repo";
    private const string OWNER = "--owner";
    private const string WHITELIST = "--whitelist";
    private const string CREATOR = "--creator";
    private const string COMPONENT = "--component";
    private const string SERIOUS_IMPACT = "--serious-impact";
    private const string OUTAGE_STATUS = "--outage-status";

    // lib/globals' defaults for PRIORITIES_FETCH_RETRY_* and GH_COLLABORATORS_RETRY_*
    private const int DEFAULT_ATTEMPTS = 3;
    private const int DEFAULT_DELAY_SECS = 2;

    private const string READS = "priorities, trusted-logins or github-incident";

    public static DiscoveryCommand? Parse(IReadOnlyList<string> args, out string error)
    {
        if (args.Count < 2 || !StringComparer.Ordinal.Equals(x: args[0], y: Verb))
        {
            error = "expected: discovery priorities|trusted-logins|github-incident [options]";

            return null;
        }

        DiscoveryRead? read = ParseRead(args[1]);

        if (read is null)
        {
            error = $"unknown discovery read '{args[1]}': expected {READS}";

            return null;
        }

        Dictionary<string, List<string>>? options = ParseOptions(
            args: args,
            allowed: AllowedOptions(read.Value),
            error: out error
        );

        if (options is null)
        {
            return null;
        }

        return read switch
        {
            DiscoveryRead.PRIORITIES => Priorities(options: options, error: out error),
            DiscoveryRead.TRUSTED_LOGINS => TrustedLogins(options: options, error: out error),
            _ => GitHubIncident(options: options, error: out error),
        };
    }

    private static DiscoveryRead? ParseRead(string read)
    {
        return read switch
        {
            "priorities" => DiscoveryRead.PRIORITIES,
            "trusted-logins" => DiscoveryRead.TRUSTED_LOGINS,
            "github-incident" => DiscoveryRead.GITHUB_INCIDENT,
            _ => null,
        };
    }

    private static IReadOnlyList<string> AllowedOptions(DiscoveryRead read)
    {
        return read switch
        {
            DiscoveryRead.PRIORITIES => [URL, USER, ATTEMPTS, DELAY_SECS],
            DiscoveryRead.TRUSTED_LOGINS => [REPO, OWNER, WHITELIST, CREATOR, ATTEMPTS, DELAY_SECS],
            _ => [URL, COMPONENT, SERIOUS_IMPACT, OUTAGE_STATUS],
        };
    }

    private static Dictionary<string, List<string>>? ParseOptions(
        IReadOnlyList<string> args,
        IReadOnlyList<string> allowed,
        out string error
    )
    {
        Dictionary<string, List<string>> options = [with(StringComparer.Ordinal)];

        for (int index = 2; index < args.Count; index += 2)
        {
            string option = args[index];

            if (index + 1 >= args.Count)
            {
                error = $"{option} needs a value";

                return null;
            }

            if (!allowed.Contains(value: option, comparer: StringComparer.Ordinal))
            {
                error = $"unknown option '{option}'";

                return null;
            }

            if (!options.TryGetValue(key: option, value: out List<string>? values))
            {
                values = [];
                options.Add(key: option, value: values);
            }

            values.Add(args[index + 1]);
        }

        error = string.Empty;

        return options;
    }

    private static DiscoveryCommand? Priorities(Dictionary<string, List<string>> options, out string error)
    {
        string? url = Required(options: options, option: URL, error: out error);

        if (url is null)
        {
            return null;
        }

        RetryPolicy? retry = Retry(options: options, error: out error);
        string user = Optional(options: options, option: USER);
        string? login = user.Length == 0 ? null : user;

        return retry is null
            ? null
            : new(
                Read: DiscoveryRead.PRIORITIES,
                Endpoint: url,
                User: login,
                Retry: retry,
                TrustedLogins: null,
                Rules: GitHubHealthRules.Default
            );
    }

    private static DiscoveryCommand? TrustedLogins(Dictionary<string, List<string>> options, out string error)
    {
        string? repository = Required(options: options, option: REPO, error: out error);

        if (repository is null)
        {
            return null;
        }

        RetryPolicy? retry = Retry(options: options, error: out error);

        return retry is null
            ? null
            : new(
                Read: DiscoveryRead.TRUSTED_LOGINS,
                Endpoint: string.Empty,
                User: null,
                Retry: retry,
                TrustedLogins: new(
                    Repository: repository,
                    Owner: Optional(options: options, option: OWNER),
                    Whitelist: Optional(options: options, option: WHITELIST),
                    Creator: Optional(options: options, option: CREATOR)
                ),
                Rules: GitHubHealthRules.Default
            );
    }

    private static DiscoveryCommand? GitHubIncident(Dictionary<string, List<string>> options, out string error)
    {
        string? url = Required(options: options, option: URL, error: out error);

        if (url is null)
        {
            return null;
        }

        if (!Uri.TryCreate(uriString: url, uriKind: UriKind.Absolute, result: out _))
        {
            error = $"{URL} must be an absolute URL";

            return null;
        }

        GitHubHealthRules rules = new(
            Components: List(options: options, option: COMPONENT, fallback: GitHubHealthRules.Default.Components),
            SeriousImpacts: List(
                options: options,
                option: SERIOUS_IMPACT,
                fallback: GitHubHealthRules.Default.SeriousImpacts
            ),
            OutageStatuses: List(
                options: options,
                option: OUTAGE_STATUS,
                fallback: GitHubHealthRules.Default.OutageStatuses
            )
        );

        return new(
            Read: DiscoveryRead.GITHUB_INCIDENT,
            Endpoint: url,
            User: null,
            Retry: new(Attempts: DEFAULT_ATTEMPTS, Delay: TimeSpan.FromSeconds(DEFAULT_DELAY_SECS)),
            TrustedLogins: null,
            Rules: rules
        );
    }

    // lib/globals accepts a positive whole number of attempts and a whole number of seconds; anything else is refused
    // here rather than replaced with the default, since the shell passes only values it has already checked
    private static RetryPolicy? Retry(Dictionary<string, List<string>> options, out string error)
    {
        int? attempts = Number(
            options: options,
            option: ATTEMPTS,
            fallback: DEFAULT_ATTEMPTS,
            minimum: 1,
            error: out error
        );

        if (attempts is null)
        {
            return null;
        }

        int? delay = Number(
            options: options,
            option: DELAY_SECS,
            fallback: DEFAULT_DELAY_SECS,
            minimum: 0,
            error: out error
        );

        return delay is null ? null : new(Attempts: attempts.Value, Delay: TimeSpan.FromSeconds(delay.Value));
    }

    private static int? Number(
        Dictionary<string, List<string>> options,
        string option,
        int fallback,
        int minimum,
        out string error
    )
    {
        error = string.Empty;

        if (!options.TryGetValue(key: option, value: out List<string>? values))
        {
            return fallback;
        }

        string value = values[^1];

        if (
            value.Length != 0
            && value.All(char.IsAsciiDigit)
            && int.TryParse(
                s: value,
                style: NumberStyles.None,
                provider: CultureInfo.InvariantCulture,
                result: out int number
            )
            && number >= minimum
        )
        {
            return number;
        }

        error = minimum == 0 ? $"{option} must be a whole number" : $"{option} must be a whole number from {minimum}";

        return null;
    }

    private static IReadOnlyList<string> List(
        Dictionary<string, List<string>> options,
        string option,
        IReadOnlyList<string> fallback
    )
    {
        return options.TryGetValue(key: option, value: out List<string>? values) ? values : fallback;
    }

    private static string Optional(Dictionary<string, List<string>> options, string option)
    {
        return options.TryGetValue(key: option, value: out List<string>? values) ? values[^1] : string.Empty;
    }

    private static string? Required(Dictionary<string, List<string>> options, string option, out string error)
    {
        string value = Optional(options: options, option: option);

        if (value.Length == 0)
        {
            error = $"{option} is required";

            return null;
        }

        error = string.Empty;

        return value;
    }
}
