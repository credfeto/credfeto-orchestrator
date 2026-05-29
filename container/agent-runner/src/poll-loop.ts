import { agentReplyThreadId } from './agent-correlation.js';
import { findByName, getAllDestinations, type DestinationEntry } from './destinations.js';
import { verifyDispatchClaims } from './dispatch-verifier.js';
import { getPendingMessages, markProcessing, markCompleted, type MessageInRow } from './db/messages-in.js';
import { writeMessageOut } from './db/messages-out.js';
import { touchHeartbeat, clearStaleProcessingAcks } from './db/connection.js';
import { getStoredSessionId, setStoredSessionId, clearStoredSessionId } from './db/session-state.js';
import {
  formatMessages,
  extractRouting,
  categorizeMessage,
  isClearCommand,
  isAckOnlyBatch,
  isBarePing,
  isRateLimitText,
  parseRateLimitReset,
  stripInternalTags,
  type RoutingContext,
} from './formatter.js';
import { writeRateLimitPause } from './rate-limit-pause.js';
import { getConfig } from './config.js';
import type { AgentProvider, AgentQuery, ProviderEvent } from './providers/types.js';

const POLL_INTERVAL_MS = 1000;
const ACTIVE_POLL_INTERVAL_MS = 500;

function log(msg: string): void {
  console.error(`[poll-loop] ${msg}`);
}

/**
 * inbound.db is journal_mode=DELETE (load-bearing for cross-mount visibility,
 * see container/agent-runner/src/db/connection.ts). Under that mode, a host
 * write briefly takes an EXCLUSIVE lock; if our 5s busy_timeout still expires
 * we get SqliteError 'database is locked'. That's transient — the next poll
 * tick will succeed. Swallow it here so a single unlucky tick doesn't crash
 * the whole agent mid-turn. Anything else propagates.
 */
function safeGetPendingMessages(): MessageInRow[] {
  try {
    return getPendingMessages();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes('database is locked')) {
      log(`inbound.db busy this tick — retrying next poll`);
      return [];
    }
    // 'unable to open database file' surfaces in test teardown when
    // processQuery's setInterval fires after the test's afterEach has
    // closed the in-memory session DB. The host owns inbound.db and never
    // removes it at runtime, so production never trips this branch.
    if (msg.includes('unable to open database')) {
      return [];
    }
    throw err;
  }
}

function generateId(): string {
  return `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Configured canned reply for a bare agent-to-agent ping, or '' if this
 * group doesn't opt in. Safe before loadConfig() (test harness) — falls
 * back to '' rather than throwing.
 */
function getPingReply(): string {
  try {
    return getConfig().pingReply;
  } catch {
    return '';
  }
}

/**
 * A task whose content JSON carries `freshSession: true` is run in an
 * ephemeral session: the prior transcript is NOT resumed, and the resulting
 * session id is NOT persisted. Use this for idempotent recurring tasks whose
 * state is fully externalized (files, GitHub, an API) — resuming the
 * transcript would re-send an ever-growing history of every prior cycle on
 * every wake. Leaving the stored session id untouched means interleaved
 * interactive chat in the same agent group still resumes its own thread.
 */
function isFreshSessionTask(msg: MessageInRow): boolean {
  if (msg.kind !== 'task') return false;
  try {
    return JSON.parse(msg.content).freshSession === true;
  } catch {
    return false;
  }
}

export interface PollLoopConfig {
  provider: AgentProvider;
  cwd: string;
  systemContext?: {
    instructions?: string;
  };
}

/**
 * Main poll loop. Runs indefinitely until the process is killed.
 *
 * 1. Poll messages_in for pending rows
 * 2. Format into prompt, call provider.query()
 * 3. While query active: continue polling, push new messages via provider.push()
 * 4. On result: write messages_out
 * 5. Mark messages completed
 * 6. Loop
 */
export async function runPollLoop(config: PollLoopConfig): Promise<void> {
  // Resume the agent's prior session from a previous container run if one
  // was persisted. The continuation is opaque to the poll-loop — the
  // provider decides how to use it (Claude resumes a .jsonl transcript,
  // other providers may reload a thread ID, etc.).
  let continuation: string | undefined = getStoredSessionId();

  if (continuation) {
    log(`Resuming agent session ${continuation}`);
  }

  // Clear leftover 'processing' acks from a previous crashed container.
  // This lets the new container re-process those messages.
  clearStaleProcessingAcks();

  let pollCount = 0;
  while (true) {
    // Skip system messages — they're responses for MCP tools (e.g., ask_user_question)
    const messages = safeGetPendingMessages().filter((m) => m.kind !== 'system');
    pollCount++;

    // Periodic heartbeat so we know the loop is alive
    if (pollCount % 30 === 0) {
      log(`Poll heartbeat (${pollCount} iterations, ${messages.length} pending)`);
    }

    if (messages.length === 0) {
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    // Accumulate gate: if the batch contains only trigger=0 rows
    // (context-only, router-stored under ignored_message_policy='accumulate'),
    // don't wake the agent. Leave them `pending` — they'll ride along the
    // next time a real trigger=1 message lands via this same getPendingMessages
    // query. Without this gate, a warm container keeps processing
    // (and potentially responding to) every accumulate-only batch, defeating
    // the "store as context, don't engage" contract. Host-side countDueMessages
    // gates the same way for wake-from-cold (see src/db/session-db.ts).
    if (!messages.some((m) => m.trigger === 1)) {
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    const ids = messages.map((m) => m.id);
    markProcessing(ids);

    const routing = extractRouting(messages);

    // Command handling: the host router gates filtered and unauthorized
    // admin commands before they reach the container. The only command
    // the runner handles directly is /clear (session reset).
    const normalMessages: MessageInRow[] = [];
    const commandIds: string[] = [];

    for (const msg of messages) {
      if ((msg.kind === 'chat' || msg.kind === 'chat-sdk') && isClearCommand(msg)) {
        log('Clearing session (resetting continuation)');
        continuation = undefined;
        clearStoredSessionId();
        writeMessageOut({
          id: generateId(),
          kind: 'chat',
          platform_id: routing.platformId,
          channel_type: routing.channelType,
          thread_id: routing.threadId,
          content: JSON.stringify({ text: 'Session cleared.' }),
        });
        commandIds.push(msg.id);
        continue;
      }
      normalMessages.push(msg);
    }

    if (commandIds.length > 0) {
      markCompleted(commandIds);
    }

    if (normalMessages.length === 0) {
      const remainingIds = ids.filter((id) => !commandIds.includes(id));
      if (remainingIds.length > 0) markCompleted(remainingIds);
      log(`All ${messages.length} message(s) were commands, skipping query`);
      continue;
    }

    // Pre-task scripts: for any task rows with a `script`, run it before the
    // provider call. Scripts returning wakeAgent=false (or erroring) gate
    // their own task row only — surviving messages still go to the agent.
    // Without the scheduling module, the marker block is empty, `keep`
    // falls back to `normalMessages`, and no gating happens.
    let keep: MessageInRow[] = normalMessages;
    let skipped: string[] = [];
    // MODULE-HOOK:scheduling-pre-task:start
    const { applyPreTaskScripts } = await import('./scheduling/task-script.js');
    const preTask = await applyPreTaskScripts(normalMessages);
    keep = preTask.keep;
    skipped = preTask.skipped;
    if (skipped.length > 0) {
      markCompleted(skipped);
      log(`Pre-task script skipped ${skipped.length} task(s): ${skipped.join(', ')}`);
    }
    // MODULE-HOOK:scheduling-pre-task:end

    if (keep.length === 0) {
      log(`All ${normalMessages.length} non-command message(s) gated by script, skipping query`);
      continue;
    }

    // Ping short-circuit: a bare "ping" is a liveness / round-trip probe
    // with a fixed answer. When this group opts in via `pingReply` in
    // container.json, answer it straight from config — no provider.query(),
    // so a connectivity check costs zero tokens (mirrors the command /
    // script short-circuits above). Opt-in is the safety boundary: only the
    // mechanical peers + watchdog set it, never the general assistant.
    // Tightly scoped so it can't swallow real work: exactly one message
    // whose entire body is exactly "ping" — "ping 8.8.8.8", "can you ping
    // X?", or "ping" bundled with other text all fall through to the agent.
    const pingReply = getPingReply();
    if (pingReply && keep.length === 1 && isBarePing(keep[0])) {
      writeMessageOut({
        id: generateId(),
        in_reply_to: routing.inReplyTo,
        kind: 'chat',
        platform_id: routing.platformId,
        channel_type: routing.channelType,
        thread_id: routing.threadId,
        content: JSON.stringify({ text: pingReply }),
      });
      markCompleted(keep.map((m) => m.id));
      log('Ping short-circuit: answered from config, no provider call (0 tokens)');
      continue;
    }

    // Format messages: passthrough commands get raw text (only if the
    // provider natively handles slash commands), others get XML.
    const prompt = formatMessagesWithCommands(keep, config.provider.supportsNativeSlashCommands);

    // Ephemeral run: every wake-eligible message in this batch is a
    // fresh-session task. Don't resume the prior transcript and don't
    // persist the session id this run produces — see isFreshSessionTask.
    // Mixed batches (a chat interleaved with the task) fall back to the
    // normal resume path so interactive continuity isn't broken.
    const ephemeral = keep.length > 0 && keep.every(isFreshSessionTask);
    const runContinuation = ephemeral ? undefined : continuation;

    log(
      `Processing ${keep.length} message(s), kinds: ${[...new Set(keep.map((m) => m.kind))].join(',')}` +
        (ephemeral ? ' (ephemeral session — no resume, no persist)' : ''),
    );

    const query = config.provider.query({
      prompt,
      continuation: runContinuation,
      cwd: config.cwd,
      systemContext: config.systemContext,
    });

    // Process the query while concurrently polling for new messages
    const skippedSet = new Set(skipped);
    const processingIds = ids.filter((id) => !commandIds.includes(id) && !skippedSet.has(id));
    try {
      const result = await processQuery(query, routing, processingIds, !ephemeral);
      if (!ephemeral && result.continuation && result.continuation !== continuation) {
        continuation = result.continuation;
        setStoredSessionId(continuation);
      }
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      log(`Query error: ${errMsg}`);

      // Stale/corrupt continuation recovery: ask the provider whether
      // this error means the stored continuation is unusable, and clear
      // it so the next attempt starts fresh. Skipped for ephemeral runs —
      // they never resumed the stored session, so an error here says
      // nothing about its validity and must not clear it.
      if (!ephemeral && continuation && config.provider.isSessionInvalid(err)) {
        log(`Stale session detected (${continuation}) — clearing for next retry`);
        continuation = undefined;
        clearStoredSessionId();
      }

      // Write error response so the user knows something went wrong
      writeMessageOut({
        id: generateId(),
        kind: 'chat',
        platform_id: routing.platformId,
        channel_type: routing.channelType,
        thread_id: routing.threadId,
        content: JSON.stringify({ text: `Error: ${errMsg}` }),
      });
    }

    // Ensure completed even if processQuery ended without a result event
    // (e.g. stream closed unexpectedly).
    markCompleted(processingIds);
    log(`Completed ${ids.length} message(s)`);
  }
}

/**
 * Format messages, handling passthrough commands differently.
 * When the provider handles slash commands natively (Claude Code),
 * passthrough commands are sent raw (no XML wrapping) so the SDK can
 * dispatch them. Otherwise they fall through to standard XML formatting.
 */
function formatMessagesWithCommands(messages: MessageInRow[], nativeSlashCommands: boolean): string {
  const parts: string[] = [];
  const normalBatch: MessageInRow[] = [];

  for (const msg of messages) {
    if (nativeSlashCommands && (msg.kind === 'chat' || msg.kind === 'chat-sdk')) {
      const cmdInfo = categorizeMessage(msg);
      if (cmdInfo.category === 'passthrough' || cmdInfo.category === 'admin') {
        // Flush normal batch first
        if (normalBatch.length > 0) {
          parts.push(formatMessages(normalBatch));
          normalBatch.length = 0;
        }
        // Pass raw command text (no XML wrapping) — SDK handles it natively
        parts.push(cmdInfo.text);
        continue;
      }
    }
    normalBatch.push(msg);
  }

  if (normalBatch.length > 0) {
    parts.push(formatMessages(normalBatch));
  }

  return parts.join('\n\n');
}

interface QueryResult {
  continuation?: string;
}

async function processQuery(
  query: AgentQuery,
  routing: RoutingContext,
  initialBatchIds: string[],
  persist: boolean,
): Promise<QueryResult> {
  let queryContinuation: string | undefined;
  let done = false;
  // Dispatch-claim verifier — see dispatch-verifier.ts. Bounded at one
  // retry per processQuery invocation: if the agent narrates a dispatch
  // without emitting the <message> block, push a correction back into
  // the active query and let it fix itself once. After that, log and
  // continue — repeated verifier loops on the same turn would burn
  // tokens for diminishing returns.
  let verifyRetriesRemaining = 1;

  // Concurrent polling: push follow-ups into the active query as they arrive.
  // We do NOT force-end the stream on silence — keeping the query open is
  // strictly cheaper than close+reopen (no cold prompt cache, no reconnect).
  // Stream liveness is decided host-side via the heartbeat file + processing
  // claim age (see src/host-sweep.ts); if something is truly stuck, the host
  // will kill the container and messages get reset to pending.
  const pollHandle = setInterval(() => {
    if (done) return;

    // Skip system messages (MCP tool responses) and /clear (needs fresh query).
    // Thread routing is the router's concern — if a message landed in this
    // session, the agent should see it. Per-thread sessions already isolate
    // threads into separate containers; shared sessions intentionally merge
    // everything. Filtering on thread_id here caused deadlocks when the
    // initial batch and follow-ups had mismatched thread_ids (e.g. a
    // host-generated welcome trigger with null thread vs a Discord DM reply).
    const newMessages = safeGetPendingMessages().filter((m) => {
      if (m.kind === 'system') return false;
      if ((m.kind === 'chat' || m.kind === 'chat-sdk') && isClearCommand(m)) return false;
      return true;
    });
    if (newMessages.length > 0) {
      const newIds = newMessages.map((m) => m.id);
      markProcessing(newIds);

      // Suppress the harness `[NEW MESSAGE ARRIVED MID-TURN]` ack-required
      // wrapper when the entire batch is bare-acks / status pings — the
      // wrapper forces a reply, and when both sides do that to each other's
      // acks they loop forever. The agent-side loop-break rule (in each
      // peer's CLAUDE.local.md) already tells it to stay silent on ack-only
      // messages; the harness just needs to stop forcing a response. See
      // formatter.ts:isAckOnlyMessage for the classification rules.
      const ackOnly = isAckOnlyBatch(newMessages);
      const prompt = formatMessages(newMessages, { interrupt: !ackOnly });
      log(
        `Pushing ${newMessages.length} follow-up message(s) into active query` +
          (ackOnly ? ' (ack-only batch — interrupt wrapper suppressed)' : ''),
      );
      query.push(prompt);

      markCompleted(newIds);
    }
  }, ACTIVE_POLL_INTERVAL_MS);

  try {
    for await (const event of query.events) {
      handleEvent(event, routing);
      touchHeartbeat();

      if (event.type === 'init') {
        queryContinuation = event.continuation;
        // Persist immediately so a mid-turn container crash still lets the
        // next wake resume the conversation. Without this, the session id
        // was only written after the full stream completed — if the
        // container died between `init` and `result`, the SDK session was
        // effectively orphaned and the next message started a blank
        // Claude session with no prior context.
        //
        // Skipped for ephemeral runs: persisting would overwrite the
        // interactive session id with a throwaway transcript, and a crash
        // mid-ephemeral-run should start fresh next time anyway.
        if (persist) setStoredSessionId(event.continuation);
      } else if (event.type === 'result') {
        // A result — with or without text — means the turn is done. Mark
        // the initial batch completed now so the host sweep doesn't see
        // stale 'processing' claims while the query stays open for
        // follow-up pushes. The agent may have responded via MCP
        // (send_message) mid-turn, or the message may not need a response
        // at all — either way the turn is finished.
        markCompleted(initialBatchIds);
        if (event.text) {
          if (handleRateLimitResult(event.text, routing)) {
            // Rate-limit detected — skip dispatching the spammy reply,
            // notify once, write the pause sentinel, and exit so the
            // host doesn't keep burning Docker spawns + API calls on
            // a key that's known-throttled.
            log('Rate-limited by Anthropic — exiting; will resume after pause window');
            process.exit(0);
          }
          const dispatchedAgents = dispatchResultText(event.text, routing);

          // Post-turn dispatch-claim verification. If the agent narrated a
          // dispatch ("Dispatched X") without actually emitting a
          // <message to="X"> block, push a correction back into the active
          // query so the agent gets one shot to fix it before the turn
          // closes. Bounded at one retry per processQuery to avoid
          // pathological feedback loops on a determinedly non-compliant
          // turn (token cost > recovery value beyond the first nudge).
          if (verifyRetriesRemaining > 0) {
            const knownAgentDests = new Set(
              getAllDestinations()
                .filter((d) => d.type === 'agent')
                .map((d) => d.name.toLowerCase()),
            );
            const correction = verifyDispatchClaims(event.text, dispatchedAgents, knownAgentDests);
            if (correction) {
              verifyRetriesRemaining--;
              log(`Dispatch-claim verifier: ${correction}`);
              query.push(correction);
            }
          }
        }
      }
    }
  } finally {
    done = true;
    clearInterval(pollHandle);
  }

  return { continuation: queryContinuation };
}

function handleEvent(event: ProviderEvent, _routing: RoutingContext): void {
  switch (event.type) {
    case 'init':
      log(`Session: ${event.continuation}`);
      break;
    case 'result':
      log(`Result: ${event.text ? event.text.slice(0, 200) : '(empty)'}`);
      break;
    case 'error':
      log(`Error: ${event.message} (retryable: ${event.retryable}${event.classification ? `, ${event.classification}` : ''})`);
      break;
    case 'progress':
      log(`Progress: ${event.message}`);
      break;
  }
}

/**
 * Default pause window when the Anthropic rate-limit string doesn't
 * include a parseable reset time. Short enough not to miss a 15-min
 * rate-limit window; long enough that the host doesn't hot-spawn the
 * container every 5 minutes for nothing.
 */
const DEFAULT_RATE_LIMIT_PAUSE_MS = 15 * 60 * 1000;

/**
 * If `text` is an Anthropic rate-limit result, post one notification
 * to the originating channel, persist the pause sentinel, and return
 * true so the caller skips the normal dispatch path. Returns false
 * for non-rate-limit results.
 */
function handleRateLimitResult(text: string, routing: RoutingContext): boolean {
  if (!isRateLimitText(text)) return false;

  const now = Date.now();
  const parsed = parseRateLimitReset(text, new Date(now));
  const pausedUntilMs = parsed ?? now + DEFAULT_RATE_LIMIT_PAUSE_MS;
  const resetIso = new Date(pausedUntilMs).toISOString();
  const trimmed = text.trim();

  writeRateLimitPause({
    paused_until_ms: pausedUntilMs,
    hit_at_ms: now,
    reason: trimmed.slice(0, 200),
  });

  const assistantName = getConfig().assistantName || 'Agent';
  const body = `⏸ ${assistantName} is paused — Anthropic rate-limited. Original message: "${trimmed}". Resuming after ${resetIso}.`;

  if (routing.channelType && routing.platformId) {
    writeMessageOut({
      id: generateId(),
      in_reply_to: routing.inReplyTo,
      kind: 'chat',
      platform_id: routing.platformId,
      channel_type: routing.channelType,
      thread_id: routing.threadId,
      content: JSON.stringify({ text: body }),
    });
  } else {
    const all = getAllDestinations();
    if (all.length === 1) {
      sendToDestination(all[0], body, routing);
    } else {
      log(`Rate-limit detected but no routing target available — notification dropped`);
    }
  }

  return true;
}

/**
 * Parse the agent's final text for <message to="name">...</message> blocks
 * and dispatch each one to its resolved destination. Text outside of blocks
 * (including <internal>...</internal>) is normally scratchpad — logged but
 * not sent.
 *
 * Single-destination shortcut: if the agent has exactly one configured
 * destination AND the output contains zero <message> blocks, the entire
 * cleaned text (with <internal> tags stripped) is sent to that destination.
 * This preserves the simple case of one user on one channel — the agent
 * doesn't need to know about wrapping syntax at all.
 */
function dispatchResultText(text: string, routing: RoutingContext): Set<string> {
  const MESSAGE_RE = /<message\s+to="([^"]+)"\s*>([\s\S]*?)<\/message>/g;

  let match: RegExpExecArray | null;
  let sent = 0;
  let lastIndex = 0;
  const scratchpadParts: string[] = [];
  // Agent destinations actually dispatched this turn — returned to the
  // caller so the dispatch-claim verifier can cross-reference against
  // the agent's narration. Channel destinations (Discord, CLI, etc.) are
  // excluded because the say-do rule is about peer dispatches.
  const dispatchedAgents = new Set<string>();

  while ((match = MESSAGE_RE.exec(text)) !== null) {
    if (match.index > lastIndex) {
      scratchpadParts.push(text.slice(lastIndex, match.index));
    }
    const toName = match[1];
    const body = match[2].trim();
    lastIndex = MESSAGE_RE.lastIndex;

    const dest = findByName(toName);
    if (!dest) {
      log(`Unknown destination in <message to="${toName}">, dropping block`);
      scratchpadParts.push(`[dropped: unknown destination "${toName}"] ${body}`);
      continue;
    }
    sendToDestination(dest, body, routing);
    sent++;
    if (dest.type === 'agent') dispatchedAgents.add(toName.toLowerCase());
  }

  // Fallback for unclosed <message to="X"> blocks. The model sometimes
  // drifts into the SDK's tool-call XML format mid-stream and closes a
  // <message> with </parameter> (or no close at all). Without this we
  // silently drop the entire intended payload and dump the raw <message>
  // open-tag text back to the originating channel, which is exactly the
  // failure mode that left peer agents unwoken in production. Greedy
  // match consumes everything from the open tag to end-of-string; the
  // strip regex removes a stray close tag the model wrote with the
  // wrong name (parameter / tool_use / invoke).
  if (lastIndex < text.length) {
    const remaining = text.slice(lastIndex);
    const UNCLOSED_RE = /<message\s+to="([^"]+)"\s*>([\s\S]*)$/;
    const unclosed = remaining.match(UNCLOSED_RE);
    if (unclosed && unclosed.index !== undefined) {
      if (unclosed.index > 0) {
        scratchpadParts.push(remaining.slice(0, unclosed.index));
      }
      const toName = unclosed[1];
      const body = unclosed[2].replace(/<\/(message|parameter|tool_use|invoke)\s*>\s*$/i, '').trim();
      const dest = findByName(toName);
      if (!dest) {
        log(`Unknown destination in unclosed <message to="${toName}">, dropping block`);
        scratchpadParts.push(`[dropped: unknown destination "${toName}"] ${body}`);
      } else {
        log(`Recovered unclosed <message to="${toName}"> (no </message> close tag found)`);
        sendToDestination(dest, body, routing);
        sent++;
        if (dest.type === 'agent') dispatchedAgents.add(toName.toLowerCase());
      }
    } else {
      scratchpadParts.push(remaining);
    }
  }

  const scratchpad = stripInternalTags(scratchpadParts.join(''));

  // Single-destination shortcut: the agent wrote plain text — send to
  // the session's originating channel (from session_routing) if available,
  // otherwise fall back to the single destination.
  if (sent === 0 && scratchpad) {
    if (routing.channelType && routing.platformId) {
      // Reply to the channel/thread the message came from
      writeMessageOut({
        id: generateId(),
        in_reply_to: routing.inReplyTo,
        kind: 'chat',
        platform_id: routing.platformId,
        channel_type: routing.channelType,
        thread_id: routing.threadId,
        content: JSON.stringify({ text: scratchpad }),
      });
      return dispatchedAgents;
    }
    const all = getAllDestinations();
    if (all.length === 1) {
      sendToDestination(all[0], scratchpad, routing);
      if (all[0].type === 'agent') dispatchedAgents.add(all[0].name.toLowerCase());
      return dispatchedAgents;
    }
  }

  if (scratchpad) {
    log(`[scratchpad] ${scratchpad.slice(0, 500)}${scratchpad.length > 500 ? '…' : ''}`);
  }

  if (sent === 0 && text.trim()) {
    log(`WARNING: agent output had no <message to="..."> blocks — nothing was sent`);
  }

  return dispatchedAgents;
}

function sendToDestination(dest: DestinationEntry, body: string, routing: RoutingContext): void {
  const platformId = dest.type === 'channel' ? dest.platformId! : dest.agentGroupId!;
  const channelType = dest.type === 'channel' ? dest.channelType! : 'agent';
  // Channel sends inherit thread_id from the inbound routing context so replies
  // land in the same thread the conversation is in (non-threaded adapters: the
  // router strips thread_id at ingest, so this is already null). Agent sends
  // carry session correlation in thread_id instead — see agentReplyThreadId.
  const threadId = dest.type === 'agent' ? agentReplyThreadId(dest.agentGroupId!) : routing.threadId;
  writeMessageOut({
    id: generateId(),
    in_reply_to: routing.inReplyTo,
    kind: 'chat',
    platform_id: platformId,
    channel_type: channelType,
    thread_id: threadId,
    content: JSON.stringify({ text: body }),
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
