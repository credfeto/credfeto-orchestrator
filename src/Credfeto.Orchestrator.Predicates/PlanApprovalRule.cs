using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Credfeto.Orchestrator.Predicates;

// The plan-approval rule's patterns (#1772), as issue_json_has_human_plan_approval (lib/github-status)
// applies them with jq's test(pattern; "i"). The four *Pattern constants are lib/globals' copies of
// cfwf's, kept here so the parity fixture can check both sides hold the same text. jq matches them
// with Oniguruma, so each .NET pattern spells out what Oniguruma's case-insensitive match accepts
// rather than relying on RegexOptions.IgnoreCase: an ASCII letter matches either case, k also
// matches the Kelvin sign (U+212A) and s the long s (U+017F), a class of ASCII letters takes those
// two as well, "ss" also matches the sharp s (U+00DF, U+1E9E) and "st" the st ligatures (U+FB05,
// U+FB06). [[:space:]] and \s match the same set in both engines (spelled out here), and jq's .
// matches one code point, a surrogate pair in .NET's UTF-16. Never loosen any of them: they are the
// human gate on every implementation plan.
public static partial class PlanApprovalRule
{
    public const string LoosePlanHeadingPattern = "##[[:space:]]*Implementation Plan";

    public const string ApprovalLineKeywordPattern = "(^|[^A-Za-z0-9_])(approved|lgtm)([^A-Za-z0-9_]|$)";

    public const string ApprovalNegationPattern =
        "(^|[^A-Za-z])(not|no|never|nope|cannot|pending|awaiting|until|unless|once|if|yet|almost|nearly|partially)"
        + "([^A-Za-z]|$)|(do|does|did|is|are|was|were|has|have|had|ca|wo|could|would|should|must|need|ai)"
        + "n.?t([^A-Za-z]|$)|[?]";

    public const string ApproverAssociationsList = "OWNER MEMBER COLLABORATOR";

    // Oniguruma's [[:space:]] and \s
    internal const string WHITE_SPACE =
        @"[\t-\r \u0085   - 

  　]";

    private const int MATCH_TIMEOUT_MILLISECONDS = 1000;

    private const RegexOptions OPTIONS = RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture;

    // [^A-Za-z0-9_] and [^A-Za-z] under "i"
    private const string NOT_WORD = @"[^A-Za-z0-9_ſK]";
    private const string NOT_LETTER = @"[^A-Za-zſK]";

    // s and s or ß; s and t or ﬅ
    private const string SS = @"(?:[sSſ][sSſ]|[ßẞ])";
    private const string ST = @"(?:[sSſ][tT]|[ﬅﬆ])";
    private const string S = @"[sSſ]";

    // jq's .: one code point other than a newline
    private const string ANY = @"(?:[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\n])";

    private const string HEADING =
        "##" + WHITE_SPACE + "*[iI][mM][pP][lL][eE][mM][eE][nN][tT][aA][tT][iI][oO][nN] [pP][lL][aA][nN]";

    private const string KEYWORD =
        "(?:^|" + NOT_WORD + ")(?:[aA][pP][pP][rR][oO][vV][eE][dD]|[lL][gG][tT][mM])(?:" + NOT_WORD + "|$)";

    private const string NEGATED_WORDS =
        "[nN][oO][tT]|[nN][oO]|[nN][eE][vV][eE][rR]|[nN][oO][pP][eE]|[cC][aA][nN][nN][oO][tT]"
        + "|[pP][eE][nN][dD][iI][nN][gG]|[aA][wW][aA][iI][tT][iI][nN][gG]|[uU][nN][tT][iI][lL]"
        + "|[uU][nN][lL][eE]"
        + SS
        + "|[oO][nN][cC][eE]|[iI][fF]|[yY][eE][tT]|[aA][lL][mM][oO]"
        + ST
        + "|[nN][eE][aA][rR][lL][yY]|[pP][aA][rR][tT][iI][aA][lL][lL][yY]";

    private const string CONTRACTED_WORDS =
        "[dD][oO]|[dD][oO][eE]"
        + S
        + "|[dD][iI][dD]|[iI]"
        + S
        + "|[aA][rR][eE]|[wW][aA]"
        + S
        + "|[wW][eE][rR][eE]|[hH][aA]"
        + S
        + "|[hH][aA][vV][eE]|[hH][aA][dD]|[cC][aA]|[wW][oO]"
        + "|[cC][oO][uU][lL][dD]|[wW][oO][uU][lL][dD]|"
        + S
        + "[hH][oO][uU][lL][dD]|[mM][uU]"
        + ST
        + "|[nN][eE][eE][dD]|[aA][iI]";

    private const string NEGATION =
        "(?:^|"
        + NOT_LETTER
        + ")(?:"
        + NEGATED_WORDS
        + ")(?:"
        + NOT_LETTER
        + "|$)"
        + "|(?:"
        + CONTRACTED_WORDS
        + ")[nN]"
        + ANY
        + "?[tT](?:"
        + NOT_LETTER
        + "|$)"
        + "|[?]";

    public static IReadOnlyList<string> ApproverAssociations { get; } = ApproverAssociationsList.Split(' ');

    // def loose_plan: test($loose; "i")
    public static bool IsLoosePlanHeading(string text)
    {
        return LoosePlanHeading().IsMatch(text);
    }

    // test("^ {0,3}>"): a Markdown quote line
    public static bool IsQuoteLine(string line)
    {
        return QuoteLine().IsMatch(line);
    }

    // test($keyword; "i")
    public static bool HasSignOffKeyword(string line)
    {
        return SignOffKeyword().IsMatch(line);
    }

    // test($negation; "i")
    public static bool HasNegation(string line)
    {
        return Negation().IsMatch(line);
    }

    // def approval_line: a line that is not a quote, holds a sign-off keyword and no negation
    public static bool IsApprovalLine(string line)
    {
        return !IsQuoteLine(line) && HasSignOffKeyword(line) && !HasNegation(line);
    }

    [GeneratedRegex(pattern: HEADING, options: OPTIONS, matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS)]
    private static partial Regex LoosePlanHeading();

    [GeneratedRegex(pattern: "^ {0,3}>", options: OPTIONS, matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS)]
    private static partial Regex QuoteLine();

    [GeneratedRegex(pattern: KEYWORD, options: OPTIONS, matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS)]
    private static partial Regex SignOffKeyword();

    [GeneratedRegex(pattern: NEGATION, options: OPTIONS, matchTimeoutMilliseconds: MATCH_TIMEOUT_MILLISECONDS)]
    private static partial Regex Negation();
}
