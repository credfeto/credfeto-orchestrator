import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb, getOutboundDb } from './db/connection.js';
import { getPendingMessages, markCompleted } from './db/messages-in.js';
import { getUndeliveredMessages } from './db/messages-out.js';
import { formatMessages, extractRouting, isAckOnlyMessage, isAckOnlyBatch, isBarePing } from './formatter.js';
import { MockProvider } from './providers/mock.js';

beforeEach(() => {
  initTestSessionDb();
});

afterEach(() => {
  closeSessionDb();
});

function insertMessage(id: string, kind: string, content: object, opts?: { processAfter?: string; trigger?: 0 | 1 }) {
  getInboundDb()
    .prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, process_after, trigger, content)
     VALUES (?, ?, datetime('now'), 'pending', ?, ?, ?)`,
    )
    .run(id, kind, opts?.processAfter ?? null, opts?.trigger ?? 1, JSON.stringify(content));
}

describe('formatter', () => {
  it('should format a single chat message', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello world' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('sender="John"');
    expect(prompt).toContain('Hello world');
  });

  it('should format multiple chat messages as XML block', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello' });
    insertMessage('m2', 'chat', { sender: 'Jane', text: 'Hi there' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('<messages>');
    expect(prompt).toContain('</messages>');
    expect(prompt).toContain('sender="John"');
    expect(prompt).toContain('sender="Jane"');
  });

  it('should format task messages', () => {
    insertMessage('m1', 'task', { prompt: 'Review open PRs' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('[SCHEDULED TASK]');
    expect(prompt).toContain('Review open PRs');
  });

  it('should format webhook messages', () => {
    insertMessage('m1', 'webhook', { source: 'github', event: 'push', payload: { ref: 'main' } });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('[WEBHOOK: github/push]');
  });

  it('should format system messages', () => {
    insertMessage('m1', 'system', { action: 'register_group', status: 'success', result: { id: 'ag-1' } });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('[SYSTEM RESPONSE]');
    expect(prompt).toContain('register_group');
  });

  it('should handle mixed kinds', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello' });
    insertMessage('m2', 'system', { action: 'test', status: 'ok', result: null });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('sender="John"');
    expect(prompt).toContain('[SYSTEM RESPONSE]');
  });

  it('should escape XML in content', () => {
    insertMessage('m1', 'chat', { sender: 'A<B', text: 'x > y && z' });
    const messages = getPendingMessages();
    const prompt = formatMessages(messages);
    expect(prompt).toContain('A&lt;B');
    expect(prompt).toContain('x &gt; y &amp;&amp; z');
  });

  it('prepends an interrupt directive when interrupt option is set', () => {
    insertMessage('m1', 'chat', { sender: 'John', text: 'Hello' });
    const messages = getPendingMessages();
    const plain = formatMessages(messages);
    const interrupted = formatMessages(messages, { interrupt: true });
    expect(plain).not.toContain('[NEW MESSAGE ARRIVED MID-TURN]');
    expect(interrupted.startsWith('[NEW MESSAGE ARRIVED MID-TURN]')).toBe(true);
    expect(interrupted).toContain('mcp__nanoclaw__send_message');
    // The original message body is still rendered after the directive.
    expect(interrupted).toContain('Hello');
    expect(interrupted).toContain('sender="John"');
  });
});

describe('ack-only classification (loop-break harness gate)', () => {
  function chat(text: string): Parameters<typeof insertMessage>[2] {
    return { sender: 'X', text };
  }

  it('classifies bare-ack texts as ack-only (case/whitespace-insensitive)', () => {
    const acks = [
      'Acknowledged.', 'ack', 'Got it', 'OK', 'k', '👍', '.', '',
      '   Acknowledged.   ', 'NOTED',
    ];
    acks.forEach((text, i) => {
      insertMessage(`a${i}`, 'chat', chat(text));
    });
    const messages = getPendingMessages();
    expect(messages).toHaveLength(acks.length);
    messages.forEach((m, i) => {
      expect({ text: acks[i], ack: isAckOnlyMessage(m) }).toEqual({ text: acks[i], ack: true });
    });
  });

  it('classifies status-ping texts as ack-only', () => {
    const acks = ['Idle', 'Standing by', 'Loop done.', 'Loop complete'];
    acks.forEach((text, i) => {
      insertMessage(`s${i}`, 'chat', chat(text));
    });
    const messages = getPendingMessages();
    messages.forEach((m, i) => {
      expect({ text: acks[i], ack: isAckOnlyMessage(m) }).toEqual({ text: acks[i], ack: true });
    });
  });

  it('classifies "(No reply ...)" loop-break markers as ack-only', () => {
    insertMessage('a1', 'chat', chat('(No reply - holding all messages per Main\'s instruction)'));
    insertMessage('a2', 'chat', chat('(No reply)'));
    const messages = getPendingMessages();
    expect(messages.every(isAckOnlyMessage)).toBe(true);
  });

  it('classifies rate-limit notifications as ack-only', () => {
    insertMessage('a1', 'chat', chat("You've hit your limit · resets 7:30pm (Europe/London)"));
    insertMessage('a2', 'chat', chat('You have hit your limit'));
    const messages = getPendingMessages();
    expect(messages.every(isAckOnlyMessage)).toBe(true);
  });

  it('classifies short "Noop N, next check at …" as ack-only', () => {
    insertMessage('a1', 'chat', chat('Noop 3, next check at 22:30Z'));
    const messages = getPendingMessages();
    expect(isAckOnlyMessage(messages[0])).toBe(true);
  });

  it('does NOT classify substantive messages as ack-only', () => {
    const real = [
      'Loop done. /priorities 200, #88 sent to rebase-agent (was BEHIND), all others awaiting review.',
      'Holding — changelog appears calmer after context compaction (now responding rather than looping).',
      'Please rebase `credfeto/credfeto-enum-source-generation` PR #88 onto main.',
      'Got it — looking it up now.',
      'Noop loop blew up because the build failed: see /tmp/build.log for details and a stack trace.',
    ];
    real.forEach((text, i) => {
      insertMessage(`r${i}`, 'chat', chat(text));
    });
    const messages = getPendingMessages();
    messages.forEach((m, i) => {
      expect({ text: real[i], ack: isAckOnlyMessage(m) }).toEqual({ text: real[i], ack: false });
    });
  });

  it('treats non-chat kinds as never ack-only', () => {
    insertMessage('m1', 'task', { prompt: 'Review open PRs' });
    insertMessage('m2', 'webhook', { source: 'github', event: 'push' });
    insertMessage('m3', 'system', { action: 'register_group', status: 'success' });
    const messages = getPendingMessages();
    expect(messages.every(isAckOnlyMessage)).toBe(false);
    messages.forEach((m) => expect(isAckOnlyMessage(m)).toBe(false));
  });

  it('isAckOnlyBatch is true only when EVERY message is ack-only and batch is non-empty', () => {
    expect(isAckOnlyBatch([])).toBe(false);

    insertMessage('a1', 'chat', chat('Acknowledged.'));
    insertMessage('a2', 'chat', chat('Got it'));
    let messages = getPendingMessages();
    expect(isAckOnlyBatch(messages)).toBe(true);
    markCompleted(messages.map((m) => m.id));

    insertMessage('a3', 'chat', chat('Acknowledged.'));
    insertMessage('a4', 'chat', chat('Please review PR #88 in repo X — it has 3 outstanding review comments.'));
    messages = getPendingMessages();
    expect(isAckOnlyBatch(messages)).toBe(false);
  });
});

describe('bare-ping classification (zero-token short-circuit gate)', () => {
  function chat(text: string): Parameters<typeof insertMessage>[2] {
    return { sender: 'Main', text };
  }

  it('matches an exact "ping" (case/whitespace-insensitive)', () => {
    const pings = ['ping', 'PING', 'Ping', '  ping  ', '\nping\n'];
    pings.forEach((text, i) => insertMessage(`p${i}`, 'chat', chat(text)));
    const messages = getPendingMessages();
    expect(messages).toHaveLength(pings.length);
    messages.forEach((m, i) => {
      expect({ text: pings[i], ping: isBarePing(m) }).toEqual({ text: pings[i], ping: true });
    });
  });

  it('does NOT match real requests that merely contain "ping"', () => {
    const notPings = [
      'ping 8.8.8.8',
      'can you ping the server?',
      'pinging now',
      'ping?',
      'ping the build and report back',
      '',
      '.',
    ];
    notPings.forEach((text, i) => insertMessage(`n${i}`, 'chat', chat(text)));
    const messages = getPendingMessages();
    messages.forEach((m, i) => {
      expect({ text: notPings[i], ping: isBarePing(m) }).toEqual({ text: notPings[i], ping: false });
    });
  });

  it('only chat / chat-sdk kinds can be a bare ping', () => {
    insertMessage('t1', 'task', { prompt: 'ping' });
    insertMessage('w1', 'webhook', { text: 'ping' });
    insertMessage('c1', 'chat', chat('ping'));
    const messages = getPendingMessages();
    const byId = Object.fromEntries(messages.map((m) => [m.id, isBarePing(m)]));
    expect(byId).toEqual({ t1: false, w1: false, c1: true });
  });
});

describe('accumulate gate (trigger column)', () => {
  it('getPendingMessages returns both trigger=0 and trigger=1 rows', () => {
    // trigger=0 rides along as context, trigger=1 is the wake-eligible row.
    // The poll loop's gate depends on this data contract.
    insertMessage('m1', 'chat', { sender: 'A', text: 'chit chat' }, { trigger: 0 });
    insertMessage('m2', 'chat', { sender: 'B', text: 'actual mention' }, { trigger: 1 });
    const messages = getPendingMessages();
    expect(messages).toHaveLength(2);
    const byId = Object.fromEntries(messages.map((m) => [m.id, m]));
    expect(byId.m1.trigger).toBe(0);
    expect(byId.m2.trigger).toBe(1);
  });

  it('trigger=0-only batch: gate predicate `some(trigger===1)` is false', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'noise' }, { trigger: 0 });
    insertMessage('m2', 'chat', { sender: 'B', text: 'more noise' }, { trigger: 0 });
    const messages = getPendingMessages();
    // This is the exact predicate the poll loop uses to skip accumulate-only
    // batches — gate should be false, so the loop sleeps without waking the agent.
    expect(messages.some((m) => m.trigger === 1)).toBe(false);
  });

  it('mixed batch: gate is true → loop proceeds, accumulated rows ride along', () => {
    insertMessage('m1', 'chat', { sender: 'A', text: 'earlier chatter' }, { trigger: 0 });
    insertMessage('m2', 'chat', { sender: 'B', text: 'the real mention' }, { trigger: 1 });
    const messages = getPendingMessages();
    expect(messages.some((m) => m.trigger === 1)).toBe(true);
    // Both messages are present for the formatter → agent sees the prior context.
    expect(messages.map((m) => m.id).sort()).toEqual(['m1', 'm2']);
  });

  it('trigger column defaults to 1 for legacy inserts without explicit value', () => {
    // The schema default is 1 (see src/db/schema.ts INBOUND_SCHEMA) — existing
    // rows / tests without the column set are effectively wake-eligible.
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, content)
         VALUES ('m1', 'chat', datetime('now'), 'pending', '{"text":"hi"}')`,
      )
      .run();
    const [msg] = getPendingMessages();
    expect(msg.trigger).toBe(1);
  });
});

describe('routing', () => {
  it('should extract routing from messages', () => {
    getInboundDb()
      .prepare(
        `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, thread_id, content)
       VALUES ('m1', 'chat', datetime('now'), 'pending', 'chan-123', 'discord', 'thread-456', '{"text":"hi"}')`,
      )
      .run();

    const messages = getPendingMessages();
    const routing = extractRouting(messages);
    expect(routing.platformId).toBe('chan-123');
    expect(routing.channelType).toBe('discord');
    expect(routing.threadId).toBe('thread-456');
    expect(routing.inReplyTo).toBe('m1');
  });

  it('routes to most recent chat message, not the first message in batch', () => {
    // Webhook arrives first (e.g. GitHub PR comment), then the user
    // follows up via chat. The plain-text reply must go to the chat
    // channel, not back to the webhook.
    const db = getInboundDb();
    db.prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, thread_id, content)
       VALUES ('w1', 'webhook', datetime('now'), 'pending', 'pr-comment-1', 'github', null, '{"text":"please rebase"}')`,
    ).run();
    db.prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, thread_id, content)
       VALUES ('m1', 'chat', datetime('now', '+1 second'), 'pending', 'discord-dm-1', 'discord', null, '{"text":"did you do it?"}')`,
    ).run();

    const messages = getPendingMessages();
    const routing = extractRouting(messages);
    expect(routing.channelType).toBe('discord');
    expect(routing.platformId).toBe('discord-dm-1');
    expect(routing.inReplyTo).toBe('m1');
  });

  it('skips non-chat messages even if they arrive after the chat', () => {
    // Webhook arrives after a chat message. The chat is still the
    // user-driven channel; the agent should reply to the chat, not
    // chase the webhook.
    const db = getInboundDb();
    db.prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, thread_id, content)
       VALUES ('m1', 'chat', datetime('now'), 'pending', 'discord-dm-1', 'discord', null, '{"text":"status?"}')`,
    ).run();
    db.prepare(
      `INSERT INTO messages_in (id, kind, timestamp, status, platform_id, channel_type, thread_id, content)
       VALUES ('w1', 'webhook', datetime('now', '+1 second'), 'pending', 'pr-comment-1', 'github', null, '{"text":"new comment"}')`,
    ).run();

    const messages = getPendingMessages();
    const routing = extractRouting(messages);
    expect(routing.channelType).toBe('discord');
    expect(routing.platformId).toBe('discord-dm-1');
    expect(routing.inReplyTo).toBe('m1');
  });
});

describe('mock provider', () => {
  it('should produce init + result events', async () => {
    const provider = new MockProvider({}, (prompt) => `Echo: ${prompt}`);
    const query = provider.query({
      prompt: 'Hello',
      cwd: '/tmp',
    });

    const events: Array<{ type: string }> = [];
    setTimeout(() => query.end(), 50);

    for await (const event of query.events) {
      events.push(event);
    }

    const typed = events.filter((e) => e.type !== 'activity');
    expect(typed.length).toBeGreaterThanOrEqual(2);
    expect(typed[0].type).toBe('init');
    expect(typed[1].type).toBe('result');
    expect((typed[1] as { text: string }).text).toBe('Echo: Hello');
  });

  it('should handle push() during active query', async () => {
    const provider = new MockProvider({}, (prompt) => `Re: ${prompt}`);
    const query = provider.query({
      prompt: 'First',
      cwd: '/tmp',
    });

    const events: Array<{ type: string; text?: string }> = [];

    setTimeout(() => query.push('Second'), 30);
    setTimeout(() => query.end(), 60);

    for await (const event of query.events) {
      events.push(event);
    }

    const results = events.filter((e) => e.type === 'result');
    expect(results).toHaveLength(2);
    expect(results[0].text).toBe('Re: First');
    expect(results[1].text).toBe('Re: Second');
  });
});

describe('end-to-end with mock provider', () => {
  it('should read messages_in, process with mock provider, write messages_out', async () => {
    // Insert a chat message into inbound DB
    insertMessage('m1', 'chat', { sender: 'User', text: 'What is 2+2?' });

    // Read and process
    const messages = getPendingMessages();
    expect(messages).toHaveLength(1);

    const routing = extractRouting(messages);
    const prompt = formatMessages(messages);

    // Create mock provider and run query
    const provider = new MockProvider({}, () => 'The answer is 4');
    const query = provider.query({
      prompt,
      cwd: '/tmp',
    });

    // Process events — simulate what poll-loop does
    const { markProcessing } = await import('./db/messages-in.js');
    const { writeMessageOut } = await import('./db/messages-out.js');

    markProcessing(['m1']);

    setTimeout(() => query.end(), 50);

    for await (const event of query.events) {
      if (event.type === 'result' && event.text) {
        writeMessageOut({
          id: `out-${Date.now()}`,
          in_reply_to: routing.inReplyTo,
          kind: 'chat',
          platform_id: routing.platformId,
          channel_type: routing.channelType,
          thread_id: routing.threadId,
          content: JSON.stringify({ text: event.text }),
        });
      }
    }

    markCompleted(['m1']);

    // Verify: message was processed (not pending, acked in processing_ack)
    const processed = getPendingMessages();
    expect(processed).toHaveLength(0);

    // Verify: response was written to outbound DB
    const outMessages = getUndeliveredMessages();
    expect(outMessages).toHaveLength(1);
    expect(JSON.parse(outMessages[0].content).text).toBe('The answer is 4');
    expect(outMessages[0].in_reply_to).toBe('m1');
  });
});
