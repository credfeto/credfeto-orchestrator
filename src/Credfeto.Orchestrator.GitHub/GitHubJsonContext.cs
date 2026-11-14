using System.Text.Json.Serialization;

namespace Credfeto.Orchestrator.GitHub;

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(PullRequestListResult))]
[JsonSerializable(typeof(BranchRequiredChecksResult))]
[JsonSerializable(typeof(string))]
internal sealed partial class GitHubJsonContext : JsonSerializerContext;
