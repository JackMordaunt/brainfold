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
// lacks: arrows, check marks and the like, which agents' transcripts are
// full of and Noto Sans does not draw. Their ids follow the mono face's.
FALLBACKS :: []ops.Font_Id{4, 5}

// fonts is SF on macOS, one variable font drawn at each weight; Noto Sans
// regular, medium and bold where it is installed; else jm:ui's default
// font, whose static outlines ignore the weight.
fonts :: proc(allocator := context.allocator) -> []ops.Font_Ref {
	out := make([]ops.Font_Ref, 6, allocator)
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
	extra := [2]string{"/usr/share/fonts/noto/NotoSansMath-Regular.ttf", "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf"}
	for f, i in extra {
		out[4 + i] = {ops.Font_Id(4 + i), os.exists(f) ? f : out[0].path, 400}
	}
	for mono in ([3]string{"/System/Library/Fonts/SFNSMono.ttf", "/usr/share/fonts/noto/NotoSansMono-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf"}) {
		if os.exists(mono) {
			out[3].path = mono
			break
		}
	}
	return out
}
