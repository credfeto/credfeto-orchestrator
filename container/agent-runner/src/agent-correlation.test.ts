import { describe, it, expect, beforeEach, afterEach } from 'bun:test';

import { agentReplyThreadId } from './agent-correlation.js';
import { initTestSessionDb, closeSessionDb, getInboundDb } from './db/connection.js';

beforeEach(() => {
  initTestSessionDb();
  delete process.env.NANOCLAW_SESSION_ID;
});

afterEach(() => {
  closeSessionDb();
  delete process.env.NANOCLAW_SESSION_ID;
});

describe('agentReplyThreadId', () => {
  it('echoes the thread_id of the most recent inbound from the target agent group', () => {
    getInboundDb()
      .prepare(
        "INSERT INTO messages_in (id, seq, kind, timestamp, channel_type, platform_id, thread_id, content) VALUES (?, ?, 'chat', datetime('now'), 'agent', ?, ?, ?)",
      )
      .run('in-1', 2, 'ag-peer', 'sess-source-A', '{"text":"do this"}');

    process.env.NANOCLAW_SESSION_ID = 'sess-mine';
    expect(agentReplyThreadId('ag-peer')).toBe('sess-source-A');
  });

  it('falls back to NANOCLAW_SESSION_ID when no prior inbound exists', () => {
    process.env.NANOCLAW_SESSION_ID = 'sess-mine';
    expect(agentReplyThreadId('ag-peer')).toBe('sess-mine');
  });

  it('returns null when no env and no prior inbound', () => {
    expect(agentReplyThreadId('ag-peer')).toBeNull();
  });

  it('ignores inbounds addressed to a different agent group', () => {
    getInboundDb()
      .prepare(
        "INSERT INTO messages_in (id, seq, kind, timestamp, channel_type, platform_id, thread_id, content) VALUES (?, ?, 'chat', datetime('now'), 'agent', ?, ?, ?)",
      )
      .run('in-1', 2, 'ag-other', 'sess-other', '{"text":"unrelated"}');

    process.env.NANOCLAW_SESSION_ID = 'sess-mine';
    expect(agentReplyThreadId('ag-peer')).toBe('sess-mine');
  });
});
