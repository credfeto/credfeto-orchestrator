<!-- markdownlint-disable-file -->
BEFORE handing the PR off or marking it ready, list the PR's files: cfwf pr view --repo {{repo_full}} --pr {{item_id}} --field files. If .deleteme.now is listed, the real change has not landed: do NOT enable auto-merge, do NOT mark the PR ready (leave it as it is), post a one-line status comment saying the real change is still missing, then STOP.
