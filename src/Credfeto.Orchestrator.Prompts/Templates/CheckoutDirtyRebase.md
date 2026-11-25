<!-- markdownlint-disable-file -->
1. The working tree is on branch '{{dirty_branch}}' with uncommitted changes AND the PR is {{merge_state}} — resolve both before any other work:
   a. git -C {{repo_path}} status   (inspect what is there)
   b. If changes belong to this PR: git -C {{repo_path}} stash && git -C {{repo_path}} checkout {{branch_name}} && git -C {{repo_path}} stash pop
      Otherwise: git -C {{repo_path}} reset HEAD && git -C {{repo_path}} checkout -- . && git -C {{repo_path}} checkout {{branch_name}}
   c. git -C {{repo_path}} fetch origin && git -C {{repo_path}} rebase origin/main
      CHANGELOG.md conflicts: keep entries from both sides. COVERAGE.md conflicts: take origin/main's copy (git -C {{repo_path}} checkout --ours -- COVERAGE.md — note rebase reverses ours/theirs vs a merge: --ours means origin/main here, not this branch), continue the rebase, and once the build/tests pass have Code Tester re-measure coverage (the main session has no build or coverage tools, so never run test or coverage commands yourself) and commit a fresh COVERAGE.md from its figures as part of this same rebase work. Any other conflict: post the details as a PR comment and stop. {{rebase_continue_rule}}
   d. git -C {{repo_path}} push --force-with-lease
