package desk_view

import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"

import "../shapes"

// The layout sweep: every page, over realistic answers, at window sizes
// from the smallest the desk allows to a wide desktop, holds to the rules
// a layout that works keeps: nothing cut off at a side, every pane inside
// the window and big enough to use, every figure card at its full height
// and all of a row's the same.

STAT_MIN_HEIGHT :: 88 // a compact card, without its note, in a short window

SWEEP_WIDTHS :: [?]f32{800, 840, 880, 920, 960, 1000, 1040, 1080, 1120, 1200, 1280, 1440, 1600}
SWEEP_HEIGHTS :: [?]f32{560, 620, 700, 800, 1000}

@(private = "file")
LONG :: "a fact long enough to wrap across several lines in a narrow pane, as many of the vault's bullets are, with a path like ~/Source/Personal/brainfold/tools/desk/view in it"

// answer delivers a realistic answer to every need a page may have.
@(private = "file")
answer :: proc(p: ^ui.Probe, m: ^Model) {
	ui.probe_deliver(p, shapes.Log{}, shapes.Log_Result {
		backlog = {{query = "harfbuzz shaping cluster", misses = 3, last = "2026-10-08 10:42:00"}, {query = "BSA", misses = 1, last = "2026-10-07 09:00:00"}},
		answered = {"prime declarations adds hold value already declared elsewhere. judge pair list. brain tend.odin", "pack saz-admin-frontend"},
		recent = {{ts = "2026-10-08 10:42:00", query = "prime awkward size activity page shows stat cards squash vertically. open app perform", hits = 5, caller = "claude"}, {ts = "2026-10-08 10:41:00", query = "pack sonar", hits = 0, caller = "claude"}},
		callers = {{caller = "claude", queries = 349, sessions = 159, misses = 60, bytes = 863_000}},
	})
	ui.probe_deliver(p, shapes.Ledger{}, shapes.Ledger_Result {
		baseline_tokens = 35_000,
		callers = {{caller = "claude", sessions = 159, lookups = 349, answered = 289, tokens_returned = 215_000, tokens_saved = 10_000_000}},
		days = {{day = "2026-10-08", lookups = 319, answered = 265, tokens_returned = 205_000}, {day = "2026-10-07", lookups = 30, answered = 23, tokens_returned = 10_000}},
	})
	ui.probe_deliver(p, shapes.Inbox{}, shapes.Inbox_Result {
		proposals = {
			{n = 1, handle = "jm:ui menu steals focus back", fact = LONG, source = "sonar gui/view/actions.odin dialogs, read in the session that found it", date = "2026-10-08", aliases = "rename dialog focus, action_menu focus return"},
			{n = 2, handle = "init_context threads own their temp allocator", fact = LONG, source = "jm", date = "2026-10-08"},
			{n = 3, handle = "brain doctor contradictions dropped", fact = LONG, source = "Jack", date = "2026-10-08"},
		},
	})
	ui.probe_deliver(p, shapes.Doctor{}, shapes.Doctor_Result {
		queries_logged = 349,
		ran_at = "10:42:00",
		took_ms = 1300,
		failed_claims = {{file = "AI/LEARNINGS.md", handle = "cl flags under git bash on github runners", kind = "path", text = "C:/Program", why = "not on this machine", checked = "2026-10-08"}},
		thin_aliases = {{file = "AI/MEMORY.md", handle = "odin debug tooling", aliases = "jm:debug (was jfm:debug"}, {file = "AI/MEMORY.md", handle = "ghostty", aliases = "mouse-scroll-multiplier"}},
		oversized = {{file = "AI/MEMORY.md", handle = "workspace-alert", len = 1274}},
	})
	ui.probe_deliver(p, shapes.Bullets{}, shapes.Bullets_Result {
		bullets = {
			{file = "AI/MEMORY.md", line = 8, handle = "jm:ui menu steals focus back", aliases = "rename dialog focus, action_menu focus return", fact = LONG, source = "sonar gui/view/actions.odin", date = "2026-09-01"},
			{file = "AI/LEARNINGS.md", line = 3, handle = "ghostty", aliases = "mouse-scroll-multiplier", fact = "a short fact", source = "", date = "2026-10-08"},
		},
		files = {"AI/MEMORY.md", "AI/LEARNINGS.md", "AI/TUNINGS.md"},
	})
		ui.probe_deliver(p, shapes.Vault{}, shapes.Vault_Result{vault = "/home/jfm/Source/Personal/brain", tool = "/home/jfm/Source/Personal/brainfold", version = "dev", commit = "1e4e8dc-dirty", sync = "on", remote = "git@mordaunt.dev:brain.git", last = "2026-10-08T10:30:13Z sent 0 received 0", changed = 2, review = "after"})
	ui.probe_deliver(p, shapes.Recall{terms = "hyprctl eval", limit = RECALL_LIMIT}, shapes.Recall_Result {
		turns = {{id = "85801a30", date = "2026-09-22", agent = "pi", title = "Dedicated workspace per project", snippet = "`[hyprctl] keyword` is dead on this setup (non-legacy parser) — it says use `[eval]` …"}, {id = "d310f148", date = "2026-09-22", agent = "pi", title = "Named workspace scrolling mode not applying", snippet = LONG}},
	})
	ui.probe_deliver(p, shapes.Around{id = "85801a30"}, shapes.Around_Result {
		id = "85801a30",
		session = "01a0c933-bce1-70db-9f37-ec17a03ff879",
		title = "Dedicated workspace per project",
		turns = {{id = "a0", ts = "2026-09-22T13:02:00Z", role = "user", body = LONG}, {id = "85801a30", ts = "2026-09-22T13:05:00Z", role = "assistant", body = LONG, hit = true}},
	})
	ui.probe_deliver(p, shapes.Bullet_Show{handle = "jm:ui menu steals focus back", at = "AI/MEMORY.md:8"}, shapes.Bullet_Show_Result {
		file = "AI/MEMORY.md",
		line = 8,
		handle = "jm:ui menu steals focus back",
		served = {times = 1234, sessions = 210, top = 400, first = "2026-09-01 10:00:00", last = "2026-10-08 10:00:00", callers = {{caller = "claude", times = 1200}, {caller = "pi", times = 34}}, queries = {{query = LONG, times = 900}, {query = "focus", times = 334}}, days = {{day = "2026-10-07", times = 30}, {day = "2026-10-08", times = 40}}},
		claims = {{kind = "path", text = "~/Source/Personal/sonar/gui/view/actions.odin", verdict = "passed", checked = "2026-10-08"}},
		history = {{commit = "eaa5237", date = "2026-10-02", subject = "sync: 2 files from omarchy", files = {"AI/INBOX.md", "AI/MEMORY.md"}}},
		proposed = {ts = "2026-10-02T20:50:08Z", agent = "claude", session = "s1", title = LONG, turn = "t1"},
	})
	ui.probe_deliver(p, shapes.Spend{days = 30}, shapes.Spend_Result {
		days = 30,
		cost = 2463.4,
		unpriced = 1_661_670_548,
		sessions = 396,
		by_day = {{name = "2026-09-20", cost = 260}, {name = "2026-10-08", cost = 420}},
		by_agent = {{name = "claude", cost = 2463, sessions = 367, tokens = 5_257_000_000}, {name = "pi", sessions = 29, tokens = 91_000_000, priced = true}},
		by_model = {{name = "claude-opus-5-5", cost = 1335, tokens = 2_011_000_000, priced = true}, {name = "claude-fable-5-1", tokens = 1_661_670_548}},
		served = 985_000,
		served_cost = 4.93,
		lookups = 1380,
		answered = 1147,
		finds = {hits = 155, misses = 17, hit_cost = 0.2, miss_cost = 0.36, saved = 24.75, enough = true},
	})
	ui.probe_deliver(p, shapes.Inbox_Review{handle = "jm:ui menu steals focus back"}, shapes.Inbox_Review_Result {
		handle   = "jm:ui menu steals focus back",
		similar  = {{file = "AI/MEMORY.md", line = 8, handle = "jm:ui menu steals focus back", fact = LONG, date = "2026-09-01", share = 0.9, same_handle = true}, {file = "AI/LEARNINGS.md", line = 3, handle = "a much longer handle that names the same focus fact in other words", fact = LONG, date = "2026-09-02", share = 0.55}},
		errors   = {"it says nothing: the fact is empty"},
		warnings = {"the fact is 430 characters (cap 400); say one fact, and spill the rest to a note"},
		origin   = {ts = "2026-10-08T10:00:00Z", agent = "claude", session = "s1", title = LONG, turn = "t1"},
	})
	ui.probe_deliver(p, shapes.Recall{terms = "harfbuzz shaping cluster", limit = 10}, shapes.Recall_Result{turns = {{id = "x1", date = "2026-09-25", agent = "claude", title = "Text shaping", snippet = LONG}}})
}

// Variant is a state a page is swept in, beyond its default.
@(private = "file")
Variant :: struct {
	name:  string,
	setup: proc(m: ^Model),
}

@(private = "file")
VARIANTS := [?]Variant {
	{"default", proc(m: ^Model) {}},
	{"rail collapsed", proc(m: ^Model) {m.collapsed = true}},
	{"rail at its widest", proc(m: ^Model) {m.nav_width = NAV_MAX}},
	{"thin aliases chosen", proc(m: ^Model) {m.findings, m.findings_chosen = .Thin_Aliases, true}},
	{"no search", proc(m: ^Model) {ui.text_set(&m.search, "")}},
	{"a bullet's provenance", proc(m: ^Model) {m.bullet_tab = 1}},
	{"every proposal ticked", proc(m: ^Model) {
		for h in ([3]string{"jm:ui menu steals focus back", "init_context threads own their temp allocator", "brain doctor contradictions dropped"}) {
			select(m, h, true)
		}
	}},
}

@(test)
every_page_lays_out_at_every_size :: proc(t: ^testing.T) {
	failures := 0
	for v in VARIANTS {
		for page in Page {
			for w in SWEEP_WIDTHS {
				for h in SWEEP_HEIGHTS {
					m: Model
					p: ui.Probe
					model_init(&m)
					m.page = page
					ui.text_set(&m.search, "hyprctl eval")
					v.setup(&m)
					ui.probe_init(&p, view, &m, {w, h})
					answer(&p, &m)
					ui.probe_frame(&p)
					ui.probe_advance(&p, 3, 0.1)
					problems := check(&p, {w, h})
					for problem in problems {
						testing.expectf(t, false, "%s, %s, at %vx%v: %s", PAGE_TITLES[page], v.name, w, h, problem)
						failures += 1
					}
					ui.probe_destroy(&p)
					model_destroy(&m)
					if failures > 40 {
						return
					}
				}
			}
		}
	}
}

// check is what is wrong with the frame a probe shows in a window of size.
@(private = "file")
check :: proc(p: ^ui.Probe, size: ops.Size) -> (problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	for o in ui.frame_overflow(ui.probe_current(p), size, context.temp_allocator) {
		append(&problems, fmt.tprintf("%s cut off at a side, near %q", o.kind, o.near))
	}
	stat_heights := make([dynamic]f32, context.temp_allocator)
	for name in ui.probe_names(p) {
		b := ui.probe_bounds(p, name)
		switch {
		case strings.has_prefix(name, "pane:"):
			if b.w < PANE_MIN.x || b.h < PANE_MIN.y {
				append(&problems, fmt.tprintf("%s is %.0fx%.0f, under %vx%v", name, b.w, b.h, PANE_MIN.x, PANE_MIN.y))
			}
			if b.x < -1 || b.y < -1 || b.x + b.w > size.x + 1 || b.y + b.h > size.y + 1 {
				append(&problems, fmt.tprintf("%s at %v runs out of the window", name, b))
			}
		case strings.has_prefix(name, "stat:"):
			if b.h < STAT_MIN_HEIGHT {
				append(&problems, fmt.tprintf("%s is squashed to %.0f high", name, b.h))
			}
			append(&stat_heights, b.h)
		}
	}
	// A widget that starts inside a pane ends inside it: the pane's box
	// does not clip, so one too wide overhangs its border, which the
	// toolkit's overflow check, looking for clips, does not see.
	panes := make([dynamic]ops.Rect, context.temp_allocator)
	for name in ui.probe_names(p) {
		if strings.has_prefix(name, "pane:") {
			append(&panes, ui.probe_bounds(p, name))
		}
	}
	for name in ui.probe_names(p) {
		if strings.has_prefix(name, "pane:") || name == "" {
			continue
		}
		b := ui.probe_bounds(p, name)
		for pane in panes {
			inside := b.x >= pane.x && b.x < pane.x + pane.w && b.y >= pane.y && b.y < pane.y + pane.h
			if inside && b.x + b.w > pane.x + pane.w + 1 {
				append(&problems, fmt.tprintf("%q runs %.0f past its pane's right edge", name, b.x + b.w - pane.x - pane.w))
			}
		}
	}
	for sh in stat_heights {
		if abs(sh - stat_heights[0]) > 1 {
			append(&problems, fmt.tprintf("figure cards differ in height: %v", stat_heights[:]))
			break
		}
	}
	return
}
