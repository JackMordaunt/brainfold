package brain

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "jm:path"

@(test)
bullet_write_adds_a_bullet_that_find_then_answers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	line := "- **tidal lock** (aliases: synchronous rotation) — one face of the moon always points at earth — astronomy — 2026-01-05"
	o, e, code := exec(f.cli, "bullet", "write", line, "--to", "LEARNINGS")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "written **tidal lock** at AI/LEARNINGS.md:"), e)
	text, _ := read_text(path.join(f.vault, "AI", "LEARNINGS.md"))
	testing.expect(t, strings.contains(text, line), text)
	o, _, _ = exec(f.cli, "find", "synchronous rotation")
	testing.expect(t, strings.contains(o, "tidal lock"), o)

	// The handle is taken now.
	_, e, code = exec(f.cli, "bullet", "write", "- **tidal lock** — another fact — x — 2026-01-05")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "is taken"), e)
}

@(test)
bullet_check_refuses_what_lint_would :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "--json", "bullet", "check", "- **future** (aliases: x) — a fact — src — 2999-01-01")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "future"), o)
	o, _, code = exec(f.cli, "--json", "bullet", "check", "- **no date** — a fact")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "date"), o)
	o, _, code = exec(f.cli, "--json", "bullet", "check", "- **plain** — a fact with no names — src — 2026-01-05")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "no aliases"), "a warning, not an error")
}

@(test)
bullet_replace_and_drop_edit_in_place :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	memory := path.join(f.vault, "AI", "MEMORY.md")
	before, _ := read_text(memory)
	lines := len(strings.split_lines(before))
	o, e, code := exec(f.cli, "bullet", "replace", "fixture tool", "- **fixture rig** (aliases: fixture, sample) — a stand-in fact, renamed — fixture — 2026-01-02")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "replaced **fixture rig**"), e)
	after, _ := read_text(memory)
	testing.expect(t, strings.contains(after, "**fixture rig**") && !strings.contains(after, "**fixture tool**"), after)
	testing.expect_value(t, len(strings.split_lines(after)), lines)

	o, e, code = exec(f.cli, "bullet", "drop", "fixture rig")
	testing.expect_value(t, code, 0)
	gone, _ := read_text(memory)
	testing.expect(t, !strings.contains(gone, "fixture rig"), gone)
	testing.expect_value(t, len(strings.split_lines(gone)), lines - 1)
	kept, _ := read_text(path.join(f.vault, "AI", "DROPPED.md"))
	testing.expect(t, strings.contains(kept, "**fixture rig**"), "on record")
	_, e, code = exec(f.cli, "bullet", "drop", "fixture rig")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "no bullet"), e)
}

@(test)
bullet_list_is_every_bullet_with_its_place :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "--json", "bullet", "list")
	testing.expect_value(t, code, 0)
	List :: struct {
		bullets: []struct {
			file, handle, fact, date: string,
			line:                     int,
		},
		files:   []string,
	}
	l: List
	testing.expect_value(t, json.unmarshal_string(o, &l), nil)
	testing.expect(t, len(l.bullets) > 0)
	found := false
	for b in l.bullets {
		if b.handle == "fixture tool" {
			found = true
			testing.expect_value(t, b.file, "AI/MEMORY.md")
			testing.expect_value(t, b.line, 8) // its line in testdata/vault/AI/MEMORY.md
			testing.expect_value(t, b.fact, "a stand-in fact used only by the test suite")
			testing.expect_value(t, b.date, "2026-01-01")
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, len(l.files), 3)
	if len(l.files) == 3 {
		testing.expect_value(t, l.files[0], "AI/MEMORY.md")
	}
}

@(test)
bullet_touch_dates_a_bullet_today :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, e, code := exec(f.cli, "bullet", "touch", "fixture tool")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "touched **fixture tool** at AI/MEMORY.md:8"), e)
	text, _ := read_text(path.join(f.vault, "AI", "MEMORY.md"))
	want := strings.concatenate({"- **fixture tool** (aliases: fixture, sample, test vault) — a stand-in fact used only by the test suite — fixture — ", today_iso()})
	testing.expect(t, strings.contains(text, want), text)
}

@(test)
bullet_at_names_one_of_two_sharing_a_handle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	learnings := path.join(f.vault, "AI", "LEARNINGS.md")
	text, _ := read_text(learnings)
	path.write(learnings, strings.concatenate({text, "- **fixture tool** (aliases: twin) — the same name, another fact — fixture — 2026-01-03\n"}))
	exec(f.cli, "reindex")
	_, e, code := exec(f.cli, "bullet", "drop", "fixture tool")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "2 bullets are"), e)
	n := len(strings.split_lines(text)) // the twin's line
	_, e, code = exec(f.cli, "bullet", "drop", "fixture tool", "--at", "AI/MEMORY.md:3")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "no longer **fixture tool**"), "a line not holding the handle is refused")
	o: string
	o, e, code = exec(f.cli, "bullet", "replace", "fixture tool", "- **fixture twin** (aliases: twin) — the same name, another fact — fixture — 2026-01-03", "--at", strings.concatenate({"AI/LEARNINGS.md:", int_str(i64(n))}))
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "replaced **fixture twin**"), e)
	_, e, code = exec(f.cli, "bullet", "touch", "fixture tool")
	testing.expect_value(t, code, 0) // one bullet has the handle again
	_, e, code = exec(f.cli, "bullet", "touch", "fixture tool", "--at")
	testing.expect_value(t, code, 1)
}

@(test)
unlink_makes_a_dead_link_plain_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	note := path.join(f.vault, "AI", "artifacts", "links.md")
	path.write(note, "# Links\n\nsee [[gone]] and [[gone|the old page]], not [[kept]]\n")
	exec(f.cli, "reindex")
	o, e, code := exec(f.cli, "unlink", "AI/artifacts/links.md", "3", "gone")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "unlinked [[gone]]"), e)
	text, _ := read_text(note)
	testing.expect_value(t, text, "# Links\n\nsee gone and the old page, not [[kept]]\n")
	_, e, code = exec(f.cli, "unlink", "AI/artifacts/links.md", "3", "gone")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "has no [[gone]]"), e)
	_, e, code = exec(f.cli, "unlink", "../outside.md", "1", "gone")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "not a file in the vault"), e)
}

@(test)
bullet_edits_without_a_handle_say_how :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	for verb in ([3]string{"replace", "drop", "touch"}) {
		_, e, code := exec(f.cli, "bullet", verb)
		testing.expect_value(t, code, 1)
		testing.expect(t, strings.contains(e, "usage: brain bullet"), e)
	}
}

@(test)
bullet_show_says_what_served_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "find", "fixture")
	o, e, code := exec(f.cli, "--json", "bullet", "show", "fixture tool")
	testing.expect_value(t, code, 0)
	Show :: struct {
		file:     string,
		line:     int,
		fact:     string,
		served:   struct {
			times:    int,
			sessions: int,
			queries:  []struct {
				query: string,
				times: int,
			},
		},
		claims:   []struct {
			verdict: string,
		},
		history:  []struct {
			commit: string,
		},
		proposed: Maybe(struct {
			session: string,
		}),
	}
	s: Show
	testing.expect(t, json.unmarshal_string(o, &s) == nil, e)
	testing.expect_value(t, s.file, "AI/MEMORY.md")
	testing.expect_value(t, s.line, 8)
	testing.expect_value(t, s.fact, "a stand-in fact used only by the test suite")
	testing.expect_value(t, s.served.times, 1)
	testing.expect(t, len(s.served.queries) == 1 && s.served.queries[0].query == "fixture" && s.served.queries[0].times == 1, o)
	testing.expect_value(t, len(s.history), 0) // the fixture is no git repository
	_, proposed := s.proposed.?
	testing.expect(t, !proposed, "no transcript proposed it")
	_, e, code = exec(f.cli, "bullet", "show", "no such bullet")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "no bullet"), e)
}

@(test)
bullet_show_lists_the_commits_that_changed_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	git(t, f.vault, "init", "-q")
	git(t, f.vault, "add", "-A")
	git(t, f.vault, "commit", "-q", "-m", "the fixture")
	exec(f.cli, "bullet", "touch", "fixture tool")
	git(t, f.vault, "commit", "-q", "-am", "dated it")
	o, e, code := exec(f.cli, "--json", "bullet", "show", "fixture tool")
	testing.expect_value(t, code, 0)
	Show :: struct {
		history: []struct {
			subject: string,
			files:   []string,
		},
	}
	s: Show
	testing.expect(t, json.unmarshal_string(o, &s) == nil, e)
	// A re-date keeps the handle's count, so only the commit that added it
	// changed how often it appears.
	testing.expect_value(t, len(s.history), 1)
	if len(s.history) == 1 {
		testing.expect_value(t, s.history[0].subject, "the fixture")
		testing.expect(t, slice_has(s.history[0].files, "AI/MEMORY.md"), o)
	}
}

@(private = "file")
slice_has :: proc(xs: []string, x: string) -> bool {
	for y in xs {
		if y == x {
			return true
		}
	}
	return false
}
