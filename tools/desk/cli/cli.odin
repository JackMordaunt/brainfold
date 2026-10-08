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

import "jm:sh"

import "../shapes"

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
		return "", false, fmt.aprintf("%s could not be run: %v", argv[0], r.err, allocator = allocator)
	}
	if r.timed_out {
		return r.stdout, false, fmt.aprintf("%s took longer than %v", argv[0], TIMEOUT, allocator = allocator)
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
	case shapes.Inbox_Review:
		r: shapes.Inbox_Review_Result
		if q.handle != "" {
			n, err := place_of(c, q.handle)
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
		return fmt.aprintf("brain %s answered what the desk cannot read: %v", args[0], err)
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
	return fmt.aprintf("brain %s failed", strings.join(args, " "))
}

@(private)
first_line :: proc(text: string) -> string {
	s := strings.trim_space(text)
	line, _, _ := strings.partition(s, "\n")
	return strings.trim_space(line)
}

// act carries out a command and says how it went, everything in allocator.
act :: proc(c: ^Client, cmd: shapes.Command, allocator := context.allocator) -> (o: shapes.Outcome_Result) {
	context.allocator = allocator
	o.done = true
	switch v in cmd {
	case shapes.Approve:
		return settle_proposals(c, v.handles, "approve", v.to)
	case shapes.Drop:
		return settle_proposals(c, v.handles, "drop", "")
	case shapes.Sync_Now:
		o = step(c, {"sync"}, "")
		if o.ok && o.message == "" {
			o.message = "In sync"
		}
		return
	case shapes.Reindex:
		return step(c, {"reindex"}, "Index rebuilt from the markdown")
	case shapes.Run_Doctor:
		// The host runs it, since its answer is a report, not a message.
		return {done = true, message = "Doctor runs in the host"}
	case shapes.Add_Alias:
		return step(c, {"alias", "add", v.handle, v.term}, fmt.aprintf("%s is also found as \"%s\" now", v.handle, v.term))
	case shapes.Remove_Alias:
		return step(c, {"alias", "remove", v.handle, v.term}, fmt.aprintf("\"%s\" no longer finds %s", v.term, v.handle))
	case shapes.Set_Vault:
		path := strings.trim_space(v.path)
		return step(c, {"install", path}, fmt.aprintf("This machine uses the vault at %s", path))
	case shapes.Write_Bullet:
		to := v.to != "" ? v.to : "MEMORY"
		return edit(c, {"--json", "bullet", "write", v.line, "--to", to}, "Written")
	case shapes.Replace_Bullet:
		return edit(c, at_args({"--json", "bullet", "replace", v.handle, v.line}, v.at), "Saved")
	case shapes.Drop_Bullet:
		return edit(c, at_args({"--json", "bullet", "drop", v.handle}, v.at), "Dropped")
	case shapes.Touch_Bullet:
		return edit(c, at_args({"--json", "bullet", "touch", v.handle}, v.at), "Dated today:")
	case shapes.Import:
		return import_sources(c, v.paths)
	case shapes.Merge:
		n, err := place_of(c, v.proposal)
		if err != "" {
			return {done = true, message = err}
		}
		return edit(c, at_args({"--json", "inbox", "merge", fmt.aprint(n), "--into", v.into, v.line}, v.at), "Merged into")
	case shapes.Set_Price:
		return step(c, {"spend", "--price", v.prefix, v.input, v.output}, fmt.aprintf("%s priced at $%s in, $%s out a million tokens", v.prefix, v.input, v.output))
	case shapes.Unlink:
		return step(c, {"unlink", v.file, fmt.aprint(v.line), v.target}, fmt.aprintf("[[%s]] is plain text now in %s", v.target, v.file))
	case shapes.Set_Review:
		if v.mode != "after" && v.mode != "before" {
			return {done = true, message = fmt.aprintf("No review mode %q", v.mode)}
		}
		said := v.mode == "after" ? "Proposals answer finds at once, marked unreviewed" : "Proposals answer finds only once approved"
		return step(c, {"review", v.mode}, said)
	}
	return {done = true, message = "Nothing to do"}
}

// settle_proposals approves or drops every proposal named, in order, each found
// afresh, and says how it went: the first failure, if any, and how many
// of the rest were done.
@(private)
settle_proposals :: proc(c: ^Client, handles: []string, verb, to: string) -> shapes.Outcome_Result {
	done_word := verb == "approve" ? "Approved" : "Dropped"
	done := 0
	first := ""
	for h in handles {
		n, err := place_of(c, h)
		if err == "" {
			args := make([dynamic]string)
			append(&args, "inbox", verb, fmt.aprint(n))
			if to != "" {
				append(&args, "--to", to)
			}
			o := step(c, args[:], "")
			if o.ok {
				done += 1
				continue
			}
			err = o.message
		}
		if first == "" {
			first = err
		}
	}
	switch {
	case len(handles) == 0:
		return {done = true, message = "Nothing selected"}
	case done == len(handles) && done == 1:
		return {done = true, ok = true, message = fmt.aprintf("%s %s", done_word, handles[0])}
	case done == len(handles):
		return {done = true, ok = true, message = fmt.aprintf("%s %d proposals", done_word, done)}
	case len(handles) == 1:
		return {done = true, message = first}
	}
	return {done = true, message = fmt.aprintf("%s %d of %d; %s", done_word, done, len(handles), first)}
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
		return {done = true, message = fmt.aprintf("Not written: %s", strings.join(r.errors, "; "))}
	}
	if r.file != "" {
		return {done = true, ok = true, message = fmt.aprintf("%s %s at %s:%d", done, r.handle, r.file, r.line)}
	}
	return {done = true, ok = true, message = fmt.aprintf("%s %s", done, r.handle)}
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
		return {done = true, ok = true, message = fmt.aprintf("Nothing new in %d memories: the vault has them already", memories)}
	case proposed == 1:
		return {done = true, ok = true, message = "1 memory proposed; it waits in the inbox"}
	}
	return {done = true, ok = true, message = fmt.aprintf("%d memories proposed; they wait in the inbox", proposed)}
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
@(private)
place_of :: proc(c: ^Client, handle: string) -> (n: int, err: string) {
	in_: shapes.Inbox_Result
	if e := call(c, {"inbox", "--json"}, &in_); e != "" {
		return 0, e
	}
	for p in in_.proposals {
		if p.handle == handle {
			return p.n, ""
		}
	}
	return 0, fmt.aprintf("%s is no longer in the inbox", handle)
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
