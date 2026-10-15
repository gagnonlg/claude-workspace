---
name: org-output
description: Answer the user's prompt with the final reply formatted as a paste-ready Emacs org-mode subtree, starting at a given heading level.
argument-hint: "[level] <prompt>"
disable-model-invocation: true
---

# Org-mode output (paste-ready)

Raw arguments: `$ARGUMENTS`

The user will copy your final reply with `/copy` and paste it directly into an
existing org file. The final reply must therefore be a clean org subtree and
nothing else.

## Step 1: Parse the arguments

- If the first whitespace-separated token is a positive integer, that is the
  **base heading level** (N). The rest is the **prompt**.
- Otherwise N = 1 and the whole argument string is the **prompt**.

## Step 2: Do the work

Answer the prompt, using tools as needed. Keep any narration between tool calls
minimal. Everything the user needs must be in the **final message**, because
only that message gets copied.

## Step 3: Final reply = one org subtree, nothing else

The final message must:

- Start on the very first line with a level-N heading: N asterisks, a space,
  and a short descriptive title (N=2 gives `** Title`).
- Contain **no** preamble ("Here's...", "Sure"), **no** closing remarks or
  offers of follow-up, and **no** mention of these instructions.
- Contain **no** Markdown code fence around the output. Output raw org text.
- Contain **no** file-level keywords (`#+TITLE`, `#+OPTIONS`, `#+STARTUP`, etc.).
  It's a subtree, not a document.
- End with the last line of content. Don't add trailing separators.

### Headings
- Sub-sections use N+1, N+2, and so on. Never go shallower than N, and never skip levels.
- Don't indent body text under headings.
- Never start a non-heading line with `*` in column 0.

### Inline markup
- Bold `*bold*`, italic `/italic/`, underline `_underline_`, strike `+strike+`
- Code, commands, identifiers, paths: `~code~`
- Literal values: `=verbatim=`
- Never use Markdown backticks, `**bold**`, or `# headings`.

### Links
- `[[https://example.com][description]]`
- Files: `[[file:path/to/file.py::42][file.py:42]]` (prefer absolute paths so
  links still work after pasting into a file elsewhere)

### Lists
- Unordered `- item` (nest with 2 spaces); ordered `1. item`
- Description lists: `- term :: description`
- Checkboxes: `- [ ] todo` / `- [X] done`

### Blocks
Use org blocks, never Markdown fences:

#+begin_src python
print("hello")
#+end_src
