<!-- markdownlint-disable-file -->
1. The working tree is on branch '{{dirty_branch}}' with uncommitted changes — clean up before checking out the PR branch:
   a. git -C {{repo_path}} status   (inspect what is there)
   b. If changes belong to this PR: git -C {{repo_path}} stash && git -C {{repo_path}} checkout {{branch_name}} && git -C {{repo_path}} stash pop
      Otherwise: git -C {{repo_path}} reset HEAD && git -C {{repo_path}} checkout -- . && git -C {{repo_path}} checkout {{branch_name}}
