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
