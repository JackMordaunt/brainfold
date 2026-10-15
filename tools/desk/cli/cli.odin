/*
Package cli is the desk's client of the brain CLI: it runs `brain
<command> --json` and reads the object it prints into the contract's
shapes, and carries out a command as the CLI calls that would. It is the
only package that knows the CLI's words; the rest of the desk sees shapes.

The process runner is a field, so a test answers with canned JSON and no
binary. Every proc here may run on a worker thread: it touches nothing
but its arguments and what it allocates.
*/
package desk_cli

import "core:encoding/cbor"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import "core:time/timezone"

import "jm:i18n"
import "jm:sh"

import "../../../msg"
import "../shapes"

// said is key in the locale in use, filled into the allocator the caller
// set. A message with nothing to fill in is the catalog's own text.
@(private)
said :: proc(key: msg.Msg, args: ..i18n.Arg) -> string {
	return msg.textf(key, ..args, allocator = context.allocator)
}

// TIMEOUT is the longest one CLI call may take; a sync talks to a remote.
TIMEOUT :: 60 * time.Second

// Exec runs the CLI with args and returns what it printed, whether it
// exited 0, and what it said on stderr.
Exec :: proc(user: rawptr, exe: string, args: []string, allocator := context.allocator) -> (stdout: string, ok: bool, stderr: string)

Client :: struct {
	exe:  string, // the brain binary; "brain" finds it on PATH
	exec: Exec, // nil runs exe
	user: rawptr, // passed to exec
}

// Query is a need the CLI answers.
Query :: union {
	shapes.Log,
	shapes.Ledger,
	shapes.Doctor,
	shapes.Recall,
	shapes.Around,
	shapes.Inbox,
	shapes.Bullets,
	shapes.Bullet_Check,
	shapes.Bullet_Show,
	shapes.Spend,
	shapes.Import_Sources,
	shapes.Inbox_Review,
	shapes.Setup,
	shapes.Find,
	shapes.Install_Plan,
	shapes.Vault,
}

// run is exec, or the real process when none is set.
run :: proc(c: ^Client, args: []string, allocator := context.allocator) -> (stdout: string, ok: bool, stderr: string) {
	if c.exec != nil {
		return c.exec(c.user, c.exe, args, allocator)
	}
	argv := make([]string, len(args) + 1, allocator)
	argv[0] = c.exe == "" ? "brain" : c.exe
	copy(argv[1:], args)
	r := sh.exec(argv, {timeout = TIMEOUT}, allocator)
	if r.err != nil {
		return "", false, msg.textf(.Could_Not_Run, argv[0], fmt.tprintf("%v", r.err), allocator = allocator)
	}
	if r.timed_out {
		return r.stdout, false, msg.textf(.Took_Too_Long, argv[0], fmt.tprintf("%v", TIMEOUT), allocator = allocator)
	}
	return r.stdout, r.ok, r.stderr
}

// read answers q as the CLI does, as the cbor bytes of its result, in
// allocator. A failure is the result's error, never a missing result.
// What the JSON is read into lives in an arena of its own, gone on return.
read :: proc(c: ^Client, q: Query, allocator := context.allocator) -> []byte {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	switch q in q {
	case shapes.Log:
		r: shapes.Log_Result
		r.error = call(c, {"log", "--json"}, &r)
		return marshal(r, allocator)
	case shapes.Ledger:
		r: shapes.Ledger_Result
		r.error = call(c, {"ledger", "--json"}, &r)
		return marshal(r, allocator)
	case shapes.Doctor:
		return marshal(doctor(c), allocator)
	case shapes.Recall:
		r: shapes.Recall_Result
		if strings.trim_space(q.terms) != "" {
			args := make([dynamic]string)
			append(&args, "recall", "--json", "--limit", fmt.aprint(q.limit > 0 ? q.limit : 20))
			for term in strings.fields(q.terms) {
				append(&args, term)
			}
			r.error = call(c, args[:], &r.turns)
		}
		return marshal(r, allocator)
	case shapes.Around:
		r: shapes.Around_Result
		if q.id != "" {
			r.error = call(c, {"recall", "--json", "--around", q.id}, &r)
		}
		return marshal(r, allocator)
	case shapes.Inbox:
		r: shapes.Inbox_Result
		r.error = call(c, {"inbox", "--json"}, &r)
		return marshal(r, allocator)
	case shapes.Bullets:
		r: shapes.Bullets_Result
		r.error = call(c, {"bullet", "list", "--json"}, &r)
		return marshal(r, allocator)
	case shapes.Bullet_Check:
		return marshal(check(c, q.line), allocator)
	case shapes.Setup:
		r: shapes.Setup_Result
		r.error = call(c, {"--json", "setup"}, &r)
		return marshal(r, allocator)
	case shapes.Find:
		r: shapes.Find_Result
		if strings.trim_space(q.terms) != "" {
			args := make([dynamic]string)
			append(&args, "--json", "find")
			for term in strings.fields(q.terms) {
				append(&args, term)
			}
			r.error = call(c, args[:], &r)
		}
		return marshal(r, allocator)
	case shapes.Inbox_Review:
		r: shapes.Inbox_Review_Result
		if q.handle != "" {
			n, missing, err := place_of(c, q.handle)
			if missing {
				err = said(.Gone_Inbox, q.handle)
			}
			if err == "" {
				r.error = call(c, {"--json", "inbox", "review", fmt.aprint(n)}, &r)
			} else {
				r.error = err
			}
		}
		return marshal(r, allocator)
	case shapes.Import_Sources:
		r: shapes.Import_Sources_Result
		r.error = call(c, {"--json", "import", "--list"}, &r)
		return marshal(r, allocator)
	case shapes.Spend:
		r: shapes.Spend_Result
		r.error = call(c, {"--json", "spend", "--days", fmt.aprint(q.days > 0 ? q.days : 30)}, &r)
		return marshal(r, allocator)
	case shapes.Bullet_Show:
		r: shapes.Bullet_Show_Result
		if q.handle != "" {
			r.error = call(c, at_args({"--json", "bullet", "show", q.handle}, q.at), &r)
		}
		return marshal(r, allocator)
	case shapes.Install_Plan:
		r: shapes.Install_Plan_Result
		if strings.trim_space(q.path) != "" {
			stdout, ok, stderr := run(c, {"install", "--dry-run", strings.trim_space(q.path)})
			r.ok = ok
			r.plan = strings.trim_space(stdout)
			if !ok {
				r.error = failure({"install"}, stdout, stderr)
			}
		}
		return marshal(r, allocator)
	case shapes.Vault:
		return marshal(read_vault(c), allocator)
	}
	return nil
}

@(private)
marshal :: proc(v: $T, allocator: mem.Allocator) -> []byte {
	out, err := cbor.marshal_into_bytes(v, allocator = allocator, temp_allocator = context.allocator)
	if err != nil {
		return nil
	}
	return out
}

// doctor is `brain doctor`, stamped with when it ran and how long it took.
doctor :: proc(c: ^Client) -> (r: shapes.Doctor_Result) {
	start := time.tick_now()
	r.error = call(c, {"doctor", "--json"}, &r)
	r.took_ms = int(time.duration_milliseconds(time.tick_since(start)))
	h, m, sec := time.clock_from_time(local_now())
	r.ran_at = fmt.aprintf("%02d:%02d:%02d", h, m, sec)
	return
}

// local_now is the time on this machine's clock, for a person to read.
@(private)
local_now :: proc() -> time.Time {
	now := time.now()
	if tz, ok := timezone.region_load("local"); ok {
		defer timezone.region_destroy(tz)
		if dt, dok := time.time_to_datetime(now); dok {
			if local, lok := timezone.datetime_to_tz(dt, tz); lok {
				if t, tok := time.datetime_to_time(local); tok {
					return t
				}
			}
		}
	}
	return now
}

// check is `brain bullet check`, whose refusal exits 1 with its reasons
// in the JSON: read either way.
check :: proc(c: ^Client, line: string) -> (r: shapes.Bullet_Check_Result) {
	if strings.trim_space(line) == "" {
		return
	}
	stdout, ok, stderr := run(c, {"--json", "bullet", "check", line})
	if e := error_of(stdout); e != "" {
		r.error = e
		return
	}
	if json.unmarshal_string(stdout, &r) != nil {
		r.error = ok ? "brain bullet check answered what the desk cannot read" : failure({"bullet", "check"}, stdout, stderr)
	}
	return
}

// read_vault is four calls, since no one command says it all. The first
// that fails names the error; what the others said is kept.
@(private)
read_vault :: proc(c: ^Client) -> (r: shapes.Vault_Result) {
	Locate :: struct {
		vault, tool: string,
	}
	Version :: struct {
		version, commit: string,
	}
	Sync :: struct {
		sync, remote, last: string,
		changed:            int,
	}
	Review :: struct {
		review: string,
	}
	loc: Locate
	ver: Version
	syn: Sync
	rev: Review
	errs := [4]string {
		call(c, {"locate", "--json"}, &loc),
		call(c, {"version", "--json"}, &ver),
		call(c, {"sync", "status", "--json"}, &syn),
		call(c, {"review", "--json"}, &rev),
	}
	r = {
		vault   = loc.vault,
		tool    = loc.tool,
		version = ver.version,
		commit  = ver.commit,
		sync    = syn.sync,
		remote  = syn.remote,
		last    = syn.last,
		changed = syn.changed,
		review  = rev.review,
	}
	for e in errs {
		if e != "" {
			r.error = e
			break
		}
	}
	return
}

// call runs the CLI and reads its JSON into out, returning what went
// wrong, or "".
call :: proc(c: ^Client, args: []string, out: ^$T) -> string {
	stdout, ok, stderr := run(c, args)
	if e := error_of(stdout); e != "" {
		return e
	}
	if !ok {
		return failure(args, stdout, stderr)
	}
	if err := json.unmarshal_string(stdout, out); err != nil {
		return said(.Cannot_Read, args[0], fmt.tprintf("%v", err))
	}
	return ""
}

// error_of is the error a --json command reports as {"error": ...}.
@(private)
error_of :: proc(stdout: string) -> string {
	Err :: struct {
		error: string,
	}
	s := strings.trim_space(stdout)
	if !strings.has_prefix(s, "{\"error\"") {
		return ""
	}
	e: Err
	if json.unmarshal_string(s, &e) != nil {
		return ""
	}
	return e.error
}

// failure is the first thing the CLI said about a call that failed.
@(private)
failure :: proc(args: []string, stdout, stderr: string) -> string {
	for s in ([2]string{stderr, stdout}) {
		if line := first_line(s); line != "" {
			return line
		}
	}
	return said(.Command_Failed, strings.join(args, " "))
}

@(private)
first_line :: proc(text: string) -> string {
	s := strings.trim_space(text)
	line, _, _ := strings.partition(s, "\n")
	return strings.trim_space(line)
}

// act carries out a command and says how it went, everything in allocator.
act :: proc(c: ^Client, cmd: shapes.Command, allocator := context.allocator) -> (o: shapes.Outcome_Result) {
	msg.refresh()
	context.allocator = allocator
	o.done = true
	switch v in cmd {
	case shapes.Approve:
		return settle_proposals(c, v.handles, "approve", v.to)
	case shapes.Drop:
		return settle_proposals(c, v.handles, "drop", "")
	case shapes.Date_Verified:
		return step(c, {"tend", "date"}, "")
	case shapes.Sync_Now:
		o = step(c, {"sync"}, "")
		if o.ok && o.message == "" {
			o.message = msg.text(.In_Sync)
		}
		return
	case shapes.Reindex:
		return step(c, {"reindex"}, msg.text(.Index_Rebuilt))
	case shapes.Run_Doctor:
		// The host runs it, since its answer is a report, not a message.
		return {done = true, message = msg.text(.Doctor_In_Host)}
	case shapes.Add_Alias:
		return step(c, {"alias", "add", v.handle, v.term}, said(.Alias_Added, v.handle, v.term))
	case shapes.Remove_Alias:
		return step(c, {"alias", "remove", v.handle, v.term}, said(.Alias_Removed, v.term, v.handle))
	case shapes.Set_Vault:
		path := strings.trim_space(v.path)
		return step(c, {"install", path}, said(.Vault_Set, path))
	case shapes.Write_Bullet:
		to := v.to != "" ? v.to : "MEMORY"
		return edit(c, {"--json", "bullet", "write", v.line, "--to", to}, msg.text(.Word_Written))
	case shapes.Replace_Bullet:
		return edit(c, at_args({"--json", "bullet", "replace", v.handle, v.line}, v.at), msg.text(.Word_Saved))
	case shapes.Drop_Bullet:
		return edit(c, at_args({"--json", "bullet", "drop", v.handle}, v.at), msg.text(.Word_Dropped))
	case shapes.Touch_Bullet:
		return edit(c, at_args({"--json", "bullet", "touch", v.handle}, v.at), msg.text(.Word_Dated))
	case shapes.Import:
		return import_sources(c, v.paths)
	case shapes.Connect:
		if hooked := step(c, {"hooks", "on", "--harness", v.agent}, ""); !hooked.ok {
			return hooked
		}
		return step(c, {"recall", "--enable", v.agent}, said(.Connected_Agent, v.agent))
	case shapes.New_Vault:
		path := strings.trim_space(v.path)
		return step(c, {"install", "--new", path}, said(.Vault_New, path))
	case shapes.Merge:
		n, missing, err := place_of(c, v.proposal)
		if missing {
			err = said(.Gone_Inbox, v.proposal)
		}
		if err != "" {
			return {done = true, message = err}
		}
		return edit(c, at_args({"--json", "inbox", "merge", fmt.aprint(n), "--into", v.into, v.line}, v.at), msg.text(.Word_Merged))
	case shapes.Set_Price:
		return step(c, {"spend", "--price", v.prefix, v.input, v.output}, said(.Priced, v.prefix, v.input, v.output))
	case shapes.Unlink:
		return step(c, {"unlink", v.file, fmt.aprint(v.line), v.target}, said(.Unlinked, v.target, v.file))
	case shapes.Set_Review:
		if v.mode != "after" && v.mode != "before" {
			return {done = true, message = said(.No_Review_Mode, v.mode)}
		}
		said := v.mode == "after" ? msg.text(.Review_After) : msg.text(.Review_Before)
		return step(c, {"review", v.mode}, said)
	}
	return {done = true, message = msg.text(.Nothing_To_Do)}
}

// settle_proposals approves or drops every proposal named, in order, each found
// afresh. A row that has already left is reported and does not fail the
// batch: the ones still there are done, and a real refusal is the only
// failure.
@(private)
settle_proposals :: proc(c: ^Client, handles: []string, verb, to: string) -> shapes.Outcome_Result {
	done_word := verb == "approve" ? msg.text(.Word_Approved) : msg.text(.Word_Dropped_Verb)
	done := 0
	kept := ""
	first := ""
	present := 0
	gone := make([dynamic]string, context.temp_allocator)
	for h in handles {
		n, missing, err := place_of(c, h)
		if missing {
			append(&gone, h)
			continue
		}
		present += 1
		if err == "" {
			args := make([dynamic]string, context.temp_allocator)
			append(&args, "inbox", verb, fmt.aprint(n))
			if to != "" {
				append(&args, "--to", to)
			}
			o := step(c, args[:], "")
			if o.ok {
				done += 1
				kept = h
				continue
			}
			err = o.message
		}
		if first == "" {
			first = err
		}
	}
	note := gone_note(gone[:])
	switch {
	case len(handles) == 0:
		return {done = true, message = msg.text(.Nothing_Selected)}
	case first == "" && done == 1 && note == "":
		return {done = true, ok = true, message = said(.Done_One, done_word, kept)}
	case first == "" && done == len(handles):
		return {done = true, ok = true, message = said(.Done_Many, done_word, done)}
	case first == "" && done > 0:
		base := done == 1 ? said(.Done_One, done_word, kept) : said(.Done_Many, done_word, done)
		return {done = true, ok = true, message = join_note(base, note)}
	case first == "" && note != "":
		return {done = true, message = note}
	case present == 1 && note == "":
		return {done = true, message = first}
	}
	return {done = true, message = join_note(said(.Done_Partial, done_word, done, present, first), note)}
}

// gone_note names each handle that was no longer in the inbox.
@(private)
gone_note :: proc(gone: []string) -> string {
	if len(gone) == 0 {
		return ""
	}
	parts := make([dynamic]string, context.temp_allocator)
	for h in gone {
		append(&parts, said(.Gone_Inbox, h))
	}
	return strings.join(parts[:], "; ")
}

// join_note appends a gone note to what the batch otherwise says.
@(private)
join_note :: proc(base, note: string) -> string {
	if note == "" {
		return base
	}
	return strings.concatenate({base, "; ", note})
}

// edit runs a bullet command and says how it went: where the bullet is
// now, or every reason it was refused.
@(private)
edit :: proc(c: ^Client, args: []string, done: string) -> shapes.Outcome_Result {
	Report :: struct {
		status, handle, file: string,
		line:                 int,
		errors, warnings:     []string,
	}
	stdout, ok, stderr := run(c, args)
	if e := error_of(stdout); e != "" {
		return {done = true, message = e}
	}
	r: Report
	if json.unmarshal_string(stdout, &r) != nil {
		return {done = true, message = failure(args, stdout, stderr)}
	}
	if !ok || r.status == "refused" {
		return {done = true, message = said(.Not_Written, strings.join(r.errors, "; "))}
	}
	if r.file != "" {
		return {done = true, ok = true, message = said(.Written_At, done, r.handle, r.file, fmt.tprint(r.line))}
	}
	return {done = true, ok = true, message = said(.Written_Handle, done, r.handle)}
}

// import_sources imports each path in turn and says how many memories
// were proposed, or the first that failed.
@(private)
import_sources :: proc(c: ^Client, paths: []string) -> shapes.Outcome_Result {
	Report :: struct {
		memories, proposed: int,
	}
	proposed, memories := 0, 0
	for p in paths {
		r: Report
		if err := call(c, {"--json", "import", p}, &r); err != "" {
			return {done = true, message = err}
		}
		proposed += r.proposed
		memories += r.memories
	}
	switch {
	case proposed == 0:
		return {done = true, ok = true, message = said(.Import_Nothing, memories)}
	case proposed == 1:
		return {done = true, ok = true, message = msg.text(.Import_One)}
	}
	return {done = true, ok = true, message = said(.Import_Many, proposed)}
}

// at_args is args, then --at at when a bullet's place is named.
@(private)
at_args :: proc(args: []string, at: string) -> []string {
	if at == "" {
		return args
	}
	out := make([dynamic]string)
	append(&out, ..args)
	append(&out, "--at", at)
	return out[:]
}

// place_of finds a proposal's place in the inbox now, by its handle.
// missing is a row that has left; err is a read that failed.
@(private)
place_of :: proc(c: ^Client, handle: string) -> (n: int, missing: bool, err: string) {
	in_: shapes.Inbox_Result
	if e := call(c, {"inbox", "--json"}, &in_); e != "" {
		return 0, false, e
	}
	for p in in_.proposals {
		if p.handle == handle {
			return p.n, false, ""
		}
	}
	return 0, true, ""
}

// step runs one CLI call for a command: said on success, or the first
// line the CLI printed when said is "".
@(private)
step :: proc(c: ^Client, args: []string, said: string) -> shapes.Outcome_Result {
	stdout, ok, stderr := run(c, args)
	if !ok {
		return {done = true, message = failure(args, stdout, stderr)}
	}
	return {done = true, ok = true, message = said != "" ? said : first_line(stdout)}
}
