<!-- markdownlint-disable-file -->

WORKING TREE IS DIRTY (MANDATORY — resolve before step 1 below):
The checkout at {{repo_path}} is currently on branch '{{dirty_branch}}' with uncommitted changes — left over from an earlier, unrelated session; a fresh issue session should never start with any.
a. git -C {{repo_path}} status   (inspect what is there)
b. If the changes are clearly relevant to THIS issue (rare): stash them — git -C {{repo_path}} stash — so they are not lost; you can pop them back later once you understand what they are.
   Otherwise (the common case — unrelated leftover state): git -C {{repo_path}} reset HEAD && git -C {{repo_path}} checkout -- .
c. git -C {{repo_path}} checkout main && git -C {{repo_path}} pull --ff-only
Only proceed to step 1 once the working tree is clean and on main. This is a mechanical cleanup step, not a reason to block the issue — the dirty state has nothing to do with this issue's own content.
