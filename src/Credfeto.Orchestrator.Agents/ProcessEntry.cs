using System;
using System.Diagnostics;

namespace Credfeto.Orchestrator.Agents;

// One process as pkill sees it: its pid, effective uid, and the text its -f pattern is tested against (PkillText)
[DebuggerDisplay("Pid={Pid}, EffectiveUid={EffectiveUid}")]
public sealed record ProcessEntry(int Pid, uint EffectiveUid, ReadOnlyMemory<byte> Text);
