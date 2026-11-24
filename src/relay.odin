package camerashots

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"

foreign import winhttp "system:Winhttp.lib"

HINTERNET :: distinct rawptr

@(default_calling_convention = "system")
foreign winhttp {
	WinHttpOpen :: proc(agent: cstring16, access: u32, proxy, bypass: cstring16, flags: u32) -> HINTERNET ---
	WinHttpConnect :: proc(session: HINTERNET, host: cstring16, port: u16, reserved: u32) -> HINTERNET ---
	WinHttpOpenRequest :: proc(conn: HINTERNET, verb, path, version, referrer: cstring16, accept: rawptr, flags: u32) -> HINTERNET ---
	WinHttpSetTimeouts :: proc(h: HINTERNET, resolve, connect, send, receive: i32) -> win.BOOL ---
	WinHttpSetOption :: proc(h: HINTERNET, option: u32, buf: rawptr, len: u32) -> win.BOOL ---
	WinHttpSendRequest :: proc(h: HINTERNET, headers: cstring16, headers_len: u32, body: rawptr, body_len, total: u32, ctx: uintptr) -> win.BOOL ---
	WinHttpReceiveResponse :: proc(h: HINTERNET, reserved: rawptr) -> win.BOOL ---
	WinHttpWebSocketCompleteUpgrade :: proc(h: HINTERNET, ctx: uintptr) -> HINTERNET ---
	WinHttpWebSocketSend :: proc(h: HINTERNET, type: u32, buf: rawptr, len: u32) -> u32 ---
	WinHttpWebSocketReceive :: proc(h: HINTERNET, buf: rawptr, len: u32, read: ^u32, type: ^u32) -> u32 ---
	WinHttpCloseHandle :: proc(h: HINTERNET) -> win.BOOL ---
}

ACCESS_AUTOMATIC_PROXY :: 4
FLAG_SECURE :: 0x00800000
OPTION_UPGRADE_TO_WEB_SOCKET :: 114
WS_BINARY :: 0
WS_TEXT :: 2

CHUNK :: 512 * 1024
PING_INTERVAL :: 20 * time.Second
RECEIVE_TIMEOUT_MS :: 60_000 // pongs arrive every 20 s, so silence means a dead link

g_relay: string // e.g. https://camerashots.example.workers.dev
g_token_generation: int // atomic, bumped on reset
g_ping_now: sync.Sema
g_ws_lock: sync.Mutex // guards g_ws and sends
g_ws: HINTERNET

ws_send :: proc(type: u32, data: []byte) -> bool {
	sync.lock(&g_ws_lock)
	defer sync.unlock(&g_ws_lock)
	if g_ws == nil do return false
	return WinHttpWebSocketSend(g_ws, type, raw_data(data), u32(len(data))) == 0
}

ping_loop :: proc() {
	for {
		sync.sema_wait_with_timeout(&g_ping_now, PING_INTERVAL)
		ws_send(WS_TEXT, transmute([]byte)string("ping"))
	}
}

relay_loop :: proc() {
	for {
		start := time.tick_now()
		relay_session()
		// Reconnect quickly after a long session, but never spin.
		wait := time.Second if time.tick_since(start) > 10 * time.Second else 3 * time.Second
		free_all(context.temp_allocator)
		time.sleep(wait)
	}
}

relay_session :: proc() {
	secure := strings.has_prefix(g_relay, "https://")
	host := g_relay[strings.index(g_relay, "://") + 3:]
	port := 443 if secure else 80
	if colon := strings.index_byte(host, ':'); colon >= 0 {
		port, _ = strconv.parse_int(host[colon + 1:], 10)
		host = host[:colon]
	}
	generation := sync.atomic_load(&g_token_generation)
	sync.lock(&g_token_lock)
	headers := fmt.tprintf("Authorization: Bearer %s", g_token)
	sync.unlock(&g_token_lock)

	session := WinHttpOpen("CameraShots", ACCESS_AUTOMATIC_PROXY, nil, nil, 0)
	if session == nil do return
	defer WinHttpCloseHandle(session)
	WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, RECEIVE_TIMEOUT_MS)
	conn := WinHttpConnect(session, win.utf8_to_wstring(host), u16(port), 0)
	if conn == nil do return
	defer WinHttpCloseHandle(conn)
	request := WinHttpOpenRequest(conn, "GET", "/api/pc", nil, nil, nil, FLAG_SECURE if secure else 0)
	if request == nil do return
	defer WinHttpCloseHandle(request)
	if !WinHttpSetOption(request, OPTION_UPGRADE_TO_WEB_SOCKET, nil, 0) do return
	if !WinHttpSendRequest(request, win.utf8_to_wstring(headers), 0xFFFF_FFFF, nil, 0, 0, 0) do return
	if !WinHttpReceiveResponse(request, nil) do return
	ws := WinHttpWebSocketCompleteUpgrade(request, 0)
	if ws == nil do return

	sync.lock(&g_ws_lock)
	g_ws = ws
	sync.unlock(&g_ws_lock)
	defer {
		sync.lock(&g_ws_lock)
		g_ws = nil
		WinHttpCloseHandle(ws)
		sync.unlock(&g_ws_lock)
	}

	buf: [4096]byte
	for {
		used := 0
		for {
			n, type: u32
			if used == len(buf) do return
			if WinHttpWebSocketReceive(ws, &buf[used], u32(len(buf) - used), &n, &type) != 0 do return
			used += int(n)
			if type == WS_TEXT do break
			if type != WS_TEXT + 1 do return // not a text fragment
		}
		// A reset revokes the old token: drop the connection without answering.
		if sync.atomic_load(&g_token_generation) != generation do return
		message := string(buf[:used])
		if message != "pong" do handle_request(message)
		free_all(context.temp_allocator)
	}
}

reply :: proc(id: u32, status: int, type: string, body: []byte, copied := false) {
	frame := make([]byte, 5 + CHUNK)
	defer delete(frame)
	(^u32le)(raw_data(frame))^ = u32le(id)
	head := fmt.tprintf("%d\n%s\n%d", status, type, 1 if copied else 0)
	frame[4] = 1 if len(body) == 0 else 0
	copy(frame[5:], head)
	if !ws_send(WS_BINARY, frame[:5 + len(head)]) do return
	rest := body
	for len(rest) > 0 {
		n := min(len(rest), CHUNK)
		copy(frame[5:], rest[:n])
		rest = rest[n:]
		frame[4] = 1 if len(rest) == 0 else 0
		if !ws_send(WS_BINARY, frame[:5 + n]) do return
	}
}

reply_text :: proc(id: u32, status: int, text: string) {
	reply(id, status, "text/plain; charset=utf-8", transmute([]byte)text)
}

// message: "<id> <path>?<query>"
handle_request :: proc(message: string) {
	space := strings.index_byte(message, ' ')
	if space < 0 do return
	parsed, ok := strconv.parse_u64(message[:space], 10)
	if !ok do return
	id := u32(parsed)
	path, query := message[space + 1:], ""
	if q := strings.index_byte(path, '?'); q >= 0 {
		query = path[q + 1:]
		path = path[:q]
	}
	switch path {
	case "/api/layout":
		send_layout(id)
	case "/api/heartbeat":
		sync.atomic_store(&g_last_heartbeat, GetTickCount64())
		win.PostMessageW(g_main, WM_SHOW_MARKERS, 0, 0)
		sync.lock(&g_layout_lock)
		version := g_layout_version
		sync.unlock(&g_layout_lock)
		reply_text(id, 200, fmt.tprint(version))
	case "/api/stop":
		sync.atomic_store(&g_last_heartbeat, 0)
		win.PostMessageW(g_main, WM_HIDE_MARKERS, 0, 0)
		reply_text(id, 200, "ok")
	case "/api/capture":
		send_capture(id, query)
	case:
		reply_text(id, 404, "not found")
	}
}

query_int :: proc(query, name: string) -> (int, bool) {
	rest := query
	for pair in strings.split_iterator(&rest, "&") {
		if len(pair) > len(name) && pair[:len(name)] == name && pair[len(name)] == '=' {
			return strconv.parse_int(pair[len(name) + 1:], 10)
		}
	}
	return 0, false
}

send_layout :: proc(id: u32) {
	b := strings.builder_make(context.temp_allocator)
	sync.lock(&g_layout_lock)
	fmt.sbprintf(&b, `{{"version":%d,"monitors":[`, g_layout_version)
	for m, i in g_monitors {
		fmt.sbprintf(&b, `%s{{"w":%d,"h":%d}}`, "," if i > 0 else "", m.w, m.h)
	}
	strings.write_string(&b, `],"markers":[`)
	for k, i in g_markers {
		fmt.sbprintf(&b, `%s{{"id":%d,"m":%d,"x":%d,"y":%d,"s":%d}}`, "," if i > 0 else "", k.id, k.monitor, k.x, k.y, k.cell * MODULES)
	}
	strings.write_string(&b, "]}")
	sync.unlock(&g_layout_lock)
	reply(id, 200, "application/json", b.buf[:])
}

send_capture :: proc(id: u32, query: string) {
	v, ok_v := query_int(query, "v")
	m, ok_m := query_int(query, "m")
	x, ok_x := query_int(query, "x")
	y, ok_y := query_int(query, "y")
	w, ok_w := query_int(query, "w")
	h, ok_h := query_int(query, "h")
	if !(ok_v && ok_m && ok_x && ok_y && ok_w && ok_h) {
		reply_text(id, 400, "missing parameter")
		return
	}
	sync.lock(&g_layout_lock)
	current := v == g_layout_version
	mon: Monitor
	valid := current && m >= 0 && m < len(g_monitors)
	if valid do mon = g_monitors[m]
	sync.unlock(&g_layout_lock)
	if !current {
		reply_text(id, 409, "display layout changed, try again")
		return
	}
	mw, mh := int(mon.w), int(mon.h)
	// Written to avoid overflow with hostile values.
	if !valid || x < 0 || y < 0 || w < 1 || h < 1 || x >= mw || y >= mh || w > mw - x || h > mh - y {
		reply_text(id, 400, "region is off screen")
		return
	}
	png, copied, ok := capture_png(mon.x + i32(x), mon.y + i32(y), i32(w), i32(h), sync.atomic_load(&g_copy_to_clipboard))
	defer delete(png)
	if !ok {
		reply_text(id, 500, "screen capture failed")
		return
	}
	win.PostMessageW(g_main, WM_CAPTURED, 0, 0)
	reply(id, 200, "image/png", png[:], copied)
}
