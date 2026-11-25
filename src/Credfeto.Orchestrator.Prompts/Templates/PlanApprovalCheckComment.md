<!-- markdownlint-disable-file -->
   Result "true"  → plan exists. Check whether a HUMAN has approved the latest plan, as one Bash call on its own:
     cfwf issue plan-status --repo {{repo_full}} --issue {{item_id}} --approval
   Read only its "approved" line; never judge the comments yourself (your own prior comments never count, even ones that happen to contain the word).
   "approved<TAB>yes" → approved — skip to step 5 (Implementation mode).
   "approved<TAB>no"  → not yet. If any comment on the issue left feedback requesting changes to the plan, revise it and re-post the FULL updated plan as a new comment in the same format as step 3. Either way — even when the plan itself needs no changes — you MUST ALSO post a short comment BEFORE re-blocking stating that no approval comment was found after the latest plan: a collaborator must post a comment after it whose own line says approved or lgtm, with no "not", "if" or question mark on that line. Silently re-applying Blocked with no comment is NEVER acceptable, especially if the label was just removed by a human. Then mark Blocked and STOP (step 3).
