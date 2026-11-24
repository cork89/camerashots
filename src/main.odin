package camerashots

import "base:runtime"
import "core:crypto"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

HEARTBEAT_TIMEOUT_MS :: 6000

WM_TRAY :: win.WM_APP + 1
WM_SHOW_MARKERS :: win.WM_APP + 2
WM_COPY_DIB :: win.WM_APP + 3
WM_HIDE_MARKERS :: win.WM_APP + 4
WM_CAPTURED :: win.WM_APP + 5

ICON_ID :: 1 // matches assets/app.rc

CMD_PAIR :: 1
CMD_RESET :: 2
CMD_CLIPBOARD :: 3
CMD_QUIT :: 4

g_main: win.HWND
g_instance: win.HINSTANCE
g_last_heartbeat: u64 // atomic, GetTickCount64
g_copy_to_clipboard := #config(CLIPBOARD, true) // atomic
g_token: string // written on the UI thread; guarded by g_token_lock
g_token_lock: sync.Mutex
PAIR_ON_SETUP :: #config(PAIR_ON_SETUP, true)
g_dir: string
g_url: string // e.g. https://my-pc.my-tailnet.ts.net
g_tray: win.NOTIFYICONDATAW

fail :: proc(msg: string) -> ! {
	win.MessageBoxW(nil, win.utf8_to_wstring(msg), win.L("CameraShots"), win.MB_ICONERROR)
	os.exit(1)
}

// Saves or loads the HTTPS address phones use. Returns false if it isn't a usable URL.
load_url :: proc(arg: string) -> bool {
	path := fmt.tprintf("%s\\url", g_dir)
	url := arg
	if url == "" {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil do return false
		url = string(data)
	}
	url = strings.trim_right(strings.trim_space(url), "/")
	local := strings.has_prefix(url, "http://127.0.0.1:") // testing in a browser on this PC
	if !local && !strings.has_prefix(url, "https://") do return false
	host := url[strings.index(url, "://") + 3:]
	if host == "" do return false
	for c in host {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', ':':
		case:
			return false
		}
	}
	g_url = strings.clone(url)
	if arg != "" && os.write_entire_file(path, g_url) != nil do fail("Could not save the address.")
	return true
}

token_path :: proc() -> string {
	return fmt.tprintf("%s\\token", g_dir)
}

new_token :: proc() {
	raw: [24]byte
	crypto.rand_bytes(raw[:])
	b: strings.Builder
	strings.builder_init(&b)
	for v in raw do fmt.sbprintf(&b, "%02x", v)
	sync.lock(&g_token_lock)
	g_token = strings.to_string(b)
	sync.unlock(&g_token_lock)
	if os.write_entire_file(token_path(), g_token) != nil do fail("Could not save the pairing token.")
}

load_token :: proc() {
	data, err := os.read_entire_file(token_path(), context.allocator)
	if err == nil && len(data) == 48 {
		g_token = string(data)
	} else {
		new_token()
	}
}

// The QR page is a local file, so the token is never served over the network.
open_pairing_page :: proc() {
	page := string(#load("../web/pair.html"))
	page, _ = strings.replace_all(page, "/*QRCODE_JS*/", string(#load("../web/qrcode.js")), context.temp_allocator)
	icon, _ := base64.encode(transmute([]byte)string(ICON), allocator = context.temp_allocator)
	page, _ = strings.replace_all(page, "__ICON__", icon, context.temp_allocator)
	page, _ = strings.replace_all(page, "__TOKEN__", g_token, context.temp_allocator)
	page, _ = strings.replace_all(page, "__URL__", g_url, context.temp_allocator)
	path := fmt.tprintf("%s\\pair.html", g_dir)
	if os.write_entire_file(path, page) != nil {
		win.MessageBoxW(g_main, win.L("Could not write the pairing page."), win.L("CameraShots"), win.MB_ICONERROR)
		return
	}
	win.ShellExecuteW(nil, win.L("open"), win.utf8_to_wstring(path), nil, nil, win.SW_SHOWNORMAL)
}

// Makes every capture visible on the PC, so a leaked token can't be used silently.
notify_capture :: proc() {
	NIIF_INFO_NOSOUND :: 0x1 | 0x10
	n := g_tray
	n.uFlags = win.NIF_INFO
	n.dwInfoFlags = NIIF_INFO_NOSOUND
	for r, i in "Screenshot taken" do n.szInfoTitle[i] = u16(r)
	for r, i in "Not you? Choose Reset pairing in the tray menu." do n.szInfo[i] = u16(r)
	win.Shell_NotifyIconW(win.NIM_MODIFY, &n)
}

tray_menu :: proc() {
	menu := win.CreatePopupMenu()
	defer win.DestroyMenu(menu)
	check: win.UINT = win.MF_CHECKED if sync.atomic_load(&g_copy_to_clipboard) else 0
	win.AppendMenuW(menu, win.MF_STRING, CMD_PAIR, win.L("Pair phone..."))
	win.AppendMenuW(menu, win.MF_STRING, CMD_RESET, win.L("Reset pairing"))
	win.AppendMenuW(menu, win.MF_STRING | check, CMD_CLIPBOARD, win.L("Copy shots to clipboard"))
	win.AppendMenuW(menu, win.MF_STRING, CMD_QUIT, win.L("Quit"))
	p: win.POINT
	win.GetCursorPos(&p)
	win.SetForegroundWindow(g_main)
	cmd := win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, p.x, p.y, 0, g_main, nil)
	switch cmd {
	case CMD_PAIR:
		open_pairing_page()
	case CMD_RESET:
		new_token()
		open_pairing_page()
	case CMD_CLIPBOARD:
		sync.atomic_store(&g_copy_to_clipboard, !sync.atomic_load(&g_copy_to_clipboard))
	case CMD_QUIT:
		win.DestroyWindow(g_main)
	}
}

// Picks the size Windows wants for the tray, so it isn't scaled down from 32 px.
load_tray_icon :: proc() -> win.HICON {
	cx, cy := win.GetSystemMetrics(win.SM_CXSMICON), win.GetSystemMetrics(win.SM_CYSMICON)
	icon := win.LoadImageW(g_instance, cstring16(win.MAKEINTRESOURCEW(ICON_ID)), win.IMAGE_ICON, cx, cy, win.LR_DEFAULTCOLOR)
	if icon == nil do return win.LoadIconA(nil, win.IDI_APPLICATION) // built without the resource
	return win.HICON(icon)
}

main_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch msg {
	case WM_TRAY:
		if u32(lp) == win.WM_RBUTTONUP || u32(lp) == win.WM_LBUTTONUP do tray_menu()
		return 0
	case WM_SHOW_MARKERS:
		show_overlays(true)
		return 0
	case WM_HIDE_MARKERS:
		show_overlays(false)
		return 0
	case WM_CAPTURED:
		notify_capture()
		return 0
	case WM_COPY_DIB:
		// Takes ownership of the global memory in lp. Returns 1 on success.
		block := win.HANDLE(uintptr(lp))
		if win.OpenClipboard(hwnd) {
			defer win.CloseClipboard()
			win.EmptyClipboard()
			if win.SetClipboardData(win.CF_DIB, block) != nil do return 1
		}
		win.GlobalFree(block)
		return 0
	case win.WM_TIMER:
		if GetTickCount64() - sync.atomic_load(&g_last_heartbeat) > HEARTBEAT_TIMEOUT_MS do show_overlays(false)
		return 0
	case win.WM_DISPLAYCHANGE:
		rebuild_overlays()
		return 0
	case win.WM_DESTROY:
		win.Shell_NotifyIconW(win.NIM_DELETE, &g_tray)
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wp, lp)
}

main :: proc() {
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	g_instance = win.HINSTANCE(win.GetModuleHandleW(nil))

	base, found := os.lookup_env("LOCALAPPDATA", context.allocator)
	if !found do fail("LOCALAPPDATA is not set.")
	g_dir = fmt.aprintf("%s\\CameraShots", base)
	os.make_directory(g_dir)

	CreateMutexW(nil, false, win.L("CameraShotsSingleInstance"))
	if win.GetLastError() == win.ERROR_ALREADY_EXISTS do fail("CameraShots is already running. Use its tray icon.")

	arg := ""
	if len(os.args) == 3 && os.args[1] == "--url" do arg = os.args[2]
	if !load_url(arg) do fail("Set your Tailscale address first:\n\ncamerashots.exe --url https://YOUR-PC.YOUR-TAILNET.ts.net")
	load_token()

	wc := win.WNDCLASSW{lpfnWndProc = main_proc, hInstance = g_instance, lpszClassName = win.L("CameraShotsMain")}
	win.RegisterClassW(&wc)
	// A hidden top-level window; message-only windows don't get WM_DISPLAYCHANGE.
	g_main = win.CreateWindowExW(0, wc.lpszClassName, win.L("CameraShots"), 0, 0, 0, 0, 0, nil, nil, g_instance, nil)
	if g_main == nil do fail("Could not create the main window.")

	register_overlay_class()
	rebuild_overlays()
	win.SetTimer(g_main, 1, 500, nil)

	g_tray = win.NOTIFYICONDATAW {
		cbSize           = size_of(win.NOTIFYICONDATAW),
		hWnd             = g_main,
		uID              = 1,
		uFlags           = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP,
		uCallbackMessage = WM_TRAY,
		hIcon            = load_tray_icon(),
	}
	for r, i in "CameraShots" do g_tray.szTip[i] = u16(r)
	win.Shell_NotifyIconW(win.NIM_ADD, &g_tray)

	start_server()

	if PAIR_ON_SETUP && arg != "" do open_pairing_page()

	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
		free_all(context.temp_allocator)
	}
}
