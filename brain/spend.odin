package brain

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// `brain spend` is what the agents on this machine cost, read from their own
// transcripts, and what the vault did to it:
//
//	brain spend [--days N]
//	brain spend --price <model prefix> <input> <output>   set a model's dollars per million tokens
//
// Spend is every model reply's tokens, priced: at the cost the agent wrote
// down when it wrote one (pi), else at list prices (PRICES, overridden per
// model by the lines of ~/.config/brain/prices.tsv: a model id prefix, then
// dollars per million input and output tokens). A reply on a model with no
// price is counted in tokens and left out of the dollars.
//
// The vault's part is measured where it can be. What it cost is the
// tokens it served. What it saved is observed, not proven: after each
// explicit `brain find` an agent ran, the replies up to the person's next
// message are what the agent spent finishing its answer; the median of
// those after a find that answered, against one that missed, times the
// finds that answered, is what answering saved, once there are
// LOOKUP_MIN of each. The proof suite (tools/proof) is the controlled test.

SPEND_DAYS :: 30
LOOKUP_MIN :: 5 // finds of each kind, hit and miss, before a saving is claimed

// Price is a model's list price, in dollars per million tokens. A cache
// write costs 1.25 times input for five minutes and twice input for an
// hour; a cache read a tenth of input (anthropic.com/pricing, prompt
// caching, as known in 2026-06).
Price :: struct {
	prefix:        string,
	input, output: f64,
}

// PRICES are Anthropic's list prices by model id prefix, from
// anthropic.com/pricing as known in 2026-06; the longest prefix that
// matches wins. The Claude 5 family is ASSUMED to keep its family's 4.5
// prices until prices.tsv says otherwise.
PRICES :: [?]Price {
	{"claude-3-opus", 15, 75},
	{"claude-3-5-haiku", 0.8, 4},
	{"claude-3-haiku", 0.25, 1.25},
	{"claude-opus-4-1", 15, 75},
	{"claude-opus-4-2025", 15, 75},
	{"claude-opus", 5, 25},
	{"claude-sonnet", 3, 15},
	{"claude-3-5-sonnet", 3, 15},
	{"claude-3-7-sonnet", 3, 15},
	{"claude-haiku", 1, 5},
}

cmd_spend :: proc(cli: ^Cli, args: []string) -> int {
	usage :: "usage: brain spend [--days N] | --price <model prefix> <input $/Mtok> <output $/Mtok>"
	if len(args) > 0 && args[0] == "--price" {
		if len(args) != 4 {
			return fail(cli, usage)
		}
		if err := set_price(cli, args[1], args[2], args[3]); err != "" {
			return fail(cli, err)
		}
		outf(cli, "%s priced at $%s in, $%s out per million tokens\n", args[1], args[2], args[3])
		return 0
	}
	days := SPEND_DAYS
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--days":
			if i + 1 >= len(args) {
				return fail(cli, usage)
			}
			n, ok := strconv.parse_int(args[i + 1])
			if !ok || n < 1 {
				return fail(cli, usage)
			}
			days = n
			i += 1
		case:
			return fail(cli, usage)
		}
	}
	db, err := open_recall_db(cli)
	if err != "" {
		return fail(cli, err)
	}
	defer sqlite3.close(&db)
	if len(adapters_on(cli)) > 0 {
		recall_sync(cli, db, false)
	}
	if e := sqlite3.exec_args(db, "attach ? as log", cli.log_db); e != nil {
		return fail(cli, sql_err(e))
	}
	sqlite3.exec(db, LOG_SCHEMA)
	s := spend_read(cli, db, days)
	if cli.json {
		spend_json(cli, s)
		return 0
	}
	outf(cli, "last %d days: $%.2f over %d sessions", days, s.cost, s.sessions)
	if s.unpriced > 0 {
		outf(cli, " (%s tokens on models with no price left out)", int_str(s.unpriced))
	}
	outf(cli, "\nthe vault served %s tokens in %d lookups, %d answered\n", int_str(s.served), s.lookups, s.answered)
	l := s.finds
	if l.enough {
		outf(cli, "after a find that answered, an agent spent $%.3f to finish (median of %d); after a miss, $%.3f (%d): about $%.2f saved\n", l.hit_cost, l.hits, l.miss_cost, l.misses, l.saved)
	} else {
		outf(cli, "%d finds answered and %d missed: too few of each (%d) to say what answering saved\n", l.hits, l.misses, LOOKUP_MIN)
	}
	return 0
}

// Spend is brain spend's answer.
Spend :: struct {
	days:            int,
	since:           string,
	cost:            f64, // dollars, the priced replies'
	input, written, read, output: i64, // tokens by kind
	unpriced:        i64, // tokens on models with no price
	replies:         int,
	sessions:        int,
	by_day:          [dynamic]Spend_Row,
	by_agent:        [dynamic]Spend_Row,
	by_model:        [dynamic]Spend_Row,
	served:          i64, // tokens the vault put into sessions
	served_cost:     f64, // those tokens at the most used model's input price
	lookups:         int,
	answered:        int,
	finds:           Finds,
}

// Spend_Row is spend under one name: a day, an agent or a model.
Spend_Row :: struct {
	name:     string,
	cost:     f64,
	tokens:   i64,
	sessions: int,
	priced:   bool, // every reply under it had a price
}

// Finds is the observed effect of an answer: what an agent spent after
// explicit finds that answered and that missed.
Finds :: struct {
	hits, misses:        int,
	hit_cost, miss_cost: f64, // median dollars to finish the reply
	hit_calls, miss_calls: f64, // median tool calls to finish it
	saved:               f64, // dollars, when enough
	enough:              bool,
}

// spend_read reads the last days of usage, and the vault's part in them.
spend_read :: proc(cli: ^Cli, db: sqlite3.Db, days: int) -> (s: Spend) {
	s.days = days
	s.since = scalar_text(db, fmt.tprintf("select date('now','-%d day')", days))
	prices := load_prices(cli)
	day_at := make(map[string]int)
	agent_at := make(map[string]int)
	model_at := make(map[string]int)
	sessions := make(map[string]bool)
	agent_sessions := make(map[string]map[string]bool)
	day_sessions := make(map[string]map[string]bool)
	model_tokens := make(map[string]i64)
	// Claude Code writes a "<synthetic>" reply no model made, costing nothing.
	stmt, err := sqlite3.query(db, "select adapter, session, substr(ts,1,10), model, input, cache_write_5m, cache_write_1h, cache_read, output, cost from usage where ts >= ? and model != '<synthetic>' order by ts", s.since)
	if err != nil {
		return
	}
	defer sqlite3.finish(&stmt)
	for sqlite3.next(&stmt) {
		agent, session, day, model := sqlite3.text(stmt, 0), sqlite3.text(stmt, 1), sqlite3.text(stmt, 2), sqlite3.text(stmt, 3)
		tin, w5, w1, rd, out := sqlite3.integer(stmt, 4), sqlite3.integer(stmt, 5), sqlite3.integer(stmt, 6), sqlite3.integer(stmt, 7), sqlite3.integer(stmt, 8)
		cost, priced := reply_cost(prices[:], model, tin, w5, w1, rd, out)
		if sqlite3.type_of(stmt, 9) != .Null {
			cost, priced = sqlite3.real(stmt, 9), true
		}
		tokens := tin + w5 + w1 + rd + out
		s.replies += 1
		s.input += tin
		s.written += w5 + w1
		s.read += rd
		s.output += out
		if priced {
			s.cost += cost
		} else {
			s.unpriced += tokens
		}
		if priced {
			model_tokens[model] += tin + w5 + w1
		}
		sessions[session] = true
		add_row(&s.by_day, &day_at, &day_sessions, day, session, cost, tokens, priced)
		add_row(&s.by_agent, &agent_at, &agent_sessions, agent, session, cost, tokens, priced)
		add_row(&s.by_model, &model_at, nil, model, session, cost, tokens, priced)
	}
	s.sessions = len(sessions)
	for &r in s.by_day {
		r.sessions = len(day_sessions[r.name])
	}
	for &r in s.by_agent {
		r.sessions = len(agent_sessions[r.name])
	}
	slice.sort_by(s.by_model[:], proc(a, b: Spend_Row) -> bool {return a.cost > b.cost})
	slice.sort_by(s.by_agent[:], proc(a, b: Spend_Row) -> bool {return a.cost > b.cost})

	// What the vault served, pushed (pack, prime) and pulled (find) alike,
	// priced as fresh input to the priced model that read the most.
	s.lookups = scalar_int(db, "select count(*) from log.queries where ts >= ?", s.since)
	s.answered = scalar_int(db, "select count(*) from log.queries where ts >= ? and hits > 0", s.since)
	s.served = i64(scalar_int(db, "select coalesce(sum(bytes),0)/4 from log.queries where ts >= ?", s.since))
	top, most := "", i64(-1)
	for m, n in model_tokens {
		if n > most {
			top, most = m, n
		}
	}
	if p, ok := price_of(prices[:], top); ok {
		s.served_cost = f64(s.served) * p.input / 1e6
	}
	s.finds = finds_read(db, prices[:], s.since)
	return
}

@(private = "file")
add_row :: proc(rows: ^[dynamic]Spend_Row, at: ^map[string]int, seen: ^map[string]map[string]bool, name, session: string, cost: f64, tokens: i64, priced: bool) {
	i, ok := at[name]
	if !ok {
		i = len(rows)
		at[name] = i
		append(rows, Spend_Row{name = name, priced = true})
	}
	r := &rows[i]
	if priced {
		r.cost += cost
	} else {
		r.priced = false
	}
	r.tokens += tokens
	if seen != nil {
		if seen[name] == nil {
			seen[name] = make(map[string]bool)
		}
		inner := &seen[name]
		inner[session] = true
	}
}

// reply_cost is one reply's dollars at list price, and whether its model
// has one.
reply_cost :: proc(prices: []Price, model: string, tin, w5, w1, rd, out: i64) -> (f64, bool) {
	p, ok := price_of(prices, model)
	if !ok {
		return 0, false
	}
	m := f64(1e6)
	return (f64(tin) * p.input + f64(w5) * p.input * 1.25 + f64(w1) * p.input * 2 + f64(rd) * p.input * 0.1 + f64(out) * p.output) / m, true
}

// price_of is the price whose prefix is the longest that model starts with.
price_of :: proc(prices: []Price, model: string) -> (best: Price, ok: bool) {
	for p in prices {
		if strings.has_prefix(model, p.prefix) && len(p.prefix) > len(best.prefix) {
			best, ok = p, true
		}
	}
	return
}

// load_prices is PRICES with prices.tsv's lines after them; an override's
// prefix, as long as the one it replaces, wins by coming later.
load_prices :: proc(cli: ^Cli) -> [dynamic]Price {
	out := make([dynamic]Price)
	user := make([dynamic]Price)
	text, _ := read_text(path.join(cli.conf_dir, "prices.tsv"))
	for line in strings.split_lines(text) {
		f := strings.fields(line)
		if len(f) != 3 || strings.has_prefix(f[0], "#") {
			continue
		}
		tin, iok := strconv.parse_f64(f[1])
		o, ook := strconv.parse_f64(f[2])
		if iok && ook {
			append(&user, Price{f[0], tin, o})
		}
	}
	for p in PRICES {
		overridden := false
		for u in user {
			overridden ||= u.prefix == p.prefix
		}
		if !overridden {
			append(&out, p)
		}
	}
	append(&out, ..user[:])
	return out
}

// set_price writes a model's price into prices.tsv, in place of any it
// had there.
set_price :: proc(cli: ^Cli, prefix, input, output: string) -> string {
	tin, iok := strconv.parse_f64(input)
	out, ook := strconv.parse_f64(output)
	if prefix == "" || strings.contains_any(prefix, " \t") || !iok || !ook || tin < 0 || out < 0 {
		return "a price is a model id prefix and two non-negative dollar amounts per million tokens"
	}
	file := path.join(cli.conf_dir, "prices.tsv")
	text, _ := read_text(file)
	lines := make([dynamic]string)
	for line in strings.split_lines(text) {
		f := strings.fields(line)
		if line == "" || (len(f) > 0 && f[0] == prefix) {
			continue
		}
		append(&lines, line)
	}
	append(&lines, fmt.aprintf("%s\t%s\t%s", prefix, input, output))
	append(&lines, "")
	if err := path.mkdirs(cli.conf_dir); err != nil {
		return fmt.aprintf("cannot create %s: %v", cli.conf_dir, err)
	}
	if err := path.write(file, strings.join(lines[:], "\n")); err != nil {
		return fmt.aprintf("cannot write %s: %v", file, err)
	}
	return ""
}

// finds_read is what agents spent after their explicit finds: for each
// `brain find` call in a transcript, the replies of that session from the
// call to the person's next message, split by whether the find answered
// (find_answered).
finds_read :: proc(db: sqlite3.Db, prices: []Price, since: string) -> (f: Finds) {
	hit_cost := make([dynamic]f64)
	miss_cost := make([dynamic]f64)
	hit_calls := make([dynamic]f64)
	miss_calls := make([dynamic]f64)
	calls, err := sqlite3.query(db, "select t.session, t.ts, t.input, r.head from tool t join tool_result r on r.id = t.id where t.ts >= ? and instr(t.input, 'brain find ') > 0 order by t.session, t.ts", since)
	if err != nil {
		return
	}
	defer sqlite3.finish(&calls)
	for sqlite3.next(&calls) {
		session, ts := strings.clone(sqlite3.text(calls, 0)), strings.clone(sqlite3.text(calls, 1))
		terms := find_terms(sqlite3.text(calls, 2))
		if terms == "" {
			continue
		}
		answered, known := find_answered(sqlite3.text(calls, 3), terms)
		if !known {
			continue
		}
		until := scalar_text(db, "select coalesce(min(ts),'9999') from turn where session = ? and role = 'user' and ts > ?", session, ts)
		cost := 0.0
		{
			u, uerr := sqlite3.query(db, "select model, input, cache_write_5m, cache_write_1h, cache_read, output, cost from usage where session = ? and ts > ? and ts < ?", session, ts, until)
			if uerr != nil {
				continue
			}
			for sqlite3.next(&u) {
				c, _ := reply_cost(prices, sqlite3.text(u, 0), sqlite3.integer(u, 1), sqlite3.integer(u, 2), sqlite3.integer(u, 3), sqlite3.integer(u, 4), sqlite3.integer(u, 5))
				if sqlite3.type_of(u, 6) != .Null {
					c = sqlite3.real(u, 6)
				}
				cost += c
			}
			sqlite3.finish(&u)
		}
		n := f64(scalar_int(db, "select count(*) from tool where session = ? and ts > ? and ts < ?", session, ts, until))
		if answered {
			append(&hit_cost, cost)
			append(&hit_calls, n)
		} else {
			append(&miss_cost, cost)
			append(&miss_calls, n)
		}
	}
	f.hits, f.misses = len(hit_cost), len(miss_cost)
	f.hit_cost, f.miss_cost = median(hit_cost[:]), median(miss_cost[:])
	f.hit_calls, f.miss_calls = median(hit_calls[:]), median(miss_calls[:])
	f.enough = f.hits >= LOOKUP_MIN && f.misses >= LOOKUP_MIN
	if f.enough {
		f.saved = max(f.miss_cost - f.hit_cost, 0) * f64(f.hits)
	}
	return
}

// find_answered reads what a find printed: a miss says "nothing in the
// vault for" its terms, a partial answer opens with PARTIAL_HEAD, and
// anything else the find printed is an answer. A call whose output was
// thrown away (a find in a chain printing nothing) is not known.
find_answered :: proc(printed, terms: string) -> (answered, known: bool) {
	if strings.contains(printed, strings.concatenate({"nothing in the vault for: ", terms}, context.temp_allocator)) {
		return false, true
	}
	if strings.contains(printed, PARTIAL_HEAD[:30]) {
		return false, true
	}
	return true, strings.trim_space(printed) != ""
}

// find_terms is the terms of the first `brain find` in a shell command,
// as the log keeps them: flags dropped, up to the end of that command.
find_terms :: proc(command: string) -> string {
	i := strings.index(command, "brain find ")
	if i < 0 {
		return ""
	}
	rest := command[i + len("brain find "):]
	for stop in ([5]string{"|", "&&", ";", "2>", "\n"}) {
		if j := strings.index(rest, stop); j >= 0 {
			rest = rest[:j]
		}
	}
	words := make([dynamic]string)
	for field in strings.fields(rest) {
		w := strings.trim(field, `"'`)
		if w == "" || strings.has_prefix(w, "-") {
			continue
		}
		append(&words, w)
	}
	return strings.join(words[:], " ")
}

// median is the middle of xs, 0 for none.
median :: proc(xs: []f64) -> f64 {
	if len(xs) == 0 {
		return 0
	}
	ys := slice.clone(xs)
	slice.sort(ys)
	n := len(ys)
	if n % 2 == 1 {
		return ys[n / 2]
	}
	return (ys[n / 2 - 1] + ys[n / 2]) / 2
}

@(private = "file")
spend_json :: proc(cli: ^Cli, s: Spend) {
	w := jw_make()
	jw_obj(&w)
	jw_field_int(&w, "days", i64(s.days))
	jw_field(&w, "since", s.since)
	jw_key(&w, "cost")
	jw_f64(&w, s.cost)
	jw_field_int(&w, "input", s.input)
	jw_field_int(&w, "written", s.written)
	jw_field_int(&w, "read", s.read)
	jw_field_int(&w, "output", s.output)
	jw_field_int(&w, "unpriced", s.unpriced)
	jw_field_int(&w, "replies", i64(s.replies))
	jw_field_int(&w, "sessions", i64(s.sessions))
	for set in ([3]struct {
			key:  string,
			rows: []Spend_Row,
		}{{"by_day", s.by_day[:]}, {"by_agent", s.by_agent[:]}, {"by_model", s.by_model[:]}}) {
		jw_key(&w, set.key)
		jw_arr(&w)
		for r in set.rows {
			jw_obj(&w)
			jw_field(&w, "name", r.name)
			jw_key(&w, "cost")
			jw_f64(&w, r.cost)
			jw_field_int(&w, "tokens", r.tokens)
			jw_field_int(&w, "sessions", i64(r.sessions))
			jw_field_bool(&w, "priced", r.priced)
			jw_end_obj(&w)
		}
		jw_end_arr(&w)
	}
	jw_field_int(&w, "served", s.served)
	jw_key(&w, "served_cost")
	jw_f64(&w, s.served_cost)
	jw_field_int(&w, "lookups", i64(s.lookups))
	jw_field_int(&w, "answered", i64(s.answered))
	jw_key(&w, "finds")
	jw_obj(&w)
	f := s.finds
	jw_field_int(&w, "hits", i64(f.hits))
	jw_field_int(&w, "misses", i64(f.misses))
	for kv in ([5]struct {
			k: string,
			v: f64,
		}{{"hit_cost", f.hit_cost}, {"miss_cost", f.miss_cost}, {"hit_calls", f.hit_calls}, {"miss_calls", f.miss_calls}, {"saved", f.saved}}) {
		jw_key(&w, kv.k)
		jw_f64(&w, kv.v)
	}
	jw_field_bool(&w, "enough", f.enough)
	jw_end_obj(&w)
	jw_end_obj(&w)
	jw_flush(cli, &w)
}
