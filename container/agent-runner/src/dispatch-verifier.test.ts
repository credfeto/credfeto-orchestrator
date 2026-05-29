import { describe, it, expect } from 'bun:test';

import { verifyDispatchClaims } from './dispatch-verifier.js';

const KNOWN = new Set(['code-writer', 'repo-sync', 'rebase-agent', 'committer']);

describe('verifyDispatchClaims', () => {
  it('returns null when nothing was claimed', () => {
    const result = verifyDispatchClaims('All done. Awaiting next cycle.', new Set(), KNOWN);
    expect(result).toBeNull();
  });

  it('returns null when claims match actual dispatches', () => {
    const text = 'Dispatched code-writer to implement the helper.';
    const result = verifyDispatchClaims(text, new Set(['code-writer']), KNOWN);
    expect(result).toBeNull();
  });

  it('flags a claim with no matching dispatch', () => {
    const text = 'Dispatched code-writer to implement the helper.';
    const result = verifyDispatchClaims(text, new Set(), KNOWN);
    expect(result).not.toBeNull();
    expect(result).toContain('code-writer');
    expect(result).toContain('<message to="code-writer">');
  });

  it('flags multiple missing dispatches in one reply', () => {
    const text = 'Dispatched repo-sync and code-writer for PR #425.';
    const result = verifyDispatchClaims(text, new Set(), KNOWN);
    expect(result).not.toBeNull();
    expect(result).toContain('repo-sync');
    expect(result).toContain('code-writer');
  });

  it('flags partial mismatch (one of two missing)', () => {
    const text = 'Dispatched repo-sync and code-writer.';
    const result = verifyDispatchClaims(text, new Set(['repo-sync']), KNOWN);
    expect(result).not.toBeNull();
    expect(result).toContain('code-writer');
    expect(result).not.toMatch(/`repo-sync`/);
  });

  it('matches verb variants: delegated / handed off / forwarded / routed / messaged / sent', () => {
    for (const verb of [
      'Delegated to code-writer',
      'Handed off to code-writer',
      'Forwarded to code-writer',
      'Routed to code-writer',
      'Messaged code-writer',
      'Sent code-writer',
      'Dispatching code-writer',
    ]) {
      const result = verifyDispatchClaims(verb, new Set(), KNOWN);
      expect(result).not.toBeNull();
    }
  });

  it('ignores casual mentions without a dispatch verb', () => {
    const text = 'The rebase-agent handles that case. The code-writer is still busy from last cycle.';
    const result = verifyDispatchClaims(text, new Set(), KNOWN);
    expect(result).toBeNull();
  });

  it('ignores dispatch verbs targeting unknown names (false-positive guard)', () => {
    // "sent the operator" — operator isn't a peer.
    const text = 'Sent the operator a status update.';
    const result = verifyDispatchClaims(text, new Set(), KNOWN);
    expect(result).toBeNull();
  });

  it('matches backtick-wrapped peer names', () => {
    const text = 'Dispatched `code-writer` and `repo-sync`.';
    const result = verifyDispatchClaims(text, new Set(), KNOWN);
    expect(result).not.toBeNull();
    expect(result).toContain('code-writer');
    expect(result).toContain('repo-sync');
  });

  it('returns null when knownAgentDests is empty', () => {
    // Defensive: no destinations configured → can't verify anything.
    const text = 'Dispatched code-writer.';
    const result = verifyDispatchClaims(text, new Set(), new Set());
    expect(result).toBeNull();
  });
});
