package brain

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

import "jm:path"

@(test)
claude_adapter_reads_what_each_reply_cost_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "s1.jsonl")
	usage := `"usage":{"input_tokens":10,"cache_creation_input_tokens":300,"cache_read_input_tokens":2000,"output_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}`
	lines := []string {
		`{"type":"user","uuid":"u1","timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"find it"}}`,
		// One reply streamed over two records, each with its usage.
		fill(`{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T10:00:01Z","message":{"id":"m1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"looking"}],USAGE}}`, "USAGE", usage),
		fill(`{"type":"assistant","uuid":"a2","timestamp":"2026-01-01T10:00:02Z","message":{"id":"m1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"brain find alpha 2>&1 | head"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}],USAGE}}`, "USAGE", usage),
		`{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"nothing in the vault for: alpha"},{"type":"tool_result","tool_use_id":"t2","content":"a.txt"}]}}`,
		// A subagent's reply is paid for too.
		`{"type":"assistant","isSidechain":true,"uuid":"a3","timestamp":"2026-01-01T10:00:03Z","message":{"id":"m2","model":"claude-haiku-4-5","role":"assistant","content":[{"type":"text","text":"sub"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":7,"cache_read_input_tokens":0,"output_tokens":1}}}`,
		`{"type":"custom-title","customTitle":"A session"}`,
	}
	testing.expect_value(t, path.write(file, strings.join(lines, "\n")), nil)
	tr := claude_emit(f.cli, file)
	testing.expect_value(t, len(tr.usage), 2)
	if len(tr.usage) == 2 {
		u := tr.usage[0]
		testing.expect_value(t, u.id, "m1")
		testing.expect_value(t, u.model, "claude-sonnet-5")
		testing.expect_value(t, u.input, 10)
		testing.expect_value(t, u.cache_write_5m, 100)
		testing.expect_value(t, u.cache_write_1h, 200)
		testing.expect_value(t, u.cache_read, 2000)
		testing.expect_value(t, u.output, 40)
		testing.expect_value(t, u.cost, -1)
		// Before the 5m/1h split a record has the total alone.
		testing.expect_value(t, tr.usage[1].cache_write_5m, 7)
	}
	testing.expect_value(t, len(tr.tools), 2)
	if len(tr.tools) == 2 {
		testing.expect_value(t, tr.tools[0].result, "nothing in the vault for: alpha")
		testing.expect_value(t, tr.tools[1].result, "") // not a brain command
	}
}

@(test)
a_find_is_judged_by_what_it_printed :: proc(t: ^testing.T) {
	testing.expect_value(t, find_terms(`brain find "order ledger" 2>&1 | head`), "order ledger")
	testing.expect_value(t, find_terms(`V=$(brain locate); brain find --json jm roadmap && echo`), "jm roadmap")
	testing.expect_value(t, find_terms("brain findx"), "")
	answered, known := find_answered("nothing in the vault for: order ledger\n(noted)", "order ledger")
	testing.expect(t, known && !answered)
	answered, known = find_answered(PARTIAL_HEAD + "AI/MEMORY.md:3 **x** — y", "order ledger")
	testing.expect(t, known && !answered, "a partial answer is a miss")
	answered, known = find_answered("AI/MEMORY.md:3 **order ledger** — the fact", "order ledger")
	testing.expect(t, known && answered)
	_, known = find_answered("  \n", "order ledger")
	testing.expect(t, !known, "nothing printed is not known")
}

@(test)
a_reply_is_priced_by_its_longest_prefix :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	prices := load_prices(f.cli)
	p, ok := price_of(prices[:], "claude-opus-4-1-20250805")
	testing.expect(t, ok)
	testing.expect_value(t, p.input, 15)
	p, ok = price_of(prices[:], "claude-opus-5-5")
	testing.expect_value(t, p.input, 5)
	_, ok = price_of(prices[:], "claude-fable-5-1")
	testing.expect(t, !ok, "a model with no price is not guessed")
	// A million of each kind: input 3, 5m write 3.75, 1h write 6, read 0.3, output 15.
	cost, priced := reply_cost(prices[:], "claude-sonnet-5", 1e6, 1e6, 1e6, 1e6, 1e6)
	testing.expect(t, priced)
	testing.expect(t, abs(cost - 28.05) < 1e-9, fmt.tprint(cost))
	// A price set wins over the list and is kept in prices.tsv.
	_, e, code := exec(f.cli, "spend", "--price", "claude-fable", "10", "50")
	testing.expect_value(t, code, 0)
	_, _, code = exec(f.cli, "spend", "--price", "claude-sonnet", "4", "20")
	testing.expect_value(t, code, 0)
	_, _, code = exec(f.cli, "spend", "--price", "claude-sonnet", "3.5", "17.5")
	testing.expect_value(t, code, 0)
	_ = e
	prices = load_prices(f.cli)
	p, ok = price_of(prices[:], "claude-fable-5-1")
	testing.expect(t, ok)
	testing.expect_value(t, p.output, 50)
	p, _ = price_of(prices[:], "claude-sonnet-5")
	testing.expect_value(t, p.input, 3.5)
	text, _ := read_text(path.join(f.cli.conf_dir, "prices.tsv"))
	testing.expect_value(t, strings.count(text, "claude-sonnet"), 1)
	_, _, code = exec(f.cli, "spend", "--price", "claude-x", "free", "1")
	testing.expect_value(t, code, 1)
}

// fill is text with each pair's first replaced by its second: JSON
// built without fmt, which reads its braces as placeholders.
@(private = "file")
fill :: proc(text: string, pairs: ..string) -> string {
	out := text
	for i := 0; i + 1 < len(pairs); i += 2 {
		out, _ = strings.replace_all(out, pairs[i], pairs[i + 1], context.temp_allocator)
	}
	return out
}

// write_session writes a Claude Code session in which an agent runs one
// find, then spends cost dollars of claude-sonnet-5 output finishing its
// reply before the person writes again.
@(private = "file")
write_session :: proc(f: Fixture, n: int, terms, printed: string, cost: f64) {
	day := today_iso()
	ts :: proc(day: string, n, s: int) -> string {
		return fmt.tprintf("%sT%02d:00:%02dZ", day, n % 24, s)
	}
	out := i64(cost * 1e6 / 15) // sonnet output is $15 a million
	printed_json, _ := json.marshal(printed, allocator = context.temp_allocator)
	n_ := fmt.tprint(n)
	lines := []string {
		fill(`{"type":"user","uuid":"u@N@","timestamp":"@T0@","message":{"role":"user","content":"go"}}`, "@N@", n_, "@T0@", ts(day, n, 0)),
		fill(`{"type":"assistant","uuid":"a@N@","timestamp":"@T1@","message":{"id":"m@N@-0","model":"claude-sonnet-5","role":"assistant","content":[{"type":"tool_use","id":"t@N@","name":"Bash","input":{"command":"brain find @TERMS@"}}],"usage":{"input_tokens":0,"output_tokens":0}}}`, "@N@", n_, "@T1@", ts(day, n, 1), "@TERMS@", terms),
		fill(`{"type":"user","uuid":"r@N@","timestamp":"@T2@","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t@N@","content":@PRINTED@}]}}`, "@N@", n_, "@T2@", ts(day, n, 2), "@PRINTED@", string(printed_json)),
		fill(`{"type":"assistant","uuid":"b@N@","timestamp":"@T3@","message":{"id":"m@N@-1","model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":0,"output_tokens":@OUT@}}}`, "@N@", n_, "@T3@", ts(day, n, 3), "@OUT@", fmt.tprint(out)),
		fill(`{"type":"user","uuid":"v@N@","timestamp":"@T4@","message":{"role":"user","content":"thanks"}}`, "@N@", n_, "@T4@", ts(day, n, 4)),
		// After the person's next message: not part of finishing the find.
		fill(`{"type":"assistant","uuid":"c@N@","timestamp":"@T5@","message":{"id":"m@N@-2","model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"later"}],"usage":{"input_tokens":0,"output_tokens":1000000}}}`, "@N@", n_, "@T5@", ts(day, n, 5)),
		`{"type":"custom-title","customTitle":"Spend fixture"}`,
	}
	path.write(path.join(f.home, ".claude", "projects", "p", fmt.tprintf("s%d.jsonl", n)), strings.join(lines, "\n"))
}

@(test)
spend_says_what_an_answer_saved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["CLAUDE_CODE_SESSION_ID"] = ""
	f.cli.env["CLAUDE_SESSION_ID"] = ""
	// Five answered finds that took $0.10 to finish, and five misses that
	// took $0.40.
	for i in 0 ..< LOOKUP_MIN {
		write_session(f, i, "alpha", "AI/MEMORY.md:3 **alpha** — the fact", 0.10)
		write_session(f, 10 + i, "beta", "nothing in the vault for: beta", 0.40)
	}
	_, _, code := exec(f.cli, "recall", "--enable", "claude")
	testing.expect_value(t, code, 0)
	o, e, c := exec(f.cli, "--json", "spend")
	testing.expect_value(t, c, 0)
	Out :: struct {
		cost:     f64,
		sessions: int,
		replies:  int,
		by_model: []struct {
			name:   string,
			priced: bool,
		},
		finds:    struct {
			hits, misses:        int,
			hit_cost, miss_cost: f64,
			saved:               f64,
			enough:              bool,
		},
	}
	s: Out
	testing.expect(t, json.unmarshal_string(o, &s) == nil, fmt.tprint(o, e))
	testing.expect_value(t, s.sessions, 2 * LOOKUP_MIN)
	testing.expect_value(t, s.replies, 3 * 2 * LOOKUP_MIN)
	// Every reply priced: $0.10 and $0.40 to finish, $15 after each.
	testing.expect(t, abs(s.cost - (f64(LOOKUP_MIN) * (0.10 + 0.40) + 2 * f64(LOOKUP_MIN) * 15)) < 0.01, fmt.tprint(s.cost))
	testing.expect_value(t, s.finds.hits, LOOKUP_MIN)
	testing.expect_value(t, s.finds.misses, LOOKUP_MIN)
	testing.expect(t, abs(s.finds.hit_cost - 0.10) < 0.001 && abs(s.finds.miss_cost - 0.40) < 0.001, fmt.tprint(s.finds))
	testing.expect(t, s.finds.enough)
	testing.expect(t, abs(s.finds.saved - 0.30 * f64(LOOKUP_MIN)) < 0.01, fmt.tprint(s.finds.saved))
}

