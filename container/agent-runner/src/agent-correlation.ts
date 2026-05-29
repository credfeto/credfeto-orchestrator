/**
 * Session correlation for agent-to-agent messages.
 *
 * Carries a source session id through the agent-to-agent hop in the
 * `thread_id` field of an outbound row. The host's `routeAgentMessage`
 * uses it to route peer replies back to the specific source session that
 * originated the conversation, rather than picking "whichever session of
 * the target agent group was created most recently" (the bug fixed by
 * this PR — see src/modules/agent-to-agent/agent-route.ts).
 *
 * Two call sites need this: the `send_message` MCP tool (mcp-tools/core.ts)
 * and the `<message to="…">` XML dispatcher (poll-loop.ts `sendToDestination`).
 * Both paths write outbound rows with channel_type='agent', so both must
 * stamp the correlation consistently.
 */
import { getInboundDb } from './db/connection.js';

/**
 * Resolve the thread_id to stamp on an outbound agent-channel message.
 *
 * Reply case (a recent inbound from this peer's agent group exists): echo
 * its thread_id, which carries the original dispatcher's session id.
 * Initial dispatch (no prior inbound from this peer): stamp our own session
 * id from NANOCLAW_SESSION_ID so the peer's eventual reply can be routed
 * back to *this* session.
 */
export function agentReplyThreadId(targetAgentGroupId: string): string | null {
  try {
    const lastInbound = getInboundDb()
      .prepare(
        "SELECT thread_id FROM messages_in WHERE channel_type = 'agent' AND platform_id = ? ORDER BY seq DESC LIMIT 1",
      )
      .get(targetAgentGroupId) as { thread_id: string | null } | undefined;
    if (lastInbound && lastInbound.thread_id) return lastInbound.thread_id;
  } catch {
    // Inbound DB not initialized (e.g. some test paths) — fall through.
  }
  return process.env.NANOCLAW_SESSION_ID || null;
}
