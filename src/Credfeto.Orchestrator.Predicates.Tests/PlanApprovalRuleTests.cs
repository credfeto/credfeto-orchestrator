using FunFair.Test.Common;
using Xunit;

namespace Credfeto.Orchestrator.Predicates.Tests;

// The plan-approval line rule, as jq's Oniguruma applies lib/globals' patterns case-insensitively. The
// whole rule is also checked case by case against the shell in the parity fixture; these pin the
// Unicode corners the .NET patterns spell out by hand.
public sealed class PlanApprovalRuleTests : TestBase
{
    [Theory]
    [InlineData("Approved", true)]
    [InlineData("LGTM", true)]
    [InlineData("lgtm, ship it", true)]
    [InlineData("pre-approved", true)]
    [InlineData("approved!", true)]
    [InlineData("    > Approved", true)]
    [InlineData("\t> Approved", true)]
    [InlineData("approved \u212anot", true)]
    [InlineData("approved knot", true)]
    [InlineData("approved\u00df", true)]
    [InlineData("> Approved", false)]
    [InlineData("   > Approved", false)]
    [InlineData(">Approved", false)]
    [InlineData("Not approved", false)]
    [InlineData("approved?", false)]
    [InlineData("approve", false)]
    [InlineData("unapproved", false)]
    [InlineData("approved_", false)]
    [InlineData("approved\u212a", false)]
    [InlineData("\u017fapproved", false)]
    [InlineData("unle\u00df approved", false)]
    [InlineData("unle\u1e9e approved", false)]
    [InlineData("unle\u017f\u017f approved", false)]
    [InlineData("almo\ufb06 approved", false)]
    [InlineData("mu\ufb05n't approved", false)]
    [InlineData("isn\u2019t approved", false)]
    [InlineData("isn\U0001F600t approved", false)]
    [InlineData("doe\u017fn't approved", false)]
    [InlineData("approved \u00dfnot", false)]
    [InlineData("Approved if green", false)]
    [InlineData("approved, pending CI", false)]
    public static void AnApprovalLineIsASignOffThatIsNotQuotedOrNegated(string line, bool expected)
    {
        Assert.Equal(expected: expected, actual: PlanApprovalRule.IsApprovalLine(line));
    }

    [Theory]
    [InlineData("## Implementation Plan", true)]
    [InlineData("##\u00a0IMPLEMENTATION PLAN", true)]
    [InlineData("###implementation plan", true)]
    [InlineData("## Implementation  Plan", false)]
    [InlineData("## \u0130mplementation Plan", false)]
    [InlineData("##\u200bImplementation Plan", false)]
    [InlineData("# Implementation Plan", false)]
    public static void TheLoosePlanHeadingMatchesAnyCaseAndWhiteSpace(string text, bool expected)
    {
        Assert.Equal(expected: expected, actual: PlanApprovalRule.IsLoosePlanHeading(text));
    }

    [Fact]
    public static void TheApproverAssociationsAreTheShells()
    {
        string[] expected = ["OWNER", "MEMBER", "COLLABORATOR"];

        Assert.Equal(expected: expected, actual: PlanApprovalRule.ApproverAssociations);
    }
}
