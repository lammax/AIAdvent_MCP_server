---
name: commit-push
description: Complete an explicitly requested git commit by pushing it to the current branch's configured upstream and verifying synchronization. Trigger when the user asks Codex to commit, including when a prior instruction says to commit at the end of the task. Do not trigger for inspection, review, or changes that the user has not authorized to commit.
---

After the requested changes and relevant checks are complete:

1. Inspect the worktree and stage only files that belong to the requested task. Preserve unrelated user changes.
2. Create the requested commit with a concise message.
3. If the commit succeeds, push the current branch to its already configured upstream in the same workflow.
4. Verify that the local branch and upstream have no remaining divergence, and report the commit hash and push result.

Never force-push, rewrite history, change remotes, create an upstream, or bypass branch protection. If the branch has no configured upstream, the push is rejected, authentication fails, or the remote advanced incompatibly, stop and report the exact blocker. Do not amend or rebase solely to make the push succeed unless the user explicitly requests it.

An explicit request to commit authorizes the ordinary follow-up push described here. It does not authorize publishing unrelated local commits; inspect ahead commits before pushing and stop if their ownership or scope is unclear.
