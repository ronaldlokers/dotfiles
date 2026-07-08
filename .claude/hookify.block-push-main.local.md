---
name: block-push-to-main
enabled: true
event: bash
pattern: git\s+push\b.*\bmain\b
action: block
---

🛑 **Direct push to `main` blocked.**

Workflow rule: never push straight to `main`. Instead:
- Branch: `git switch -c fix/<topic>` or `feat/<topic>`
- Push the branch: `git push -u origin <branch>`
- Open a PR: `gh pr create`

If this is an intentional, reviewed exception, run the push in a terminal outside Claude Code.
