import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { initTestSessionDb, closeSessionDb, getInboundDb, getOutboundDb } from '../db/connection.js';
import { sendMessage } from './core.js';

beforeEach(() => {
  initTestSessionDb();
  delete process.env.NANOCLAW_SESSION_ID;
  getInboundDb()
    .prepare(
      "INSERT INTO destinations (name, display_name, type, agent_group_id) VALUES ('main', 'Main', 'agent', 'ag-main')",
    )
    .run();
});

afterEach(() => {
  closeSessionDb();
  delete process.env.NANOCLAW_SESSION_ID;
});

function lastOutboundThreadId(): string | null {
  const row = getOutboundDb()
    .prepare("SELECT thread_id FROM messages_out ORDER BY seq DESC LIMIT 1")
    .get() as { thread_id: string | null } | undefined;
  return row?.thread_id ?? null;
}

describe('send_message — agent-to-agent thread_id correlation', () => {
  it('echoes the most recent inbound thread_id when replying to a peer', async () => {
    // Simulate "we received an inbound from ag-main with correlation id sess-source-A".
    getInboundDb()
      .prepare(
        "INSERT INTO messages_in (id, seq, kind, timestamp, channel_type, platform_id, thread_id, content) VALUES (?, ?, 'chat', datetime('now'), 'agent', 'ag-main', ?, ?)",
      )
      .run('in-1', 2, 'sess-source-A', '{"text":"clone X please"}');

    process.env.NANOCLAW_SESSION_ID = 'sess-mine';
    await sendMessage.handler({ to: 'main', text: 'done' });

    // Reply correlation: thread_id must be the inbound's correlation, NOT our own
    // session id — that's how the host routes the reply back to sess-source-A.
    expect(lastOutboundThreadId()).toBe('sess-source-A');
  });

  it('stamps own session id on an initial dispatch (no prior inbound)', async () => {
    process.env.NANOCLAW_SESSION_ID = 'sess-mine';
    await sendMessage.handler({ to: 'main', text: 'kick off work' });

    expect(lastOutboundThreadId()).toBe('sess-mine');
  });

  it('falls back to null when no session id env var is set and no prior inbound', async () => {
    await sendMessage.handler({ to: 'main', text: 'hi' });

    expect(lastOutboundThreadId()).toBeNull();
  });
});
