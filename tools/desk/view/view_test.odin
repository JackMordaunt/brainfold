package desk_view

import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:ui"
import "jm:ui/ops"

import "../shapes"

@(private = "file")
open :: proc(p: ^ui.Probe, m: ^Model, page: Page) {
	model_init(m)
	m.page = page
	ui.probe_init(p, view, m, {1280, 840})
}

@(private = "file")
close :: proc(p: ^ui.Probe, m: ^Model) {
	ui.probe_destroy(p)
	model_destroy(m)
}

// Every page draws with nothing answered and asks for what it shows: a
// page that panics or needs nothing after a hot reload is what this
// catches. The rail's two needs are on every page.
@(test)
every_page_draws_and_asks :: proc(t: ^testing.T) {
	for page in Page {
		m: Model
		p: ui.Probe
		open(&p, &m, page)
		defer close(&p, &m)
		testing.expect(t, ui.probe_needs_q(&p, shapes.Log{}), PAGE_TITLES[page])
		testing.expect(t, ui.probe_needs_q(&p, shapes.Inbox{}), PAGE_TITLES[page])
		dump := ui.probe_dump(&p)
		defer delete(dump)
		testing.expect(t, strings.contains(dump, PAGE_NOTES[page]), PAGE_TITLES[page])
	}
}

@(test)
a_page_needs_only_its_own :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Doctor)
	defer close(&p, &m)
	testing.expect(t, ui.probe_needs_q(&p, shapes.Doctor{}))
	testing.expect(t, !ui.probe_needs_q(&p, shapes.Ledger{}))
	testing.expect(t, !ui.probe_needs_q(&p, shapes.Vault{}))
	m.page = .Vault
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_needs_q(&p, shapes.Vault{}))
	testing.expect(t, !ui.probe_needs_q(&p, shapes.Doctor{}))
}

@(test)
the_rail_counts_what_waits :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Vault)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Inbox{}, shapes.Inbox_Result{proposals = {{n = 1, handle = "a"}, {n = 2, handle = "b"}, {n = 3, handle = "c"}}})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Inbox"), "the rail's item")
	testing.expect_value(t, m.page, Page.Inbox)
	sem := ui.probe_semantics(&p)
	defer delete(sem)
	testing.expect(t, strings.contains(sem, "\"Inbox 3\""), "the count")
	testing.expect(t, strings.contains(sem, "Approve"), "a proposal")
}

// An approve is a command carrying the handle, and the button shows it
// running until its Outcome comes back; then a toast says how it went.
@(test)
a_command_waits_on_its_outcome :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Inbox)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Inbox{}, shapes.Inbox_Result{proposals = {{n = 1, handle = "only", fact = "a fact"}}})
	ui.probe_frame(&p)
	// The last Approve drawn is the detail pane's; the first, the bulk one.
	testing.expect(t, ui.probe_click_top(&p, "Approve"))
	testing.expect_value(t, m.n_pending, 1)
	testing.expect(t, waiting_on(&m, .Approve, "only"))
	testing.expect(t, ui.probe_needs_q(&p, shapes.Outcome{id = m.pending[0].id}), "the outcome is needed")
	ui.probe_deliver(&p, shapes.Outcome{id = m.pending[0].id}, shapes.Outcome_Result{done = true, ok = true, message = "Approved only"})
	ui.probe_frame(&p)
	testing.expect_value(t, m.n_pending, 0)
	dump := ui.probe_dump(&p)
	defer delete(dump)
	testing.expect(t, strings.contains(dump, "Approved only"), "the toast")
}

// While a new search loads, the last answer stays on screen.
@(test)
recall_keeps_the_last_answer_while_the_next_loads :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Recall)
	defer close(&p, &m)
	ui.text_set(&m.search, "eval")
	ui.probe_deliver(&p, shapes.Recall{terms = "eval", limit = RECALL_LIMIT}, shapes.Recall_Result{turns = {{id = "1", agent = "pi", title = "First answer"}}})
	ui.probe_frame(&p)
	ui.text_set(&m.search, "eval hypr")
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_needs_q(&p, shapes.Recall{terms = "eval hypr", limit = RECALL_LIMIT}))
	testing.expect(t, ui.probe_needs_q(&p, shapes.Recall{terms = "eval", limit = RECALL_LIMIT}), "the last answer is kept")
	dump := ui.probe_dump(&p)
	defer delete(dump)
	testing.expect(t, strings.contains(dump, "First answer"))
}

@(test)
figures_read_at_a_glance :: proc(t: ^testing.T) {
	testing.expect_value(t, thousands(14219700), "14,219,700")
	testing.expect_value(t, thousands(611), "611")
	testing.expect_value(t, thousands(-1000), "-1,000")
	testing.expect_value(t, compact(14219700), "14M")
	testing.expect_value(t, compact(1_500_000), "1.5M")
	testing.expect_value(t, compact(378204), "378k")
	testing.expect_value(t, compact(9999), "9,999")
	testing.expect_value(t, percent(452, 611), "74%")
	testing.expect_value(t, percent(1, 0), "–")
}

// Ticked proposals go in one command, and only once the dialog is
// confirmed; cancelled, nothing is sent and the ticks stay.
@(test)
a_bulk_approve_asks_first_and_sends_one_command :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Inbox)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Inbox{}, shapes.Inbox_Result{proposals = {{n = 1, handle = "a"}, {n = 2, handle = "b"}, {n = 3, handle = "c"}}})
	ui.probe_frame(&p)
	select(&m, "a", true)
	select(&m, "c", true)
	ui.probe_frame(&p)

	testing.expect(t, ui.probe_click(&p, "Approve"))
	ui.probe_advance(&p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click(&p, "Cancel"), "the dialog's cancel")
	ui.probe_advance(&p, 20, 1.0 / 60) // its close, played out
	testing.expect_value(t, m.n_pending, 0)
	testing.expect_value(t, len(m.selected), 2)

	testing.expect(t, ui.probe_click(&p, "Approve"))
	ui.probe_advance(&p, 20, 1.0 / 60)
	sent: []string
	ui.probe_frame(&p)
	testing.expect(t, m.confirm, "the dialog is open")
	testing.expect(t, ui.probe_click_top(&p, "Approve"), "the dialog's confirm")
	for c in ui.probe_commands(&p) {
		if cmd, ok := ui.command_as(c, shapes.Command); ok {
			if a, is := cmd.(shapes.Approve); is {
				sent = a.handles
			}
		}
	}
	testing.expect_value(t, len(sent), 2)
	if len(sent) == 2 {
		testing.expect_value(t, sent[0], "a")
		testing.expect_value(t, sent[1], "c")
	}
	testing.expect_value(t, m.n_pending, 1)
	testing.expect_value(t, len(m.selected), 0)
	testing.expect(t, waiting_on(&m, .Approve, "c"))
	testing.expect(t, !waiting_on(&m, .Approve, "b"))
}

// A tick for a proposal no longer in the inbox is let go.
@(test)
ticks_follow_the_inbox :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Inbox)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Inbox{}, shapes.Inbox_Result{proposals = {{n = 1, handle = "a"}, {n = 2, handle = "b"}}})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Select all"))
	testing.expect_value(t, len(m.selected), 2)
	ui.probe_deliver(&p, shapes.Inbox{}, shapes.Inbox_Result{proposals = {{n = 1, handle = "b"}}})
	ui.probe_frame(&p)
	testing.expect_value(t, len(m.selected), 1)
	testing.expect(t, is_selected(&m, "b"))
}

// A fresh report that orders the list differently keeps the item chosen.
@(test)
a_finding_stays_chosen_across_reports :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Doctor)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Doctor{}, shapes.Doctor_Result{thin_aliases = {{file = "AI/MEMORY.md", handle = "one"}, {file = "AI/MEMORY.md", handle = "two", aliases = "deux"}}})
	ui.probe_frame(&p)
	testing.expect_value(t, m.findings, Finding_List.Thin_Aliases) // the first list with something in it
	testing.expect(t, ui.probe_click(&p, "two"))
	ui.probe_deliver(&p, shapes.Doctor{}, shapes.Doctor_Result{thin_aliases = {{file = "AI/MEMORY.md", handle = "two", aliases = "deux"}, {file = "AI/MEMORY.md", handle = "zero"}, {file = "AI/MEMORY.md", handle = "one"}}})
	ui.probe_frame(&p)
	sem := ui.probe_semantics(&p)
	defer delete(sem)
	testing.expect(t, strings.contains(sem, `"deux (press backspace`), "still two, its alias as a token")
}

// A thin bullet's names can be taken away and added to, each a command
// naming the bullet.
@(test)
aliases_are_edited_in_place :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Doctor)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Doctor{}, shapes.Doctor_Result{thin_aliases = {{file = "AI/MEMORY.md", handle = "ghostty", aliases = "mouse-scroll-multiplier"}}})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Remove mouse-scroll-multiplier"), "the token's remove")
	sent := ""
	for c in ui.probe_commands(&p) {
		if cmd, ok := ui.command_as(c, shapes.Command); ok {
			if r, is := cmd.(shapes.Remove_Alias); is {
				sent = fmt.tprintf("%s/%s", r.handle, r.term)
			}
		}
	}
	testing.expect_value(t, sent, "ghostty/mouse-scroll-multiplier")
	settle_all(&p, &m)

	ui.text_set(&m.alias, "terminal emulator")
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Add"))
	sent = ""
	for c in ui.probe_commands(&p) {
		if cmd, ok := ui.command_as(c, shapes.Command); ok {
			if a, is := cmd.(shapes.Add_Alias); is {
				sent = fmt.tprintf("%s/%s", a.handle, a.term)
			}
		}
	}
	testing.expect_value(t, sent, "ghostty/terminal emulator")
	testing.expect_value(t, ui.text_string(&m.alias), "")

	// A name that would break the bullet is not sent.
	settle_all(&p, &m)
	ui.text_set(&m.alias, "a, b")
	ui.probe_frame(&p)
	ui.probe_click(&p, "Add")
	testing.expect_value(t, m.n_pending, 0)
}

// settle_all answers every command in flight as done.
@(private = "file")
settle_all :: proc(p: ^ui.Probe, m: ^Model) {
	for i in 0 ..< m.n_pending {
		ui.probe_deliver(p, shapes.Outcome{id = m.pending[i].id}, shapes.Outcome_Result{done = true, ok = true})
	}
	ui.probe_frame(p)
	ui.probe_frame(p)
}

// Hovering a list of findings says what it means.
@(test)
a_findings_list_explains_itself_on_hover :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Doctor)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Doctor{}, shapes.Doctor_Result{thin_aliases = {{file = "AI/MEMORY.md", handle = "one"}}})
	ui.probe_frame(&p)
	c, ok := ui.probe_center(&p, "Stale")
	testing.expect(t, ok)
	ui.probe_move(&p, c.x, c.y)
	// Not at once: a pointer only passing over raises nothing.
	ui.probe_advance(&p, 4, 0.05)
	testing.expect(t, !ui.probe_tagged(&p, FINDING_HELP[.Stale]), "no tooltip at 200ms")
	ui.probe_advance(&p, 10, 0.05)
	testing.expect(t, ui.probe_tagged(&p, FINDING_HELP[.Stale]), "the tooltip")
}

// The rail's edge drags to resize it, within its bounds, and a button
// collapses it to icons and back.
@(test)
the_rail_resizes_and_collapses :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Vault)
	defer close(&p, &m)
	testing.expect(t, ui.probe_drag(&p, "Resize the sidebar", 40, 0), "the edge")
	testing.expect_value(t, nav_width(&m), NAV_WIDTH + 40)
	ui.probe_drag(&p, "Resize the sidebar", 500, 0)
	testing.expect_value(t, nav_width(&m), f32(NAV_MAX))
	testing.expect(t, ui.probe_click(&p, "Collapse the sidebar"))
	ui.probe_frame(&p)
	testing.expect_value(t, nav_width(&m), f32(RAIL))
	testing.expect(t, ui.probe_click(&p, "Inbox"), "a page by its icon")
	testing.expect_value(t, m.page, Page.Inbox)
	testing.expect(t, ui.probe_click(&p, "Expand the sidebar"))
	ui.probe_frame(&p)
	testing.expect_value(t, nav_width(&m), f32(NAV_MAX))
}

// A narrow window shows the rail collapsed, and offers no expanding it.
@(test)
a_narrow_window_collapses_the_rail :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	model_init(&m)
	m.page = .Doctor
	ui.probe_init(&p, view, &m, MIN_WINDOW)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Doctor{}, shapes.Doctor_Result{thin_aliases = {{file = "AI/MEMORY.md", handle = "one"}}})
	ui.probe_frame(&p)
	testing.expect_value(t, nav_width(&m), f32(RAIL))
	testing.expect(t, !ui.probe_tagged(&p, "Expand the sidebar"))
	// Doctor's lists fold into a menu named Findings: no pane of buttons.
	testing.expect(t, !ui.probe_tagged(&p, "Stale"), "no list buttons")
	testing.expect(t, ui.probe_tagged(&p, "Findings"), "the menu")
}

// Panes stay side by side at every size: a narrow window narrows them,
// it never stacks them.
@(test)
panes_stay_side_by_side :: proc(t: ^testing.T) {
	for wide in ([2]bool{false, true}) {
		m: Model
		p: ui.Probe
		model_init(&m)
		m.page = .Inbox
		ui.probe_init(&p, view, &m, wide ? ops.Size{1280, 800} : MIN_WINDOW)
		defer close(&p, &m)
		ui.probe_deliver(&p, shapes.Inbox{}, shapes.Inbox_Result{proposals = {{n = 1, handle = "only", fact = "the fact"}}})
		ui.probe_frame(&p)
		list := ui.probe_bounds(&p, "pane:Proposals")
		detail := ui.probe_bounds(&p, "pane:Proposal")
		testing.expect(t, detail.x >= list.x + list.w, "the detail beside the list")
		testing.expect_value(t, detail.y, list.y)
		testing.expect(t, list.w >= PANE_MIN.x && list.w <= LIST_MAX, "the list within its range")
	}
}

// A page's controls in the header are as tall as the header's own.
@(test)
header_controls_share_a_height :: proc(t: ^testing.T) {
	for page in ([2]Page{.Doctor, .Vault}) {
		m: Model
		p: ui.Probe
		open(&p, &m, page)
		defer close(&p, &m)
		ui.probe_deliver(&p, shapes.Doctor{}, shapes.Doctor_Result{ran_at = "10:00:00"})
		ui.probe_frame(&p)
		sync := ui.probe_bounds(&p, "Sync now")
		control := ui.probe_bounds(&p, page == .Doctor ? "Run doctor" : "Rebuild index")
		testing.expect(t, sync.h > 0 && control.h > 0, PAGE_TITLES[page])
		testing.expect_value(t, control.h, sync.h)
		testing.expect_value(t, control.y, sync.y)
	}
}

@(private = "file")
BULLETS :: shapes.Bullets_Result {
	bullets = {
		{file = "AI/MEMORY.md", line = 8, handle = "fixture tool", aliases = "fixture, sample", fact = "a stand-in fact", source = "fixture", date = "2026-01-01"},
		{file = "AI/LEARNINGS.md", line = 3, handle = "tidal lock", aliases = "synchronous rotation", fact = "one face points at earth", source = "astronomy", date = "2026-01-02"},
	},
	files = {"AI/MEMORY.md", "AI/LEARNINGS.md", "AI/TUNINGS.md"},
}

// sent is the last command of type T the frame sent.
@(private = "file")
sent :: proc(p: ^ui.Probe, $T: typeid) -> (v: T, ok: bool) {
	for c in ui.probe_commands(p) {
		if cmd, is := ui.command_as(c, shapes.Command); is {
			if x, match := cmd.(T); match {
				v, ok = x, true
			}
		}
	}
	return
}

@(test)
a_bullet_edited_is_checked_then_saved_in_its_place :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Bullets)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Bullets{}, BULLETS)
	ui.probe_frame(&p)
	testing.expect_value(t, chosen(&m.bullet), "fixture tool")
	testing.expect_value(t, ui.text_string(&m.editor.fact), "a stand-in fact")
	ui.text_set(&m.editor.fact, "a stand-in fact, corrected")
	ui.probe_frame(&p)
	line := "- **fixture tool** (aliases: fixture, sample) — a stand-in fact, corrected — fixture — 2026-01-01"
	testing.expect(t, ui.probe_needs_q(&p, shapes.Bullet_Check{line = line}), "lint is asked")
	ui.probe_deliver(&p, shapes.Bullet_Check{line = line}, shapes.Bullet_Check_Result{status = "checked", warnings = {"a warning"}})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Save"))
	r, ok := sent(&p, shapes.Replace_Bullet)
	testing.expect(t, ok, "a replace")
	testing.expect_value(t, r.handle, "fixture tool")
	testing.expect_value(t, r.line, line)
}

@(test)
a_new_bullet_is_written_and_then_chosen :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Bullets)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Bullets{}, BULLETS)
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "New bullet"))
	testing.expect(t, m.editor.drafting)
	// Empty, it cannot be written.
	ui.probe_click(&p, "Write bullet")
	_, early := sent(&p, shapes.Write_Bullet)
	testing.expect(t, !early, "nothing written while empty")
	ui.text_set(&m.editor.handle, "orbital period")
	ui.text_set(&m.editor.fact, "the moon goes round in 27 days")
	ui.text_set(&m.editor.date, "2026-01-03")
	ui.probe_frame(&p)
	line := "- **orbital period** — the moon goes round in 27 days — 2026-01-03"
	ui.probe_deliver(&p, shapes.Bullet_Check{line = line}, shapes.Bullet_Check_Result{status = "checked"})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Write bullet"))
	w, ok := sent(&p, shapes.Write_Bullet)
	testing.expect(t, ok)
	testing.expect_value(t, w.line, line)
	testing.expect_value(t, w.to, "MEMORY")
	ui.probe_deliver(&p, shapes.Outcome{id = m.pending[0].id}, shapes.Outcome_Result{done = true, ok = true, message = "Written"})
	ui.probe_frame(&p)
	// Chosen once the list holds it.
	list := BULLETS
	more := make([]shapes.Bullet, 3, context.temp_allocator)
	copy(more, list.bullets)
	more[2] = {file = "AI/MEMORY.md", line = 9, handle = "orbital period", fact = "the moon goes round in 27 days", date = "2026-01-03"}
	list.bullets = more
	ui.probe_deliver(&p, shapes.Bullets{}, list)
	ui.probe_frame(&p)
	testing.expect(t, !m.editor.drafting)
	testing.expect_value(t, chosen(&m.bullet), "orbital period")
}

@(test)
a_miss_becomes_a_draft_with_its_evidence :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Misses)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Log{}, shapes.Log_Result{backlog = {{query = "harfbuzz", misses = 2, last = "2026-10-08 10:00:00"}}})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Write a bullet"))
	ui.probe_deliver(&p, shapes.Bullets{}, BULLETS)
	ui.probe_frame(&p)
	testing.expect_value(t, m.page, Page.Bullets)
	testing.expect(t, m.editor.drafting)
	testing.expect_value(t, ui.text_string(&m.editor.handle), "harfbuzz")
	testing.expect(t, ui.probe_needs_q(&p, shapes.Recall{terms = "harfbuzz", limit = 5}), "what was said about it")
}

@(test)
a_bullet_is_dropped_after_asking :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Bullets)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Bullets{}, BULLETS)
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Drop"))
	ui.probe_advance(&p, 20, 1.0 / 60)
	testing.expect(t, m.editor.dropping, "the dialog")
	testing.expect(t, ui.probe_click_top(&p, "Drop"), "its confirm")
	d, ok := sent(&p, shapes.Drop_Bullet)
	testing.expect(t, ok)
	testing.expect_value(t, d.handle, "fixture tool")
}

@(test)
activity_charts_the_trend :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Activity)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Log{}, shapes.Log_Result{})
	ui.probe_deliver(&p, shapes.Ledger{}, shapes.Ledger_Result {
		callers = {{caller = "claude", lookups = 40, answered = 30}},
		days = {{day = "2026-10-08", lookups = 30, answered = 25, tokens_saved = 900}, {day = "2026-10-07", lookups = 10, answered = 5, tokens_saved = 100}},
		top_bullets = {{handle = "sonar", file = "AI/MEMORY.md", served = 12, sessions = 9}},
	})
	ui.probe_frame(&p)
	ui.probe_advance(&p, 2, 0.1)
	sem := ui.probe_semantics(&p)
	defer delete(sem)
	testing.expect(t, strings.contains(sem, "Lookups a day, answered and missed"), "the bars")
	testing.expect(t, strings.contains(sem, "Tokens saved, so far"), "the area")
	testing.expect(t, ui.probe_click(&p, "sonar"), "a bullet served most")
	testing.expect_value(t, m.page, Page.Bullets)
	testing.expect_value(t, chosen(&m.bullet), "sonar")
}

// Changing the vault asks install what it would do, shows that, and
// binds the new folder only when asked to.
@(test)
the_vault_moves_after_its_plan_is_shown :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Vault)
	defer close(&p, &m)
	ui.probe_deliver(&p, shapes.Vault{}, shapes.Vault_Result{vault = "/home/me/brain"})
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_click(&p, "Change vault…"))
	ui.probe_advance(&p, 10, 1.0 / 60)
	testing.expect(t, m.moving)
	testing.expect_value(t, ui.text_string(&m.vault_path), "/home/me/brain")
	ui.text_set(&m.vault_path, "/home/me/other")
	ui.probe_frame(&p)
	testing.expect(t, ui.probe_needs_q(&p, shapes.Install_Plan{path = "/home/me/other"}), "the plan is asked")
	ui.probe_deliver(&p, shapes.Install_Plan{path = "/home/me/other"}, shapes.Install_Plan_Result{ok = true, plan = "vault: /home/me/other\n  warning: /home/me/other has no AI/ — is that the vault?\n  [dry] vault path recorded"})
	ui.probe_advance(&p, 3, 1.0 / 60)
	sem := ui.probe_semantics(&p)
	defer delete(sem)
	testing.expect(t, strings.contains(sem, "has no AI/"), "the warning")
	testing.expect(t, ui.probe_click_top(&p, "Use this vault"))
	v, ok := sent(&p, shapes.Set_Vault)
	testing.expect(t, ok)
	testing.expect_value(t, v.path, "/home/me/other")
	testing.expect(t, !m.moving)
}

// Only the bullets in view are laid out, however many there are: laying
// out 300 every frame cost 95 ms a frame.
@(test)
only_the_bullets_in_view_are_laid_out :: proc(t: ^testing.T) {
	m: Model
	p: ui.Probe
	open(&p, &m, .Bullets)
	defer close(&p, &m)
	many := make([]shapes.Bullet, 300, context.temp_allocator)
	for &b, i in many {
		b = {file = "AI/MEMORY.md", line = i + 1, handle = fmt.tprintf("bullet %03d", i), fact = "a fact long enough to wrap, were it wrapped, across several lines of a narrow pane", date = "2026-01-01"}
	}
	ui.probe_deliver(&p, shapes.Bullets{}, shapes.Bullets_Result{bullets = many, files = {"AI/MEMORY.md"}})
	ui.probe_frame(&p)
	rows := 0
	for name in ui.probe_names(&p) {
		if strings.has_prefix(name, "bullet ") {
			rows += 1
		}
	}
	testing.expect(t, rows > 0 && rows < 30, fmt.tprintf("%d rows laid out", rows))
}
