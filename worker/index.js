import { DurableObject } from 'cloudflare:workers';

const TIMEOUT_MS = 30_000;
const MAX_REPLY = 48 * 1024 * 1024;
const ROUTES = { '/api/layout': 'GET', '/api/heartbeat': 'POST', '/api/stop': 'POST', '/api/capture': 'POST' };

const text = (body, status) => new Response(body, { status, headers: { 'Cache-Control': 'no-store' } });

async function sha256(s) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

// Everything outside /api is a static file from web/ (see wrangler.jsonc).
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const pc = path === '/api/pc';
    if (!pc && ROUTES[path] !== request.method) return text('not found', 404);
    if (pc && request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return text('expected websocket', 426);
    const token = /^Bearer ([0-9a-f]{48})$/.exec(request.headers.get('Authorization') ?? '')?.[1];
    if (!token) return text('not paired', 401);
    // Only the owner's token may open a room. Fails closed until the secret is set.
    const allowed = env.TOKEN_SHA256?.trim();
    if (!allowed) return text('Set the TOKEN_SHA256 secret on the Worker.', 500);
    if ((await sha256(token)) !== allowed) return text('not paired', 401);
    // The secret token names the room, so a phone can only reach the PC it paired with.
    return env.ROOM.get(env.ROOM.idFromName(token)).fetch(request);
  },
};

// Relays phone requests to one PC over a WebSocket.
// To PC:   text "<id> <path>?<query>"
// From PC: binary [u32 LE id][u8 last] + payload. The first frame's payload is
//          "<status>\n<content type>\n<copied 0|1>"; later frames are the body.
export class Room extends DurableObject {
  pending = new Map();
  nextId = 1;

  constructor(ctx, env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  pc() {
    return this.ctx.getWebSockets().find((ws) => ws.readyState === WebSocket.OPEN);
  }

  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/api/pc') {
      for (const old of this.ctx.getWebSockets()) old.close(4000, 'replaced');
      this.failAll();
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    const ws = this.pc();
    if (!ws) return text('PC offline', 503);
    const id = this.nextId++ >>> 0;
    return new Promise((resolve) => {
      const timer = setTimeout(() => this.finish(id, text('PC timed out', 504)), TIMEOUT_MS);
      this.pending.set(id, { resolve, timer, ws, head: null, chunks: [], size: 0 });
      try {
        ws.send(`${id} ${url.pathname}${url.search}`);
      } catch {
        this.finish(id, text('PC offline', 503));
      }
    });
  }

  finish(id, response) {
    const p = this.pending.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(id);
    p.resolve(response);
  }

  failAll(ws) {
    for (const [id, p] of [...this.pending]) if (!ws || p.ws === ws) this.finish(id, text('PC offline', 503));
  }

  webSocketMessage(ws, message) {
    if (typeof message === 'string' || message.byteLength < 5) return;
    const view = new DataView(message);
    const id = view.getUint32(0, true);
    const p = this.pending.get(id);
    if (!p || p.ws !== ws) return;
    const payload = new Uint8Array(message, 5);
    if (!p.head) p.head = new TextDecoder().decode(payload).split('\n');
    else {
      p.chunks.push(payload);
      p.size += payload.byteLength;
    }
    if (p.size > MAX_REPLY) return this.finish(id, text('screenshot too large', 500));
    if (!view.getUint8(4)) return;
    const [status, type, copied] = p.head;
    const headers = { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
    if (copied === '1') headers['X-Copied'] = '1';
    this.finish(id, new Response(new Blob(p.chunks), { status: +status, headers }));
  }

  webSocketClose(ws) {
    this.failAll(ws);
  }

  webSocketError(ws) {
    this.failAll(ws);
  }
}
