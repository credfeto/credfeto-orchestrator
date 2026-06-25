<!-- Locally Maintained -->
# GitHub Projects v2 Instructions

[Back to Local Instructions Index](index.md)

> Load when: working on `create-project`, on `oneshot`'s `_wf_*` project-discovery functions, or on any code that interacts with the GitHub Projects v2 GraphQL API.

## Operational Rules

### Test one repo before scaling (MANDATORY)

Before running any operation across multiple repos, run it against **one** canary repo and verify the full outcome end-to-end — including from the bot's perspective — before continuing.  Specifically:

1. Run the operation on a single low-stakes repo.
2. Check the bot can both **discover** the project via `repository.projectsV2` AND **update** it (`viewerCanUpdate: true`) via node-ID lookup.
3. Only then proceed with the rest of the repos.

A silent failure that affects 60+ repos all at once is far harder to recover from than one that affects one.

### Verify bot access two ways

After creating or updating any project, always verify the orchestrator bot (`dnyw4l3n13`) can access it from `nanoclaw.lan` via **both** paths:

```bash
# Path 1 — direct node lookup (confirms the collaborator grant worked)
ssh -n nanoclaw.lan "gh api graphql \
  -f query='query(\$id:ID!){node(id:\$id){...on ProjectV2{id title viewerCanUpdate}}}' \
  -f id='<PVT_...>' --jq '.data.node'"

# Path 2 — repository discovery (the path oneshot actually uses)
ssh -n nanoclaw.lan "gh api graphql \
  -f query='query(\$o:String!,\$r:String!){repository(owner:\$o,name:\$r){projectsV2(first:5){nodes{id title viewerCanUpdate}}}}' \
  -f o='<owner>' -f r='<repo>' --jq '.data.repository.projectsV2.nodes'"
```

Both must return `viewerCanUpdate: true`.  A pass on path 1 but a miss on path 2 means the project exists but `oneshot` will not find it.

### Never suppress mutation errors

Critical mutations — collaborator grants, project creation — must **not** use `>/dev/null 2>&1`.  Always capture and surface the actual error output.  Silent failure is what allowed the wrong `ProjectV2CollaboratorInput` type to go undetected across all 61 credfeto repos.

## `create-project` Script Rules

### Check and enable `hasProjectsEnabled` before creating

If a repo has Projects disabled (`hasProjectsEnabled: false`), `repository.projectsV2` returns empty even when the project node is correctly linked via `repositoryId`.  `oneshot`'s discovery will always miss such a project.

Before creating a project, check and enable if needed:

```bash
enabled=$(gh repo view "${owner}/${repo}" --json hasProjectsEnabled --jq '.hasProjectsEnabled')
if [ "${enabled}" != "true" ]; then
    gh repo edit "${owner}/${repo}" --enable-projects
fi
```

### `|| exit 1` on every command substitution that wraps a `die`-calling function

Command substitutions swallow the called function's `exit` code.  Without an explicit `|| exit 1`, a `die` inside a helper silently leaves its caller with an empty variable and the script continues:

```bash
# WRONG — die inside resolve_owner_node_id has no effect on the caller
owner_node_id=$(resolve_owner_node_id "${owner}")

# CORRECT
owner_node_id=$(resolve_owner_node_id "${owner}") || exit 1
```

Apply this to every command substitution that calls a function which may call `die`.

## GitHub Projects v2 GraphQL API

### Correct collaborator mutation type

The input type is **`ProjectV2Collaborator`**, not `ProjectV2CollaboratorInput` (which does not exist in the schema).  Using the wrong type fails silently when error output is suppressed.

```graphql
# WRONG
mutation($p:ID!, $c:[ProjectV2CollaboratorInput!]!) { ... }

# CORRECT
mutation($p:ID!, $c:[ProjectV2Collaborator!]!) {
  updateProjectV2Collaborators(input:{projectId:$p, collaborators:$c}) {
    collaborators(first:5) {          # pagination required
      nodes {
        ...on User { login }          # union type — inline fragment required
      }
    }
  }
}
```

### `ProjectV2Actor` is a union — always use inline fragments

Any field that returns a `ProjectV2Actor` union type (collaborators, viewers, etc.) requires `...on User { login }` rather than `.login` directly.  Without the fragment the field silently returns nothing.

### `gh api graphql --jq` outputs raw JSON on error — guard against it

When a GraphQL query errors (e.g. the org does not exist), `gh api graphql --jq` may write the raw JSON error response body to stdout instead of applying the `--jq` filter.  Guard any ID extracted this way:

```bash
if [ -z "${id}" ] || [ "${id}" = "null" ] || [[ "${id}" == \{* ]]; then
    # treat as failure / fall through to alternate query
fi
```

### `createProjectV2` with `repositoryId` — repo-scoped projects

Passing `repositoryId` to `createProjectV2` creates a repo-scoped project, sets the default repository, and auto-links the project to the repo — **no separate `linkProjectV2ToRepository` call is needed**.

```graphql
mutation($ownerId:ID!, $title:String!, $repoId:ID!) {
  createProjectV2(input:{ownerId:$ownerId, title:$title, repositoryId:$repoId}) {
    projectV2 { id }
  }
}
```

Without `repositoryId` the project is owner-scoped and `repository.projectsV2` will not find it.

### Orgs vs personal accounts — collaborator grants work the same way

`updateProjectV2Collaborators` works for org-owned projects even when the bot is **not** an org member.  The explicit per-project collaborator grant is required regardless of whether the owner is a personal account or an org — repo WRITE access alone is not enough for project access.
