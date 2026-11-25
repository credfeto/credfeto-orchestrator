using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Credfeto.Orchestrator.GitHub;

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(PullRequestListResult))]
[JsonSerializable(typeof(BranchRequiredChecksResult))]
[JsonSerializable(typeof(AuthStatusResult))]
[JsonSerializable(typeof(PullRequestViewResult))]
[JsonSerializable(typeof(BranchCompareResult))]
[JsonSerializable(typeof(PullRequestCommentsResult))]
[JsonSerializable(typeof(ClosingIssueLabelsResult))]
[JsonSerializable(typeof(string))]
[JsonSerializable(typeof(bool))]
[JsonSerializable(typeof(int))]
[JsonSerializable(typeof(IReadOnlyList<string>))]
internal sealed partial class GitHubJsonContext : JsonSerializerContext;
