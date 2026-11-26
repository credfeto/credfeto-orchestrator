using System.Threading;
using System.Threading.Tasks;
using Credfeto.Orchestrator.Jq;

namespace Credfeto.Orchestrator.Install;

// JSON reads and prints as jq -c does: numbers keep their literal form, keys their order, escapes are decoded
public sealed class JsonSelfTest : ISelfTestCheck
{
    private const string INPUT = """
        { "b": [1.50, 1E2, "A\n"], "a": null }
        """;

    private const string EXPECTED = """
        {"b":[1.50,1E+2,"A\n"],"a":null}
        """;

    public string Name => "json";

    public ValueTask RunAsync(CancellationToken cancellationToken)
    {
        string actual;

        try
        {
            actual = JqFormatter.ToJson(JqParser.Parse(INPUT));
        }
        catch (JqException exception)
        {
            throw new SelfTestFailedException(message: "parsing: " + exception.Message, innerException: exception);
        }

        SelfTestExpect.Same(what: "compact JSON", expected: EXPECTED, actual: actual);

        return ValueTask.CompletedTask;
    }
}
