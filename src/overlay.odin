package camerashots

import "base:runtime"
import "core:sync"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import user32 "system:User32.lib"
foreign import gdi32 "system:Gdi32.lib"
foreign import shcore "system:Shcore.lib"

@(default_calling_convention = "system")
foreign user32 {
	SetWindowDisplayAffinity :: proc(hwnd: win.HWND, affinity: win.DWORD) -> win.BOOL ---
}
@(default_calling_convention = "system")
foreign gdi32 {
	@(link_name = "CombineRgn")
	combine_rgn :: proc(dst, a, b: win.HRGN, mode: i32) -> i32 ---
}
@(default_calling_convention = "system")
foreign shcore {
	@(link_name = "GetDpiForMonitor")
	get_dpi_for_monitor :: proc(mon: win.HMONITOR, kind: i32, x, y: ^u32) -> win.HRESULT ---
}

@(default_calling_convention = "system")
foreign kernel32 {
	GetTickCount64 :: proc() -> u64 ---
	CreateMutexW :: proc(attrs: rawptr, owner: win.BOOL, name: cstring16) -> win.HANDLE ---
}

// Test builds can capture the markers to check detection.
TEST_CAPTURE_MARKERS :: #config(TEST_CAPTURE_MARKERS, false)
EXCLUDE_FROM_CAPTURE :: 0 when TEST_CAPTURE_MARKERS else 0x11
REGION_OR :: 2

// Sizes in 96-dpi units; scaled per monitor so markers look the same size.
CELL :: 8 // one marker module
MODULES :: 8 // 6 payload + black border
SPACING :: 320

Monitor :: struct {
	x, y, w, h: i32, // virtual-desktop physical pixels
	dpi:        u32,
	hwnd:       win.HWND,
}

Marker :: struct {
	id, monitor: int,
	x, y, cell:  i32, // monitor-local top-left of the black square
}

// Layout is written on the UI thread and read by server threads.
g_layout_lock: sync.Mutex
g_monitors: [dynamic]Monitor
g_markers: [dynamic]Marker
g_layout_version: int
g_visible: bool // UI thread only

register_overlay_class :: proc() {
	wc := win.WNDCLASSW{lpfnWndProc = overlay_proc, hInstance = g_instance, lpszClassName = win.L("CameraShotsOverlay")}
	win.RegisterClassW(&wc)
}

enum_monitor :: proc "system" (mon: win.HMONITOR, dc: win.HDC, r: win.LPRECT, data: win.LPARAM) -> win.BOOL {
	context = runtime.default_context()
	dx, dy: u32 = 96, 96
	get_dpi_for_monitor(mon, 0, &dx, &dy)
	append(&g_monitors, Monitor{x = r.left, y = r.top, w = r.right - r.left, h = r.bottom - r.top, dpi = dx})
	return true
}

// Lays out markers, growing the spacing until all IDs fit in the dictionary.
place_markers :: proc() {
	for spacing: i32 = SPACING;; spacing += 40 {
		clear(&g_markers)
		for m, mi in g_monitors {
			cell := max(i32(4), CELL * i32(m.dpi) / 96)
			step := spacing * i32(m.dpi) / 96
			outer := cell * (MODULES + 2) // includes white quiet zone
			cols := max(i32(2), (m.w + step / 2) / step + 1)
			rows := max(i32(2), (m.h + step / 2) / step + 1)
			for r in 0 ..< rows {
				for c in 0 ..< cols {
					append(&g_markers, Marker {
						id      = len(g_markers),
						monitor = mi,
						x       = c * (m.w - outer) / (cols - 1) + cell,
						y       = r * (m.h - outer) / (rows - 1) + cell,
						cell    = cell,
					})
				}
			}
		}
		if len(g_markers) <= len(MARKER_CODES) do return
	}
}

rebuild_overlays :: proc() {
	sync.lock(&g_layout_lock)
	defer sync.unlock(&g_layout_lock)
	for m in g_monitors do win.DestroyWindow(m.hwnd)
	clear(&g_monitors)
	win.EnumDisplayMonitors(nil, nil, enum_monitor, 0)
	place_markers()
	g_layout_version += 1
	g_visible = false // the next heartbeat shows the new windows

	for &m, mi in g_monitors {
		ex := win.WS_EX_LAYERED | win.WS_EX_TRANSPARENT | win.WS_EX_TOPMOST | win.WS_EX_TOOLWINDOW | win.WS_EX_NOACTIVATE
		m.hwnd = win.CreateWindowExW(ex, win.L("CameraShotsOverlay"), win.L("CameraShots markers"), win.WS_POPUP, m.x, m.y, m.w, m.h, nil, nil, g_instance, nil)
		if m.hwnd == nil do fail("Could not create the marker overlay.")
		win.SetLayeredWindowAttributes(m.hwnd, 0, 255, win.LWA_ALPHA)
		if !SetWindowDisplayAffinity(m.hwnd, EXCLUDE_FROM_CAPTURE) {
			fail("Windows could not hide the markers from screenshots. Windows 10 version 2004 or newer is required.")
		}
		// The window only exists where the markers are.
		region := win.CreateRectRgnIndirect(&win.RECT{})
		for k in g_markers {
			if k.monitor != mi do continue
			end := k.cell * (MODULES + 1)
			part := win.CreateRectRgnIndirect(&win.RECT{k.x - k.cell, k.y - k.cell, k.x + end, k.y + end})
			combine_rgn(region, region, part, REGION_OR)
			win.DeleteObject(win.HGDIOBJ(part))
		}
		win.SetWindowRgn(m.hwnd, region, true) // takes ownership of region
	}
}

show_overlays :: proc(show: bool) {
	if show == g_visible do return
	g_visible = show
	for m in g_monitors {
		if show {
			win.SetWindowPos(m.hwnd, win.HWND_TOPMOST, m.x, m.y, m.w, m.h, win.SWP_NOACTIVATE | win.SWP_SHOWWINDOW)
		} else {
			win.ShowWindow(m.hwnd, win.SW_HIDE)
		}
	}
}

paint_overlay :: proc(hwnd: win.HWND) {
	ps: win.PAINTSTRUCT
	dc := win.BeginPaint(hwnd, &ps)
	defer win.EndPaint(hwnd, &ps)
	black := win.HBRUSH(win.GetStockObject(win.BLACK_BRUSH))
	white := win.HBRUSH(win.GetStockObject(win.WHITE_BRUSH))
	fill :: proc(dc: win.HDC, x, y, size: i32, brush: win.HBRUSH) {
		win.FillRect(dc, &win.RECT{x, y, x + size, y + size}, brush)
	}
	for m, mi in g_monitors {
		if m.hwnd != hwnd do continue
		for k in g_markers {
			if k.monitor != mi do continue
			fill(dc, k.x - k.cell, k.y - k.cell, k.cell * (MODULES + 2), white)
			fill(dc, k.x, k.y, k.cell * MODULES, black)
			code := MARKER_CODES[k.id]
			for bit in 0 ..< 36 {
				if (code >> uint(35 - bit)) & 1 == 0 do continue
				fill(dc, k.x + i32(bit % 6 + 1) * k.cell, k.y + i32(bit / 6 + 1) * k.cell, k.cell, white)
			}
		}
	}
}

overlay_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch msg {
	case win.WM_PAINT:
		paint_overlay(hwnd)
		return 0
	case win.WM_DPICHANGED:
		return 0 // already laid out in physical pixels
	case win.WM_NCHITTEST:
		return -1 // HTTRANSPARENT
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}
