import { describe, expect, test } from 'bun:test';

import { detectEnvHookBypass } from './claude.js';

describe('detectEnvHookBypass', () => {
  test.each([
    ['HUSKY=0 git commit -m x'],
    ['HUSKY=false git push origin main'],
    ['LEFTHOOK=0 git commit -m x'],
    ['LEFTHOOK=FALSE git push'],
    ['HUSKY_SKIP_HOOKS=1 git commit -m x'],
    ['LEFTHOOK_SKIP_HOOKS=foo git commit -m x'],
    ['GIT_HOOKS_SKIP=1 git push'],
    ['echo ok; HUSKY=0 git commit -m x'],
    ['cd repo && HUSKY=0 git commit -m x'],
    ['$(HUSKY=0 git commit -m x)'],
    ['HUSKY=0 git rebase main'],
    ['HUSKY=0 git merge feature'],
    ['HUSKY=0 git cherry-pick abc123'],
  ])('blocks: %s', (cmd) => {
    expect(detectEnvHookBypass(cmd)).not.toBeNull();
  });

  test.each([
    ['HUSKY=1 git commit -m x'], // husky enabled
    ['HUSKY=0 npm test'], // not a git write op
    ['HUSKY=0 git status'], // git read op
    ['HUSKY_LOG=1 git commit -m x'], // unrelated husky env
    ['MYHUSKY=0 git commit -m x'], // boundary check — not literal HUSKY
    ['git commit -m x'], // no env at all
    ['git status'], // no env, no write op
    // Note: `HUSKY=0 echo "git commit"` over-blocks (regex matches the literal
    // string "git commit"). Accepted false positive — over-blocking on hook
    // bypass is safer than the alternative of full shell parsing.
  ])('allows: %s', (cmd) => {
    expect(detectEnvHookBypass(cmd)).toBeNull();
  });
});
