using System.Collections.Generic;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Commands;

// A predicate command and the options it was given, keyed on the option's name (--trusted-file)
[DebuggerDisplay("Kind={Kind}, Options={Options.Count}")]
public sealed record PredicateCommand(PredicateKind Kind, IReadOnlyDictionary<string, string> Options);
