package brain

import "core:fmt"
import "core:strings"
import "core:time"

import git "jm:git"
import "jm:sqlite3"

// bullet_show is one bullet and where it came from, for a person deciding
// whether to trust it:
//
//	brain bullet show <handle> [--at FILE:LINE]
//
// what it says; how it has been served (how often, in how many sessions,
// to whom, by which queries, and a day at a time); what brain verify
// found of its claims; the vault commits that added or changed it; and
// the agent session that proposed it, when a transcript on this machine
// holds the `brain propose` call. Every part is evidence this machine
// has: a bullet from another machine's session shows no proposal here.
bullet_show :: proc(cli: ^Cli, handle, place: string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	file, at, lerr := bullet_place(cli, handle, place)
	if lerr != "" {
		return fail(cli, lerr)
	}
	db, oerr := open_index(cli)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)
	if scalar_int(db, "select count(*) from bullets where file=? and line=? and handle=?", file, i64(at), handle) == 0 {
		return fail(cli, fmt.aprintf("%s:%d is no longer **%s**; reindex and try again", file, at, handle))
	}
	history := bullet_history(cli, handle)
	proposed := find_origin(cli, handle)
	if !cli.json {
		return show_text(cli, db, file, at, handle, history, proposed)
	}

	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "file", file)
	jw_field_int(&w, "line", i64(at))
	jw_field(&w, "handle", handle)
	for col in ([5]string{"section", "aliases", "fact", "source", "date"}) {
		jw_field(&w, col, scalar_text(db, fmt.tprintf("select %s from bullets where file=? and line=?", col), file, i64(at)))
	}

	// What it was served to. A serve is a query that returned it; the log
	// keeps the file, so a bullet sharing its handle in another file is
	// not counted as this one.
	jw_key(&w, "served")
	jw_obj(&w)
	FROM :: " from query_hits h join queries q on q.id = h.query_id where h.handle=? and h.file=?"
	jw_field_int(&w, "times", i64(scalar_int(db, "select count(*)" + FROM, handle, file)))
	jw_field_int(&w, "sessions", i64(scalar_int(db, "select count(distinct nullif(q.session,''))" + FROM, handle, file)))
	jw_field_int(&w, "top", i64(scalar_int(db, "select count(*)" + FROM + " and h.rank = 1", handle, file)))
	jw_field_int(&w, "used", i64(scalar_int(db, "select count(*) from serve_outcome where handle=? and used=1", handle)))
	jw_field(&w, "first", scalar_text(db, "select coalesce(min(q.ts),'')" + FROM, handle, file))
	jw_field(&w, "last", scalar_text(db, "select coalesce(max(q.ts),'')" + FROM, handle, file))
	jw_key(&w, "callers")
	jw_rows(&w, db, "select coalesce(nullif(q.caller,''),'unknown') as caller, count(*) as times" + FROM + " group by 1 order by 2 desc, 1", handle, file)
	jw_key(&w, "queries")
	jw_rows(&w, db, "select q.q as query, count(*) as times, max(q.ts) as last" + FROM + " group by q.q order by 2 desc, 3 desc limit 8", handle, file)
	jw_key(&w, "days")
	jw_rows(&w, db, "select substr(q.ts,1,10) as day, count(*) as times" + FROM + " and q.ts >= date('now','-30 day') group by 1 order by 1", handle, file)
	jw_end_obj(&w)

	jw_key(&w, "claims")
	jw_rows(&w, db, "select kind, text, verdict, why, substr(checked,1,10) as checked from claims where file=? and handle=? order by line, kind", file, handle)

	jw_key(&w, "history")
	jw_arr(&w)
	for c in history {
		jw_obj(&w)
		jw_field(&w, "commit", c.commit)
		jw_field(&w, "date", c.date)
		jw_field(&w, "subject", c.subject)
		jw_key(&w, "files")
		jw_arr(&w)
		for f in c.files {
			jw_str(&w, f)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
	}
	jw_end_arr(&w)

	jw_key(&w, "proposed")
	if proposed.session == "" {
		jw_null(&w)
	} else {
		jw_obj(&w)
		jw_field(&w, "ts", proposed.ts)
		jw_field(&w, "agent", proposed.agent)
		jw_field(&w, "session", proposed.session)
		jw_field(&w, "title", proposed.title)
		jw_field(&w, "turn", proposed.turn)
		jw_end_obj(&w)
	}
	jw_end_obj(&w)
	jw_flush(cli, &w)
	return 0
}

// show_text is bullet_show for a person at a terminal: the figures, the
// commits and the proposal, one line each.
@(private = "file")
show_text :: proc(cli: ^Cli, db: sqlite3.Db, file: string, at: int, handle: string, history: []Change, proposed: Origin) -> int {
	FROM :: " from query_hits h join queries q on q.id = h.query_id where h.handle=? and h.file=?"
	outf(cli, "%s:%d **%s**\n", file, at, handle)
	outf(cli, "served %d times in %d sessions, last %s\n", scalar_int(db, "select count(*)" + FROM, handle, file), scalar_int(db, "select count(distinct nullif(q.session,''))" + FROM, handle, file), scalar_text(db, "select coalesce(max(q.ts),'never')" + FROM, handle, file))
	for c in history {
		outf(cli, "%s %s %s (%s)\n", c.date, c.commit, c.subject, strings.join(c.files, ", "))
	}
	if proposed.session != "" {
		outf(cli, "proposed %s by %s in \"%s\" (turn %s)\n", proposed.ts, proposed.agent, proposed.title, proposed.turn)
	}
	return 0
}

// Change is one vault commit that added, changed or removed a bullet.
Change :: struct {
	commit, date, subject: string,
	files:                 []string, // the vault's files the commit touched
}

// bullet_history is every commit of the vault that changed how many times
// **handle** appears under AI/, newest first: when it was proposed,
// approved, renamed or moved. A vault that is not a git repository has
// none.
bullet_history :: proc(cli: ^Cli, handle: string) -> []Change {
	repo, ok := vault_repo(cli)
	if !ok {
		return nil
	}
	defer git.close(&repo)
	commits, err := git.log(repo)
	if err != nil {
		return nil
	}
	needle := strings.concatenate({"**", handle, "**"})
	out := make([dynamic]Change)
	for c in commits {
		files, patch, cerr := git.changes(repo, c.id, {"AI"}, context_lines = 0)
		if cerr != nil || !alters_count(patch, needle) {
			continue
		}
		y, m, d := time.date(c.at)
		date := strings.concatenate({pad4(y), "-", pad2(m), "-", pad2(d)})
		append(&out, Change{commit = c.id[:7], date = date, subject = c.summary, files = files})
		if len(out) == 20 {
			break
		}
	}
	return out[:]
}

// alters_count is whether patch changes how many times needle appears:
// more on its added lines than its removed ones, or fewer, as `git log
// -S` decides whether a commit touched a string.
alters_count :: proc(patch, needle: string) -> bool {
	added, removed := 0, 0
	rest := patch
	for line in strings.split_lines_iterator(&rest) {
		switch {
		case strings.has_prefix(line, "+++") || strings.has_prefix(line, "---"):
		case strings.has_prefix(line, "+"):
			added += strings.count(line, needle)
		case strings.has_prefix(line, "-"):
			removed += strings.count(line, needle)
		}
	}
	return added != removed
}

// Origin is the agent turn that proposed a bullet: the session, when,
// and the turn a person reads to see why.
Origin :: struct {
	ts, agent, session, title, turn: string,
}

// find_origin finds the first `brain propose` call in this machine's
// transcripts that names **handle**, and the turn it answered: the last
// turn of the session at or before the call, so reading around it shows
// what the agent was asked and what it said.
find_origin :: proc(cli: ^Cli, handle: string) -> (p: Origin) {
	db, err := open_recall_db(cli)
	if err != "" {
		return
	}
	defer sqlite3.close(&db)
	needle := strings.concatenate({"**", handle, "**"})
	p.session = scalar_text(db, "select session from tool where instr(input, 'brain propose') > 0 and instr(input, ?) > 0 order by ts limit 1", needle)
	if p.session == "" {
		return
	}
	p.ts = scalar_text(db, "select ts from tool where session=? and instr(input, 'brain propose') > 0 and instr(input, ?) > 0 order by ts limit 1", p.session, needle)
	p.turn = scalar_text(db, "select id from turn where session=? and ts <= ? order by ts desc limit 1", p.session, p.ts)
	p.agent = scalar_text(db, "select adapter from turn where id=?", p.turn)
	p.title = scalar_text(db, "select title from turn where id=?", p.turn)
	if p.turn == "" {
		p = {}
	}
	return
}
