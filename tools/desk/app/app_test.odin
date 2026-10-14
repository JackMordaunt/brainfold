package desk_app

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import "jm:ui"

import "../cli"
import "../view"

// The desk less the window: the view in a probe, which hands its needs
// and commands to the host and drains its inbox each frame, as the frame
// loop does. The pipeline and the workers are real; the CLI is a table.

@(private = "file")
Fake :: struct {
	mutex:   sync.Mutex,
	answers: map[string]string,
	calls:   [dynamic]string,
}

@(private = "file")
fake_exec :: proc(user: rawptr, exe: string, args: []string, allocator := context.allocator) -> (stdout: string, ok: bool, stderr: string) {
	f := (^Fake)(user)
	sync.mutex_guard(&f.mutex)
	key := strings.join(args, " ", f.calls.allocator)
	append(&f.calls, key)
	if out, found := f.answers[key]; found {
		return strings.clone(out, allocator), true, ""
	}
	return "", false, strings.clone("no such command", allocator)
}

// times_asked is how many times the CLI was called with exactly key.
@(private = "file")
times_asked :: proc(f: ^Fake, key: string) -> (n: int) {
	sync.mutex_guard(&f.mutex)
	for c in f.calls {
		if c == key {
			n += 1
		}
	}
	return
}

@(private = "file")
answer :: proc(f: ^Fake, key, json: string) {
	sync.mutex_guard(&f.mutex)
	f.answers[key] = json
}

@(private = "file")
Rig :: struct {
	h:    Host,
	f:    Fake,
	m:    view.Model,
	p:    ui.Probe,
	data: ui.Data_Host,
}

@(private = "file")
rig_open :: proc(r: ^Rig, poll := POLL) {
	r.f.answers = make(map[string]string)
	r.f.calls = make([dynamic]string)
	answer(&r.f, "log --json", `{"backlog":[{"query":"BSA","misses":3,"last":"2026-10-07 21:59:08"}],"answered":[],"recent":[{"ts":"2026-10-07 21:59:08","query":"prime status","hits":9,"caller":"claude"}],"callers":[{"caller":"claude","queries":10,"sessions":4,"misses":1,"bytes":2048}]}`)
	answer(&r.f, "ledger --json", `{"baseline_tokens":32296,"callers":[{"caller":"claude","sessions":4,"lookups":10,"answered":9,"tokens_returned":6200,"tokens_saved":300000}],"days":[{"day":"2026-10-07","lookups":10,"answered":9,"tokens_returned":6200,"tokens_saved":300000}]}`)
	answer(&r.f, "inbox --json", `{"proposals":[{"n":1,"handle":"tend date verified bullets","fact":"33 bullets verify","source":"tend date","date":"2026-10-02"},{"n":2,"handle":"jm:ui layout stance","fact":"kits clone the look","source":"session","date":"2026-10-03"}]}`)
	answer(&r.f, "inbox approve 1", "approved")
	answer(&r.f, "recall --json --limit 30 hyprctl", `[{"id":"85801a30","date":"2026-09-22","agent":"pi","title":"Dedicated workspace per project","snippet":"use eval"}]`)
	answer(&r.f, "recall --json --around 85801a30", `{"id":"85801a30","session":"s1","title":"Dedicated workspace per project","turns":[{"id":"a0","ts":"2026-09-22T13:02:00Z","role":"user","body":"make each project its own workspace","hit":false},{"id":"85801a30","ts":"2026-09-22T13:05:00Z","role":"assistant","body":"use eval","hit":true}]}`)
	init(&r.h, {exec = fake_exec, user = &r.f}, poll = poll)
	r.data = data_host(&r.h)
	view.model_init(&r.m)
	ui.probe_init(&r.p, view.view, &r.m, {1280, 840}, data = &r.data)
}

@(private = "file")
rig_close :: proc(r: ^Rig) {
	ui.probe_destroy(&r.p)
	stop(&r.h)
	view.model_destroy(&r.m)
	delete(r.f.answers)
	for c in r.f.calls {
		delete(c)
	}
	delete(r.f.calls)
}

// settle frames until the host is idle and a frame asks nothing new.
@(private = "file")
settle :: proc(r: ^Rig, limit := 10 * time.Second) -> bool {
	deadline := time.tick_now()._nsec + i64(limit)
	for time.tick_now()._nsec < deadline {
		ui.probe_frame(&r.p)
		if idle(&r.h) {
			ui.probe_frame(&r.p)
			if idle(&r.h) {
				ui.probe_advance(&r.p, 1, 0.2) // past a wait's delay, so the page is drawn as it stands
				return true
			}
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

@(private = "file")
shows :: proc(r: ^Rig, text: string) -> bool {
	dump := ui.probe_dump(&r.p)
	defer delete(dump)
	return strings.contains(dump, text)
}

@(test)
the_rail_counts_and_the_page_come_from_the_cli :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	testing.expect(t, settle(&r), "the host went idle")
	testing.expect(t, shows(&r, "Lookups"), "the activity page")
	testing.expect(t, shows(&r, "prime status"), "the recent lookup")
	testing.expect(t, shows(&r, "90%"), "answered of lookups")
	// The rail needs the log and the inbox on every page.
	testing.expect_value(t, times_asked(&r.f, "log --json"), 1)
	testing.expect_value(t, times_asked(&r.f, "inbox --json"), 1)
	testing.expect_value(t, times_asked(&r.f, "doctor --json"), 0)
}

@(test)
a_page_left_is_not_read_again :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r, poll = 50 * time.Millisecond)
	defer rig_close(&r)
	testing.expect(t, settle(&r))
	r.m.page = .Inbox
	testing.expect(t, settle(&r))
	before := times_asked(&r.f, "ledger --json")
	time.sleep(300 * time.Millisecond)
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "ledger --json"), before)
	// What is still live is read on every poll.
	testing.expect(t, times_asked(&r.f, "inbox --json") > 2, "the inbox is polled")
}

@(test)
a_poll_with_nothing_new_delivers_nothing :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r, poll = 30 * time.Millisecond)
	defer rig_close(&r)
	testing.expect(t, settle(&r))
	n := len(r.p.layout.shapes)
	time.sleep(200 * time.Millisecond)
	testing.expect_value(t, ui.inbox_pending(&r.h.inbox), false)
	testing.expect_value(t, len(r.p.layout.shapes), n)

	// The vault moves: the next poll brings it.
	answer(&r.f, "inbox --json", `{"proposals":[]}`)
	time.sleep(200 * time.Millisecond)
	r.m.page = .Inbox
	testing.expect(t, settle(&r))
	testing.expect(t, shows(&r, "Nothing waiting"), "the empty inbox")
}

@(test)
approving_runs_the_cli_and_says_so :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	r.m.page = .Inbox
	testing.expect(t, settle(&r))
	testing.expect(t, shows(&r, "jm:ui layout stance"))
	reads := times_asked(&r.f, "inbox --json")
	// The detail pane's Approve, drawn after the bulk one: the first
	// proposal's, which is the one shown.
	testing.expect(t, ui.probe_click_top(&r.p, "Approve"), "the button")
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "inbox approve 1"), 1)
	testing.expect_value(t, r.m.n_pending, 0)
	testing.expect(t, shows(&r, "Approved tend date verified bullets"), "a toast")
	// One read to find its place, one after it is done.
	testing.expect_value(t, times_asked(&r.f, "inbox --json"), reads + 2)
}

@(test)
a_search_typed_runs_once :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	r.m.page = .Recall
	testing.expect(t, settle(&r))
	for c in "hyprctl" {
		ui.text_set(&r.m.search, strings.concatenate({ui.text_string(&r.m.search), string([]u8{u8(c)})}, context.temp_allocator))
		ui.probe_frame(&r.p)
	}
	testing.expect(t, settle(&r))
	testing.expect(t, shows(&r, "Dedicated workspace per project"), "the turn")
	testing.expect(t, shows(&r, "make each project its own workspace"), "the conversation around it")
	calls := 0
	sync.mutex_guard(&r.f.mutex)
	for c in r.f.calls {
		if strings.has_prefix(c, "recall --json --limit") {
			calls += 1
		}
	}
	testing.expect_value(t, calls, 1)
	// The first turn is chosen, and the conversation around it read.
	around := 0
	for c in r.f.calls {
		if c == "recall --json --around 85801a30" {
			around += 1
		}
	}
	testing.expect_value(t, around, 1)
}

@(test)
a_failed_call_is_a_banner_not_a_blank :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	r.m.page = .Doctor // no doctor answer in the table
	testing.expect(t, settle(&r))
	testing.expect(t, shows(&r, "The vault did not answer"))
	testing.expect(t, shows(&r, "no such command"))
}

// A test of the shape's ownership more than the ui: an answer that lands
// for a need the ui dropped is not delivered.
@(test)
an_answer_for_a_dropped_need_is_dropped :: proc(t: ^testing.T) {
	h: Host
	f: Fake
	f.answers = make(map[string]string)
	f.calls = make([dynamic]string)
	defer {
		delete(f.answers)
		for c in f.calls {
			delete(c)
		}
		delete(f.calls)
	}
	answer(&f, "doctor --json", `{"queries_logged":1}`)
	init(&h, cli.Client{exec = fake_exec, user = &f})
	defer stop(&h)
	need := ui.Need{key = 42, kind = "desk_shapes.Doctor"}
	on_need(&h, need, true)
	on_need(&h, need, false)
	deadline := time.tick_now()._nsec + i64(5 * time.Second)
	for !idle(&h) && time.tick_now()._nsec < deadline {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, idle(&h))
	// The need was read: the CLI answered it, and the answer was dropped.
	testing.expect_value(t, times_asked(&f, "doctor --json"), 1)
	testing.expect_value(t, ui.inbox_pending(&h.inbox), false)
}

// A hot-reloaded child asks for what the one before it had: the host was
// never told the first had gone, and the answer is the same, but the new
// child has nothing, so it is answered again.
@(test)
a_need_asked_again_is_answered_again :: proc(t: ^testing.T) {
	h: Host
	f: Fake
	f.answers = make(map[string]string)
	f.calls = make([dynamic]string)
	defer {
		delete(f.answers)
		for c in f.calls {
			delete(c)
		}
		delete(f.calls)
	}
	answer(&f, "doctor --json", `{"queries_logged":1}`)
	init(&h, cli.Client{exec = fake_exec, user = &f})
	defer stop(&h)
	need := ui.Need{key = 42, kind = "desk_shapes.Doctor"}
	wait :: proc(h: ^Host) -> bool {
		deadline := time.tick_now()._nsec + i64(5 * time.Second)
		for time.tick_now()._nsec < deadline {
			sync.mutex_lock(&h.mutex)
			n := h.pending
			sync.mutex_unlock(&h.mutex)
			if n == 0 {
				return true
			}
			time.sleep(5 * time.Millisecond)
		}
		return false
	}
	on_need(&h, need, true)
	testing.expect(t, wait(&h))
	testing.expect(t, ui.inbox_pending(&h.inbox), "the first answer")
	_ = ui.inbox_take(&h.inbox, context.temp_allocator)
	on_need(&h, need, true)
	testing.expect(t, wait(&h))
	testing.expect(t, ui.inbox_pending(&h.inbox), "the same answer, again")
	_ = ui.inbox_take(&h.inbox, context.temp_allocator)
}

@(test)
a_bulk_drop_runs_each_and_says_so_once :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	answer(&r.f, "inbox drop 1", "dropped")
	answer(&r.f, "inbox drop 2", "dropped")
	r.m.page = .Inbox
	testing.expect(t, settle(&r))
	testing.expect(t, ui.probe_click(&r.p, "Select all"))
	testing.expect(t, ui.probe_click(&r.p, "Drop"))
	ui.probe_advance(&r.p, 20, 1.0 / 60)
	testing.expect(t, ui.probe_click_top(&r.p, "Drop"), "the dialog's confirm")
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "inbox drop 1"), 1)
	testing.expect_value(t, times_asked(&r.f, "inbox drop 2"), 1)
	testing.expect(t, shows(&r, "Dropped 2 proposals"), "one toast")
}

@(test)
a_doctor_run_says_what_changed :: proc(t: ^testing.T) {
	testing.expect_value(t, summarise(Findings{}, false, #partial Findings{.Stale = 2, .Dead_Link = 1}, context.temp_allocator), "Doctor found 3 findings")
	testing.expect_value(t, summarise(#partial Findings{.Stale = 2}, true, #partial Findings{.Stale = 2}, context.temp_allocator), "No change since the last run: 2 findings")
	testing.expect_value(
		t,
		summarise(#partial Findings{.Failed_Claim = 1, .Thin_Aliases = 4}, true, #partial Findings{.Failed_Claim = 2, .Thin_Aliases = 1}, context.temp_allocator),
		"Since the last run: 1 new failed claim, 3 fewer bullets with thin aliases",
	)
}

// Doctor is read when its page opens and again only when asked; the run
// replaces the report and says what moved.
@(test)
doctor_runs_when_asked_not_on_the_poll :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r, poll = 30 * time.Millisecond)
	defer rig_close(&r)
	answer(&r.f, "doctor --json", `{"queries_logged":5,"thin_aliases":[{"file":"AI/MEMORY.md","handle":"a"},{"file":"AI/MEMORY.md","handle":"b"}]}`)
	r.m.page = .Doctor
	testing.expect(t, settle(&r))
	time.sleep(200 * time.Millisecond)
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "doctor --json"), 1)
	testing.expect(t, shows(&r, "Report from"))

	answer(&r.f, "doctor --json", `{"queries_logged":6,"thin_aliases":[{"file":"AI/MEMORY.md","handle":"a"}]}`)
	testing.expect(t, ui.probe_click(&r.p, "Check"))
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "doctor --json"), 2)
	testing.expect(t, shows(&r, "Since the last run: 1 fewer bullet with thin aliases"), "the summary")
	testing.expect(t, shows(&r, "6"), "the new report")
}

// An alias added runs brain alias, then doctor again, so the thin list
// no longer holds the bullet.
@(test)
an_alias_added_reruns_doctor :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	answer(&r.f, "doctor --json", `{"queries_logged":5,"thin_aliases":[{"file":"AI/MEMORY.md","handle":"ghostty","aliases":"mouse-scroll-multiplier"}]}`)
	answer(&r.f, "alias add ghostty terminal emulator", "ghostty: 1 changed")
	r.m.page = .Doctor
	testing.expect(t, settle(&r))
	answer(&r.f, "doctor --json", `{"queries_logged":5,"thin_aliases":[]}`)
	ui.text_set(&r.m.alias, "terminal emulator")
	ui.probe_frame(&r.p)
	testing.expect(t, ui.probe_click(&r.p, "Add"))
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "alias add ghostty terminal emulator"), 1)
	testing.expect_value(t, times_asked(&r.f, "doctor --json"), 2)
	testing.expect(t, shows(&r, "No thin aliases"), "the list, from the fresh report")
}

// A bullet written in the desk runs brain bullet write, and the list is
// read again so it shows.
@(test)
a_bullet_written_runs_the_cli :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	answer(&r.f, "bullet list --json", `{"bullets":[{"file":"AI/MEMORY.md","line":8,"handle":"fixture tool","fact":"a stand-in fact","date":"2026-01-01"}],"files":["AI/MEMORY.md","AI/LEARNINGS.md","AI/TUNINGS.md"]}`)
	line := "- **orbital period** — the moon goes round in 27 days — 2026-01-03"
	answer(&r.f, strings.concatenate({"--json bullet check ", line}, context.temp_allocator), `{"status":"checked","errors":[],"warnings":[]}`)
	answer(&r.f, strings.concatenate({"--json bullet write ", line, " --to MEMORY"}, context.temp_allocator), `{"status":"written","handle":"orbital period","file":"AI/MEMORY.md","line":9,"errors":[],"warnings":[]}`)
	r.m.page = .Bullets
	testing.expect(t, settle(&r))
	testing.expect(t, ui.probe_click(&r.p, "New"))
	ui.text_set(&r.m.editor.handle, "orbital period")
	ui.text_set(&r.m.editor.fact, "the moon goes round in 27 days")
	ui.text_set(&r.m.editor.date, "2026-01-03")
	testing.expect(t, settle(&r))
	testing.expect(t, ui.probe_click(&r.p, "Write"))
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, strings.concatenate({"--json bullet write ", line, " --to MEMORY"}, context.temp_allocator)), 1)
	testing.expect(t, shows(&r, "Written orbital period at AI/MEMORY.md:9"), "the toast")
	testing.expect(t, times_asked(&r.f, "bullet list --json") >= 2, "the list read again")
	testing.expect_value(t, times_asked(&r.f, "doctor --json"), 0) // no report shown, none made
}

// A stale bullet's "Confirm" runs brain bullet touch, then doctor
// again, so the bullet leaves the stale list.
@(test)
a_stale_bullet_touched_reruns_doctor :: proc(t: ^testing.T) {
	r: Rig
	rig_open(&r)
	defer rig_close(&r)
	answer(&r.f, "doctor --json", `{"queries_logged":5,"stale":[{"file":"AI/MEMORY.md","handle":"old fact","date":"2025-01-01"}]}`)
	answer(&r.f, "--json bullet touch old fact", `{"status":"touched","handle":"old fact","file":"AI/MEMORY.md","line":3,"errors":[],"warnings":[]}`)
	r.m.page = .Doctor
	testing.expect(t, settle(&r))
	answer(&r.f, "doctor --json", `{"queries_logged":5,"stale":[]}`)
	testing.expect(t, ui.probe_click(&r.p, "Confirm"))
	testing.expect(t, settle(&r))
	testing.expect_value(t, times_asked(&r.f, "--json bullet touch old fact"), 1)
	testing.expect_value(t, times_asked(&r.f, "doctor --json"), 2)
	testing.expect(t, shows(&r, "Dated today: old fact at AI/MEMORY.md:3"), "the toast")
	testing.expect(t, shows(&r, "No stale"), "the list, from the fresh report")
}
