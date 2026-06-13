# Working Agreement

## Running activity log — on the pty.party canvas

This project keeps a **running activity log directly on the pty.party canvas** (not
in a file). Each chunk of work is a titled PRD card so a human operator can
glance at the canvas and see what has happened since they last looked.

Whenever we do *anything* in this project, follow this loop:

1. **Decide the task group** — a short title for the batch of work you're about
   to do (e.g. `Fix PRD note duplication`).
2. **Push a card to the canvas** with the `add_note_to_canvas` MCP tool:
   - `title` = the group heading.
   - `body` = a Markdown task list of the work, using `- [ ]` (todo) and
     `- [x]` (done); indent two spaces for a sub-task.
3. **Tick tasks off as you go** — re-push the *same* group (same `title`) with
   updated `- [x]` lines the moment a task is actually finished. Cards update
   **in place by title**, so re-pushing updates the existing card instead of
   adding a new one. Keep the title stable for the life of the group.
4. **Document issues as task items.** Since a card only renders task lines, log
   an issue as its own checkbox prefixed with `⚠️` — unchecked while open,
   checked once resolved:
   - `- [ ] ⚠️ Issue: <short description>`
   - `- [x] ⚠️ Issue: <problem> — fixed: <how>`

### Rules of thumb

- **One card per logical chunk of work** — don't lump unrelated tasks under a
  single title.
- **Keep line items terse** — one line each. The card is a glanceable summary.
- **Never silently skip the log.** If we touch the project, a card goes up or
  gets updated. This is the first and last step of any task.
- **Stable titles.** Changing a group's title creates a second card instead of
  updating the first one.

### If the MCP tool is unavailable

The `ptyparty` MCP server may be disconnected. The app watches an inbox folder, so
drop the same manifest JSON into
`~/Library/Application Support/ptyparty/inbox/` and pty.party will pick it up:

```json
{"note":{"title":"<heading>","body":"<task lines>"},"terminalId":null}
```

Write it under a dotted staging name first, then rename to a `*.json` final
name, so pty.party never reads a half-written file.
