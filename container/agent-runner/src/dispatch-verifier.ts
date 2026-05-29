/**
 * Post-turn verifier: catches the "narrated dispatch without actually sending"
 * failure mode that breaks the orchestration chain silently.
 *
 * When an agent says "Dispatched Code Writer" in its chat reply without
 * emitting a matching `<message to="code-writer">…</message>` block, the
 * peer never wakes; downstream cycles see the same "still waiting on X"
 * report indefinitely. The agent's own runtime prompt (`core.instructions.md`
 * §"Say-do consistency") forbids this, but compliance drifts under load.
 *
 * This module scans the agent's final reply for dispatch verbs targeting
 * known agent destinations, cross-references against the dispatches that
 * actually happened in the same turn, and returns a correction string if
 * the agent claimed something it didn't do. The poll-loop pushes that
 * correction back into the active query so the agent gets one shot to
 * actually emit the missing block before the turn closes.
 */

// Two-pass scan: find dispatch verbs, then collect every known-peer-name
// token in the following ~200 chars (up to the next sentence boundary or
// the next verb). This handles "Dispatched X and Y", "Sent X, Y, then Z",
// and stand-alone "Delegated to the rebase-agent" uniformly.
//
// The dest-name filter (knownAgentDests) is what keeps the second pass
// from false-positiving on words like "and", "the", "agent" — only names
// that actually live in the runtime destinations map get flagged.
const VERB_PATTERN = new RegExp(
  String.raw`\b(?:dispatch(?:ed|ing)?|delegat(?:ed|ing)?|hand(?:ed)?\s+off|forward(?:ed|ing)?|pass(?:ed)?\s+(?:on\s+)?to|rout(?:ed|ing)?|messag(?:ed|ing)|sent|sending|ask(?:ed)?)\b`,
  'gi',
);
const PEER_TOKEN_PATTERN = /\x60?([a-z][a-z0-9_-]{1,30})\x60?/g;
// Sentence-end punctuation or a second verb cuts the look-ahead window —
// keeps "Dispatched X. Y is still running." from flagging Y.
const WINDOW_END = /[.!?\n]|\b(?:dispatch|delegat|forward|rout|messag|send|sent|hand|pass|ask)/i;

/**
 * Compare narrated dispatch claims against actually-dispatched destinations.
 *
 * @param text                Agent's final reply text (post-`<internal>` strip not required —
 *                            internal tags are part of "the agent's own scratchpad" and the
 *                            say-do rule applies there too).
 * @param dispatchedTo        Set of destination names this turn actually sent to via
 *                            `<message to="X">` (or any other recognised dispatch path).
 *                            Lower-cased.
 * @param knownAgentDests     Set of valid agent destination names from the runtime
 *                            destinations map. Used to filter false positives — we only
 *                            flag a claim if it names a real peer.
 * @returns null if all claims match actual sends; otherwise a correction string
 *          suitable for pushing back into the active query.
 */
export function verifyDispatchClaims(
  text: string,
  dispatchedTo: Set<string>,
  knownAgentDests: Set<string>,
): string | null {
  if (knownAgentDests.size === 0) return null;

  const claimed = new Set<string>();
  // Reset module-level regex state — multiple calls share the regex objects.
  VERB_PATTERN.lastIndex = 0;
  let verbMatch: RegExpExecArray | null;
  while ((verbMatch = VERB_PATTERN.exec(text)) !== null) {
    const windowStart = VERB_PATTERN.lastIndex;
    const rawWindow = text.slice(windowStart, windowStart + 200);
    const endIdx = rawWindow.search(WINDOW_END);
    const window = endIdx >= 0 ? rawWindow.slice(0, endIdx) : rawWindow;

    PEER_TOKEN_PATTERN.lastIndex = 0;
    let peerMatch: RegExpExecArray | null;
    while ((peerMatch = PEER_TOKEN_PATTERN.exec(window)) !== null) {
      const name = peerMatch[1].toLowerCase();
      if (knownAgentDests.has(name)) {
        claimed.add(name);
      }
    }
  }

  const missing = [...claimed].filter((n) => !dispatchedTo.has(n));
  if (missing.length === 0) return null;

  const list = missing.map((n) => `\`${n}\``).join(', ');
  const exampleName = missing[0];
  return [
    `[VERIFY] Your reply narrated a dispatch to ${list}, but no matching \`<message to="${exampleName}">…</message>\` block was emitted in this turn.`,
    `Either emit the missing dispatch block(s) now, or correct your reply so it doesn't claim a send that didn't happen.`,
    `(Say-do rule: \`core.instructions.md\` §"Say-do consistency".)`,
  ].join(' ');
}
