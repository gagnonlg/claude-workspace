---
name: prompt-file
description: Use when the user invokes "/prompt-file <filename>" — reads the named file and executes the instructions it contains.
---

# Prompt File

## Overview
Thin alias: `/prompt-file PROMPT.md` means "Read PROMPT.md and execute the instructions therein, please."

## Behavior
Given `args` (a filename, e.g. `PROMPT.md`):

1. Read the file at that path (relative to the current working directory unless an absolute/other path is given).
2. Treat its contents as the user's instructions for this turn and carry them out, exactly as if the user had typed: "Read `<file>` and execute the instructions therein, please."

No other transformation, summarization, or confirmation step is needed — just read and do.
