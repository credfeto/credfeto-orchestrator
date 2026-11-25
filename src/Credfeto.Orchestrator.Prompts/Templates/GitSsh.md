<!-- markdownlint-disable-file -->
Git transport — SSH is always configured and always works:
- Both this container's /etc/gitconfig and the host user's ~/.gitconfig rewrite https://github.com/ to git@github.com: via url.insteadOf, so every git operation uses SSH regardless of what URL is stored in .git/config.
- The proxy (GH_HOST) blocks gh push and gh rebase — always use git CLI directly for commits and pushes, never gh.
- If git push fails: run ssh-add -l to verify the SSH agent has keys loaded and check git remote get-url origin. A transient push error is NOT a reason to add a Blocked label or post a comment asking for human action — diagnose and retry.
