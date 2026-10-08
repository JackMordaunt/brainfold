package brain

import "core:strings"
import "core:testing"

import "jm:path"

@(test)
alias_adds_and_removes_in_the_markdown :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	memory := path.join(f.vault, "AI", "MEMORY.md")
	o, e, code := exec(f.cli, "alias", "add", "fixture tool", "rig fixture", "jig")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "2 changed"), e)
	text, _ := read_text(memory)
	testing.expect(t, strings.contains(text, ", rig fixture, jig)"), text)
	// A name it already has is not added twice, in any case.
	o, _, _ = exec(f.cli, "alias", "add", "fixture tool", "JIG")
	testing.expect(t, strings.contains(o, "0 changed"), o)
	// The index follows: a find by the new name lands on it.
	o, _, code = exec(f.cli, "find", "rig fixture")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "fixture tool"), o)

	o, _, code = exec(f.cli, "alias", "remove", "fixture tool", "rig fixture", "jig")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "2 changed"), o)
	after, _ := read_text(memory)
	testing.expect(t, !strings.contains(after, "rig fixture"), after)
}

@(test)
alias_drops_an_empty_list_and_refuses_what_would_break_a_bullet :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	// Its three aliases taken out at once: the header loses its alias list.
	_, _, code := exec(f.cli, "alias", "remove", "fixture tool", "fixture", "sample", "test vault")
	testing.expect_value(t, code, 0)
	l := line_of(t, f, "fixture tool")
	testing.expect(t, strings.has_prefix(l, "- **fixture tool** — a stand-in fact"), l)

	_, e, bad := exec(f.cli, "alias", "add", "fixture tool", "a, b")
	testing.expect_value(t, bad, 1)
	testing.expect(t, strings.contains(e, "comma"), e)
	_, e, bad = exec(f.cli, "alias", "add", "no such bullet", "x")
	testing.expect_value(t, bad, 1)
	testing.expect(t, strings.contains(e, "no bullet"), e)
}

// line_of is the vault line holding the bullet with this handle.
@(private = "file")
line_of :: proc(t: ^testing.T, f: Fixture, handle: string) -> string {
	text, _ := read_text(path.join(f.vault, "AI", "MEMORY.md"))
	for l in strings.split_lines(text) {
		if strings.has_prefix(l, strings.concatenate({"- **", handle, "**"})) {
			return l
		}
	}
	testing.fail_now(t, "no line")
}

// An alias an older hand wrote with a parenthesis can be taken out, and
// the header loses the whole of it, not up to its first closing one.
@(test)
alias_removes_one_with_a_parenthesis :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	memory := path.join(f.vault, "AI", "MEMORY.md")
	path.append_file(memory, "- **odin debug tooling** (aliases: jm:debug (was jfm:debug)) — the debug allocator and ASan — fixture — 2026-01-02\n")
	exec(f.cli, "reindex")
	o, e, code := exec(f.cli, "alias", "remove", "odin debug tooling", "jm:debug (was jfm:debug")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "1 changed"), e)
	l := line_of(t, f, "odin debug tooling")
	testing.expect_value(t, l, "- **odin debug tooling** — the debug allocator and ASan — fixture — 2026-01-02")
}
