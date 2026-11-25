using System;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Discovery;
using Credfeto.Orchestrator.GitHub;

namespace Credfeto.Orchestrator.Commands;

// Each command prints what the shell function it replaces prints, and exits with a code its shell caller maps to that
// function's return code
public sealed class DiscoveryCommandRunner
{
    private readonly IGitHubIncidentGate _health;
    private readonly IPriorityFeed _priorities;
    private readonly ITrustedLoginsReader _trustedLogins;

    public DiscoveryCommandRunner(
        IPriorityFeed priorities,
        ITrustedLoginsReader trustedLogins,
        IGitHubIncidentGate health
    )
    {
        this._priorities = priorities;
        this._trustedLogins = trustedLogins;
        this._health = health;
    }

    public ValueTask<DiscoveryOutcome> RunAsync(DiscoveryCommand command, CancellationToken cancellationToken)
    {
        return command.Read switch
        {
            DiscoveryRead.PRIORITIES => this.PrioritiesAsync(command: command, cancellationToken: cancellationToken),
            DiscoveryRead.TRUSTED_LOGINS => this.TrustedLoginsAsync(
                command: command,
                cancellationToken: cancellationToken
            ),
            _ => this.GitHubIncidentAsync(command: command, cancellationToken: cancellationToken),
        };
    }

    // jq -c prints the filtered feed with a newline, and nothing for a body without a JSON value
    private async ValueTask<DiscoveryOutcome> PrioritiesAsync(
        DiscoveryCommand command,
        CancellationToken cancellationToken
    )
    {
        PriorityFeedResult result = await this._priorities.FetchAsync(
            url: command.Endpoint,
            user: command.User,
            retry: command.Retry,
            cancellationToken: cancellationToken
        );

        return result.Status switch
        {
            PriorityFeedStatus.FETCHED => new(
                ExitCode: ExitCodes.Success,
                Printed: result.Items is null ? string.Empty : result.Items + "\n"
            ),
            PriorityFeedStatus.UNPARSEABLE => new(
                ExitCode: ExitCodes.Unparseable,
                Printed: string.Empty,
                Problem: $"the priorities feed at {result.Feed} is not the expected JSON: {result.Problem}"
            ),
            _ => new(
                ExitCode: ExitCodes.Failure,
                Printed: string.Empty,
                Problem: string.Create(
                    provider: CultureInfo.InvariantCulture,
                    $"the priorities feed at {result.Feed} could not be read after {command.Retry.Attempts} attempt(s): "
                ) + result.Problem
            ),
        };
    }

    // get_trusted_logins prints the array without a newline
    private async ValueTask<DiscoveryOutcome> TrustedLoginsAsync(
        DiscoveryCommand command,
        CancellationToken cancellationToken
    )
    {
        TrustedLoginsRequest request = command.TrustedLogins
            ?? throw new ArgumentException(message: "No trusted logins request", paramName: nameof(command));

        try
        {
            string trusted = await this._trustedLogins.ReadAsync(
                request: request,
                retry: command.Retry,
                cancellationToken: cancellationToken
            );

            return new(ExitCode: ExitCodes.Success, Printed: trusted);
        }
        catch (GitHubReadException exception)
        {
            return new(
                ExitCode: ExitCodes.Failure,
                Printed: string.Empty,
                Problem: string.Create(
                    provider: CultureInfo.InvariantCulture,
                    $"the collaborators of {request.Repository} could not be read after {command.Retry.Attempts} "
                )
                    + "attempt(s): "
                    + exception.Message
            );
        }
    }

    // github_incident_open prints the incident's line only for a serious or minor incident
    private async ValueTask<DiscoveryOutcome> GitHubIncidentAsync(
        DiscoveryCommand command,
        CancellationToken cancellationToken
    )
    {
        GitHubIncident incident = await this._health.CheckAsync(
            url: new(command.Endpoint),
            rules: command.Rules,
            cancellationToken: cancellationToken
        );

        return incident.Kind switch
        {
            GitHubIncidentKind.SERIOUS => new(ExitCode: ExitCodes.Success, Printed: incident.Line + "\n"),
            GitHubIncidentKind.MINOR => new(ExitCode: ExitCodes.MinorIncident, Printed: incident.Line + "\n"),
            GitHubIncidentKind.NONE => new(ExitCode: ExitCodes.NoIncident, Printed: string.Empty),
            _ => new(ExitCode: ExitCodes.Failure, Printed: string.Empty, Problem: incident.Problem),
        };
    }
}
