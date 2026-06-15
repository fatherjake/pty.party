import Foundation

/// The source of the dependency-free MCP bridge that pty.party pushes to a
/// remote host so a remote claude can drive the canvas Log over the
/// reverse-forwarded RPC socket.
///
/// IMPORTANT: keep this in sync with `mcp-server/ptyparty-remote-bridge.mjs`,
/// which is the canonical, testable copy. This embedded duplicate exists so the
/// installed .app is self-contained (it ships only the binary).
enum RemoteBridge {
    static let source = #"""
#!/usr/bin/env node
// pty.party remote MCP bridge — a dependency-free MCP stdio server for tiles
// running on a remote host over SSH. Pushed by the app; needs only `node`.
import { connect } from "node:net";

const TERMINAL_ID = process.env.PTYPARTY_TERMINAL_ID || null;
const RPC = process.env.PTYPARTY_RPC || "";
const SOCKET_PATH = RPC.startsWith("unix:") ? RPC.slice("unix:".length) : null;

function ptypartyRequest(payload, timeoutMs = 3000) {
  return new Promise((resolve) => {
    if (!SOCKET_PATH) return resolve(null);
    const sock = connect(SOCKET_PATH);
    let buf = "";
    let settled = false;
    const done = (value) => {
      if (settled) return;
      settled = true;
      sock.destroy();
      resolve(value);
    };
    sock.setTimeout(timeoutMs, () => done(null));
    sock.on("connect", () => sock.write(JSON.stringify(payload) + "\n"));
    sock.on("data", (chunk) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        try {
          done(JSON.parse(buf.slice(0, nl)));
        } catch {
          done(null);
        }
      }
    });
    sock.on("error", () => done(null));
    sock.on("close", () => done(null));
  });
}

const text = (t, isError = false) => ({ content: [{ type: "text", text: t }], isError });

const TOOLS = [
  {
    name: "add_to_checklist",
    description:
      "Appends checklist items to the Log card(s) this terminal is connected " +
      "to on the pty.party canvas. The user creates a Log (right-click the " +
      "canvas → New Log) and drags a connection from it to this terminal; " +
      "items you add then appear on that card. Each item starts unchecked — " +
      "call check_off_item to tick it once done. Optionally group items under " +
      "a section heading; re-using the same section keeps related items together.",
    inputSchema: {
      type: "object",
      properties: {
        items: {
          type: "array",
          items: { type: "string" },
          description: "Checklist items to append; each becomes a '- [ ]' line",
        },
        section: {
          type: "string",
          description: "Optional heading to group these items under, e.g. a task name",
        },
      },
      required: ["items"],
    },
    handler: async ({ items, section }) => {
      if (!items || items.length === 0) return text("Provide at least one item to add.", true);
      const r = await ptypartyRequest({
        type: "log_append",
        terminalId: TERMINAL_ID,
        items,
        section: section ?? null,
      });
      if (!r) return text("The pty.party app doesn't appear to be reachable from this host.", true);
      if (!r.ok) {
        return text(
          r.error === "no log connected"
            ? "No Log is connected to this terminal. Ask the user to create a Log " +
              "on the canvas (right-click → New Log) and drag a connection from it " +
              "to this terminal."
            : `Could not add to the Log: ${r.error ?? "unknown error"}`,
          true
        );
      }
      return text(`Added ${items.length} item(s) to ${r.logs} connected Log(s).`);
    },
  },
  {
    name: "check_off_item",
    description:
      "Marks a checklist item done on the Log(s) this terminal is connected to, " +
      "matching by the item's text (case-insensitive). Use it after you finish a " +
      "task you previously added with add_to_checklist.",
    inputSchema: {
      type: "object",
      properties: {
        item: { type: "string", description: "The text of the item to tick off, as it was added" },
      },
      required: ["item"],
    },
    handler: async ({ item }) => {
      const r = await ptypartyRequest({ type: "log_check", terminalId: TERMINAL_ID, item });
      if (!r) return text("The pty.party app doesn't appear to be reachable from this host.", true);
      if (!r.ok) {
        return text(
          r.error === "no log connected"
            ? "No Log is connected to this terminal."
            : `Could not update the Log: ${r.error ?? "unknown error"}`,
          true
        );
      }
      if (!r.checked) return text(`No unchecked item matching "${item}" was found on the Log.`, true);
      return text(`Checked off "${item}".`);
    },
  },
  {
    name: "get_connected_terminal_output",
    description:
      "Returns the recent output of the other terminals the user has connected " +
      "to this one on the pty.party canvas (dashed lines between terminals).",
    inputSchema: { type: "object", properties: {} },
    handler: async () => {
      const r = await ptypartyRequest({ type: "connected_terminal_output", terminalId: TERMINAL_ID });
      if (!r) return text("The pty.party app doesn't appear to be reachable from this host.", true);
      const terminals = r.terminals ?? [];
      if (terminals.length === 0) {
        return text(
          "No terminals are connected to this one. The user can drag from this " +
          "terminal's edge port onto another terminal to connect them."
        );
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
    },
  },
];

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

async function handle(msg) {
  const { id, method, params } = msg;
  const hasId = id !== undefined && id !== null;
  switch (method) {
    case "initialize":
      send({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: params?.protocolVersion || "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "ptyparty", version: "1.0.0" },
        },
      });
      return;
    case "notifications/initialized":
      return;
    case "ping":
      if (hasId) send({ jsonrpc: "2.0", id, result: {} });
      return;
    case "tools/list":
      send({
        jsonrpc: "2.0",
        id,
        result: {
          tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
        },
      });
      return;
    case "tools/call": {
      const tool = TOOLS.find((t) => t.name === params?.name);
      if (!tool) {
        send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Unknown tool: ${params?.name}` } });
        return;
      }
      if (!TERMINAL_ID) {
        send({ jsonrpc: "2.0", id, result: text("This session isn't running inside a pty.party terminal.", true) });
        return;
      }
      try {
        const result = await tool.handler(params.arguments ?? {});
        send({ jsonrpc: "2.0", id, result });
      } catch (err) {
        send({ jsonrpc: "2.0", id, result: text(`Tool error: ${err?.message ?? err}`, true) });
      }
      return;
    }
    default:
      if (hasId) send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
  }
}

let inbuf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  inbuf += chunk;
  let nl;
  while ((nl = inbuf.indexOf("\n")) >= 0) {
    const line = inbuf.slice(0, nl).trim();
    inbuf = inbuf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    handle(msg);
  }
});
process.stdin.on("end", () => process.exit(0));
"""#
}
