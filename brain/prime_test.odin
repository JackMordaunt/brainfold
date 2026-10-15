package brain

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sh"

@(test)
prime_terms_drop_noise_and_pasted_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	terms := prime_terms("How do I rebuild the sqlite index? <pasted_content id=\"1\">\nlibgit2 everywhere\n</pasted_content id=\"1\"> please")
	testing.expect_value(t, strings.join(terms, " "), "rebuild sqlite index")
	testing.expect_value(t, len(prime_terms("do it now")), 0)
	// A sentence dot is not part of the word: "ok." is the stop word ok.
	testing.expect_value(t, len(prime_terms("do it now.")), 0)
	testing.expect_value(t, len(prime_terms("ok.")), 0)
	testing.expect_value(t, len(prime_terms("yes.")), 0)
}

// A prompt with nothing past the stop list prints nothing and logs no lookup.
@(test)
prime_prints_nothing_when_nothing_is_past_the_stop_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	_, _, code := exec(f.cli, "reindex")
	testing.expect_value(t, code, 0)
	f.cli.has_stdin = true
	f.cli.stdin = `{"session_id":"s-quiet","hook_event_name":"UserPromptSubmit","prompt":"ok."}`
	o := ""
	o, _, code = exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	testing.expect_value(t, count_int(t, f, "select count(*) from queries"), 0)
}

// A one-line acknowledgement is not a question. Bullets that merely share
// its words, a fixed reply or a single-letter name, stay unserved, and
// nothing is logged.
@(test)
prime_stays_quiet_on_an_acknowledgement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	mem := path.join(f.vault, "AI", "MEMORY.md")
	text, rerr := path.read(mem)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(
		t,
		path.write(
			mem,
			strings.concatenate(
				{
					text,
					"- **fixed reply fields** (aliases: trailer) — mandatory per-answer fields become a trailer ritual; word caps ignored — fixture — 2026-01-03\n",
					"- **no single-letter names** (aliases: variable naming) — any single-letter name is at least a word — fixture — 2026-01-03\n",
				},
			),
		),
		nil,
	)
	_, _, code := exec(f.cli, "reindex")
	testing.expect_value(t, code, 0)
	f.cli.has_stdin = true
	f.cli.stdin = `{"session_id":"s-ack","hook_event_name":"UserPromptSubmit","prompt":"answer single word ok."}`
	o := ""
	o, _, code = exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	testing.expect_value(t, count_int(t, f, "select count(*) from queries"), 0)
	testing.expect_value(t, strings.join(prime_terms("answer single word ok."), " "), "")
}

// Naming a handle still primes, acknowledgement words or not, and that
// bullet is served once in the session. Another session is served again.
@(test)
prime_still_serves_a_named_handle_once_per_session :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	mem := path.join(f.vault, "AI", "MEMORY.md")
	text, rerr := path.read(mem)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(
		t,
		path.write(
			mem,
			strings.concatenate(
				{
					text,
					"- **fixed reply fields** (aliases: trailer) — mandatory per-answer fields become a trailer ritual; word caps ignored — fixture — 2026-01-03\n",
					"- **no single-letter names** (aliases: variable naming) — any single-letter name is at least a word — fixture — 2026-01-03\n",
				},
			),
		),
		nil,
	)
	f.cli.has_stdin = true
	f.cli.stdin = `{"session_id":"s-real","hook_event_name":"UserPromptSubmit","prompt":"answer single word sqlite ok."}`
	o, _, code := exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	testing.expect(t, !strings.contains(o, "fixed reply fields") && !strings.contains(o, "single-letter"), o)
	o, _, code = exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	f.cli.stdin = `{"session_id":"s-real-2","hook_event_name":"UserPromptSubmit","prompt":"answer single word sqlite ok."}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
}

// A prompt's bullets are served once per session: the second prompt on
// the same topic, and a prompt after the pack served it, print nothing.
@(test)
prime_serves_each_bullet_once_per_session :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	hook := `{"session_id":"s-prime","hook_event_name":"UserPromptSubmit","prompt":"why does the sqlite index need fts5?","cwd":"/tmp"}`
	f.cli.stdin, f.cli.has_stdin = hook, true
	o, _, code := exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, PRIME_HEAD), o)
	testing.expect(t, strings.contains(o, "**sqlite**") && !strings.contains(o, "libgit2"), o)
	testing.expect_value(t, last_query_row(t, f), "1 claude s-prime")

	o, _, code = exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")

	// Another session is served; a prompt about nothing prints nothing.
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"sqlite?"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	// A prompt about nothing gets the hint once per session, then nothing.
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"what is the weather"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, "")
	f.cli.stdin = `{"session_id":"s-hint","hook_event_name":"UserPromptSubmit","prompt":"what is the weather"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, PRIME_HINT)
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, "")
	// A fact only a note holds follows the bullets.
	f.cli.stdin = `{"session_id":"s-note","hook_event_name":"UserPromptSubmit","prompt":"later the git library is chosen?"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, NOTES_HEAD) && strings.contains(o, "handoffs/"), o)
	// A sentence no bullet holds whole is answered by the bullets holding
	// enough of it; one shared word is not enough.
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"which git library does the app bind, and does it shell out to a binary on PATH for the index?"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, "**libgit2**") && !strings.contains(o, "**sqlite**"), o)

	// Typed at a terminal, the prompt is the arguments.
	f.cli.has_stdin = false
	f.cli.env["BRAIN_SESSION"] = "s-three"
	o, _, code = exec(f.cli, "prime", "the", "libgit2", "binding", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	hits, _ := v.(json.Object)["hits"].(json.Array)
	testing.expect_value(t, len(hits), 1)
	if len(hits) == 1 {
		testing.expect_value(t, json_string(hits[0], "handle"), "libgit2")
	}

	// The pack counts as served too.
	f.cli.env["BRAIN_SESSION"] = "s-four"
	o, _, _ = exec(f.cli, "pack", "fixture")
	testing.expect(t, strings.contains(o, "**fixture tool**"), o)
	o, _, _ = exec(f.cli, "prime", "fixture", "tool")
	testing.expect_value(t, o, "")
}

settle_transcript :: proc(turns: int, work, propose: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"user","uuid":"u0","message":{"role":"user","content":"start"}}` + "\n")
	for i in 0 ..< turns {
		strings.write_string(&b, `{"type":"assistant","uuid":"a`)
		strings.write_string(&b, int_str(i64(i)))
		strings.write_string(&b, `","message":{"role":"assistant","content":[{"type":"text","text":"working"}`)
		if work && i == 1 {
			strings.write_string(&b, `,{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/a"}}`)
		}
		if propose && i == 2 {
			strings.write_string(&b, `,{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"brain propose '- **x** — y'"}}`)
		}
		strings.write_string(&b, "]}}\n")
	}
	return strings.to_string(b)
}

// Reading is not work: a session of lookups, greps and quietened commands
// is never asked; one that wrote, built or committed is.
@(test)
settle_counts_only_mutating_shell_as_work :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	reads := [?]string{"ls -la", "cat a.md | grep x", "brain find busctl 2>&1; echo ---; brain recall busctl 2>/dev/null", "rg -n TODO src >/dev/null"}
	for r in reads {
		testing.expect(t, !shell_mutates(r), r)
	}
	writes := [?]string{"echo hi > out.txt", "chmod +x run.sh", "sed -i 's/a/b/' f", "git commit -m x", "just release", "mkdir -p a/b"}
	for w in writes {
		testing.expect(t, shell_mutates(w), w)
	}
	tr := Transcript{tools = []Tool{{name = "Bash", input = "ls"}, {name = "Bash", input = "brain find x"}}}
	_, worked, proposed := settle_scan(tr)
	testing.expect(t, !worked && !proposed, "lookups alone are not work")
	tr = Transcript{tools = []Tool{{name = "Bash", input = "printf x > f"}, {name = "Bash", input = "brain propose '- **x** — y'"}}}
	_, worked, proposed = settle_scan(tr)
	testing.expect(t, worked && proposed, "a write is work and the proposal is seen")
}

@(test)
settle_asks_once_when_work_went_unproposed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "t.jsonl")
	// The path is a JSON string, so a Windows path's backslashes are escaped.
	hook := proc(file, session: string, active: bool) -> string {
		return strings.concatenate({`{"session_id":"`, session, `","hook_event_name":"Stop","stop_hook_active":`, active ? "true" : "false", `,"transcript_path":"`, json_escape(file), `"}`})
	}
	f.cli.has_stdin = true

	// No work, or already proposed: nothing to say, however much was said.
	testing.expect_value(t, path.write(file, settle_transcript(8, false, false)), nil)
	f.cli.stdin = hook(file, "s1", false)
	o, _, code := exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	testing.expect_value(t, path.write(file, settle_transcript(8, true, true)), nil)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")

	// Work without a proposal blocks the stop once, with the ask, however
	// short the session (at Stop the last reply is not even written yet).
	testing.expect_value(t, path.write(file, settle_transcript(2, true, false)), nil)
	o, _, code = exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	testing.expect_value(t, json_string(v, "decision"), "block")
	testing.expect(t, strings.contains(json_string(v, "reason"), "brain propose"), o)
	testing.expect(t, strings.contains(json_string(v, "reason"), "This session wrote a."), o)
	testing.expect(t, os.exists(path.join(f.state, "settle", "s1")), "the session is stamped")
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
	// A continuation after the block never blocks again.
	f.cli.stdin = hook(file, "s2", true)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
}

@(test)
hooks_turn_on_and_off_in_every_harness_here :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_EXE"] = "/opt/brain"
	// Claude Code is always here; pi only once its agent directory is.
	o, _, code := exec(f.cli, "hooks")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "claude  SessionStart       brain pack    off\nclaude  UserPromptSubmit   brain prime   off\nclaude  Stop               brain settle  off\n")
	testing.expect_value(t, path.mkdirs(path.join(f.home, ".pi", "agent")), nil)
	o, _, _ = exec(f.cli, "hooks")
	testing.expect(t, strings.has_suffix(o, "pi      agent_before_settle brain settle  off\n"), o)

	o, _, code = exec(f.cli, "hooks", "on")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "claude  Stop               brain settle  on\n"), o)
	testing.expect(t, strings.contains(o, "pi      before_agent_start brain prime   on\n"), o)
	text, _ := path.read(path.join(f.home, ".claude", "settings.json"))
	testing.expect(t, strings.contains(text, `"/opt/brain prime 2>/dev/null || true"`), text)
	ext, rerr := path.read(path.join(f.home, ".pi", "agent", "extensions", "brain.ts"))
	testing.expect_value(t, rerr, nil)
	testing.expect(t, strings.has_prefix(ext, PI_MARK) && strings.contains(ext, `const BRAIN = "/opt/brain";`), ext)
	testing.expect(t, strings.contains(ext, `"agent_before_settle"`) && strings.contains(ext, `["settle", "--harness", "pi"`), ext)
	o, _, _ = exec(f.cli, "hooks", "--json")
	testing.expect_value(t, o, `{"claude":{"pack":true,"prime":true,"settle":true},"pi":{"pack":true,"prime":true,"settle":true}}` + "\n")

	// Off for one harness leaves the other alone.
	o, _, code = exec(f.cli, "hooks", "off", "--harness", "pi")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "brain extension removed"), o)
	testing.expect(t, !os.exists(path.join(f.home, ".pi", "agent", "extensions", "brain.ts")), "the extension is gone")
	o, _, _ = exec(f.cli, "hooks")
	testing.expect(t, strings.contains(o, "claude  Stop               brain settle  on\n"), o)
	testing.expect(t, strings.contains(o, "pi      session_start      brain pack    off\n"), o)
	o, _, code = exec(f.cli, "hooks", "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "claude  Stop               brain settle  off\n"), o)
	_, _, code = exec(f.cli, "hooks", "sideways")
	testing.expect_value(t, code, 1)
	_, _, code = exec(f.cli, "hooks", "--harness", "codex")
	testing.expect_value(t, code, 1)
}

// pi passes the event as flags, not JSON: prime takes the prompt after
// --, settle the transcript, and the reply is the shape its extension
// reads.
@(test)
pi_harness_drives_prime_and_settle_by_flags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.has_stdin = false
	o, _, code := exec(f.cli, "prime", "--harness", "pi", "--session", "pi-1", "--", "why", "does", "the", "sqlite", "index", "need", "fts5?")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	testing.expect_value(t, last_query_row(t, f), "1 pi pi-1")
	o, _, _ = exec(f.cli, "prime", "--harness", "pi", "--session", "pi-1", "--", "sqlite", "fts5")
	testing.expect_value(t, o, "")

	file := path.join(f.root, "pi.jsonl")
	testing.expect_value(t, path.write(file, pi_transcript(8, true, false)), nil)
	o, _, code = exec(f.cli, "settle", "--harness", "pi", "--session", "pi-1", "--transcript", file)
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	testing.expect(t, strings.contains(json_string(v, "reason"), "brain propose"), o)
	testing.expect(t, strings.contains(json_string(v, "reason"), "This session wrote a."), o)
	_, has_decision := v.(json.Object)["decision"]
	testing.expect(t, !has_decision, "pi's reply carries no Claude decision field")
	o, _, _ = exec(f.cli, "settle", "--harness", "pi", "--session", "pi-1", "--transcript", file)
	testing.expect_value(t, o, "")
	o, _, _ = exec(f.cli, "settle", "--harness", "pi", "--session", "pi-2", "--transcript", file, "--continuing")
	testing.expect_value(t, o, "")
	testing.expect(t, !wants_stdin({"prime", "--harness", "pi", "--session", "x", "--", "hi"}), "flags carry the event")
	testing.expect(t, wants_stdin({"settle"}), "a bare settle reads the hook's JSON")
}

// A pi session with n assistant turns, an edit when work is true and a
// brain propose call when propose is true; untitled, like a live one.
pi_transcript :: proc(turns: int, work, propose: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"session","version":3,"id":"pi-1","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp/p"}` + "\n")
	strings.write_string(&b, `{"type":"message","id":"m0","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"start"}}` + "\n")
	for i in 0 ..< turns {
		strings.write_string(&b, `{"type":"message","id":"a`)
		strings.write_string(&b, int_str(i64(i)))
		strings.write_string(&b, `","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"working"}`)
		if work && i == 1 {
			strings.write_string(&b, `,{"type":"toolCall","id":"c1","name":"edit","arguments":{"path":"/tmp/p/a.odin","oldText":"x"}}`)
		}
		if propose && i == 2 {
			strings.write_string(&b, `,{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"brain propose '- **x** — y'"}}`)
		}
		strings.write_string(&b, "]}}\n")
	}
	return strings.to_string(b)
}

// Grok is present when its home directory is. Hooks register under it, and a
// shell function in the rc file is what puts the pack on the command line.
@(test)
grok_harness_registers_the_shell_function_and_the_hooks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_EXE"] = "/opt/brain"
	testing.expect_value(t, path.mkdirs(path.join(f.home, ".grok")), nil)

	o, _, code := exec(f.cli, "hooks")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "grok    SessionStart       brain pack    off\n"), o)
	testing.expect(t, strings.contains(o, "grok    UserPromptSubmit   brain prime   off\n"), o)
	testing.expect(t, strings.contains(o, "grok    Stop               brain settle  off\n"), o)

	o, _, code = exec(f.cli, "hooks", "on", "--harness", "grok")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "grok    Stop               brain settle  on\n"), o)

	script := path.join(f.home, ".grok", "hooks", "brain.sh")
	text, rerr := path.read(script)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, strings.has_prefix(text, "# brainfold hooks:"), text)
	testing.expect(t, strings.contains(text, "'/opt/brain'"), text)
	testing.expect(t, strings.contains(text, "user_prompt_submit") && strings.contains(text, "session_start"), text)
	testing.expect(t, strings.contains(text, "prime") && strings.contains(text, "--harness") && strings.contains(text, "grok"), text)
	testing.expect(t, strings.contains(text, "end_turn") && strings.contains(text, `"decision":"block"`), text)

	hooks, _ := path.read(path.join(f.home, ".grok", "hooks", "brain.json"))
	testing.expect(t, strings.contains(hooks, "SessionStart") && strings.contains(hooks, "UserPromptSubmit"), hooks)
	testing.expect(t, strings.contains(hooks, "Stop") && strings.contains(hooks, "SessionEnd"), hooks)
	testing.expect(t, strings.contains(hooks, "brain.sh") && strings.contains(hooks, `"timeout":10`) && strings.contains(hooks, `"timeout":30`), hooks)
	testing.expect(t, !strings.contains(hooks, "startup|clear|compact"), hooks)

	rc, _ := path.read(path.join(f.home, ".bashrc"))
	testing.expect(t, strings.contains(rc, "brain:grok >>>") && strings.contains(rc, "brain hooks on"), rc)
	testing.expect(t, strings.contains(rc, "command grok --rules") && strings.contains(rc, "'/opt/brain'"), rc)
	testing.expect(t, strings.contains(rc, "--cwd") && strings.contains(rc, "version"), rc)

	o, _, _ = exec(f.cli, "hooks", "--json", "--harness", "grok")
	testing.expect_value(t, o, `{"grok":{"pack":true,"prime":true,"settle":true}}` + "\n")

	o, _, code = exec(f.cli, "hooks", "on", "--harness", "grok")
	testing.expect_value(t, code, 0)
	rc2, _ := path.read(path.join(f.home, ".bashrc"))
	testing.expect_value(t, rc2, rc)

	o, _, code = exec(f.cli, "hooks", "off", "--harness", "grok")
	testing.expect_value(t, code, 0)
	testing.expect(t, !os.exists(script), "the hook script is gone")
	testing.expect(t, !os.exists(path.join(f.home, ".grok", "hooks", "brain.json")), "the hook file is gone")
	rc3, _ := path.read(path.join(f.home, ".bashrc"))
	testing.expect(t, !strings.contains(rc3, "brain:grok"), rc3)
	testing.expect(t, strings.contains(o, "grok    SessionStart       brain pack    off\n"), o)
}

// A prompt's bullet is read from Grok's own JSON, held until Stop, and handed
// back as the decision Grok feeds the model. Settle has nothing to read.
@(test)
grok_harness_primes_on_stop_and_packs_before_start :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.has_stdin = true
	f.cli.stdin = `{"hookEventName":"user_prompt_submit","sessionId":"g-1","prompt":"why does the sqlite index need fts5?"}`
	o, _, code := exec(f.cli, "prime", "--harness", "grok")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	testing.expect_value(t, last_query_row(t, f), "1 grok g-1")
	o, _, _ = exec(f.cli, "prime", "--harness", "grok")
	testing.expect_value(t, o, "")

	f.cli.stdin = `{"hook_event_name":"UserPromptSubmit","session_id":"g-2","prompt":"sqlite fts5","stop_hook_active":false}`
	o, _, code = exec(f.cli, "prime", "--harness", "grok")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	testing.expect_value(t, last_query_row(t, f), "1 grok g-2")

	ev, ok := grok_parse(`{"hookEventName":"stop","sessionId":"g","transcriptPath":"/t","stopHookActive":true,"prompt":"hi"}`)
	testing.expect(t, ok && ev.continuing, "camelCase stop is Grok's")
	testing.expect_value(t, ev.session, "g")
	testing.expect_value(t, ev.transcript, "/t")
	testing.expect_value(t, ev.prompt, "hi")

	// No recall adapter reads updates.jsonl, so settle stays quiet even when
	// the file is a transcript another harness would ask about.
	file := path.join(f.root, "t.jsonl")
	testing.expect_value(t, path.write(file, settle_transcript(8, true, false)), nil)
	f.cli.has_stdin = false
	o, _, code = exec(f.cli, "settle", "--harness", "grok", "--session", "g-1", "--transcript", file)
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")

	if _, found := sh.which("sh"); !found {
		return
	}
	bin := path.join(f.root, "bin")
	testing.expect_value(t, path.mkdirs(bin), nil)
	stub := path.join(bin, "brain")
	fake := path.join(bin, "grok")
	calls := path.join(f.root, "calls")
	pwds := path.join(f.root, "pwds")
	seen := path.join(f.root, "stdin")
	arg1 := path.join(f.root, "arg1")
	arg2 := path.join(f.root, "arg2")
	argc := path.join(f.root, "argc")
	mode := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	testing.expect_value(t, path.write(stub, strings.concatenate({
		"#!/bin/sh\n",
		"printf '%s %s %s\\n' \"$1\" \"$BRAIN_CALLER\" \"$BRAIN_SESSION\" >> \"", calls, "\"\n",
		"printf '%s\\n' \"$PWD\" >> \"", pwds, "\"\n",
		"case \"$1\" in\n",
		"  prime) cat > \"", seen, "\"; printf '%s\\n' 'bullet \"sqlite\"' ;;\n",
		"  pack) printf '%s\\n' 'pack body' ;;\n",
		"  settle) printf '%s\\n' '{\"decision\":\"block\",\"reason\":\"propose\"}' ;;\n",
		"esac\n",
		"exit 0\n",
	})), nil)
	testing.expect_value(t, path.write(fake, strings.concatenate({
		"#!/bin/sh\n",
		"printf '%s\\n' \"$1\" > \"", arg1, "\"\n",
		"printf '%s\\n' \"$2\" > \"", arg2, "\"\n",
		"printf '%s\\n' \"$#\" > \"", argc, "\"\n",
		"exit 0\n",
	})), nil)
	testing.expect_value(t, os.change_mode(stub, mode), nil)
	testing.expect_value(t, os.change_mode(fake, mode), nil)

	f.cli.env["BRAIN_EXE"] = stub
	testing.expect_value(t, path.mkdirs(path.join(f.home, ".grok")), nil)
	_, _, code = exec(f.cli, "hooks", "on", "--harness", "grok")
	testing.expect_value(t, code, 0)
	script := path.join(f.home, ".grok", "hooks", "brain.sh")

	prompt := `{"prompt":"why sqlite"}`
	r := sh.exec(
		{"/bin/sh", script},
		{
			env = {"PATH=/usr/bin:/bin", "GROK_HOOK_EVENT=user_prompt_submit", "GROK_SESSION_ID=s1"},
			stdin = prompt,
		},
	)
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, r.stdout, "")
	got, _ := path.read(seen)
	testing.expect_value(t, got, prompt)
	logged, _ := path.read(calls)
	testing.expect(t, strings.contains(logged, "prime grok s1"), logged)
	pending := path.join(f.home, ".grok", "brain-pending", "s1")
	held, _ := path.read(pending)
	testing.expect(t, strings.contains(held, `bullet "sqlite"`), held)

	stop := `{"reason":"end_turn","transcript_path":"/tmp/updates.jsonl","stopHookActive":false}`
	r = sh.exec(
		{"/bin/sh", script},
		{env = {"PATH=/usr/bin:/bin", "GROK_HOOK_EVENT=stop", "GROK_SESSION_ID=s1"}, stdin = stop},
	)
	testing.expect(t, r.ok, sh.error(r))
	v, jerr := json.parse_string(strings.trim_space(r.stdout))
	testing.expect_value(t, jerr, nil)
	testing.expect_value(t, json_string(v, "decision"), "block")
	testing.expect(t, strings.contains(json_string(v, "reason"), `bullet "sqlite"`), r.stdout)
	testing.expect(t, !os.exists(pending), "the bullet is delivered once")

	os.remove(calls)
	r = sh.exec(
		{"/bin/sh", script},
		{env = {"PATH=/usr/bin:/bin", "GROK_HOOK_EVENT=stop", "GROK_SESSION_ID=s1"}, stdin = stop},
	)
	testing.expect(t, r.ok, sh.error(r))
	testing.expect(t, strings.contains(r.stdout, `"reason":"propose"`), r.stdout)
	logged, _ = path.read(calls)
	testing.expect(t, strings.contains(logged, "settle grok s1"), logged)

	os.remove(calls)
	r = sh.exec(
		{"/bin/sh", script},
		{env = {"PATH=/usr/bin:/bin", "GROK_HOOK_EVENT=stop", "GROK_SESSION_ID=s1"}, stdin = `{"reason":"shutdown"}`},
	)
	testing.expect(t, r.ok, sh.error(r))
	testing.expect_value(t, r.stdout, "")
	testing.expect(t, !os.exists(calls), "a shutdown stop is not a turn")

	if _, found := sh.which("bash"); !found {
		return
	}
	os.remove(calls)
	os.remove(arg1)
	rc := path.join(f.home, ".bashrc")
	shell_env := []string{strings.concatenate({"PATH=", bin, ":/usr/bin:/bin"}), strings.concatenate({"HOME=", f.home})}
	r = sh.exec(
		{"/bin/bash", "-c", `source "$1"; grok version`, "bash", rc},
		{env = shell_env},
	)
	testing.expect(t, r.ok, sh.error(r))
	testing.expect(t, !os.exists(calls), "version is not a session")
	a1, _ := path.read(arg1)
	testing.expect_value(t, strings.trim_space(a1), "version")

	os.remove(pwds)
	elsewhere := path.join(f.root, "elsewhere")
	testing.expect_value(t, path.mkdirs(elsewhere), nil)
	r = sh.exec(
		{"/bin/bash", "-c", `source "$1"; grok --cwd "$2" -p hello`, "bash", rc, elsewhere},
		{env = shell_env},
	)
	testing.expect(t, r.ok, sh.error(r))
	a1, _ = path.read(arg1)
	a2, _ := path.read(arg2)
	n, _ := path.read(argc)
	testing.expect_value(t, strings.trim_space(a1), "--rules")
	testing.expect_value(t, strings.trim_space(a2), "pack body")
	testing.expect_value(t, strings.trim_space(n), "6")
	pwd, _ := path.read(pwds)
	testing.expect(t, strings.contains(pwd, elsewhere), pwd)
}
