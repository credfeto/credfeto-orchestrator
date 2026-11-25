<!-- markdownlint-disable-file -->
1. The working tree is already on this PR's own branch '{{dirty_branch}}' with uncommitted changes. They are very likely unfinished work on this PR from an earlier session: do NOT discard them (never git reset or git checkout -- . here):
   a. git -C {{repo_path}} status   (inspect what is there)
   b. git -C {{repo_path}} diff     (review the uncommitted changes)
   c. If they belong to this PR: get them building and passing the tests, then commit and push them. If they clearly do not, stash them so nothing is lost: git -C {{repo_path}} stash
