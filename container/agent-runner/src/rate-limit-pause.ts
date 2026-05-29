/**
 * Rate-limit pause sentinel.
 *
 * When the agent-runner observes a rate-limit response from the Claude
 * SDK, it writes /workspace/.rate-limit-pause with the absolute reset
 * time. On every subsequent container spawn, index.ts reads this and
 * exits immediately (no API call) if we're still in the window.
 *
 * Per-session by virtue of the /workspace mount being per-session.
 */
import fs from 'fs';

const SENTINEL_PATH = '/workspace/.rate-limit-pause';

export interface RateLimitPause {
  paused_until_ms: number;
  hit_at_ms: number;
  reason: string;
}

export function writeRateLimitPause(pause: RateLimitPause): void {
  try {
    fs.writeFileSync(SENTINEL_PATH, JSON.stringify(pause), { mode: 0o644 });
  } catch (err) {
    // Non-fatal: worst case the next spawn pays the API-call cost to
    // discover the limit again, same as pre-fix.
    console.error(`[rate-limit-pause] failed to write sentinel: ${err instanceof Error ? err.message : err}`);
  }
}

/**
 * Read the sentinel. Returns the pause record if a valid one exists,
 * null if absent. Deletes the file if it's malformed.
 */
export function readRateLimitPause(): RateLimitPause | null {
  let raw: string;
  try {
    raw = fs.readFileSync(SENTINEL_PATH, 'utf8');
  } catch {
    return null;
  }
  try {
    const parsed = JSON.parse(raw) as RateLimitPause;
    if (typeof parsed.paused_until_ms !== 'number' || !Number.isFinite(parsed.paused_until_ms)) {
      throw new Error('invalid paused_until_ms');
    }
    return parsed;
  } catch {
    try { fs.unlinkSync(SENTINEL_PATH); } catch {}
    return null;
  }
}

export function clearRateLimitPause(): void {
  try { fs.unlinkSync(SENTINEL_PATH); } catch {}
}
