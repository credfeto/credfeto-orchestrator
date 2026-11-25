<!-- markdownlint-disable-file -->
- Start the session with exactly this command, as its own Bash call: cfwf pr status --repo {{repo_full}} --pr {{pr_number}}
  It prints the PR metadata, the Workflow board status, ready-at, the required-check verdict with the failing and pending check names, the changed-file count and the comment activity. Its exit code follows cfwf pr checks: 0 every required check passed, 3 at least one failed, 4 at least one pending, 5 no checks yet.
- Run one cfwf command per Bash call, with no `;`, `&&`, `|`, `echo $?` or redirection around it, and read the exit code from the tool result. A compound command containing cfwf is refused in unattended runs and ends the session.
- Use cfwf pr comments, cfwf pr view --field ... and cfwf pr diff only for detail cfwf pr status does not print, each as its own Bash call.
