import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { mkdir, readdir, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { z } from "zod";

// The pty.party app writes the currently selected canvas image here, and
// deletes the file when nothing is selected.
const SELECTION_PATH = join(
  homedir(),
  "Library/Application Support/ptyparty/selected-image.png"
);

// pty.party watches this directory and puts any image dropped into it onto the
// canvas. Writes are staged under a dotted name and renamed in atomically.
const INBOX_DIR = join(homedir(), "Library/Application Support/ptyparty/inbox");

// pty.party publishes each terminal's connected images under a folder named
// after the terminal's ID.
const CONNECTIONS_DIR = join(
  homedir(),
  "Library/Application Support/ptyparty/connections"
);

// Live-state RPC with the running pty.party app: drop a request JSON in
// requests/, pty.party answers in responses/ under the same name.
const REQUESTS_DIR = join(homedir(), "Library/Application Support/ptyparty/requests");
const RESPONSES_DIR = join(homedir(), "Library/Application Support/ptyparty/responses");

async function ptypartyRequest(payload, timeoutMs = 3000) {
  await mkdir(REQUESTS_DIR, { recursive: true });
  const id = randomUUID();
  const staging = join(REQUESTS_DIR, `.staging-${id}`);
  await writeFile(staging, JSON.stringify(payload));
  await rename(staging, join(REQUESTS_DIR, `${id}.json`));
  const responsePath = join(RESPONSES_DIR, `${id}.json`);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = JSON.parse(await readFile(responsePath, "utf8"));
      await unlink(responsePath).catch(() => {});
      return response;
    } catch {
      await sleep(50);
    }
  }
  return null;
}

const server = new McpServer({ name: "ptyparty", version: "1.0.0" });

server.registerTool(
  "get_selected_image",
  {
    description:
      "Returns the image currently selected on the pty.party canvas. " +
      "Use this when the user refers to 'the selected image', 'this image', " +
      "or asks about an image they have picked in the pty.party app.",
    inputSchema: {},
  },
  async () => {
    let data;
    try {
      data = await readFile(SELECTION_PATH);
    } catch {
      return {
        content: [
          {
            type: "text",
            text:
              "No image is currently selected in pty.party. " +
              "Ask the user to click an image on the pty.party canvas first.",
          },
        ],
      };
    }
    const { mtime } = await stat(SELECTION_PATH);
    return {
      content: [
        {
          type: "text",
          text: `Currently selected pty.party image (selected at ${mtime.toISOString()}):`,
        },
        {
          type: "image",
          data: data.toString("base64"),
          mimeType: "image/png",
        },
      ],
    };
  }
);

// Reads `name` from a process's environment via `ps eww` (own user only).
// Returns the value, or null if absent/unreadable.
function envVarOfPid(pid, name) {
  try {
    const out = execFileSync("ps", ["eww", "-o", "command=", "-p", String(pid)], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const match = out.match(new RegExp(`(?:^|\\s)${name}=(\\S+)`));
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

function ppidOf(pid) {
  try {
    const out = execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const ppid = parseInt(out.trim(), 10);
    return Number.isFinite(ppid) ? ppid : null;
  } catch {
    return null;
  }
}

// pty.party sets PTYPARTY_TERMINAL_ID in the environment of every terminal it spawns.
// Claude passes that env straight through to this MCP server, but some clients
// (e.g. Codex) launch MCP servers with a sanitized environment that drops it.
// In that case, recover it by walking up the process tree — codex and the
// shell pty.party launched both still carry the variable.
function resolveTerminalID() {
  if (process.env.PTYPARTY_TERMINAL_ID) return process.env.PTYPARTY_TERMINAL_ID;
  let pid = process.ppid;
  const seen = new Set();
  for (let i = 0; i < 16 && pid && pid > 1 && !seen.has(pid); i++) {
    seen.add(pid);
    const found = envVarOfPid(pid, "PTYPARTY_TERMINAL_ID");
    if (found) return found;
    pid = ppidOf(pid);
  }
  return null;
}

// The terminal this MCP server is running inside, so pty.party can place images /
// notes next to it and answer queries about its connected tiles.
const TERMINAL_ID = resolveTerminalID();

server.registerTool(
  "add_image_to_canvas",
  {
    description:
      "Puts an image onto the pty.party canvas. Provide either the absolute path " +
      "of an image file on disk, or base64-encoded image data. When called " +
      "from a Claude session inside a pty.party terminal, the image is placed " +
      "just below that terminal; otherwise it appears at the center of the " +
      "user's current view.",
    inputSchema: {
      path: z
        .string()
        .optional()
        .describe("Absolute path to an image file on disk"),
      data: z
        .string()
        .optional()
        .describe("Base64-encoded image data (alternative to path)"),
    },
  },
  async ({ path, data }) => {
    const fail = (text) => ({ content: [{ type: "text", text }], isError: true });
    if (!path && !data) {
      return fail("Provide either `path` or `data`.");
    }
    await mkdir(INBOX_DIR, { recursive: true });
    const id = randomUUID();
    const staging = join(INBOX_DIR, `.staging-${id}`);
    const final = join(INBOX_DIR, `${Date.now()}-${id}.json`);
    try {
      const buffer = path ? await readFile(path) : Buffer.from(data, "base64");
      const manifest = JSON.stringify({
        image: buffer.toString("base64"),
        terminalId: TERMINAL_ID,
      });
      await writeFile(staging, manifest);
      await rename(staging, final);
    } catch (error) {
      return fail(`Could not add the image: ${error.message}`);
    }
    return {
      content: [
        {
          type: "text",
          text:
            "Image sent to the pty.party canvas. It appears immediately if pty.party " +
            "is running, otherwise on its next launch.",
        },
      ],
    };
  }
);

server.registerTool(
  "add_note_to_canvas",
  {
    description:
      "Pins a PRD-style checklist card onto the pty.party canvas — a titled card " +
      "that renders a Markdown task list with checkboxes, the first unchecked " +
      "item highlighted as 'in progress', and an x/y progress bar. Use it to " +
      "show the user a plan, a todo list, or a PRD broken into tasks. The " +
      "`body` MUST be a Markdown task list using `- [ ]` (todo) and `- [x]` " +
      "(done); indent a line by two spaces to make it a sub-task. Non-task " +
      "lines are ignored. When called from a session inside a pty.party terminal, " +
      "the card appears just below that terminal; otherwise it appears at the " +
      "center of the user's current view.",
    inputSchema: {
      title: z
        .string()
        .optional()
        .describe("Short heading shown in bold at the top of the card"),
      body: z
        .string()
        .describe(
          "The checklist as a Markdown task list, e.g.\n" +
          "- [x] Done task\n- [ ] Todo task\n  - [ ] A sub-task\n" +
          "Use two-space indentation for sub-tasks."
        ),
    },
  },
  async ({ title, body }) => {
    const fail = (text) => ({ content: [{ type: "text", text }], isError: true });
    if (!body || !body.trim()) {
      return fail("Provide the checklist `body` as a Markdown task list.");
    }
    await mkdir(INBOX_DIR, { recursive: true });
    const id = randomUUID();
    const staging = join(INBOX_DIR, `.staging-${id}`);
    const final = join(INBOX_DIR, `${Date.now()}-${id}.json`);
    try {
      const manifest = JSON.stringify({
        note: { title: title ?? null, body },
        terminalId: TERMINAL_ID,
      });
      await writeFile(staging, manifest);
      await rename(staging, final);
    } catch (error) {
      return fail(`Could not add the checklist: ${error.message}`);
    }
    return {
      content: [
        {
          type: "text",
          text:
            "Checklist pinned to the pty.party canvas. It appears immediately if " +
            "pty.party is running, otherwise on its next launch.",
        },
      ],
    };
  }
);

server.registerTool(
  "add_to_checklist",
  {
    description:
      "Appends checklist items to the Log card(s) this terminal is connected " +
      "to on the pty.party canvas. The user creates a Log (right-click the canvas " +
      "→ New Log) and drags a connection from it to this terminal; items you " +
      "add then appear on that card, and several terminals can write to the " +
      "same shared Log. Each item starts unchecked — call `check_off_item` to " +
      "tick it once done. Optionally group items under a section heading; " +
      "re-using the same section name keeps related items together.",
    inputSchema: {
      items: z
        .array(z.string())
        .describe("Checklist items to append; each becomes a '- [ ]' line"),
      section: z
        .string()
        .optional()
        .describe("Optional heading to group these items under, e.g. a task name"),
    },
  },
  async ({ items, section }) => {
    const fail = (text) => ({ content: [{ type: "text", text }], isError: true });
    if (!TERMINAL_ID) {
      return fail(
        "This session isn't running inside a pty.party terminal, so it has no " +
        "connected Log."
      );
    }
    if (!items || items.length === 0) {
      return fail("Provide at least one item to add.");
    }
    const response = await ptypartyRequest({
      type: "log_append",
      terminalId: TERMINAL_ID,
      items,
      section: section ?? null,
    });
    if (!response) {
      return fail("The pty.party app doesn't appear to be running.");
    }
    if (!response.ok) {
      return fail(
        response.error === "no log connected"
          ? "No Log is connected to this terminal. Ask the user to create a " +
            "Log on the canvas (right-click → New Log) and drag a connection " +
            "from it to this terminal."
          : `Could not add to the Log: ${response.error ?? "unknown error"}`
      );
    }
    return {
      content: [
        {
          type: "text",
          text: `Added ${items.length} item(s) to ${response.logs} connected Log(s).`,
        },
      ],
    };
  }
);

server.registerTool(
  "check_off_item",
  {
    description:
      "Marks a checklist item done on the Log(s) this terminal is connected " +
      "to, matching by the item's text (case-insensitive). Use it after you " +
      "finish a task you previously added with `add_to_checklist`.",
    inputSchema: {
      item: z
        .string()
        .describe("The text of the item to tick off, as it was added"),
    },
  },
  async ({ item }) => {
    const fail = (text) => ({ content: [{ type: "text", text }], isError: true });
    if (!TERMINAL_ID) {
      return fail("This session isn't running inside a pty.party terminal.");
    }
    const response = await ptypartyRequest({
      type: "log_check",
      terminalId: TERMINAL_ID,
      item,
    });
    if (!response) {
      return fail("The pty.party app doesn't appear to be running.");
    }
    if (!response.ok) {
      return fail(
        response.error === "no log connected"
          ? "No Log is connected to this terminal."
          : `Could not update the Log: ${response.error ?? "unknown error"}`
      );
    }
    if (!response.checked) {
      return fail(`No unchecked item matching "${item}" was found on the Log.`);
    }
    return {
      content: [{ type: "text", text: `Checked off "${item}".` }],
    };
  }
);

server.registerTool(
  "get_connected_images",
  {
    description:
      "Returns the images the user has visually connected to this terminal " +
      "on the pty.party canvas (by dragging from an image's corner handle to " +
      "this terminal). Use when the user mentions 'the connected images', " +
      "'my images', or asks you to look at images related to this session.",
    inputSchema: {},
  },
  async () => {
    if (!TERMINAL_ID) {
      return {
        content: [
          {
            type: "text",
            text:
              "This Claude session is not running inside a pty.party terminal, " +
              "so it has no connected images.",
          },
        ],
      };
    }
    let files = [];
    try {
      const dir = join(CONNECTIONS_DIR, TERMINAL_ID);
      files = (await readdir(dir))
        .filter((f) => f.endsWith(".png"))
        .sort((a, b) => parseInt(a) - parseInt(b))
        .map((f) => join(dir, f));
    } catch {
      // No directory means no connections.
    }
    if (files.length === 0) {
      return {
        content: [
          {
            type: "text",
            text:
              "No images are connected to this terminal. The user can drag " +
              "from an image's corner handle to this terminal to connect one.",
          },
        ],
      };
    }
    const content = [
      { type: "text", text: `${files.length} connected image(s):` },
    ];
    for (const file of files) {
      content.push({
        type: "image",
        data: (await readFile(file)).toString("base64"),
        mimeType: "image/png",
      });
    }
    return { content };
  }
);

server.registerTool(
  "get_connected_notes",
  {
    description:
      "Returns the sticky notes the user has visually connected to this " +
      "terminal on the pty.party canvas (by dragging from a note's edge port to " +
      "this terminal). Use when the user mentions 'the connected notes', 'my " +
      "notes', or asks you to look at notes related to this session. Each " +
      "note is returned as Markdown.",
    inputSchema: {},
  },
  async () => {
    if (!TERMINAL_ID) {
      return {
        content: [
          {
            type: "text",
            text:
              "This Claude session is not running inside a pty.party terminal, " +
              "so it has no connected notes.",
          },
        ],
      };
    }
    let files = [];
    try {
      const dir = join(CONNECTIONS_DIR, TERMINAL_ID, "notes");
      files = (await readdir(dir))
        .filter((f) => f.endsWith(".md"))
        .sort((a, b) => parseInt(a) - parseInt(b))
        .map((f) => join(dir, f));
    } catch {
      // No directory means no connected notes.
    }
    if (files.length === 0) {
      return {
        content: [
          {
            type: "text",
            text:
              "No notes are connected to this terminal. The user can select a " +
              "note and drag from one of its edge ports to this terminal to " +
              "connect one.",
          },
        ],
      };
    }
    const content = [
      { type: "text", text: `${files.length} connected note(s):` },
    ];
    for (const file of files) {
      content.push({
        type: "text",
        text: await readFile(file, "utf8"),
      });
    }
    return { content };
  }
);

server.registerTool(
  "get_connected_terminal_output",
  {
    description:
      "Returns the recent output of the other terminals the user has " +
      "connected to this one on the pty.party canvas (dashed lines between " +
      "terminals). Use when the user says things like 'watch this " +
      "terminal', 'look at the connected terminal', or 'check the last " +
      "output from this'. Output is captured live at call time — call " +
      "again to see newer output.",
    inputSchema: {},
  },
  async () => {
    if (!TERMINAL_ID) {
      return {
        content: [
          {
            type: "text",
            text:
              "This Claude session is not running inside a pty.party terminal, " +
              "so it has no connected terminals.",
          },
        ],
      };
    }
    const response = await ptypartyRequest({
      type: "connected_terminal_output",
      terminalId: TERMINAL_ID,
    });
    if (!response) {
      return {
        content: [
          { type: "text", text: "The pty.party app doesn't appear to be running." },
        ],
        isError: true,
      };
    }
    const terminals = response.terminals ?? [];
    if (terminals.length === 0) {
      return {
        content: [
          {
            type: "text",
            text:
              "No terminals are connected to this one. The user can click " +
              "this terminal and drag from one of its edge ports onto " +
              "another terminal to connect them.",
          },
        ],
      };
    }
    return {
      content: terminals.map((t, i) => ({
        type: "text",
        text:
          `--- Connected terminal ${i + 1}` +
          (t.title ? ` (${t.title})` : "") +
          ` — recent output ---\n` +
          (t.output || "(no output)"),
      })),
    };
  }
);

await server.connect(new StdioServerTransport());
