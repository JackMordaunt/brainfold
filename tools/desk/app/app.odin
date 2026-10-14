/*
Package app is the desk's host: the pipeline that answers the ui's needs
by asking the brain CLI, and carries out its commands. It never imports
the view; app_test.odin drives it with a ui.Probe and canned CLI answers.

	needs (log, ledger, doctor, inbox, vault) ─────────┐
	needs (recall) ─ debounce(250 ms) ──────────────────┼─ async_map(cli.read, 4) ─ deliver
	interval(5 s) ─┬─ refresh: every live need again,  ┘
	               │  doctor aside
	changed ───────┘
	commands ─ async_map(cli.act, 1) ─ settle ─ the outcome, and changed
	                                          (Run_Doctor, an alias edit: the report too)

A need is read as soon as it appears, a recall once its terms have been
still for a moment: each key typed is a new need, and only the last is
run. Every five
seconds, and after every command, each live need is read again, so the
desk follows what agents do to the vault while it is open; an answer the
same as the last one delivered for its need is not delivered again, so a
quiet vault costs the ui no frames. An answer for a need the ui has
stopped asking for is dropped at the door. Commands run one at a time, in
order.
*/
package desk_app

import "core:encoding/cbor"
import "core:hash"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "jm:stream"
import "jm:ui"

import "../../../msg"
import "../cli"
import "../shapes"

QUIET :: 250 * time.Millisecond // a recall's terms are still for this long before it runs
POLL :: 5 * time.Second // how often every live need is read again
WORKERS :: 4
MAX_TERMS :: 2048 // the longest recall terms, turn id or bullet line a need carries

Kind :: enum u8 {
	Log,
	Ledger,
	Doctor,
	Recall,
	Around,
	Inbox,
	Vault,
	Bullets,
	Check,
	Plan,
	Show,
	Spend,
	Imports,
	Review,
	Setup,
	Find,
}

// Read is one need to answer: what to ask, under which key. A recall's
// terms, or a turn's id, are held in the value, so a Read crosses threads
// by copy.
Read :: struct {
	key:       ui.Need_Key,
	kind:      Kind,
	terms:     [MAX_TERMS]u8,
	terms_len: int,
	limit:     int,
}

// Read_Done is an answer: the result's cbor bytes, the host's to free.
Read_Done :: struct {
	key:  ui.Need_Key,
	kind: Kind,
	data: []byte,
}

// Act is a command on its way: its strings are the host's, freed once it
// has run.
Act :: struct {
	cmd: shapes.Command,
}

Act_Done :: struct {
	act:     Act,
	outcome: shapes.Outcome_Result,
	doctor:  []byte, // a Run_Doctor's report, the host's to free
}

// Refresh asks for every live need to be read again.
Refresh :: struct {}

Host :: struct {
	p:         ^stream.Pipeline,
	direct:    stream.Port(Read),
	typed:     stream.Port(Read),
	commands:  stream.Port(Act),
	changed:   stream.Port(Refresh),
	inbox:     ui.Inbox,
	workers:   ^stream.Workers,
	client:    cli.Client,
	mutex:     sync.Mutex,
	live:      map[ui.Need_Key]Read, // under mutex: the needs open now
	sent:      map[ui.Need_Key]u64, // under mutex: a hash of what each was last given
	pending:   int, // under mutex: reads and commands not yet delivered
	waiting:   [Kind]int, // under mutex: typed needs held in the quiet, of which each kind's last will run
	reads:     [dynamic]Read, // refresh's answer, until the stage has emitted it
	findings:  Findings, // under mutex: the last doctor report's counts, to say what a run changed
	reported:  bool, // under mutex: findings holds a report
	pool:      ^thread.Thread,
	wake:      proc(),
	allocator: mem.Allocator,
}

// init builds the pipeline and starts its threads. client says how the
// CLI is reached; wake is called from a pipeline thread whenever a shape
// is in the inbox.
init :: proc(h: ^Host, client: cli.Client, wake: proc() = nil, poll := POLL) {
	h.client = client
	h.wake = wake
	h.allocator = context.allocator
	ui.inbox_init(&h.inbox, h.allocator)
	h.live = make(map[ui.Need_Key]Read, h.allocator)
	h.sent = make(map[ui.Need_Key]u64, h.allocator)
	h.reads = make([dynamic]Read, h.allocator)
	h.workers = stream.workers_start(WORKERS, h.allocator)

	p := stream.make_pipeline(h.allocator, cap = 64)
	h.p = p
	direct, typed: stream.Stream(Read)
	direct, h.direct = stream.port(p, Read, cap = 64, name = "needs")
	typed, h.typed = stream.port(p, Read, cap = 64, name = "recalls")
	commands: stream.Stream(Act)
	commands, h.commands = stream.port(p, Act, cap = 64, name = "commands")
	changed: stream.Stream(Refresh)
	changed, h.changed = stream.port(p, Refresh, cap = 4, name = "changed")

	ticks := stream.transform(stream.interval(p, poll, name = "poll"), tick)
	again := stream.flat_map_with(stream.merge([]stream.Stream(Refresh){ticks, changed}, name = "refresh in"), h, refresh, name = "refresh")
	// One key for every recall: a search typed a key at a time is a new
	// need per key, and only the last is worth running.
	settled := stream.transform_with(stream.debounce_by(typed, QUIET, recall_key, name = "quiet"), h, released, name = "released")
	reads := stream.merge([]stream.Stream(Read){direct, settled, again}, name = "reads")
	answers := stream.async_map(reads, h.workers, h, read_one, concurrency = WORKERS, ordered = false, name = "cli read")
	stream.for_each_with(answers, h, deliver, name = "deliver")

	acted := stream.async_map(commands, h.workers, h, act_one, concurrency = 1, ordered = true, name = "cli act")
	stream.for_each_with(acted, h, settle, name = "settle")

	h.pool = thread.create_and_start_with_poly_data(h, pool_main)
}

// data_host is what a frame loop takes: the callbacks and the inbox.
data_host :: proc(h: ^Host) -> ui.Data_Host {
	return {user = h, on_need = on_need, on_command = on_command, inbox = &h.inbox}
}

stop :: proc(h: ^Host) {
	stream.stop(h.p)
	thread.join(h.pool)
	thread.destroy(h.pool)
	stream.workers_stop(h.workers)
	stream.destroy(h.p)
	delete(h.live)
	delete(h.sent)
	delete(h.reads)
	ui.inbox_destroy(&h.inbox)
}

// idle is whether nothing is being read or done and the inbox is empty,
// for a test or a headless render to wait on.
idle :: proc(h: ^Host) -> bool {
	sync.mutex_lock(&h.mutex)
	n := h.pending
	for w in h.waiting {
		n += w
	}
	sync.mutex_unlock(&h.mutex)
	return n == 0 && !ui.inbox_pending(&h.inbox)
}

// --- the main thread ---------------------------------------------------------

// on_need reads a need that appeared and forgets one that went. An
// Outcome is not read: settle answers it when its command is done.
on_need :: proc(user: rawptr, need: ui.Need, added: bool) {
	h := (^Host)(user)
	r, ok := read_of(need)
	if !ok {
		return
	}
	sync.mutex_lock(&h.mutex)
	if !added {
		delete_key(&h.live, need.key)
		delete_key(&h.sent, need.key)
		sync.mutex_unlock(&h.mutex)
		return
	}
	h.live[need.key] = r
	// A need that appears has no answer where it appeared, whatever this
	// host last sent for its key: a hot-reloaded child asks again for
	// what the one before it was given.
	delete_key(&h.sent, need.key)
	if typed(r.kind) {
		h.waiting[r.kind] += 1
	} else {
		h.pending += 1
	}
	sync.mutex_unlock(&h.mutex)
	// Sent with the lock released: a full port waits on the pool, and a
	// pool thread delivering waits on the lock.
	stream.port_send(typed(r.kind) ? h.typed : h.direct, r)
}

// read_of is the Read a need asks for, if the CLI answers it.
read_of :: proc(need: ui.Need) -> (r: Read, ok: bool) {
	r.key = need.key
	switch {
	case ui.need_is(need, shapes.Log):
		r.kind = .Log
	case ui.need_is(need, shapes.Ledger):
		r.kind = .Ledger
	case ui.need_is(need, shapes.Doctor):
		r.kind = .Doctor
	case ui.need_is(need, shapes.Inbox):
		r.kind = .Inbox
	case ui.need_is(need, shapes.Vault):
		r.kind = .Vault
	case ui.need_is(need, shapes.Bullets):
		r.kind = .Bullets
	case ui.need_is(need, shapes.Install_Plan):
		q, qok := ui.need_as(need, shapes.Install_Plan)
		if !qok {
			return {}, false
		}
		r.kind = .Plan
		r.terms_len = copy(r.terms[:], q.path)
	case ui.need_is(need, shapes.Bullet_Check):
		q, qok := ui.need_as(need, shapes.Bullet_Check)
		if !qok {
			return {}, false
		}
		r.kind = .Check
		r.terms_len = copy(r.terms[:], q.line)
	case ui.need_is(need, shapes.Setup):
		r.kind = .Setup
	case ui.need_is(need, shapes.Find):
		q, qok := ui.need_as(need, shapes.Find)
		if !qok {
			return {}, false
		}
		r.kind = .Find
		r.terms_len = copy(r.terms[:], q.terms)
	case ui.need_is(need, shapes.Inbox_Review):
		q, qok := ui.need_as(need, shapes.Inbox_Review)
		if !qok {
			return {}, false
		}
		r.kind = .Review
		r.terms_len = copy(r.terms[:], q.handle)
	case ui.need_is(need, shapes.Import_Sources):
		r.kind = .Imports
	case ui.need_is(need, shapes.Spend):
		q, qok := ui.need_as(need, shapes.Spend)
		if !qok {
			return {}, false
		}
		r.kind = .Spend
		r.limit = q.days
	case ui.need_is(need, shapes.Bullet_Show):
		q, qok := ui.need_as(need, shapes.Bullet_Show)
		if !qok {
			return {}, false
		}
		r.kind = .Show
		// One buffer holds both: the place, a separator no path or handle
		// has, the handle.
		r.terms_len = copy(r.terms[:], strings.concatenate({q.at, "\x1f", q.handle}, context.temp_allocator))
	case ui.need_is(need, shapes.Around):
		q, qok := ui.need_as(need, shapes.Around)
		if !qok {
			return {}, false
		}
		r.kind = .Around
		r.terms_len = copy(r.terms[:], q.id)
	case ui.need_is(need, shapes.Recall):
		q, qok := ui.need_as(need, shapes.Recall)
		if !qok {
			return {}, false
		}
		r.kind = .Recall
		r.terms_len = copy(r.terms[:], q.terms)
		r.limit = q.limit
	case:
		return {}, false
	}
	return r, true
}

// on_command sends a command on with its strings copied out of the
// frame's memory.
on_command :: proc(user: rawptr, c: ui.Command) {
	h := (^Host)(user)
	cmd, ok := ui.command_as(c, shapes.Command)
	if !ok {
		return
	}
	cmd = clone_command(cmd, h.allocator)
	sync.mutex_lock(&h.mutex)
	h.pending += 1
	sync.mutex_unlock(&h.mutex)
	stream.port_send(h.commands, Act{cmd})
}

@(private)
clone_command :: proc(c: shapes.Command, allocator: mem.Allocator) -> shapes.Command {
	switch v in c {
	case shapes.Approve:
		return shapes.Approve{v.id, clone_strings(v.handles, allocator), strings.clone(v.to, allocator)}
	case shapes.Drop:
		return shapes.Drop{v.id, clone_strings(v.handles, allocator)}
	case shapes.Set_Review:
		return shapes.Set_Review{v.id, strings.clone(v.mode, allocator)}
	case shapes.Add_Alias:
		return shapes.Add_Alias{v.id, strings.clone(v.handle, allocator), strings.clone(v.term, allocator)}
	case shapes.Remove_Alias:
		return shapes.Remove_Alias{v.id, strings.clone(v.handle, allocator), strings.clone(v.term, allocator)}
	case shapes.Write_Bullet:
		return shapes.Write_Bullet{v.id, strings.clone(v.line, allocator), strings.clone(v.to, allocator)}
	case shapes.Replace_Bullet:
		return shapes.Replace_Bullet{v.id, strings.clone(v.handle, allocator), strings.clone(v.line, allocator), strings.clone(v.at, allocator)}
	case shapes.Drop_Bullet:
		return shapes.Drop_Bullet{v.id, strings.clone(v.handle, allocator), strings.clone(v.at, allocator)}
	case shapes.Touch_Bullet:
		return shapes.Touch_Bullet{v.id, strings.clone(v.handle, allocator), strings.clone(v.at, allocator)}
	case shapes.Import:
		return shapes.Import{v.id, clone_strings(v.paths, allocator)}
	case shapes.Connect:
		return shapes.Connect{v.id, strings.clone(v.agent, allocator)}
	case shapes.New_Vault:
		return shapes.New_Vault{v.id, strings.clone(v.path, allocator)}
	case shapes.Merge:
		return shapes.Merge{v.id, strings.clone(v.proposal, allocator), strings.clone(v.into, allocator), strings.clone(v.at, allocator), strings.clone(v.line, allocator)}
	case shapes.Set_Price:
		return shapes.Set_Price{v.id, strings.clone(v.prefix, allocator), strings.clone(v.input, allocator), strings.clone(v.output, allocator)}
	case shapes.Unlink:
		return shapes.Unlink{v.id, strings.clone(v.file, allocator), v.line, strings.clone(v.target, allocator)}
	case shapes.Set_Vault:
		return shapes.Set_Vault{v.id, strings.clone(v.path, allocator)}
	case shapes.Sync_Now, shapes.Reindex, shapes.Run_Doctor:
		return c
	}
	return c
}

@(private)
clone_strings :: proc(ss: []string, allocator: mem.Allocator) -> []string {
	out := make([]string, len(ss), allocator)
	for x, i in ss {
		out[i] = strings.clone(x, allocator)
	}
	return out
}

@(private)
free_strings :: proc(ss: []string, allocator: mem.Allocator) {
	for x in ss {
		delete(x, allocator)
	}
	delete(ss, allocator)
}

@(private)
free_command :: proc(c: shapes.Command, allocator: mem.Allocator) {
	#partial switch v in c {
	case shapes.Approve:
		free_strings(v.handles, allocator)
		delete(v.to, allocator)
	case shapes.Drop:
		free_strings(v.handles, allocator)
	case shapes.Set_Review:
		delete(v.mode, allocator)
	case shapes.Add_Alias:
		delete(v.handle, allocator)
		delete(v.term, allocator)
	case shapes.Remove_Alias:
		delete(v.handle, allocator)
		delete(v.term, allocator)
	case shapes.Write_Bullet:
		delete(v.line, allocator)
		delete(v.to, allocator)
	case shapes.Replace_Bullet:
		delete(v.handle, allocator)
		delete(v.line, allocator)
		delete(v.at, allocator)
	case shapes.Drop_Bullet:
		delete(v.handle, allocator)
		delete(v.at, allocator)
	case shapes.Touch_Bullet:
		delete(v.handle, allocator)
		delete(v.at, allocator)
	case shapes.Import:
		free_strings(v.paths, allocator)
	case shapes.Connect:
		delete(v.agent, allocator)
	case shapes.New_Vault:
		delete(v.path, allocator)
	case shapes.Merge:
		delete(v.proposal, allocator)
		delete(v.into, allocator)
		delete(v.at, allocator)
		delete(v.line, allocator)
	case shapes.Set_Price:
		delete(v.prefix, allocator)
		delete(v.input, allocator)
		delete(v.output, allocator)
	case shapes.Unlink:
		delete(v.file, allocator)
		delete(v.target, allocator)
	case shapes.Set_Vault:
		delete(v.path, allocator)
	}
}

// --- the pipeline -------------------------------------------------------------

// typed is whether a kind of need is asked a key at a time, and so waits
// out a quiet before it runs.
typed :: proc(k: Kind) -> bool {
	return k == .Recall || k == .Check || k == .Plan || k == .Find
}

// recall_key collapses a kind's typed needs to the last: a search or a
// bullet being written, each on its own.
recall_key :: proc(r: Read) -> int {
	return int(r.kind)
}

// released is the typed need that outlasted the quiet: the ones it
// replaced will never run.
released :: proc(h: ^Host, r: Read) -> Read {
	sync.mutex_lock(&h.mutex)
	h.waiting[r.kind] = 0
	h.pending += 1
	sync.mutex_unlock(&h.mutex)
	return r
}

tick :: proc(_: time.Duration) -> Refresh {
	return {}
}

// refresh is a read for every live need but a recall, whose answer does
// not move under it, and doctor and spend, which take a second or more:
// doctor runs when the person asks (Run_Doctor), spend when its page
// opens or a price is set. The slice lives until the next call.
refresh :: proc(h: ^Host, _: Refresh) -> []Read {
	clear(&h.reads)
	sync.mutex_lock(&h.mutex)
	for _, r in h.live {
		if r.kind != .Recall && r.kind != .Around && r.kind != .Doctor && r.kind != .Check && r.kind != .Plan && r.kind != .Spend && r.kind != .Imports && r.kind != .Review && r.kind != .Setup && r.kind != .Find {
			append(&h.reads, r)
			h.pending += 1
		}
	}
	sync.mutex_unlock(&h.mutex)
	return h.reads[:]
}

// read_one runs on a worker: the CLI call for one need.
read_one :: proc(h: ^Host, r: Read) -> Read_Done {
	q: cli.Query
	switch r.kind {
	case .Log:
		q = shapes.Log{}
	case .Ledger:
		q = shapes.Ledger{}
	case .Doctor:
		q = shapes.Doctor{}
	case .Inbox:
		q = shapes.Inbox{}
	case .Vault:
		q = shapes.Vault{}
	case .Recall:
		terms := r.terms
		q = shapes.Recall{terms = string(terms[:r.terms_len]), limit = r.limit}
	case .Around:
		id := r.terms
		q = shapes.Around{id = string(id[:r.terms_len])}
	case .Bullets:
		q = shapes.Bullets{}
	case .Check:
		line := r.terms
		q = shapes.Bullet_Check{line = string(line[:r.terms_len])}
	case .Plan:
		path := r.terms
		q = shapes.Install_Plan{path = string(path[:r.terms_len])}
	case .Spend:
		q = shapes.Spend{days = r.limit}
	case .Imports:
		q = shapes.Import_Sources{}
	case .Setup:
		q = shapes.Setup{}
	case .Find:
		terms := r.terms
		q = shapes.Find{terms = string(terms[:r.terms_len])}
	case .Review:
		handle := r.terms
		q = shapes.Inbox_Review{handle = string(handle[:r.terms_len])}
	case .Show:
		both := r.terms
		at, _, handle := strings.partition(string(both[:r.terms_len]), "\x1f")
		q = shapes.Bullet_Show{handle = handle, at = at}
	}
	return {r.key, r.kind, cli.read(&h.client, q, h.allocator)}
}

// deliver, on a pool thread, hands an answer to the ui unless its need
// has gone or it says what the last one said.
deliver :: proc(h: ^Host, d: Read_Done) {
	defer delete(d.data, h.allocator)
	sum := hash.fnv64a(d.data)
	// Pending until the answer is in the inbox: a host that counts none
	// pending has delivered everything it read.
	defer {
		sync.mutex_lock(&h.mutex)
		h.pending -= 1
		sync.mutex_unlock(&h.mutex)
	}
	sync.mutex_lock(&h.mutex)
	_, live := h.live[d.key]
	last, sent := h.sent[d.key]
	fresh := live && d.data != nil && !(sent && last == sum)
	if fresh {
		h.sent[d.key] = sum
	}
	if d.kind == .Doctor {
		if f, ok := findings_of(d.data); ok {
			h.findings, h.reported = f, true
		}
	}
	sync.mutex_unlock(&h.mutex)
	if !fresh {
		return
	}
	ui.inbox_put(&h.inbox, d.key, d.data)
	if h.wake != nil {
		h.wake()
	}
}

// act_one runs on a worker: the CLI calls for one command.
act_one :: proc(h: ^Host, a: Act) -> Act_Done {
	msg.refresh()
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	if _, ok := a.cmd.(shapes.Run_Doctor); ok {
		return run_doctor(h, a, mem.dynamic_arena_allocator(&arena))
	}
	o := cli.act(&h.client, a.cmd, mem.dynamic_arena_allocator(&arena))
	// An edit changes what doctor finds: while the report is shown, it is
	// made again, so the page shows the vault as the edit left it and
	// a fixed finding leaves its list.
	#partial switch _ in a.cmd {
	case shapes.Approve, shapes.Drop, shapes.Merge, shapes.Add_Alias, shapes.Remove_Alias, shapes.Write_Bullet, shapes.Replace_Bullet, shapes.Drop_Bullet, shapes.Touch_Bullet, shapes.Unlink:
		if o.ok && doctor_shown(h) {
			d := run_doctor(h, a, mem.dynamic_arena_allocator(&arena))
			delete(d.outcome.message, h.allocator)
			return {act = a, outcome = {done = true, ok = true, message = strings.clone(o.message, h.allocator)}, doctor = d.doctor}
		}
	}
	o.message = strings.clone(o.message, h.allocator)
	return {act = a, outcome = o}
}

// doctor_shown is whether the view needs the doctor report now.
doctor_shown :: proc(h: ^Host) -> bool {
	// The key is made in a buffer here: a worker's own temp allocator is
	// never freed.
	buf: [1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	sync.mutex_lock(&h.mutex)
	defer sync.mutex_unlock(&h.mutex)
	return ui.key_of(shapes.Doctor{}) in h.live
}

// settle, on a pool thread, answers the command's Outcome and has every
// live need read again, since the vault may have moved.
settle :: proc(h: ^Host, a: Act_Done) {
	buf: [4096]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	context.temp_allocator = mem.arena_allocator(&arena)
	if a.doctor != nil {
		key := ui.key_of(shapes.Doctor{})
		sync.mutex_lock(&h.mutex)
		h.sent[key] = hash.fnv64a(a.doctor)
		sync.mutex_unlock(&h.mutex)
		ui.inbox_put(&h.inbox, key, a.doctor)
		delete(a.doctor, h.allocator)
	}
	ui.inbox_put_value(&h.inbox, shapes.Outcome{id = shapes.command_id(a.act.cmd)}, a.outcome)
	delete(a.outcome.message, h.allocator)
	free_command(a.act.cmd, h.allocator)
	sync.mutex_lock(&h.mutex)
	h.pending -= 1
	sync.mutex_unlock(&h.mutex)
	// A full port has a refresh waiting already.
	stream.port_push(h.changed, Refresh{})
	if h.wake != nil {
		h.wake()
	}
}

// --- doctor runs ----------------------------------------------------------------

// Finding_Kind is one of doctor's lists, as a run's summary names it.
Finding_Kind :: enum u8 {
	Failed_Claim,
	Stale,
	Dead_Link,
	Duplicate_Handle,
	Thin_Aliases,
	Oversized,
	Orphaned_Note,
	Worth_Promoting,
	Never_Returned,
}

// KIND_MSG is each kind's noun, in the form the count's plural rule picks.
KIND_MSG := [Finding_Kind]msg.Msg {
	.Failed_Claim     = .Name_Failed,
	.Stale            = .Name_Stale,
	.Dead_Link        = .Name_Link,
	.Duplicate_Handle = .Name_Dupe,
	.Thin_Aliases     = .Name_Thin,
	.Oversized        = .Name_Over,
	.Orphaned_Note    = .Name_Orphan,
	.Worth_Promoting  = .Name_Promote,
	.Never_Returned   = .Name_Never,
}

Findings :: [Finding_Kind]int

findings_of :: proc(data: []byte) -> (f: Findings, ok: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	al := mem.dynamic_arena_allocator(&arena)
	d: shapes.Doctor_Result
	if cbor.unmarshal_from_bytes(data, &d, allocator = al, temp_allocator = al) != nil || d.error != "" {
		return {}, false
	}
	return counts(d), true
}

counts :: proc(d: shapes.Doctor_Result) -> Findings {
	return {
		.Failed_Claim = len(d.failed_claims),
		.Stale = len(d.stale),
		.Dead_Link = len(d.dead_links),
		.Duplicate_Handle = len(d.duplicate_handles),
		.Thin_Aliases = len(d.thin_aliases),
		.Oversized = len(d.oversized),
		.Orphaned_Note = len(d.orphan_artifacts),
		.Worth_Promoting = len(d.promote),
		.Never_Returned = len(d.never_returned),
	}
}

// summarise says what a report changed against the one before it: each
// list that moved, most urgent first, or that nothing did.
summarise :: proc(before: Findings, had: bool, now: Findings, allocator := context.allocator) -> string {
	total := 0
	for n in now {
		total += n
	}
	if !had {
		return msg.textf(.Doctor_Found, total, allocator = allocator)
	}
	b := strings.builder_make(allocator)
	for k in Finding_Kind {
		diff := now[k] - before[k]
		if diff == 0 {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_string(&b, ", ")
		}
		n := abs(diff)
		noun := msg.text_form(KIND_MSG[k], n)
		clause := msg.textf(diff > 0 ? .Count_New : .Count_Fewer, n, noun, allocator = allocator)
		strings.write_string(&b, clause)
	}
	if strings.builder_len(b) == 0 {
		return msg.textf(.Doctor_Same, total, allocator = allocator)
	}
	return msg.textf(.Doctor_Since, strings.to_string(b), allocator = allocator)
}

// run_doctor makes a fresh report and says what changed since the last.
run_doctor :: proc(h: ^Host, a: Act, allocator: mem.Allocator) -> Act_Done {
	context.allocator = allocator
	r := cli.doctor(&h.client)
	if r.error != "" {
		return {act = a, outcome = {done = true, message = strings.clone(r.error, h.allocator)}}
	}
	now := counts(r)
	sync.mutex_lock(&h.mutex)
	before, had := h.findings, h.reported
	h.findings, h.reported = now, true
	sync.mutex_unlock(&h.mutex)
	r.summary = summarise(before, had, now)
	data, err := cbor.marshal_into_bytes(r, allocator = h.allocator, temp_allocator = allocator)
	if err != nil {
		return {act = a, outcome = {done = true, message = strings.clone(msg.text(.Report_Unreadable), h.allocator)}}
	}
	return {act = a, outcome = {done = true, ok = true, message = strings.clone(r.summary, h.allocator)}, doctor = data}
}

pool_main :: proc(h: ^Host) {
	stream.run(h.p, 2)
}
