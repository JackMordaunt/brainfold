package desk_cli

import "core:encoding/cbor"
import "core:strings"
import "core:testing"

import "../shapes"

// Canned is a CLI that answers from a table, by its arguments joined with
// spaces, and remembers what it was asked.
@(private = "file")
Canned :: struct {
	answers: map[string]string,
	calls:   [dynamic]string,
}

@(private = "file")
canned_exec :: proc(user: rawptr, exe: string, args: []string, allocator := context.allocator) -> (stdout: string, ok: bool, stderr: string) {
	c := (^Canned)(user)
	key := strings.join(args, " ", context.temp_allocator)
	append(&c.calls, strings.clone(key, context.temp_allocator))
	if out, found := c.answers[key]; found {
		return strings.clone(out, allocator), true, ""
	}
	return "", false, strings.clone("unknown command", allocator)
}

@(private = "file")
canned :: proc(c: ^Canned) -> Client {
	c.answers = make(map[string]string, context.temp_allocator)
	c.calls = make([dynamic]string, context.temp_allocator)
	return {exec = canned_exec, user = c}
}

@(private = "file")
decode :: proc(t: ^testing.T, data: []byte, $T: typeid) -> (v: T) {
	testing.expect(t, data != nil, "an answer")
	err := cbor.unmarshal_from_bytes(data, &v, allocator = context.temp_allocator, temp_allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	return
}

@(test)
a_log_is_read_field_for_field :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["log --json"] = `{"backlog":[{"query":"BSA","misses":3,"last":"2026-10-07 21:59:08"}],"answered":["agenda"],"recent":[{"ts":"2026-10-07 21:59:08","query":"prime status","hits":9,"caller":"claude"}],"callers":[{"caller":"claude","queries":611,"sessions":347,"misses":159,"bytes":1512817}]}`
	data := read(&client, shapes.Log{}, context.temp_allocator)
	r := decode(t, data, shapes.Log_Result)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, len(r.backlog), 1)
	testing.expect_value(t, r.backlog[0].query, "BSA")
	testing.expect_value(t, r.backlog[0].misses, 3)
	testing.expect_value(t, r.answered[0], "agenda")
	testing.expect_value(t, r.recent[0].hits, 9)
	testing.expect_value(t, r.callers[0].bytes, 1512817)
}

@(test)
a_recall_passes_each_term_and_reads_the_array :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["recall --json --limit 5 hyprctl eval"] = `[{"id":"85801a30","date":"2026-09-22","agent":"pi","title":"Dedicated workspace","snippet":"use eval"}]`
	r := decode(t, read(&client, shapes.Recall{terms = "  hyprctl   eval ", limit = 5}, context.temp_allocator), shapes.Recall_Result)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, len(r.turns), 1)
	testing.expect_value(t, r.turns[0].agent, "pi")
}

@(test)
an_empty_recall_asks_nothing :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	r := decode(t, read(&client, shapes.Recall{terms = "  "}, context.temp_allocator), shapes.Recall_Result)
	testing.expect_value(t, len(r.turns), 0)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, len(c.calls), 0)
}

@(test)
a_failure_is_the_results_error :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["doctor --json"] = `{"error":"no vault: run brain install"}`
	r := decode(t, read(&client, shapes.Doctor{}, context.temp_allocator), shapes.Doctor_Result)
	testing.expect_value(t, r.error, "no vault: run brain install")

	// No answer at all: what the CLI said on stderr.
	i := decode(t, read(&client, shapes.Inbox{}, context.temp_allocator), shapes.Inbox_Result)
	testing.expect_value(t, i.error, "unknown command")

	// An answer that is not the shape: said so, not a crash.
	c.answers["ledger --json"] = `not json`
	l := decode(t, read(&client, shapes.Ledger{}, context.temp_allocator), shapes.Ledger_Result)
	testing.expect(t, strings.contains(l.error, "cannot read"), l.error)
}

@(test)
the_vault_is_four_calls_in_one_shape :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["locate --json"] = `{"vault":"/v","tool":"/t"}`
	c.answers["version --json"] = `{"version":"dev","commit":"1e4e8dc","dirty":false}`
	c.answers["sync status --json"] = `{"sync":"on","remote":"git@example:brain.git","last":"never","changed":2}`
	c.answers["review --json"] = `{"review":"after"}`
	v := decode(t, read(&client, shapes.Vault{}, context.temp_allocator), shapes.Vault_Result)
	testing.expect_value(t, v.error, "")
	testing.expect_value(t, v.vault, "/v")
	testing.expect_value(t, v.commit, "1e4e8dc")
	testing.expect_value(t, v.changed, 2)
	testing.expect_value(t, v.review, "after")
}

@(test)
approve_finds_the_proposal_by_handle :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["inbox --json"] = `{"proposals":[{"n":1,"handle":"first"},{"n":2,"handle":"second"}]}`
	c.answers["inbox approve 2"] = "approved"
	o := act(&client, shapes.Approve{id = 1, handles = {"second"}}, context.temp_allocator)
	testing.expect(t, o.done && o.ok, o.message)
	testing.expect_value(t, o.message, "Approved second")
	testing.expect_value(t, c.calls[len(c.calls) - 1], "inbox approve 2")

	// Gone since the ui drew it: no call, and the person is told.
	gone := act(&client, shapes.Drop{id = 2, handles = {"third"}}, context.temp_allocator)
	testing.expect(t, gone.done && !gone.ok)
	testing.expect(t, strings.contains(gone.message, "no longer in the inbox"), gone.message)
	testing.expect_value(t, c.calls[len(c.calls) - 1], "inbox --json")
}

@(test)
a_failed_command_says_what_the_cli_said :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	o := act(&client, shapes.Sync_Now{id = 1}, context.temp_allocator)
	testing.expect(t, o.done && !o.ok)
	testing.expect_value(t, o.message, "unknown command")

	bad := act(&client, shapes.Set_Review{id = 2, mode = "sometimes"}, context.temp_allocator)
	testing.expect(t, !bad.ok)
	testing.expect_value(t, len(c.calls), 1)
}

// A batch finds each proposal afresh, by its handle, and is approved at
// the place the inbox gives it then.
@(test)
a_batch_finds_each_by_handle :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["inbox --json"] = `{"proposals":[{"n":1,"handle":"a"},{"n":2,"handle":"b"},{"n":3,"handle":"c"}]}`
	c.answers["inbox approve 1"] = "ok"
	c.answers["inbox approve 3"] = "ok"
	o := act(&client, shapes.Approve{id = 1, handles = {"a", "c"}}, context.temp_allocator)
	testing.expect(t, o.ok, o.message)
	testing.expect_value(t, o.message, "Approved 2 proposals")

	// One gone, one done: not ok, and both counted.
	part := act(&client, shapes.Drop{id = 2, handles = {"gone", "a"}}, context.temp_allocator)
	testing.expect(t, !part.ok)
	testing.expect_value(t, part.message, "Dropped 0 of 2; gone is no longer in the inbox")
}

// A bullet's provenance is asked for by its place, and a proposal the
// CLI reports as null reads as none.
@(test)
a_provenance_is_read_by_place :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["--json bullet show twin --at AI/MEMORY.md:4"] = `{"file":"AI/MEMORY.md","line":4,"handle":"twin","fact":"a fact","source":"","date":"2026-01-01","served":{"times":3,"sessions":2,"top":1,"used":0,"first":"2026-10-01 10:00:00","last":"2026-10-08 11:00:00","callers":[{"caller":"claude","times":3}],"queries":[{"query":"twin","times":3,"last":"2026-10-08 11:00:00"}],"days":[{"day":"2026-10-08","times":3}]},"claims":[{"kind":"path","text":"~/x","verdict":"failed","why":"not on this machine","checked":"2026-10-08"}],"history":[{"commit":"eaa5237","date":"2026-10-02","subject":"sync: 2 files from omarchy","files":["AI/MEMORY.md"]}],"proposed":null}`
	r := decode(t, read(&client, shapes.Bullet_Show{handle = "twin", at = "AI/MEMORY.md:4"}, context.temp_allocator), shapes.Bullet_Show_Result)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, r.served.times, 3)
	testing.expect_value(t, r.served.callers[0].caller, "claude")
	testing.expect_value(t, r.served.days[0].times, 3)
	testing.expect_value(t, r.claims[0].verdict, "failed")
	testing.expect_value(t, r.history[0].files[0], "AI/MEMORY.md")
	testing.expect_value(t, r.proposed.session, "")
	// Without a place, none is passed.
	c.answers["--json bullet show solo"] = `{"file":"AI/MEMORY.md","line":2,"handle":"solo","served":{"times":0},"claims":[],"history":[],"proposed":{"ts":"2026-10-02T20:50:08Z","agent":"claude","session":"s1","title":"Why","turn":"t1"}}`
	r = decode(t, read(&client, shapes.Bullet_Show{handle = "solo"}, context.temp_allocator), shapes.Bullet_Show_Result)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, r.proposed.turn, "t1")
}

@(test)
spend_is_read_for_its_window :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["--json spend --days 7"] = `{"days":7,"since":"2026-10-01","cost":12.5,"unpriced":100,"replies":40,"sessions":3,"by_day":[{"name":"2026-10-08","cost":12.5,"tokens":900,"sessions":3,"priced":true}],"by_agent":[],"by_model":[{"name":"claude-fable-5-1","cost":0,"tokens":100,"sessions":0,"priced":false}],"served":2000,"served_cost":0.01,"lookups":9,"answered":8,"finds":{"hits":6,"misses":5,"hit_cost":0.2,"miss_cost":0.35,"hit_calls":3,"miss_calls":5,"saved":0.9,"enough":true}}`
	r := decode(t, read(&client, shapes.Spend{days = 7}, context.temp_allocator), shapes.Spend_Result)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, r.cost, 12.5)
	testing.expect_value(t, r.by_model[0].priced, false)
	testing.expect_value(t, r.finds.hits, 6)
	testing.expect(t, r.finds.enough)
	testing.expect_value(t, r.finds.saved, 0.9)
}

@(test)
an_import_takes_each_source_and_counts_what_it_proposed :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["--json import /a/memory"] = `{"sources":1,"memories":4,"proposed":3}`
	c.answers["--json import /b/GEMINI.md"] = `{"sources":1,"memories":2,"proposed":2}`
	o := act(&client, shapes.Import{id = 1, paths = {"/a/memory", "/b/GEMINI.md"}}, context.temp_allocator)
	testing.expect(t, o.ok)
	testing.expect_value(t, o.message, "5 memories proposed; they wait in the inbox")
	c.answers["--json import /a/memory"] = `{"sources":1,"memories":4,"proposed":0}`
	o = act(&client, shapes.Import{id = 2, paths = {"/a/memory"}}, context.temp_allocator)
	testing.expect_value(t, o.message, "Nothing new in 4 memories: the vault has them already")
	o = act(&client, shapes.Import{id = 3, paths = {"/missing"}}, context.temp_allocator)
	testing.expect(t, !o.ok)
}

// A proposal is reviewed and merged by its place in the inbox now, found
// by its handle.
@(test)
a_proposal_is_reviewed_and_merged_by_its_place :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["inbox --json"] = `{"proposals":[{"n":1,"handle":"other"},{"n":2,"handle":"twin"}]}`
	c.answers["--json inbox review 2"] = `{"n":2,"handle":"twin","similar":[{"file":"AI/MEMORY.md","line":4,"handle":"Twin","fact":"f","share":0.8,"same_handle":true}],"errors":[],"warnings":["it has no aliases"],"origin":null}`
	r := decode(t, read(&client, shapes.Inbox_Review{handle = "twin"}, context.temp_allocator), shapes.Inbox_Review_Result)
	testing.expect_value(t, r.error, "")
	testing.expect_value(t, len(r.similar), 1)
	testing.expect(t, r.similar[0].same_handle)
	testing.expect_value(t, r.similar[0].share, 0.8)
	testing.expect_value(t, r.origin.session, "")
	line := "- **Twin** — merged — x — 2026-10-08"
	c.answers[strings.concatenate({"--json inbox merge 2 --into Twin ", line, " --at AI/MEMORY.md:4"}, context.temp_allocator)] = `{"status":"merged","handle":"Twin","file":"AI/MEMORY.md","line":4,"errors":[],"warnings":[]}`
	o := act(&client, shapes.Merge{id = 1, proposal = "twin", into = "Twin", at = "AI/MEMORY.md:4", line = line}, context.temp_allocator)
	testing.expect(t, o.ok, o.message)
	testing.expect_value(t, o.message, "Merged into Twin at AI/MEMORY.md:4")
}

@(test)
setup_is_read_and_its_steps_run :: proc(t: ^testing.T) {
	c: Canned
	client := canned(&c)
	c.answers["--json setup"] = `{"vault":{"path":"","exists":false,"bullets":0},"agents":[{"name":"claude","installed":true,"hooks":false,"reading":false}],"lookups":0,"memories":{"sources":0,"new":0},"sync":false}`
	r := decode(t, read(&client, shapes.Setup{}, context.temp_allocator), shapes.Setup_Result)
	testing.expect_value(t, r.error, "")
	testing.expect(t, !r.vault.exists)
	testing.expect(t, r.agents[0].installed && !r.agents[0].hooks)
	c.answers["--json find how do tests run"] = `{"query":"how do tests run","hits":[{"file":"AI/MEMORY.md","line":3,"handle":"tests","fact":"just test"}]}`
	f := decode(t, read(&client, shapes.Find{terms = " how  do tests run "}, context.temp_allocator), shapes.Find_Result)
	testing.expect_value(t, f.error, "")
	testing.expect_value(t, f.hits[0].handle, "tests")
	// Connecting is the hooks, then the transcripts.
	c.answers["hooks on --harness claude"] = "claude hooks on"
	c.answers["recall --enable claude"] = "recall: claude enabled"
	o := act(&client, shapes.Connect{id = 1, agent = "claude"}, context.temp_allocator)
	testing.expect(t, o.ok, o.message)
	testing.expect_value(t, c.calls[len(c.calls) - 2], "hooks on --harness claude")
	testing.expect_value(t, c.calls[len(c.calls) - 1], "recall --enable claude")
	c.answers["install --new /home/me/Notes/brain"] = "created"
	o = act(&client, shapes.New_Vault{id = 2, path = "/home/me/Notes/brain "}, context.temp_allocator)
	testing.expect(t, o.ok, o.message)
	testing.expect_value(t, c.calls[len(c.calls) - 1], "install --new /home/me/Notes/brain")
	// A step that fails says why, and goes no further.
	o = act(&client, shapes.Connect{id = 3, agent = "pi"}, context.temp_allocator)
	testing.expect(t, !o.ok)
	testing.expect_value(t, c.calls[len(c.calls) - 1], "hooks on --harness pi")
}
