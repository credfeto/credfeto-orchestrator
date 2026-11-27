using System.Diagnostics;

namespace Credfeto.Orchestrator.Predicates;

// What a `checks` query answers: Printed is what the shell function prints and Holds whether it returns 0. Refusal
// says why the answer could differ from the one bash gives (the tool then exits 3 and bash answers); it is null for
// an answer
[DebuggerDisplay("Holds={Holds}, Printed={Printed}, Refusal={Refusal}")]
public sealed record ChecksAnswer(bool Holds, string Printed, string? Refusal)
{
    public static ChecksAnswer Of(bool holds)
    {
        return new(Holds: holds, Printed: string.Empty, Refusal: null);
    }

    public static ChecksAnswer Printing(string printed)
    {
        return new(Holds: true, Printed: printed, Refusal: null);
    }

    public static ChecksAnswer Refused(string refusal)
    {
        return new(Holds: false, Printed: string.Empty, Refusal: refusal);
    }
}
