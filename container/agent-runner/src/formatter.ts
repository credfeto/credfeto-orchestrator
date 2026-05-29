import { findByRouting } from './destinations.js';
import type { MessageInRow } from './db/messages-in.js';
import { TIMEZONE, formatLocalTime } from './timezone.js';

/**
 * Command categories for messages starting with '/'.
 * - admin: sender must be in NANOCLAW_ADMIN_USER_IDS
 * - filtered: silently drop (mark completed without processing)
 * - passthrough: pass raw to the agent (no XML wrapping)
 * - none: not a command — format normally
 */
export type CommandCategory = 'admin' | 'filtered' | 'passthrough' | 'none';

const ADMIN_COMMANDS = new Set(['/remote-control', '/clear', '/compact', '/context', '/cost', '/files']);
const FILTERED_COMMANDS = new Set(['/help', '/login', '/logout', '/doctor', '/config', '/start']);

export interface CommandInfo {
  category: CommandCategory;
  command: string; // the command name (e.g., '/clear')
  text: string; // full original text
  senderId: string | null;
}

/**
 * Categorize a message as a command or not.
 * Only applies to chat/chat-sdk messages.
 *
 * The extracted `senderId` is compared against `NANOCLAW_ADMIN_USER_IDS`
 * which stores ids in the namespaced form `<channel_type>:<raw>` (see
 * src/db/users.ts). chat-sdk-bridge serializes `author.userId` as a raw
 * platform id with no prefix, so we prefix it here. If the id already
 * contains a `:` we assume it's pre-namespaced (non-chat-sdk adapters
 * that populate `senderId` directly) and leave it alone.
 */
export function categorizeMessage(msg: MessageInRow): CommandInfo {
  const content = parseContent(msg.content);
  const text = (content.text || '').trim();
  const senderId = extractSenderId(msg, content);

  if (!text.startsWith('/')) {
    return { category: 'none', command: '', text, senderId };
  }

  // Extract the command name (e.g., '/clear' from '/clear some args')
  const command = text.split(/\s/)[0].toLowerCase();

  if (ADMIN_COMMANDS.has(command)) {
    return { category: 'admin', command, text, senderId };
  }

  if (FILTERED_COMMANDS.has(command)) {
    return { category: 'filtered', command, text, senderId };
  }

  return { category: 'passthrough', command, text, senderId };
}

/**
 * Narrow check for /clear — the only command the runner handles directly.
 * All other command gating (filtered, admin) is done by the host router
 * before messages reach the container.
 */
export function isClearCommand(msg: MessageInRow): boolean {
  const content = parseContent(msg.content);
  const text = (content.text || '').trim();
  return text.toLowerCase().startsWith('/clear');
}

/**
 * True iff this chat message's entire body is exactly "ping"
 * (case-insensitive, after trim). Used by the poll loop to answer an
 * agent-to-agent liveness/round-trip probe from config WITHOUT spending an
 * LLM turn. Deliberately exact: "ping the server", "can you ping X?", or
 * "ping" bundled with other text are real requests and must reach the agent.
 */
export function isBarePing(msg: MessageInRow): boolean {
  if (msg.kind !== 'chat' && msg.kind !== 'chat-sdk') return false;
  const content = parseContent(msg.content);
  return (content.text || '').trim().toLowerCase() === 'ping';
}

// Bare-acknowledgement texts that carry no actionable content. Match is
// exact (case-insensitive, after trim) — anything longer is by definition
// not bare-ack.
const BARE_ACK_TEXTS = new Set([
  '', '.', '👍', '👌', '✅', '🙏',
  'ack', 'acknowledged', 'acknowledged.',
  'got it', 'got it.',
  'ok', 'ok.', 'okay', 'okay.', 'k', 'kk',
  'noted', 'noted.',
  'thanks', 'thanks.', 'thx', 'ty',
  'idle', 'idle.',
  'standing by', 'standing by.',
  'loop complete', 'loop complete.',
  'loop done', 'loop done.',
  'no reply', 'no reply.',
]);

/**
 * Classify a single chat-message body as "ack-only" — i.e. a bare
 * acknowledgement, status ping, or rate-limit notification with no
 * actionable content. Used by the mid-turn-push path to suppress the
 * harness `[NEW MESSAGE ARRIVED MID-TURN]` ack-required wrapper.
 *
 * False positives here are costly (they'd make a real task look like
 * chatter), so the patterns are deliberately narrow:
 * - exact short bare-ack words
 * - "(no reply" loop-break markers (peer-emitted)
 * - rate-limit notifications
 * - "noop N…" backoff status lines (only when very short)
 *
 * Anything longer than the explicit patterns is NOT considered ack-only —
 * a substantive sentence is content even if it starts with a soft word.
 */
function isAckOnlyText(text: string): boolean {
  const t = text.trim().toLowerCase();
  if (BARE_ACK_TEXTS.has(t)) return true;
  // Loop-break "no reply" markers from peers running the loop-break rule.
  if (t.startsWith('(no reply')) return true;
  // Rate-limit notifications forwarded by Main while a peer is throttled.
  if (isRateLimitText(text)) return true;
  // Orchestrator backoff status, e.g. "noop 3, next check at 22:30Z" — only
  // suppress if the line is short enough to be pure status with no payload.
  if (/^noop\s+\d/.test(t) && t.length < 80) return true;
  return false;
}

/**
 * The Anthropic SDK emits a `result` whose text starts with this phrase
 * when the API key has hit its rate limit. We detect this in the poll
 * loop to suppress the noisy outbound (one rate-limit message used to
 * fan out as a real reply to the originating channel + every peer) and
 * to pause the container until the reset window passes.
 */
export function isRateLimitText(text: string): boolean {
  const t = text.trim().toLowerCase();
  return t.startsWith("you've hit your limit") || t.startsWith('you have hit your limit');
}

/**
 * Parse the reset moment from a rate-limit string like
 *   "You've hit your limit · resets 2:40pm (Europe/London)"
 * and return it as an absolute Unix-ms timestamp. If parsing fails (or
 * the SDK changes wording), returns null — the caller should fall back
 * to a sane default pause window.
 */
export function parseRateLimitReset(text: string, now: Date = new Date()): number | null {
  const m = text.match(/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)/i);
  if (!m) return null;
  let hour = parseInt(m[1], 10);
  const minute = m[2] ? parseInt(m[2], 10) : 0;
  const ampm = m[3].toLowerCase();
  const tz = m[4].trim();
  if (Number.isNaN(hour) || Number.isNaN(minute)) return null;
  if (hour < 1 || hour > 12 || minute < 0 || minute > 59) return null;
  if (ampm === 'pm' && hour < 12) hour += 12;
  if (ampm === 'am' && hour === 12) hour = 0;

  try {
    // Figure out today's date AND current UTC offset in the target tz.
    const fmt = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      year: 'numeric', month: 'numeric', day: 'numeric',
      hour: 'numeric', minute: 'numeric', second: 'numeric', hour12: false,
    });
    const parts = Object.fromEntries(fmt.formatToParts(now).map((p) => [p.type, p.value])) as Record<string, string>;
    const y = parseInt(parts.year, 10);
    const mo = parseInt(parts.month, 10);
    const d = parseInt(parts.day, 10);
    const h = parseInt(parts.hour === '24' ? '0' : parts.hour, 10);
    const mi = parseInt(parts.minute, 10);
    const s = parseInt(parts.second, 10);
    if ([y, mo, d, h, mi, s].some(Number.isNaN)) return null;
    // "now-in-tz as if it were UTC" minus "actual UTC now" = tz offset in ms.
    const tzAsUtcMs = Date.UTC(y, mo - 1, d, h, mi, s);
    const offsetMs = tzAsUtcMs - now.getTime();
    // Target = today in tz at hour:minute, expressed as UTC ms.
    let targetUtcMs = Date.UTC(y, mo - 1, d, hour, minute) - offsetMs;
    // If the target is already in the past it must mean tomorrow.
    if (targetUtcMs <= now.getTime()) {
      targetUtcMs += 24 * 60 * 60 * 1000;
    }
    return targetUtcMs;
  } catch {
    return null;
  }
}

/**
 * Whole-message ack-only check: only chat / chat-sdk messages can be
 * ack-only — task / webhook / system messages are substantive triggers
 * by definition and never qualify.
 */
export function isAckOnlyMessage(msg: MessageInRow): boolean {
  if (msg.kind !== 'chat' && msg.kind !== 'chat-sdk') return false;
  const content = parseContent(msg.content);
  return isAckOnlyText(content.text || '');
}

/**
 * True iff every message in the batch is ack-only and the batch is
 * non-empty. Used to gate suppression of the mid-turn ack wrapper —
 * if a single substantive message is in the batch, the wrapper still
 * fires (the agent must ack the substantive one).
 */
export function isAckOnlyBatch(messages: MessageInRow[]): boolean {
  if (messages.length === 0) return false;
  return messages.every(isAckOnlyMessage);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function extractSenderId(msg: MessageInRow, content: any): string | null {
  const raw: string | null = content?.senderId || content?.author?.userId || null;
  if (!raw) return null;
  // Already namespaced (e.g. "telegram:123") — use as-is.
  if (raw.includes(':')) return raw;
  // Raw platform id from chat-sdk serialization — prefix with channel type.
  if (!msg.channel_type) return raw;
  return `${msg.channel_type}:${raw}`;
}

/**
 * Routing context extracted from messages_in rows.
 * Copied to messages_out by default so responses go back to the sender.
 */
export interface RoutingContext {
  platformId: string | null;
  channelType: string | null;
  threadId: string | null;
  inReplyTo: string | null;
}

/**
 * Extract routing context from a batch of messages.
 *
 * Picks the most-recent **chat** message (kind === 'chat' or 'chat-sdk').
 * The most recent user-initiated chat is the right "where to reply"
 * because:
 *   - Webhooks (kind='webhook'), tasks ('task'), and system pings
 *     ('system') aren't user-driven channels — replying to them lands
 *     in the wrong place. e.g., a GitHub PR-comment webhook arrives in
 *     the same batch as a Discord DM asking for status; without the
 *     filter, the agent's plain-text reply went back to the PR
 *     comment thread instead of Discord.
 *   - Within chat messages, the most recent one is the user's latest
 *     turn — that's the channel they're actively waiting in.
 *
 * Falls back to the first message of any kind if there are no chat
 * messages in the batch (defensive — shouldn't happen in normal flow,
 * since something needs to be a chat for the agent to reply at all).
 */
export function extractRouting(messages: MessageInRow[]): RoutingContext {
  const lastChat = [...messages]
    .reverse()
    .find((m) => m.kind === 'chat' || m.kind === 'chat-sdk');
  const pick = lastChat ?? messages[0];
  return {
    platformId: pick?.platform_id ?? null,
    channelType: pick?.channel_type ?? null,
    threadId: pick?.thread_id ?? null,
    inReplyTo: pick?.id ?? null,
  };
}

/**
 * Format a batch of messages_in rows into a prompt string.
 *
 * Prepends a `<context timezone="<IANA>" />` header so the agent always knows
 * what timezone it's in — every timestamp it sees in message bodies is the
 * user's local time, and every time it produces (schedules, suggests) should
 * be interpreted as local time in that same zone. This header is v1 behavior
 * (src/v1/router.ts:20-22); dropping it led to misinterpretations where the
 * agent scheduled tasks for the wrong hour.
 *
 * Strips routing fields — the agent never sees platform_id, channel_type, thread_id.
 */
export function formatMessages(messages: MessageInRow[], options?: { interrupt?: boolean }): string {
  // INTERRUPT marker for messages pushed mid-turn (poll-loop.ts:~291).
  // The Claude Agent SDK injects pushed messages as the next user-role
  // turn input, but if the agent is deep in a tool chain it tends to
  // ignore the soft "send an ack" guidance in core.instructions.md.
  // Prepending a literal directive in the user-role payload is much
  // harder to skip past than a system-prompt rule.
  const interruptHeader = options?.interrupt
    ? '[NEW MESSAGE ARRIVED MID-TURN] Your VERY NEXT action MUST be a `mcp__nanoclaw__send_message` call to acknowledge this — before ANY other tool call. A one-line ack is fine ("Got it — finishing X first, will pick this up next."). Then resume your prior work.\n\n'
    : '';
  const header = `${interruptHeader}<context timezone="${escapeXml(TIMEZONE)}" />\n`;
  if (messages.length === 0) return header;

  // Group by kind
  const chatMessages = messages.filter((m) => m.kind === 'chat' || m.kind === 'chat-sdk');
  const taskMessages = messages.filter((m) => m.kind === 'task');
  const webhookMessages = messages.filter((m) => m.kind === 'webhook');
  const systemMessages = messages.filter((m) => m.kind === 'system');

  const parts: string[] = [];

  if (chatMessages.length > 0) {
    parts.push(formatChatMessages(chatMessages));
  }
  if (taskMessages.length > 0) {
    parts.push(...taskMessages.map(formatTaskMessage));
  }
  if (webhookMessages.length > 0) {
    parts.push(...webhookMessages.map(formatWebhookMessage));
  }
  if (systemMessages.length > 0) {
    parts.push(...systemMessages.map(formatSystemMessage));
  }

  return header + parts.join('\n\n');
}

function formatChatMessages(messages: MessageInRow[]): string {
  if (messages.length === 1) {
    return formatSingleChat(messages[0]);
  }

  const lines = ['<messages>'];
  for (const msg of messages) {
    lines.push(formatSingleChat(msg));
  }
  lines.push('</messages>');
  return lines.join('\n');
}

function formatSingleChat(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const sender = content.sender || content.author?.fullName || content.author?.userName || 'Unknown';
  const time = formatLocalTime(msg.timestamp, TIMEZONE);
  const text = content.text || '';
  const idAttr = msg.seq != null ? ` id="${msg.seq}"` : '';
  const replyAttr = content.replyTo?.id ? ` reply_to="${escapeXml(String(content.replyTo.id))}"` : '';
  const replyPrefix = formatReplyContext(content.replyTo);
  const attachmentsSuffix = formatAttachments(content.attachments);

  // Look up the destination name for the origin (reverse map lookup).
  // If not found, fall back to a raw channel:platform_id marker so nothing
  // gets silently dropped — this should only happen if the destination was
  // removed between when the message was received and when it's being processed.
  const fromDest = findByRouting(msg.channel_type, msg.platform_id);
  const fromAttr = fromDest
    ? ` from="${escapeXml(fromDest.name)}"`
    : msg.channel_type || msg.platform_id
      ? ` from="unknown:${escapeXml(msg.channel_type || '')}:${escapeXml(msg.platform_id || '')}"`
      : '';

  return `<message${idAttr}${fromAttr} sender="${escapeXml(sender)}" time="${escapeXml(time)}"${replyAttr}>${replyPrefix}${escapeXml(text)}${attachmentsSuffix}</message>`;
}

function formatTaskMessage(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const parts = ['[SCHEDULED TASK]'];
  if (content.scriptOutput) {
    parts.push('', 'Script output:', JSON.stringify(content.scriptOutput, null, 2));
  }
  parts.push('', 'Instructions:', content.prompt || '');
  return parts.join('\n');
}

function formatWebhookMessage(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  const source = content.source || 'unknown';
  const event = content.event || 'unknown';
  return `[WEBHOOK: ${source}/${event}]\n\n${JSON.stringify(content.payload || content, null, 2)}`;
}

function formatSystemMessage(msg: MessageInRow): string {
  const content = parseContent(msg.content);
  return `[SYSTEM RESPONSE]\n\nAction: ${content.action || 'unknown'}\nStatus: ${content.status || 'unknown'}\nResult: ${JSON.stringify(content.result || null)}`;
}

/**
 * Render the quoted original inside the <message> body.
 *
 * Matches v1 format (src/v1/router.ts:10-18): `<quoted_message from="X">Y</quoted_message>`.
 * Requires BOTH sender and text — if only id is present the reply_to attribute
 * on the parent <message> carries the link without an inline preview.
 *
 * No truncation here (v1 didn't truncate).
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function formatReplyContext(replyTo: any): string {
  if (!replyTo) return '';
  const sender = replyTo.sender;
  const text = replyTo.text;
  if (!sender || !text) return '';
  return `\n  <quoted_message from="${escapeXml(sender)}">${escapeXml(text)}</quoted_message>\n`;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function formatAttachments(attachments: any[] | undefined): string {
  if (!Array.isArray(attachments) || attachments.length === 0) return '';
  const parts = attachments.map((a) => {
    const name = a.name || a.filename || 'attachment';
    const type = a.type || 'file';
    const localPath = a.localPath ? `/workspace/${a.localPath}` : '';
    const url = a.url || '';
    if (localPath) {
      return `[${type}: ${escapeXml(name)} — saved to ${escapeXml(localPath)}]`;
    }
    return url ? `[${type}: ${escapeXml(name)} (${escapeXml(url)})]` : `[${type}: ${escapeXml(name)}]`;
  });
  return '\n' + parts.join('\n');
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseContent(json: string): any {
  try {
    return JSON.parse(json);
  } catch {
    return { text: json };
  }
}

function escapeXml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Strip `<internal>...</internal>` blocks from agent output, then trim.
 * Ported from v1 (src/v1/router.ts:25-27). Used to remove the agent's
 * own scratchpad/reasoning before a reply goes out over a channel.
 */
export function stripInternalTags(text: string): string {
  return text.replace(/<internal>[\s\S]*?<\/internal>/g, '').trim();
}
