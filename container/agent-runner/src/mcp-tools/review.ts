/**
 * Review-gate MCP tool: submit_for_review.
 *
 * This is the ONLY way to mark a branch ready for review. The agent opens a
 * PR, then calls `submit_for_review` — it must NOT claim a branch is "ready"
 * or "ok" in prose. The host verifies CI itself and posts the real verdict.
 *
 * With the two-DB split, the container cannot write to inbound.db or message
 * the operator directly. `submit_for_review` is sent as a `kind='system'`
 * action via messages_out — the host reads it during delivery, resolves the
 * PR, holds until CI concludes, then posts the green / red verdict.
 */
import { writeMessageOut } from '../db/messages-out.js';
import { getSessionRouting } from '../db/session-routing.js';
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

function log(msg: string): void {
  console.error(`[mcp-tools] ${msg}`);
}

function generateId(): string {
  return `sys-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

export const submitForReview: McpToolDefinition = {
  tool: {
    name: 'submit_for_review',
    description:
      'Submit a pull request for review. This is the ONLY way to mark a branch as ready — never claim a branch is "ready", "ok" or "complete" in prose. The host verifies CI itself and posts the real verdict (green or red) to the operator once CI concludes.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        repo: { type: 'string', description: 'Repository in "owner/name" form (e.g. "credfeto/credfeto-dispatcher")' },
        pr: { type: 'number', description: 'Pull request number' },
        title: { type: 'string', description: 'Optional short title / summary of the change' },
      },
      required: ['repo', 'pr'],
    },
  },
  async handler(args) {
    const repo = (args.repo as string)?.trim();
    const pr = typeof args.pr === 'number' ? args.pr : Number(args.pr);
    const title = (args.title as string) || null;

    if (!repo || !repo.includes('/')) return err('repo is required in "owner/name" form');
    if (!Number.isInteger(pr) || pr <= 0) return err('pr must be a positive integer');

    const r = getSessionRouting();

    // Write as a system action — the host resolves the PR, holds for CI, and
    // posts the verdict to the operator.
    writeMessageOut({
      id: generateId(),
      kind: 'system',
      platform_id: r.platform_id,
      channel_type: r.channel_type,
      thread_id: r.thread_id,
      content: JSON.stringify({ action: 'submit_for_review', repo, pr, title }),
    });

    log(`submit_for_review: ${repo} PR #${pr}`);
    return ok(
      `Submitted ${repo} PR #${pr} for review. The host is verifying CI and will report the real verdict (green or red) to the operator once CI concludes. Do not claim the branch is ready yourself.`,
    );
  },
};

registerTools([submitForReview]);
