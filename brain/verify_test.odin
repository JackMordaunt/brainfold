package brain

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sqlite3"

@(test)
claims_are_read_out_of_a_fact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	claims := extract_claims(f.cli, "AI/MEMORY.md", 1, "h", "lives at /opt/x (see `~/notes/a.md`), run `brain doctor`; commit 7d6fbd6 at https://x.y/z/abc1234; the notes in brainfold/2026-09-28-roadmap.md; version 1.2.3; cl takes /nologo, the route /code/brain-cli/ answers 301, //two-slash-prefix marks a line, jm/YYYY-*-friction.md names them; on Windows C:\\Tools\\brain.exe and on a Mac /private/var/x")
	kinds := make([dynamic]string)
	for c in claims {
		append(&kinds, strings.concatenate({c.kind, "=", c.text}))
	}
	testing.expect_value(t, strings.join(kinds[:], " "), "path=/opt/x path=~/notes/a.md command=brain doctor sha=7d6fbd6 vault-file=brainfold/2026-09-28-roadmap.md path=C:\\Tools\\brain.exe path=/private/var/x")
	testing.expect(t, !is_sha("decade") && !is_sha("1234567") && is_sha("7d6fbd6"), "sha shape")
}

@(test)
verify_tests_claims_and_dates_what_passed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	mem := path.join(f.vault, "AI", "MEMORY.md")
	// A path under the home directory keeps the claim independent of where
	// the fixture itself lands.
	testing.expect_value(t, path.mkdirs(path.join(f.home, "notes")), nil)
	testing.expect_value(
		t,
		path.append_file(
			mem,
			strings.concatenate(
				{
					"- **vault path** (aliases: where) — the notes live at ~/notes and AI/MEMORY.md is the index; `brain doctor` reads it — fixture — 2026-01-01\n",
					"- **gone path** (aliases: missing) — the old build sat at /tmp/nonexistent-brain-test/path — fixture — 2026-01-01\n",
					"- **bad command** (aliases: typo) — run `brain reindexx` after editing — fixture — 2026-01-01\n",
				},
			),
		),
		nil,
	)
	o, _, code := exec(f.cli, "verify")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "4 bullets make 6 checkable claims; 2 failed\n"), o)
	testing.expect(t, strings.contains(o, "**gone path** path /tmp/nonexistent-brain-test/path: not on this machine"), o)
	testing.expect(t, strings.contains(o, "**bad command** command brain reindexx: no such subcommand"), o)
	testing.expect(t, !strings.contains(o, "**vault path**") && !strings.contains(o, "**sqlite**"), o)

	o, _, code = exec(f.cli, "verify", "--json")
	testing.expect_value(t, code, 1)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	failures, _ := v.(json.Object)["failures"].(json.Array)
	testing.expect_value(t, len(failures), 2)
	if len(failures) == 2 {
		testing.expect_value(t, json_string(failures[0], "handle"), "gone path")
		testing.expect_value(t, json_string(failures[0], "text"), "/tmp/nonexistent-brain-test/path")
		testing.expect_value(t, json_string(failures[1], "text"), "brain reindexx")
		testing.expect_value(t, json_string(failures[1], "why"), "no such subcommand")
	}

	// Doctor reads the verdicts back.
	o, _, code = exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "claims that failed") && strings.contains(o, "reindexx"), o)

	// --apply dates the bullets whose claims all passed and nothing else.
	o, _, code = exec(f.cli, "verify", "--apply")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "dated today: 2 bullets"), o)
	text, _ := path.read(mem)
	today := today_iso()
	testing.expect(t, strings.contains(text, strings.concatenate({"`brain doctor` reads it — fixture — ", today})), text)
	testing.expect(t, strings.contains(text, strings.concatenate({"`brain sync` rebuilds it — fixture — ", today})), text)
	testing.expect(t, strings.contains(text, "/tmp/nonexistent-brain-test/path — fixture — 2026-01-01"), text)
	testing.expect(t, strings.contains(text, "libgit2** (aliases: jm:git, git library) — the git library the app binds instead of a git binary on PATH — fixture — 2026-01-02"), "a bullet with no claim keeps its date")

	// One handle at a time.
	o, _, code = exec(f.cli, "verify", "typo")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "1 bullets make 1 checkable claims; 1 failed\n"), o)
}

@(test)
doctor_names_bullets_served_before_a_correction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	exec(f.cli, "recall", "--sync")
	exec(f.cli, "reindex")
	// The serve a minute before the correction, plus an earlier rank-1 hit
	// still inside ten turns and a pack that shares the serve's timestamp.
	// Those are not the prompt the correction follows.
	db, err := open_index(f.cli)
	testing.expect_value(t, err, "")
	sqlite3.exec(db, "insert into queries(id,ts,q,hits,caller,session) values(6,'2026-01-01 10:00:10','earlier lookup',1,'claude','sess-one')")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(6,'AI/MEMORY.md','reply style',1)")
	sqlite3.exec(db, "insert into queries(id,ts,q,hits,caller,session) values(7,'2026-01-01 10:01:30','filmstrip',1,'claude','sess-one')")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(7,'AI/MEMORY.md','fixture tool',1)")
	sqlite3.exec(db, "insert into queries(id,ts,q,hits,caller,session) values(8,'2026-01-01 10:01:30','pack omacut',3,'claude','sess-one')")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(8,'AI/MEMORY.md','fixed reply fields',1)")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(8,'AI/MEMORY.md','hook binary',2)")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(8,'AI/MEMORY.md','verify and learn',3)")
	sqlite3.close(&db)
	o, _, code := exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "AI/MEMORY.md **fixture tool** served 2026-01-01 10:01:30, then: No, don't move the filmstrip"), o)
	testing.expect(t, !strings.contains(o, "reply style") && !strings.contains(o, "fixed reply fields") && !strings.contains(o, "hook binary") && !strings.contains(o, "verify and learn"), o)
	o, _, _ = exec(f.cli, "doctor", "--json")
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	suspect, _ := v.(json.Object)["suspect"].(json.Array)
	testing.expect_value(t, len(suspect), 1)
	if len(suspect) == 1 {
		testing.expect_value(t, json_string(suspect[0], "handle"), "fixture tool")
		testing.expect_value(t, json_string(suspect[0], "session"), "sess-one")
	}
}

// Help's command lines are the subcommands a bullet may name. They are
// read from `brain help`, not copied here, so help and COMMANDS cannot
// drift apart. `help` itself has no line of its own.
@(test)
help_subcommands_are_the_commands_verify_accepts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "help", "--color=never")
	testing.expect_value(t, code, 0)
	listed := help_subcommands(o)
	testing.expect(t, len(listed) > 0, "help lists commands")
	for sub in listed {
		testing.expectf(t, command_known(sub), "help lists %q, COMMANDS does not", sub)
	}
	for sub in COMMANDS {
		if sub == "help" {
			continue
		}
		testing.expectf(t, help_lists(listed, sub), "COMMANDS has %q, help does not list it", sub)
	}
}

// A command help lists is not a failed claim. A path that is not on this
// machine still is: the check is not pointed at some other directory.
@(test)
verify_passes_commands_help_lists_and_fails_a_missing_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	help, _, code := exec(f.cli, "help", "--color=never")
	testing.expect_value(t, code, 0)
	b := strings.builder_make()
	strings.write_string(&b, "- **live commands** —")
	for sub in help_subcommands(help) {
		fmt.sbprintf(&b, " `brain %s`", sub)
	}
	strings.write_string(&b, " `brain help` are commands — fixture — 2026-01-01\n")
	strings.write_string(&b, "- **old checkout** — the checkout was ~/Source/brainfold — fixture — 2026-01-01\n")
	strings.write_string(&b, "- **bad command** — run `brain reindexx` — fixture — 2026-01-01\n")
	mem := path.join(f.vault, "AI", "MEMORY.md")
	testing.expect_value(t, path.append_file(mem, strings.to_string(b)), nil)
	o, _, vcode := exec(f.cli, "verify", "live commands", "old checkout", "bad command")
	testing.expect_value(t, vcode, 1)
	testing.expect_value(t, strings.count(o, "not on this machine"), 1)
	testing.expect_value(t, strings.count(o, "no such subcommand"), 1)
	testing.expect(t, strings.contains(o, "**old checkout** path ~/Source/brainfold: not on this machine"), o)
	testing.expect(t, strings.contains(o, "brain reindexx: no such subcommand"), o)
}

// help_subcommands is every subcommand `brain help` prints on its own line.
help_subcommands :: proc(text: string) -> []string {
	found := make([dynamic]string)
	seen := make(map[string]bool)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "  brain ") {
			continue
		}
		name := line[len("  brain "):]
		if i := strings.index_byte(name, ' '); i >= 0 {
			name = name[:i]
		}
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		append(&found, name)
	}
	return found[:]
}

command_known :: proc(name: string) -> bool {
	for c in COMMANDS {
		if c == name {
			return true
		}
	}
	return false
}

help_lists :: proc(listed: []string, name: string) -> bool {
	for s in listed {
		if s == name {
			return true
		}
	}
	return false
}

// The prompt the correction answers was primed the way prime logs it.
// A later find and the pack logged beside that prime are other serves.
@(test)
doctor_joins_a_correction_to_the_prompt_it_follows :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	exec(f.cli, "recall", "--sync")
	exec(f.cli, "reindex")
	// What prime writes: "prime " plus the prompt's terms, not the raw turn.
	logged := strings.concatenate({"prime ", strings.join(prime_terms("the playhead jumps to the frame you clicked when scrubbing"), " ")})
	testing.expect_value(t, logged, "prime playhead jumps frame clicked scrubbing")
	db, err := open_index(f.cli)
	testing.expect_value(t, err, "")
	sqlite3.exec_args(db, "insert into queries(id,ts,q,hits,caller,session) values(6,'2026-01-01 10:00:01',?,2,'claude','sess-one')", logged)
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(6,'AI/MEMORY.md','fixture tool',1)")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(6,'AI/MEMORY.md','playhead seam',2)")
	sqlite3.exec(db, "insert into queries(id,ts,q,hits,caller,session) values(7,'2026-01-01 10:01:30','filmstrip',1,'claude','sess-one')")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(7,'AI/MEMORY.md','reply style',1)")
	sqlite3.exec(db, "insert into queries(id,ts,q,hits,caller,session) values(8,'2026-01-01 10:00:01','pack omacut',3,'claude','sess-one')")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(8,'AI/MEMORY.md','fixed reply fields',1)")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(8,'AI/MEMORY.md','hook binary',2)")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(8,'AI/MEMORY.md','verify and learn',3)")
	sqlite3.close(&db)
	o, _, code := exec(f.cli, "doctor", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	suspect, _ := v.(json.Object)["suspect"].(json.Array)
	got := make(map[string]bool)
	for s in suspect {
		got[json_string(s, "handle")] = true
		testing.expect_value(t, json_string(s, "served"), "2026-01-01 10:00:01")
	}
	testing.expect_value(t, len(suspect), 2)
	testing.expect(t, got["fixture tool"] && got["playhead seam"], o)
	testing.expect(t, !got["reply style"] && !got["fixed reply fields"] && !got["hook binary"] && !got["verify and learn"], o)
}
