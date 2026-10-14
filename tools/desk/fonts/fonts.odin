/*
Package fonts is the faces the desk opens with, for the child, the host
and a headless render alike: the system sans at Primer's three weights
(ids 0, 1, 2), a monospace face (id 3) and two fallbacks (ids 4, 5).
*/
package desk_fonts

import "core:os"

import "jm:ui"
import "jm:ui/ops"

// FALLBACKS are the faces tried, in order, for a character the sans
// lacks. 4 and 5 are arrows and symbols. 6 to 10 are the scripts the
// sans does not cover: Arabic, Devanagari, Bengali, Thai, then CJK.
FALLBACKS :: []ops.Font_Id{4, 5, 6, 7, 8, 9, 10}

// fonts is SF on macOS, one variable font drawn at each weight; Noto Sans
// regular, medium and bold where it is installed; else jm:ui's default
// font, whose static outlines ignore the weight.
fonts :: proc(allocator := context.allocator) -> []ops.Font_Ref {
	out := make([]ops.Font_Ref, 11, allocator)
	SF :: "/System/Library/Fonts/SFNS.ttf"
	NOTO :: "/usr/share/fonts/noto/NotoSans-"
	weights := [3]f32{400, 500, 600}
	switch {
	case os.exists(SF):
		for w, i in weights {
			out[i] = {ops.Font_Id(i), SF, w}
		}
	case os.exists(NOTO + "Regular.ttf"):
		files := [3]string{NOTO + "Regular.ttf", NOTO + "Medium.ttf", NOTO + "Bold.ttf"}
		for f, i in files {
			out[i] = {ops.Font_Id(i), os.exists(f) ? f : files[0], weights[i]}
		}
	case:
		for w, i in weights {
			out[i] = {ops.Font_Id(i), ui.default_font(), w}
		}
	}
	out[3] = {3, out[0].path, 400}
	// A fallback not installed stands in as the sans, which draws nothing
	// more but keeps the ids.
	extra := [?]string{
		"/usr/share/fonts/noto/NotoSansMath-Regular.ttf",
		"/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
		"/usr/share/fonts/noto/NotoSansArabic-Regular.ttf",
		"/usr/share/fonts/noto/NotoSansDevanagari-Regular.ttf",
		"/usr/share/fonts/noto/NotoSansBengali-Regular.ttf",
		"/usr/share/fonts/noto/NotoSansThai-Regular.ttf",
		"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	}
	// The same faces Atlas looks for on macOS and Windows, after the Linux path.
	alt := [?]string{
		"",
		"",
		"/System/Library/Fonts/GeezaPro.ttc",
		"/System/Library/Fonts/Kohinoor.ttc",
		"/System/Library/Fonts/KohinoorBangla.ttc",
		"/System/Library/Fonts/Thonburi.ttc",
		"/System/Library/Fonts/PingFang.ttc",
	}
	win := [?]string{
		"",
		"",
		"C:/Windows/Fonts/tahoma.ttf",
		"C:/Windows/Fonts/Nirmala.ttc",
		"C:/Windows/Fonts/Nirmala.ttc",
		"C:/Windows/Fonts/LeelawUI.ttf",
		"C:/Windows/Fonts/msyh.ttc",
	}
	for f, i in extra {
		path := f
		if !os.exists(path) && alt[i] != "" && os.exists(alt[i]) {
			path = alt[i]
		}
		if !os.exists(path) && win[i] != "" && os.exists(win[i]) {
			path = win[i]
		}
		if !os.exists(path) {
			path = out[0].path
		}
		out[4 + i] = {ops.Font_Id(4 + i), path, 400}
	}
	for mono in ([3]string{"/System/Library/Fonts/SFNSMono.ttf", "/usr/share/fonts/noto/NotoSansMono-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf"}) {
		if os.exists(mono) {
			out[3].path = mono
			break
		}
	}
	return out
}
