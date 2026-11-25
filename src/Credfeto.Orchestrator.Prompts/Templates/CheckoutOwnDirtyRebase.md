<!-- markdownlint-disable-file -->
1. The working tree is on this PR's own branch '{{dirty_branch}}' with uncommitted changes AND the PR is {{merge_state}}. The changes are very likely unfinished work on this PR from an earlier session: do NOT discard them (never git reset or git checkout -- . here):
   a. git -C {{repo_path}} status   (inspect what is there)
   b. git -C {{repo_path}} diff     (review the uncommitted changes)
   c. git -C {{repo_path}} stash
   d. git -C {{repo_path}} fetch origin && git -C {{repo_path}} rebase origin/main
      CHANGELOG.md conflicts: keep entries from both sides. COVERAGE.md conflicts: take origin/main's copy (git -C {{repo_path}} checkout --ours -- COVERAGE.md; note rebase reverses ours/theirs vs a merge: --ours means origin/main here, not this branch), continue the rebase, and once the build/tests pass have Code Tester re-measure coverage (the main session has no build or coverage tools, so never run test or coverage commands yourself) and commit a fresh COVERAGE.md from its figures as part of this same rebase work. Any other conflict: post the details as a PR comment and stop. {{rebase_continue_rule}}
   e. git -C {{repo_path}} push --force-with-lease
   f. git -C {{repo_path}} stash pop, so the next cycle finds the work and finishes it in PHASE C. If the pop conflicts, leave the stash in place (it is not lost) and say so in your status comment.
