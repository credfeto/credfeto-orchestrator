using System.Text.RegularExpressions;

namespace Credfeto.Orchestrator.Predicates;

// The other patterns lib/github-status matches with jq's test and capture, spelled out for .NET as
// PlanApprovalRule explains
internal static partial class StatusPatterns
{
    private const int MATCH_TIMEOUT_MILLISECONDS = 1000;

    private const RegexOptions OPTIONS = RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture;

    // issue_json_has_plan_comment's test("##\\s*Implementation Plan"; "i"): \s is [[:space:]], so this
    // is the loose plan heading
    private const string PLAN_COMMENT =
        "##"
        + PlanApprovalRule.WHITE_SPACE
        + "*[iI][mM][pP][lL][eE][mM][eE][nN][tT][aA][tT][iI][oO][nN] [pP][lL][aA][nN]";

    // pr_json_env_block_image_sha's capture("<!--\\s*orchestrator:env-block\\s+image-sha=(?<sha>[0-9a-f]+)\\s*-->")
    private const string ENV_BLOCK =
        "<!--"
        + PlanApprovalRule.WHITE_SPACE
        + "*orchestrator:env-block"
        + PlanApprovalRule.WHITE_SPACE
        + "+image-sha=(?<sha>[0-9a-f]+)"
        + PlanApprovalRule.WHITE_SPACE
        + "*-->";

    [GeneratedRegex(pattern: PLAN_COMMENT, options: OPTIONS, matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS)]
    public static partial Regex PlanComment();

    [GeneratedRegex(pattern: ENV_BLOCK, options: OPTIONS, matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS)]
    public static partial Regex EnvBlock();
}
