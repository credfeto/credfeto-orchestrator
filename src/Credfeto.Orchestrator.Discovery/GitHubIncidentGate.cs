using System;
using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Discovery;

public sealed class GitHubIncidentGate : IGitHubIncidentGate
{
    // github_incident_open's curl --location --connect-timeout 5 --max-time 10
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan MaxTime = TimeSpan.FromSeconds(10);

    private readonly IUrlReader _urls;

    public GitHubIncidentGate(IUrlReader urls)
    {
        this._urls = urls;
    }

    public async ValueTask<GitHubIncident> CheckAsync(
        Uri url,
        GitHubHealthRules rules,
        CancellationToken cancellationToken
    )
    {
        try
        {
            string body = await this._urls.ReadAsync(
                request: new(Url: url, FollowRedirects: true, ConnectTimeout: ConnectTimeout, MaxTime: MaxTime),
                cancellationToken: cancellationToken
            );

            return GitHubIncidentEvaluator.Evaluate(json: body, rules: rules);
        }
        catch (UrlReadException exception)
        {
            return Unreadable(exception.Message);
        }
        catch (JqException exception)
        {
            return Unreadable("the status is not the expected JSON: " + exception.Message);
        }
    }

    private static GitHubIncident Unreadable(string problem)
    {
        return new(Kind: GitHubIncidentKind.UNREADABLE, Line: string.Empty, Problem: problem);
    }
}
