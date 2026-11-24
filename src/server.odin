package camerashots

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

// Plain HTTP on loopback only. Tailscale Serve adds HTTPS and forwards to this port.
PORT :: #config(PORT, 47810)
MAX_CONNECTIONS :: 32
REQUEST_TIMEOUT :: 10 * time.Second

Asset :: struct {
	path, type, body: string,
}

ICON :: #load("../assets/icon.ico", string)

ASSETS := [?]Asset {
	{"/", "text/html; charset=utf-8", #load("../web/index.html", string)},
	{"/app.js", "text/javascript; charset=utf-8", #load("../web/app.js", string)},
	{"/aruco.js", "text/javascript; charset=utf-8", #load("../web/aruco.js", string)},
	{"/cv.js", "text/javascript; charset=utf-8", #load("../web/cv.js", string)},
	{"/region.js", "text/javascript; charset=utf-8", #load("../web/region.js", string)},
	{"/manifest.webmanifest", "application/manifest+json", #load("../web/manifest.webmanifest", string)},
	{"/icon-180.png", "image/png", #load("../assets/icon-180.png", string)},
	{"/icon-192.png", "image/png", #load("../assets/icon-192.png", string)},
	{"/icon-512.png", "image/png", #load("../assets/icon-512.png", string)},
	{"/favicon.ico", "image/x-icon", ICON},
}

SECURITY_HEADERS ::
	"Cache-Control: no-store\r\n" +
	"X-Content-Type-Options: nosniff\r\n" +
	"Referrer-Policy: no-referrer\r\n" +
	"Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' blob:; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"

g_connections: int // atomic
g_capture_lock: sync.Mutex

start_server :: proc() {
	listener, err := net.listen_tcp({net.IP4_Loopback, PORT})
	if err != nil do fail(fmt.tprintf("Could not listen on 127.0.0.1:%d. Another program may be using that port.", PORT))
	thread.create_and_start_with_poly_data(listener, accept_loop, self_cleanup = true)
}

accept_loop :: proc(listener: net.TCP_Socket) {
	for {
		sock, _, err := net.accept_tcp(listener)
		if err != nil {
			time.sleep(100 * time.Millisecond) // never spin
			continue
		}
		if sync.atomic_add(&g_connections, 1) >= MAX_CONNECTIONS {
			sync.atomic_sub(&g_connections, 1)
			net.close(sock)
			continue
		}
		if thread.create_and_start_with_poly_data(sock, serve_connection, self_cleanup = true) == nil {
			sync.atomic_sub(&g_connections, 1)
			net.close(sock)
		}
	}
}

// One request per connection. No route needs a request body, so bodies are ignored.
serve_connection :: proc(sock: net.TCP_Socket) {
	defer sync.atomic_sub(&g_connections, 1)
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, REQUEST_TIMEOUT)
	net.set_option(sock, .Send_Timeout, 30 * time.Second)

	buf: [16 * 1024]byte
	used := 0
	start := time.tick_now()
	for {
		if used == len(buf) {
			reply_text(sock, 431, "request too large")
			return
		}
		n, err := net.recv_tcp(sock, buf[used:])
		if err != nil || n == 0 || time.tick_since(start) > REQUEST_TIMEOUT do return
		used += n
		if end := strings.index(string(buf[:used]), "\r\n\r\n"); end >= 0 {
			handle_request(sock, string(buf[:end]))
			net.shutdown(sock, .Send)
			return
		}
	}
}

handle_request :: proc(sock: net.TCP_Socket, head: string) {
	rest := head
	line, _ := strings.split_iterator(&rest, "\r\n")
	method, _ := strings.split_iterator(&line, " ")
	path, _ := strings.split_iterator(&line, " ")
	query := ""
	if q := strings.index_byte(path, '?'); q >= 0 {
		query = path[q + 1:]
		path = path[:q]
	}

	if method == "GET" {
		for a in ASSETS {
			if a.path == path {
				reply(sock, 200, a.type, transmute([]byte)a.body)
				return
			}
		}
	}

	expected: string
	switch path {
	case "/api/layout":
		expected = "GET"
	case "/api/heartbeat", "/api/stop", "/api/capture":
		expected = "POST"
	}
	if expected == "" || method != expected {
		reply_text(sock, 404, "not found")
		return
	}
	if !authorized(rest) {
		reply_text(sock, 401, "not paired")
		return
	}

	switch path {
	case "/api/layout":
		send_layout(sock)
	case "/api/heartbeat":
		sync.atomic_store(&g_last_heartbeat, GetTickCount64())
		win.PostMessageW(g_main, WM_SHOW_MARKERS, 0, 0)
		sync.lock(&g_layout_lock)
		version := g_layout_version
		sync.unlock(&g_layout_lock)
		reply_text(sock, 200, fmt.tprint(version))
	case "/api/stop":
		sync.atomic_store(&g_last_heartbeat, 0)
		win.PostMessageW(g_main, WM_HIDE_MARKERS, 0, 0)
		reply_text(sock, 200, "ok")
	case "/api/capture":
		send_capture(sock, query)
	}
}

authorized :: proc(headers: string) -> bool {
	PREFIX :: "Bearer "
	rest := headers
	for line in strings.split_iterator(&rest, "\r\n") {
		colon := strings.index_byte(line, ':')
		if colon < 0 || !strings.equal_fold(line[:colon], "authorization") do continue
		value := strings.trim_space(line[colon + 1:])
		if !strings.has_prefix(value, PREFIX) do return false
		token := value[len(PREFIX):]
		sync.lock(&g_token_lock)
		defer sync.unlock(&g_token_lock)
		return len(g_token) > 0 && crypto.compare_constant_time(transmute([]byte)token, transmute([]byte)g_token) == 1
	}
	return false
}

reply :: proc(sock: net.TCP_Socket, status: int, type: string, body: []byte, copied := false) {
	head := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n%s%s\r\n",
		status,
		"OK" if status == 200 else "Error",
		type,
		len(body),
		SECURITY_HEADERS,
		"X-Copied: 1\r\n" if copied else "",
	)
	if _, err := net.send_tcp(sock, transmute([]byte)head); err != nil do return
	net.send_tcp(sock, body)
}

reply_text :: proc(sock: net.TCP_Socket, status: int, text: string) {
	reply(sock, status, "text/plain; charset=utf-8", transmute([]byte)text)
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

send_layout :: proc(sock: net.TCP_Socket) {
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
	reply(sock, 200, "application/json", b.buf[:])
}

send_capture :: proc(sock: net.TCP_Socket, query: string) {
	v, ok_v := query_int(query, "v")
	m, ok_m := query_int(query, "m")
	x, ok_x := query_int(query, "x")
	y, ok_y := query_int(query, "y")
	w, ok_w := query_int(query, "w")
	h, ok_h := query_int(query, "h")
	if !(ok_v && ok_m && ok_x && ok_y && ok_w && ok_h) {
		reply_text(sock, 400, "missing parameter")
		return
	}
	sync.lock(&g_layout_lock)
	current := v == g_layout_version
	mon: Monitor
	valid := current && m >= 0 && m < len(g_monitors)
	if valid do mon = g_monitors[m]
	sync.unlock(&g_layout_lock)
	if !current {
		reply_text(sock, 409, "display layout changed, try again")
		return
	}
	mw, mh := int(mon.w), int(mon.h)
	// Written to avoid overflow with hostile values.
	if !valid || x < 0 || y < 0 || w < 1 || h < 1 || x >= mw || y >= mh || w > mw - x || h > mh - y {
		reply_text(sock, 400, "region is off screen")
		return
	}
	sync.lock(&g_capture_lock) // a full-screen capture is large; take one at a time
	png, copied, ok := capture_png(mon.x + i32(x), mon.y + i32(y), i32(w), i32(h), sync.atomic_load(&g_copy_to_clipboard))
	sync.unlock(&g_capture_lock)
	defer delete(png)
	if !ok {
		reply_text(sock, 500, "screen capture failed")
		return
	}
	win.PostMessageW(g_main, WM_CAPTURED, 0, 0)
	reply(sock, 200, "image/png", png[:], copied)
}
