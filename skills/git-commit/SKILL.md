---
name: git-commit
description: The user-mandated git commiting workflow
---

# Git Commit Workflow

Use this skill whenever creating Git commits in this repository.

---

## 1. Authorship 

- **Primary Author**: The human user (uses local `git config user.name` and `user.email`).
- **Co-Author**: Claude (`Claude <noreply@anthropic.com>`).

Place the `Co-authored-by:` trailer at the very end of the commit message, separated from the commit body by a single blank line:

```text
<short summary>

<optional body detailing motivation and changes>

Co-authored-by: Claude <noreply@anthropic.com>
```
