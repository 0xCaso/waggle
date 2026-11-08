// A minimal newline-delimited JSON-RPC client over the daemon's unix socket.
// The shim keeps one connection open for its whole life and matches responses
// to requests by id (the daemon may also push `event` notifications).
//
// A dead socket is surfaced as DaemonConnectionError: the close/error handlers
// reject every in-flight call, so the shim can restart the daemon on demand,
// reconnect and retry the call once (KNOCK-18).

import { LineSplitter } from "../line-splitter";
import { CodedError, ERROR_CODE_DATA_KEY, ToolErrorCode, UNCLASSIFIED_ERROR_CODE } from "../protocol/error-codes";

interface Waiter {
  resolve: (message: RpcMessage) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface ClientData {
  splitter: LineSplitter;
  // WAG-343: open calls by request id. A response settles its own call, so a call that waits a long
  // time (case.wait) never holds up another one (case.update) on the same connection.
  waiters: Map<unknown, Waiter>;
  // Bytes the socket has not taken yet. A unix socket buffer is about 8 KB on macOS, so a larger
  // request (an 8 KB design kit, HAIL-166) is written in parts, the rest when the socket drains.
  outbox: Uint8Array[];
}

function flushOutbox(socket: Bun.Socket<ClientData>): void {
  const conn = socket.data;
  while (conn.outbox.length > 0) {
    const chunk = conn.outbox[0]!;
    const written = socket.write(chunk);
    if (written < 0) throw new Error("write failed");
    if (written < chunk.length) {
      conn.outbox[0] = chunk.subarray(written);
      return;
    }
    conn.outbox.shift();
  }
}

function send(socket: Bun.Socket<ClientData>, text: string): void {
  socket.data.outbox.push(new TextEncoder().encode(text));
  flushOutbox(socket);
}

interface RpcMessage {
  jsonrpc: string;
  id?: unknown;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
  method?: string;
  params?: unknown;
}

// WAG-409: the stable code of a daemon error. The daemon names it in error.data; an older daemon
// does not, so the JSON-RPC code stands in for the ones that have a single meaning.
const RPC_CODE_ERROR_CODES: Record<number, string> = {
  [-32602]: "invalid_params",
  [-32001]: "case_not_found",
  [-32002]: "case_not_yours",
  [-32003]: "session_not_known",
  [-32006]: "reply_not_queued",
  [-32007]: "follows_case_invalid",
  [-32008]: "replaces_case_invalid",
  [-32009]: "choice_not_offered",
};

export class DaemonRpcError extends Error {
  public readonly errorCode: string;
  constructor(
    public code: number,
    message: string,
    public data?: unknown,
  ) {
    // The daemon puts the real cause in error.data.message for -32603. Surface
    // that instead of the bare "Internal error" envelope (HAIL-27). A -32602
    // carries error.data.issues (server.ts formatIssues) instead: since the
    // shim no longer validates waggle_ask/waggle_check/waggle_update/waggle_guide
    // input itself (HAIL-48 - the daemon is now the only validator), a bad
    // field surfaces here for the first time, and the agent needs the same
    // per-field message text a schema.safeParse issue always carried.
    super(DaemonRpcError.displayMessage(message, data));
    this.name = "DaemonRpcError";
    const named = data && typeof data === "object" ? (data as Record<string, unknown>)[ERROR_CODE_DATA_KEY] : undefined;
    this.errorCode =
      typeof named === "string" && ToolErrorCode.safeParse(named).success
        ? named
        : (RPC_CODE_ERROR_CODES[code] ?? UNCLASSIFIED_ERROR_CODE);
  }

  private static displayMessage(message: string, data?: unknown): string {
    if (data && typeof data === "object") {
      const issues = (data as { issues?: unknown }).issues;
      if (Array.isArray(issues) && issues.length > 0) {
        return issues.map((issue) => DaemonRpcError.issueText(issue)).join("\n");
      }
      const inner = (data as { message?: unknown }).message;
      if (typeof inner === "string" && inner.length > 0) return inner;
    }
    return message;
  }

  private static issueText(issue: unknown): string {
    if (typeof issue !== "object" || issue === null) return String(issue);
    const path = (issue as { path?: unknown }).path;
    const text = (issue as { message?: unknown }).message;
    return path ? `${String(path)}: ${String(text)}` : String(text);
  }
}

// The socket died (closed, failed, or was never connected). The caller should
// reconnect, not retry against the same dead connection.
// A call got no answer in time. The daemon may still have done the work, so only an idempotent call
// (case.create with a client_request_id, HAIL-197) is retried on this.
export class DaemonTimeoutError extends CodedError {
  constructor(message: string) {
    super(message, "daemon_timeout");
    this.name = "DaemonTimeoutError";
  }
}

export class DaemonConnectionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DaemonConnectionError";
  }
}

export class DaemonClient {
  private socket: Bun.Socket<ClientData> | null = null;
  private conn: ClientData | null = null;
  private connecting: Promise<void> | null = null;
  private nextId = 1;
  // Called once each time a live connection is lost or closed (peer close,
  // socket error, or close()). The shim uses it to start its background
  // reconnect loop (HAIL-63). Never called for a connect that failed.
  onClose: (() => void) | null = null;
  // Called for a request the daemon pushes (a line with a `method` and an id,
  // HAIL-76 session.nudge). The returned promise settles the answer the client
  // writes back on the same connection. Never queued behind a waiting call().
  onRequest: ((method: string, params: unknown) => Promise<unknown>) | null = null;

  get connected(): boolean {
    return this.socket !== null;
  }

  async connect(socketPath: string): Promise<void> {
    if (this.socket) return;
    if (!this.connecting) {
      this.connecting = this.doConnect(socketPath).finally(() => {
        this.connecting = null;
      });
    }
    return this.connecting;
  }

  private async doConnect(socketPath: string): Promise<void> {
    const conn: ClientData = { splitter: new LineSplitter(), waiters: new Map(), outbox: [] };
    const self = this;
    const socket = await Bun.connect<ClientData>({
      unix: socketPath,
      data: conn,
      socket: {
        open() {},
        drain(socket) {
          try {
            flushOutbox(socket);
          } catch {
            // The close handler reports a dead socket.
          }
        },
        data(_socket, data) {
          for (const line of conn.splitter.push(data)) {
            if (self.handlePush(socket, line)) continue;
            let message: RpcMessage;
            try {
              message = JSON.parse(line) as RpcMessage;
            } catch {
              continue;
            }
            // A notification, or an answer to a call that already timed out: nobody waits for it.
            const waiter = message.id === undefined ? undefined : conn.waiters.get(message.id);
            if (!waiter) continue;
            conn.waiters.delete(message.id);
            clearTimeout(waiter.timer);
            waiter.resolve(message);
          }
        },
        close() {
          const was = self.socket === socket;
          if (was) {
            self.socket = null;
            self.conn = null;
          }
          failWaiters(conn, new DaemonConnectionError("waggle daemon connection closed"));
          if (was) self.onClose?.();
        },
        error() {
          const was = self.socket === socket;
          if (was) {
            self.socket = null;
            self.conn = null;
          }
          failWaiters(conn, new DaemonConnectionError("waggle daemon connection failed"));
          if (was) self.onClose?.();
        },
      },
    });
    this.socket = socket;
    this.conn = conn;
  }

  // True when the line was a daemon request (handled here, answered on `socket`).
  private handlePush(socket: Bun.Socket<ClientData>, line: string): boolean {
    if (!this.onRequest || !line.includes('"method"')) return false;
    let message: RpcMessage;
    try {
      message = JSON.parse(line) as RpcMessage;
    } catch {
      return false;
    }
    if (typeof message.method !== "string" || message.id === undefined) return false;
    const reply = (body: object) => {
      try {
        send(socket, JSON.stringify({ jsonrpc: "2.0", id: message.id, ...body }) + "\n");
      } catch {
        // The connection closed before the answer; the daemon times the push out.
      }
    };
    this.onRequest(message.method, message.params).then(
      (result) => reply({ result: result ?? {} }),
      (err) => reply({ error: { code: -32000, message: (err as Error).message } }),
    );
    return true;
  }

  close(): void {
    const wasConnected = this.socket !== null;
    if (this.socket) {
      try {
        this.socket.end();
      } catch {
        // Already closed.
      }
    }
    const conn = this.conn;
    this.socket = null;
    this.conn = null;
    if (conn) {
      failWaiters(conn, new DaemonConnectionError("waggle daemon connection closed"));
    }
    if (wasConnected) this.onClose?.();
  }

  // WAG-268: one message with no id and no answer. Used to cancel a waiting call, so it must not
  // wait behind that call. A closed connection ignores it.
  notify(method: string, params: unknown): void {
    if (!this.socket) return;
    try {
      send(this.socket, JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
    } catch {
      // The close handler reports a dead socket.
    }
  }

  async call(method: string, params: unknown, timeoutMs = 120000): Promise<unknown> {
    const conn = this.conn;
    if (!this.socket || !conn) {
      throw new DaemonConnectionError("waggle daemon is not connected");
    }
    const id = this.nextId++;
    const answer = new Promise<RpcMessage>((resolve, reject) => {
      const timer = setTimeout(() => {
        conn.waiters.delete(id);
        reject(new DaemonTimeoutError("timed out waiting for the waggle daemon"));
      }, timeoutMs);
      conn.waiters.set(id, { resolve, reject, timer });
    });
    try {
      send(this.socket, JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    } catch {
      this.close();
      await answer.catch(() => {});
      throw new DaemonConnectionError("waggle daemon is not connected");
    }
    const message = await answer;
    if (message.error) {
      throw new DaemonRpcError(message.error.code, message.error.message, message.error.data);
    }
    return message.result;
  }
}

function failWaiters(conn: ClientData, error: Error): void {
  const open = [...conn.waiters.values()];
  conn.waiters.clear();
  for (const waiter of open) {
    clearTimeout(waiter.timer);
    waiter.reject(error);
  }
}
