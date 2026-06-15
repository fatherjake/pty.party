# Working Agreement — pty.party

This project runs inside **pty.party**, an infinite canvas where terminals,
notes, images, and a shared **Log** card are wired together. Two habits make
the canvas useful:

1. Keep a **running checklist on a connected Log card** as you work.
2. Use the **ptyparty MCP tools** to read the canvas — the selected image,
   connected images/notes, sibling terminal output (see the `ptyparty`
   skill).

## Running activity log — on a connected Log card

This project keeps a **running checklist of work on a Log card on the
pty.party canvas** (not in a file). As you work, you push the tasks you're
about to do onto a shared Log and tick them off as they finish, so a human
operator can glance at the canvas and watch progress happen in real time.

### One-time setup (ask the operator if it's missing)

The checklist tools only work when this terminal is **connected to a Log**:

1. Right-click the canvas → **New Log** (or press ⇧⌘L) to drop an "Activity
   Log" card.
2. Drag from the Log card's edge port onto this terminal to connect them.

Several terminals can connect to the same Log and share one running
checklist. If a checklist tool reports that no Log is connected, ask the
operator to do those two steps, then retry.

### The loop

Whenever we do *anything* in this project, follow this loop:

1. **Plan the task group** — a short section name for the batch of work
   you're about to do (e.g. `Fix PRD note duplication`).
2. **Push the tasks** with the `add_to_checklist` MCP tool the moment you
   start:
   - `items` = one short line per task; each becomes an unchecked `- [ ]`
     entry on every connected Log.
   - `section` = the group name, so related items stay together. Re-use the
     same section name to append more items to that group later.
3. **Check items off as you go** — call `check_off_item` with the item's text
   (matched case-insensitively) the moment a task is actually finished. Don't
   save it for the end; tick each item the instant it's done.
4. **Log issues as items too.** Add an issue as its own item prefixed with
   `⚠️` while it's open, then `check_off_item` it once resolved:
   - `⚠️ Issue: <short description>` — added while open
   - check it off once fixed (add a `⚠️ Fixed: <how>` item first if the fix
     is worth recording)

### Rules of thumb

- **One section per logical chunk of work** — don't lump unrelated tasks
  under one section name.
- **Keep items terse** — one short line each. The Log is a glanceable
  summary.
- **Add before you do, check the moment it's done** — the Log should track
  reality as it happens, not get back-filled at the end.
- **Never silently skip the log.** If we touch the project, items go up and
  get checked off. This is the first and last step of any task.
- **Match the text when checking off.** `check_off_item` matches on the item
  text, so pass it as you added it.

### If the MCP tool is unavailable

The `ptyparty` MCP server may be disconnected while the app itself is still
running. The checklist tools talk to the app over a file RPC, so you can
drive the connected Log directly using this terminal's ID
(`$PTYPARTY_TERMINAL_ID`).

Drop a request JSON into `~/Library/Application Support/ptyparty/requests/`,
writing it under a dotted staging name first and then renaming it to a
`*.json` final name so the app never reads a half-written file. The app
replies in `responses/` under the same name.

- Append items:
  ```json
  {"type":"log_append","terminalId":"<PTYPARTY_TERMINAL_ID>","items":["Task one","Task two"],"section":"Task group"}
  ```
- Check an item off:
  ```json
  {"type":"log_check","terminalId":"<PTYPARTY_TERMINAL_ID>","item":"Task one"}
  ```

Both still require a Log connected to this terminal, exactly like the MCP
tools.

**On a remote host this file fallback does not work** — that directory lives on
the Mac running pty.party, not on the host. Remote tiles reach the canvas
through the MCP bridge instead (set it up from the title bar's host menu →
**Set Up Remote Log…**), so use the `add_to_checklist` / `check_off_item` MCP
tools there.

## Where pty.party state lives

The app and the `ptyparty` MCP server communicate over a small file RPC under
`~/Library/Application Support/ptyparty/`:

- `selected-image.png` — the image currently selected on the canvas.
- `connections/<terminalId>/` — images (and `notes/`) wired to each terminal.
- `inbox/` — drop an image or note here and the app places it on the canvas.
- `requests/` + `responses/` — the live-query RPC described above.
- `activity/<terminalId>` — the tile's live status (`working`/`asking`/`idle`),
  written by Claude Code hooks so the canvas shows whether a session is
  working, needs you, or done.

pty.party injects `PTYPARTY_TERMINAL_ID` into every terminal it spawns, so
the connection-aware MCP tools (and the activity hooks) know which terminal
they're running in.