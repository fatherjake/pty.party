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
