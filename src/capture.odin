package camerashots

import "base:runtime"
import "core:c"
import "core:mem"
import stbi "vendor:stb/image"
import win "core:sys/windows"

// Captures a rectangle in virtual-desktop pixels. Returns PNG bytes.
capture_png :: proc(x, y, w, h: i32, to_clipboard: bool) -> (png: [dynamic]byte, copied: bool, ok: bool) {
	screen := win.GetDC(nil)
	defer win.ReleaseDC(nil, screen)
	dc := win.CreateCompatibleDC(screen)
	defer win.DeleteDC(dc)

	// Bottom-up 32-bit rows: the layout CF_DIB expects.
	info: win.BITMAPINFO
	info.bmiHeader = {
		biSize     = size_of(win.BITMAPINFOHEADER),
		biWidth    = w,
		biHeight   = h,
		biPlanes   = 1,
		biBitCount = 32,
	}
	bits: win.PVOID
	bmp := win.CreateDIBSection(screen, &info, win.DIB_RGB_COLORS, &bits, nil, 0)
	if bmp == nil do return
	defer win.DeleteObject(win.HGDIOBJ(bmp))
	old := win.SelectObject(dc, win.HGDIOBJ(bmp))
	defer win.SelectObject(dc, old)
	if !win.BitBlt(dc, 0, 0, w, h, screen, x, y, win.SRCCOPY | win.CAPTUREBLT) do return

	count := int(w) * int(h)
	src := ([^][4]byte)(bits)[:count]
	if to_clipboard do copied = copy_dib(&info.bmiHeader, bits, count * 4)

	rgb := make([][3]byte, count)
	defer delete(rgb)
	for row in 0 ..< int(h) {
		from := src[(int(h) - 1 - row) * int(w):][:w]
		to := rgb[row * int(w):][:w]
		for p, i in from do to[i] = {p[2], p[1], p[0]}
	}
	sink :: proc "c" (ctx, data: rawptr, size: c.int) {
		context = runtime.default_context()
		append((^[dynamic]byte)(ctx), ..([^]byte)(data)[:size])
	}
	ok = stbi.write_png_to_func(sink, &png, w, h, 3, raw_data(rgb), w * 3) != 0
	return
}

copy_dib :: proc(header: ^win.BITMAPINFOHEADER, bits: rawptr, size: int) -> bool {
	hs := size_of(win.BITMAPINFOHEADER)
	block := win.HANDLE(win.GlobalAlloc(win.GMEM_MOVEABLE, win.SIZE_T(hs + size)))
	if block == nil do return false
	p := win.GlobalLock(win.HGLOBAL(block))
	mem.copy(p, header, hs)
	mem.copy(rawptr(uintptr(p) + uintptr(hs)), bits, size)
	win.GlobalUnlock(win.HGLOBAL(block))
	return win.SendMessageW(g_main, WM_COPY_DIB, 0, win.LPARAM(uintptr(block))) == 1
}
