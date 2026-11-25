<!-- markdownlint-disable-file -->

WORKING TREE IS DIRTY ON THIS ISSUE'S OWN RESUMABLE BRANCH (MANDATORY — read before step 1 below):
The checkout at {{repo_path}} is on branch '{{dirty_branch}}' with uncommitted changes. This is the
SAME branch an earlier session for this issue pushed and then died before opening a pull request
— these uncommitted changes are very likely further, genuine progress on this issue, not leftover
state from something unrelated. Do NOT discard them.
a. git -C {{repo_path}} status   (inspect what is there)
b. git -C {{repo_path}} diff     (review the uncommitted changes)
c. If they are clearly unrelated to this issue (rare): stash them first — git -C {{repo_path}} stash — so nothing is lost, then continue on this branch anyway.
Stay on '{{dirty_branch}}' and continue the plan from here — do NOT reset to main and do NOT create a new branch (see step 7). Once ready, commit, push, and create the draft pull request as step 7 describes.
