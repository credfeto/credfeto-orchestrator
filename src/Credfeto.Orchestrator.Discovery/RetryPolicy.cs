using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Discovery;

// A read is tried up to Attempts times, sleeping Delay between two attempts (never after the last, and not at all when
// Delay is zero), as the shell's PRIORITIES_FETCH_RETRY_* and GH_COLLABORATORS_RETRY_* settings do
[DebuggerDisplay("Attempts={Attempts}, Delay={Delay}")]
public sealed record RetryPolicy(int Attempts, TimeSpan Delay);
