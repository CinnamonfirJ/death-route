const CAPACITY = 4;
const MAX_ROOMS = 48;
const MAX_PACKET = 65536;
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE = /^[A-HJ-NP-Z2-9]{6}$/;
const MODES = new Set(["coop", "tdm", "ffa"]);
const MAPS = new Set(["hospital", "camp", "wasteland"]);
const HEADERS = { "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store" };

export default {
  fetch(request, env) {
    return env.LOBBIES.getByName("directory-v1").fetch(request);
  },
};

function status(socket, message) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

export class LobbyRelay {
  constructor(ctx) {
    this.ctx = ctx;
    this.rate = new WeakMap();
  }

  members(code) {
    return this.ctx.getWebSockets(code).filter(socket => socket.readyState === WebSocket.OPEN);
  }

  rooms() {
    return this.ctx.getWebSockets("host").filter(socket => socket.readyState === WebSocket.OPEN);
  }

  fetch(request) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/rooms") {
      const rooms = this.rooms().flatMap(socket => {
        const host = socket.deserializeAttachment();
        const count = this.members(host.code).length;
        if (!host.public || host.started || count >= CAPACITY) return [];
        return [{ code: host.code, name: host.name, count, capacity: CAPACITY,
          mode: host.mode, location: host.location }];
      });
      return Response.json({ rooms }, { headers: HEADERS });
    }
    if (url.pathname !== "/play" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Not found", { status: 404, headers: HEADERS });
    }

    const creating = url.searchParams.get("create") === "1";
    const [client, socket] = Object.values(new WebSocketPair());
    if (creating && this.rooms().length >= MAX_ROOMS) {
      return this.reject(client, socket, "The room service is busy. Try again shortly.");
    }
    let code = url.searchParams.get("code") ?? "";
    if (creating) {
      do {
        code = Array.from(crypto.getRandomValues(new Uint8Array(6)), n => ALPHABET[n % 32]).join("");
      } while (this.members(code).length);
    }
    const members = CODE.test(code) ? this.members(code) : [];
    const host = members.find(peer => peer.deserializeAttachment().id === 1)?.deserializeAttachment();
    if (!creating && (!host || host.started || members.length >= CAPACITY)) {
      return this.reject(client, socket, "That room is closed, full, or already playing.");
    }

    // IDs are assigned by the relay. A browser cannot impersonate the match host.
    let id = 1;
    if (!creating) {
      do {
        id = crypto.getRandomValues(new Uint32Array(1))[0] & 0x7fffffff;
      } while (id <= 1 || members.some(peer => peer.deserializeAttachment().id === id));
    }
    const mode = url.searchParams.get("mode");
    const location = url.searchParams.get("location");
    const member = { id, code, public: creating && url.searchParams.get("public") === "1",
      name: (url.searchParams.get("name") ?? "Courier").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 16),
      mode: MODES.has(mode) ? mode : "coop", location: MAPS.has(location) ? location : "hospital",
      started: false };
    this.ctx.acceptWebSocket(socket, creating ? [code, "host"] : [code]);
    socket.serializeAttachment(member);
    status(socket, { type: "welcome", code, id, peers: members.map(peer => peer.deserializeAttachment().id) });
    for (const peer of members) status(peer, { type: "joined", id });
    return new Response(null, { status: 101, webSocket: client });
  }

  reject(client, socket, message) {
    this.ctx.acceptWebSocket(socket);
    status(socket, { type: "error", message });
    socket.close(1008, "Cannot join room");
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket, message) {
    const member = socket.deserializeAttachment();
    if (!member) return;
    const now = Date.now();
    let budget = this.rate.get(socket);
    if (!budget || now - budget.time >= 1000) {
      budget = { time: now, packets: 0, bytes: 0 };
      this.rate.set(socket, budget);
    }
    const size = typeof message === "string" ? message.length : message.byteLength;
    budget.bytes += size;
    if (++budget.packets > 3000 || budget.bytes > 1024 * 1024 || size > MAX_PACKET + 4) {
      socket.close(1008, "Room traffic limit exceeded");
      return;
    }
    if (typeof message === "string") {
      if (member.id !== 1 || size > 512) return;
      let command;
      try { command = JSON.parse(message); } catch { return; }
      if (!command || typeof command !== "object") return;
      if (command.type === "settings") {
        if (MODES.has(command.mode)) member.mode = command.mode;
        if (MAPS.has(command.location)) member.location = command.location;
        socket.serializeAttachment(member);
      } else if (command.type === "start") {
        member.started = true;
        socket.serializeAttachment(member);
      } else if (command.type === "kick" && command.id > 1) {
        const peer = this.members(member.code).find(p => p.deserializeAttachment().id === command.id);
        peer?.close(1008, "Removed from room");
      }
      return;
    }
    if (size < 5) return;
    const packet = new DataView(message);
    const target = packet.getInt32(0, true);
    packet.setInt32(0, member.id, true);
    for (const peer of this.members(member.code)) {
      const id = peer.deserializeAttachment().id;
      if (id !== member.id && (target === 0 || target === id || (target < 0 && -target !== id))) {
        peer.send(message);
      }
    }
  }

  webSocketClose(socket) {
    const member = socket.deserializeAttachment();
    if (!member) return;
    for (const peer of this.members(member.code)) {
      if (peer === socket) continue;
      if (member.id === 1) peer.close(1001, "The host left the room");
      else status(peer, { type: "left", id: member.id });
    }
  }

  webSocketError(socket) {
    socket.close(1011, "Connection error");
  }
}
