using Credfeto.Orchestrator.Fingerprints;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Predicates;

// lib/globals' _JQ_DEF_COUNTED_LOGIN and _JQ_DEF_AUTOMATED_SUMMARY, with $trusted and $me bound
internal sealed class CountedLogins
{
    private readonly JqValue _me;
    private readonly JqValue _trusted;

    public CountedLogins(JqValue trusted, string me)
    {
        this._trusted = trusted;
        this._me = JqValue.FromString(me);
    }

    // counted_login: a login counts when there is no trusted list or jq's index finds it in the list,
    // and it is not the orchestrator's own (when one is given)
    public bool Counts(JqValue login)
    {
        return (
                JqBuiltins.Equal(left: this._trusted, right: JqValue.Null)
                || JqBuiltins.HasIndex(value: this._trusted, item: login)
            ) && (this._me.Text.Length == 0 || !JqBuiltins.Equal(left: login, right: this._me));
    }

    // def automated_summary($b)
    public static bool IsAutomatedSummary(JqValue body)
    {
        return AutomatedSummary.IsAutomatedSummary(body);
    }
}
