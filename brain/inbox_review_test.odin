package brain

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "jm:path"

// Review shows a proposal beside the bullet it repeats, by handle or by
// what it says, with what lint says of it.
@(test)
inbox_review_shows_what_a_proposal_may_repeat :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	_, e, code := exec(
		f.cli,
		"propose",
		"--force",
		"- **Fixture Tool** — a stand-in fact used only by the test suite, said again — test — 2026-01-02",
	)
	testing.expect_value(t, code, 0)
	_ = e
	o: string
	o, e, code = exec(f.cli, "--json", "inbox", "review", "1")
	testing.expect_value(t, code, 0)
	Review :: struct {
		n:        int,
		handle:   string,
		similar:  []struct {
			file, handle: string,
			line:         int,
			share:        f64,
			same_handle:  bool,
		},
		errors:   []string,
		warnings: []string,
		origin:   Maybe(struct {
				session: string,
			}),
	}
	r: Review
	testing.expect(t, json.unmarshal_string(o, &r) == nil, e)
	testing.expect_value(t, r.handle, "Fixture Tool")
	testing.expect(t, len(r.similar) >= 1, o)
	if len(r.similar) >= 1 {
		s := r.similar[0]
		testing.expect_value(t, s.handle, "fixture tool")
		testing.expect_value(t, s.file, "AI/MEMORY.md")
		testing.expect(t, s.same_handle, "the same handle, in another case")
		testing.expect(t, s.share > 0.5, o)
	}
	testing.expect_value(t, len(r.errors), 0)
	testing.expect(t, len(r.warnings) == 1 && strings.contains(r.warnings[0], "no aliases"), o)
	_, proposed := r.origin.?
	testing.expect(t, !proposed, "no transcript proposed it")
	_, _, code = exec(f.cli, "inbox", "review", "9")
	testing.expect_value(t, code, 1)
}

// Merge writes the merged line in the bullet's place and retires the
// proposal, which is then not proposed again.
@(test)
inbox_merge_folds_a_proposal_into_its_bullet :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	proposal := "- **fixture tool** (aliases: stand-in) — a stand-in fact used only by the test suite, and by the docs — test — 2026-01-02"
	_, _, code := exec(f.cli, "propose", "--force", proposal)
	testing.expect_value(t, code, 0)
	// Refused as lint would refuse it: nothing changes.
	_, e, c := exec(
		f.cli,
		"inbox",
		"merge",
		"1",
		"--into",
		"fixture tool",
		"- **fixture tool** — dated in the future — x — 2999-01-01",
	)
	testing.expect_value(t, c, 1)
	testing.expect(t, strings.contains(e, "future"), e)
	merged := "- **fixture tool** (aliases: fixture, sample, test vault, stand-in) — a stand-in fact used only by the test suite and the docs — fixture — 2026-01-03"
	o: string
	o, e, c = exec(
		f.cli,
		"inbox",
		"merge",
		"1",
		"--into",
		"fixture tool",
		"--at",
		"AI/MEMORY.md:8",
		merged,
	)
	testing.expect_value(t, c, 0)
	testing.expect(t, strings.contains(o, "merged **fixture tool** at AI/MEMORY.md:8"), e)
	memory, _ := read_text(path.join(f.vault, "AI", "MEMORY.md"))
	testing.expect(t, strings.contains(memory, merged), memory)
	inbox, inbox_ok := read_text(path.join(f.vault, INBOX_FILE))
	testing.expect(t, inbox_ok, "the inbox is still there")
	testing.expect(t, !strings.contains(inbox, "by the docs"), "the proposal left the inbox")
	dropped, _ := read_text(path.join(f.vault, DROPPED_FILE))
	testing.expect(t, strings.contains(dropped, proposal), "kept on record")
	o, _, _ = exec(f.cli, "propose", "--force", proposal)
	testing.expect(t, strings.contains(o, "dropped this fact before"), o)
	_, _, c = exec(f.cli, "inbox", "merge", "1")
	testing.expect_value(t, c, 1)
}
