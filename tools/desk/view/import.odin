package desk_view

import "core:path/filepath"
import "core:strings"

import "jm:ui"
import "jm:ui/primer"

import "../shapes"

// Importing what the agents remembered on their own: every Claude Code
// project's memories and Gemini CLI's, proposed into the inbox, so what
// one agent learned is offered to the others.

// Import_Pick is the import dialog: open, and the source paths ticked,
// filled from the list the first time it arrives.
Import_Pick :: struct {
	open:   bool,
	filled: bool,
	ticked: [dynamic]string, // in the model's allocator
	gen:    int, // bumped after an import, so the list is read again
}

// inbox_control opens the import dialog.
inbox_control :: proc(gtx: ^ui.Ctx, m: ^Model) {
	st := ui.stack_open(gtx)
	defer ui.close(&st)
	busy := waiting_on(m, .Import)
	if primer.button(gtx, tr(m, .Import), .Default, .Medium, leading = .Download, loading = busy) && !busy {
		open_import(m)
	}
	primer.tooltip(gtx, tr(m, .Import_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
}

// open_import opens the dialog with every source that has something new
// ticked once the list arrives.
open_import :: proc(m: ^Model) {
	m.import_pick.open = true
	m.import_pick.filled = false
	untick_all(m)
}

@(private = "file")
untick_all :: proc(m: ^Model) {
	for p in m.import_pick.ticked {
		delete(p, m.allocator)
	}
	clear(&m.import_pick.ticked)
}

@(private = "file")
ticked :: proc(m: ^Model, p: string) -> int {
	for x, i in m.import_pick.ticked {
		if x == p {
			return i
		}
	}
	return -1
}

// import_dialog is the sources, each to tick, and the import of those
// ticked.
import_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ip := &m.import_pick
	if !ip.open {
		return
	}
	s := &m.scheme
	list, st := ui.need(gtx, shapes.Import_Sources{gen = ip.gen}, shapes.Import_Sources_Result)
	if ready(st) && !ip.filled {
		ip.filled = true
		for src in list.sources {
			if src.new > 0 {
				append(&ip.ticked, strings.clone(src.path, m.allocator))
			}
		}
	}
	fresh := 0
	if ready(st) {
		for src in list.sources {
			if ticked(m, src.path) >= 0 {
				fresh += src.new
			}
		}
	}
	go_, cancel: bool
	label := tf(m, .Propose_Memories, fresh)
	footer := []primer.Dialog_Button{{content = tr(m, .Cancel), clicked = &cancel}, {content = label, type = .Primary, disabled = fresh == 0, clicked = &go_}}
	dl := primer.dialog_open(gtx, &ip.open, tr(m, .Import_Memories), tr(m, .Import_Body), footer, width = .Large)
	if dl.visible {
		ui.column(gtx, gap = 8, align = .Fill)
		switch {
		case !ready(st):
			loading(gtx, 3)
		case list.error != "":
			primer.inline_message(gtx, list.error, .Critical, .Small)
		case len(list.sources) == 0:
			primer.text(gtx, tr(m, .No_Memories), .Small, color = s[.Fg_Color_Muted])
		case:
			for src, i in list.sources {
				on := ticked(m, src.path) >= 0
				name := src.label
				if src.kind == "claude" {
					project := filepath.base(src.label)
					name = tf(m, .Claude_Project, project == "~" ? tr(m, .Home_Folder) : project)
				} else if src.kind == "gemini" {
					name = tr(m, .Gemini_Cli)
				}
				caption := src.new == 0 ? tf(m, .Memories_Known, src.memories) : tf(m, .Memories_New, src.new, src.memories, short_path(src.label))
				if primer.checkbox(gtx, &on, name, caption = caption, state = src.new == 0 ? .Disabled : .Live, key = u64(i + 1)) {
					if j := ticked(m, src.path); on && j < 0 {
						append(&ip.ticked, strings.clone(src.path, m.allocator))
					} else if !on && j >= 0 {
						delete(ip.ticked[j], m.allocator)
						ordered_remove(&ip.ticked, j)
					}
				}
			}
		}
	}
	primer.dialog_close(&dl)
	if cancel {
		ip.open = false
	}
	if go_ && fresh > 0 {
		send(gtx, m, .Import, ip.ticked[:])
		ip.open = false
	}
}

// PATH_SHOWN is the longest a path is shown in full; a longer one keeps
// its start and end.
PATH_SHOWN :: 40

// short_path is p cut in the middle when it is too long for a line.
short_path :: proc(p: string) -> string {
	q := p
	if len(q) <= PATH_SHOWN {
		return q
	}
	return strings.concatenate({q[:16], "…", q[len(q) - (PATH_SHOWN - 17):]}, context.temp_allocator)
}
