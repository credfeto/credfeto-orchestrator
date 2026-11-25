<!-- markdownlint-disable-file -->
Workflow board: this repository has a Workflow board. Its Status values, in order: {{statuses}}.
  Set this {{noun}}'s status:  {{board_set_command}}
  Read this {{noun}}'s status: cfwf workflow-status --check --repo {{repo_full}} --{{item_kind}} {{item_id}}
Never update the board with gh project or gh api graphql; they are denied.
