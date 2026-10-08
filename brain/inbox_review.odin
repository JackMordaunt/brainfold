package brain

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "jm:path"
import "jm:sqlite3"

// Reviewing a proposal before it is approved: what in the vault it may
// repeat, what lint says of it, and the agent turn that proposed it; and
// folding it into a bullet it repeats, in place of approving it.
//
//	brain inbox review <n>                                   the proposal and what bears on it
//	brain inbox merge <n> --into <handle> [--at F:L] '<line>' write line in place of that bullet; the proposal is retired
//
// A merged proposal goes to AI/DROPPED.md, as a dropped one does: what it
// said lives on in the bullet, and it is not proposed again.

SIMILAR_SHARE :: 0.5 // of a proposal's content words a bullet must share to be shown beside it
SIMILAR_MAX :: 5

// Near_Match is a vault bullet a proposal may repeat: how much of the
// proposal's content it shares, and whether it has the same handle.
Near_Match :: struct {
	hit:         Hit,
	share:       f64,
	same_handle: bool,
}

// similar_bullets is the bullets outside the inbox that b may repeat: any
// with its handle, whatever the case, then those sharing at least
// SIMILAR_SHARE of its content words (restating_bullet's measure), the
// closest first, at most limit.
similar_bullets :: proc(cli: ^Cli, b: Bullet, limit := SIMILAR_MAX) -> []Near_Match {
	out := make([dynamic]Near_Match)
	if ensure_db(cli) != "" {
		return nil
	}
	db, oerr := open_index(cli)
	if oerr != "" {
		return nil
	}
	defer sqlite3.close(&db)
	words := make([dynamic]string)
	stop := PRIME_STOP
	for t in query_terms(strings.concatenate({b.handle, " ", b.fact})) {
		if utf8.rune_count_in_string(t) >= 4 &&
		   !slice.contains(stop[:], t) &&
		   !slice.contains(words[:], t) {
			append(&words, t)
		}
	}
	share :: proc(h: Hit, words: []string) -> f64 {
		if len(words) == 0 {
			return 0
		}
		return(
			f64(
				count_met_terms(
					strings.concatenate({h.handle, " ", h.aliases, " ", h.fact}),
					words,
				),
			) /
			f64(len(words)) \
		)
	}
	seen := make(map[string]bool)
	{
		stmt, err := sqlite3.query(
			db,
			"select file, line, raw, handle, aliases, fact, source, date from bullets where lower(handle) = lower(?) and file != ?",
			b.handle,
			INBOX_FILE,
		)
		if err == nil {
			for sqlite3.next(&stmt) {
				h := Hit {
					file    = strings.clone(sqlite3.text(stmt, 0)),
					line    = sqlite3.integer(stmt, 1),
					raw     = strings.clone(sqlite3.text(stmt, 2)),
					handle  = strings.clone(sqlite3.text(stmt, 3)),
					aliases = strings.clone(sqlite3.text(stmt, 4)),
					fact    = strings.clone(sqlite3.text(stmt, 5)),
					source  = strings.clone(sqlite3.text(stmt, 6)),
					date    = strings.clone(sqlite3.text(stmt, 7)),
				}
				seen[fmt.aprintf("%s:%d", h.file, h.line)] = true
				append(&out, Near_Match{h, share(h, words[:]), true})
			}
			sqlite3.finish(&stmt)
		}
	}
	if len(words) >= 2 {
		if m, ok := build_match(db, strings.join(words[:], " ")); ok {
			for h in query_fts(db, m.or, FIND_LIMIT * 2) {
				if h.file == INBOX_FILE ||
				   h.handle == "" ||
				   seen[fmt.aprintf("%s:%d", h.file, h.line)] {
					continue
				}
				if s := share(h, words[:]); s >= SIMILAR_SHARE {
					append(&out, Near_Match{h, s, false})
				}
			}
		}
	}
	slice.stable_sort_by(out[:], proc(a, b: Near_Match) -> bool {
		if a.same_handle != b.same_handle {
			return a.same_handle
		}
		return a.share > b.share
	})
	return out[:min(len(out), limit)]
}

// inbox_review says what bears on proposal want, the line chosen of lines.
inbox_review :: proc(cli: ^Cli, chosen: Inbox_Line, want: int) -> int {
	b := chosen.bullet
	similar := similar_bullets(cli, b)
	errors, warnings := check_bullet(cli, chosen.text)
	origin := find_origin(cli, b.handle)
	if !cli.json {
		outf(cli, "#%d %s\n", want, chosen.text)
		for e in errors {
			outf(cli, "lint: %s\n", e)
		}
		for x in warnings {
			outf(cli, "note: %s\n", x)
		}
		for s in similar {
			outf(
				cli,
				"may repeat %s:%d **%s** (%.0f%% shared%s)\n",
				s.hit.file,
				s.hit.line,
				s.hit.handle,
				s.share * 100,
				s.same_handle ? ", same handle" : "",
			)
		}
		if origin.session != "" {
			outf(
				cli,
				"proposed %s by %s in \"%s\" (turn %s)\n",
				origin.ts,
				origin.agent,
				origin.title,
				origin.turn,
			)
		}
		return 0
	}
	w := jw_make()
	jw_obj(&w)
	jw_field_int(&w, "n", i64(want))
	jw_field(&w, "handle", b.handle)
	jw_field(&w, "line", chosen.text)
	jw_key(&w, "similar")
	jw_arr(&w)
	for s in similar {
		jw_obj(&w)
		jw_field(&w, "file", s.hit.file)
		jw_field_int(&w, "line", s.hit.line)
		jw_field(&w, "handle", s.hit.handle)
		jw_field(&w, "aliases", s.hit.aliases)
		jw_field(&w, "fact", s.hit.fact)
		jw_field(&w, "source", s.hit.source)
		jw_field(&w, "date", s.hit.date)
		jw_key(&w, "share")
		jw_f64(&w, s.share)
		jw_field_bool(&w, "same_handle", s.same_handle)
		jw_end_obj(&w)
	}
	jw_end_arr(&w)
	jw_key(&w, "errors")
	jw_arr(&w)
	for e in errors {
		jw_str(&w, e)
	}
	jw_end_arr(&w)
	jw_key(&w, "warnings")
	jw_arr(&w)
	for x in warnings {
		jw_str(&w, x)
	}
	jw_end_arr(&w)
	jw_key(&w, "origin")
	if origin.session == "" {
		jw_null(&w)
	} else {
		jw_obj(&w)
		jw_field(&w, "ts", origin.ts)
		jw_field(&w, "agent", origin.agent)
		jw_field(&w, "session", origin.session)
		jw_field(&w, "title", origin.title)
		jw_field(&w, "turn", origin.turn)
		jw_end_obj(&w)
	}
	jw_end_obj(&w)
	jw_flush(cli, &w)
	return 0
}

// inbox_merge writes line in place of the bullet named into (the one at
// place, when given) and retires proposal want, at index at of lines. The
// line is held to what a written bullet is, and a handle it renames to
// must be free.
inbox_merge :: proc(
	cli: ^Cli,
	lines: []Inbox_Line,
	at, want: int,
	rest: []string,
	usage: string,
) -> int {
	into, place, line := "", "", ""
	for i := 0; i < len(rest); i += 1 {
		switch {
		case rest[i] == "--into" && i + 1 < len(rest):
			into = rest[i + 1]
			i += 1
		case rest[i] == "--at" && i + 1 < len(rest):
			place = rest[i + 1]
			i += 1
		case line == "":
			line = rest[i]
		case:
			return fail(cli, usage)
		}
	}
	if into == "" || line == "" {
		return fail(cli, usage)
	}
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	file, n, lerr := bullet_place(cli, into, place)
	if lerr != "" {
		return fail(cli, lerr)
	}
	errors, warnings := check_bullet(cli, line)
	b, _ := parse_bullet(line, "")
	if len(errors) == 0 && b.handle != into {
		if f, l := first_with_handle(cli, b.handle); f != "" {
			append(&errors, fmt.aprintf("**%s** is taken, by %s:%d", b.handle, f, l))
		}
	}
	if len(errors) > 0 {
		return bullet_report(cli, "refused", into, file, n, errors, warnings)
	}
	if err := set_line(cli, file, n, into, line); err != "" {
		return fail(cli, err)
	}
	// The proposal is retired as a dropped one is: kept on record, never
	// proposed again.
	dropped := path.join(cli.vault, DROPPED_FILE)
	text, dexists := read_text(dropped)
	if !dexists {
		text = DROPPED_HEAD
	}
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"})
	}
	if werr := path.write(dropped, strings.concatenate({text, lines[at].text, "\n"}));
	   werr != nil {
		return fail(cli, fmt.aprintf("cannot write %s: %v", dropped, werr))
	}
	if err := write_inbox(cli, drop_at(lines, at)); err != "" {
		return fail(cli, err)
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	return bullet_report(cli, "merged", b.handle, file, n, errors, warnings)
}
