import Foundation

/// The text the Welcome card installs into a user's project: the `PARTY.md`
/// working agreement and the `ptyparty` skill. The app ships no bundled
/// resources, so this content is embedded here as the single source the
/// installer writes. The repo's own `PARTY.md` and `skills/ptyparty/SKILL.md`
/// are kept identical to these for reference and dogfooding.
enum OnboardingContent {
    /// Written to `<project>/PARTY.md`.
    static let partyMarkdown = """
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

    ## Where pty.party state lives

    The app and the `ptyparty` MCP server communicate over a small file RPC under
    `~/Library/Application Support/ptyparty/`:

    - `selected-image.png` — the image currently selected on the canvas.
    - `connections/<terminalId>/` — images (and `notes/`) wired to each terminal.
    - `inbox/` — drop an image or note here and the app places it on the canvas.
    - `requests/` + `responses/` — the live-query RPC described above.

    pty.party injects `PTYPARTY_TERMINAL_ID` into every terminal it spawns, so
    the connection-aware MCP tools know which terminal they're running in.
    """

    /// Written to `<skills folder>/ptyparty/SKILL.md`.
    static let skillMarkdown = """
    ---
    name: ptyparty
    description: Use when working inside a pty.party terminal to read the canvas (the selected image, connected images/notes, sibling terminal output) or to drive a shared Log checklist. Trigger on mentions of pty.party, "the selected image", "connected notes", the activity Log, or the ptyparty MCP tools.
    ---

    # ptyparty — reading and driving the pty.party canvas

    pty.party is an infinite macOS canvas where terminals, notes, images, and a
    shared **Log** card are wired together with connections. When you run inside a
    pty.party terminal, the `ptyparty` MCP server lets you see what the operator
    has linked to *this* terminal and update the canvas as you work.

    The server discovers which terminal it's in via the `PTYPARTY_TERMINAL_ID`
    environment variable that pty.party injects, so the connection-aware tools
    just work — no setup needed beyond having the server registered.

    ## Reading the canvas

    - **`get_selected_image`** — the image currently selected on the canvas. Use
      it when the user says "the selected image", "this image", or refers to
      something they've clicked in the app.
    - **`get_connected_images`** — every image wired to this terminal.
    - **`get_connected_notes`** — notes wired to this terminal, as Markdown.
    - **`get_connected_terminal_output`** — recent output of the terminals
      connected to this one, so you can see what a sibling agent is doing.

    ## Writing to the canvas

    - **`add_image_to_canvas`** — place an image (by path or base64) on the
      canvas, near this terminal.
    - **`add_note_to_canvas`** — pin a titled Markdown note/checklist card.
    - **`add_to_checklist`** — append items to the **Log** card(s) connected to
      this terminal. `items` is one short line each (each becomes a `- [ ]`);
      optional `section` groups related items under a heading.
    - **`check_off_item`** — tick a Log item done, matched case-insensitively by
      its text. Pass the text exactly as you added it.

    ## The Log workflow

    A Log card is a live, shared checklist. The operator creates one (right-click
    → **New Log**) and drags a connection from it to this terminal. Once
    connected, push the tasks you're about to do with `add_to_checklist` and tick
    each off with `check_off_item` the moment it's done, so progress shows on the
    canvas in real time. If a checklist tool reports no Log is connected, ask the
    operator to create one and connect it, then retry.

    See `PARTY.md` in the project root for the full working agreement around the
    Log loop.
    """

    /// The one line prepended to a project's `AGENTS.md` / `CLAUDE.md` pointing
    /// agents at the installed working agreement.
    static let pointerLine = "First, read PARTY.md before doing anything in this project."
}
