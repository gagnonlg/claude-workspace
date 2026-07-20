# CLAUDE.md

## Working in this repo
- Tasks are to be completed by subagents **of the appropriate complexity** — match the
  subagent (and model) to the difficulty of the task.
- Always commit after the subagent's work is done **and verified**.

## Commit attribution
- The repo's default git identity (`git config user.name`/`user.email`) is the repo
  owner, Louis-Guillaume Gagnon (`gagnonlg@stanford.edu`).
- When Claude creates a commit, override the default identity with `-c` flags so the
  commit is authored **as Claude**, e.g.:
  `git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit -m "..."`
- Add the repo owner as a co-author:
  `Co-Authored-By: Louis-Guillaume Gagnon <gagnonlg@stanford.edu>`
