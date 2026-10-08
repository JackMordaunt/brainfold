package brain

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:unicode/utf8"

import "jm:path"
import "jm:sqlite3"

// cmd_bullet reads and writes the vault's bullets one at a time, for a
// person editing them (the desk) rather than an agent proposing them:
//
//	brain bullet list                        every bullet, where it is and what it says
//	brain bullet check '<bullet>'            what lint would say of it, written nowhere
//	brain bullet write '<bullet>' [--to F]   add it to a core file (MEMORY by default)
//	brain bullet replace <handle> '<bullet>' put it in the place of the bullet now named so
//	brain bullet drop <handle>               take that bullet out
//	brain bullet touch <handle>              date it today: it was checked and still holds
//	brain bullet show <handle>               it, and where it came from: serves, claims, commits, proposal
//
// replace, drop, touch and show take --at FILE:LINE, which names the one meant
// where two bullets share a handle; without it such a handle is refused.
//
// A bullet is written only when check finds nothing wrong with it, and a
// handle stays unique: a write or a rename onto a handle another bullet
// has is refused. Every write reindexes.
cmd_bullet :: proc(cli: ^Cli, args: []string) -> int {
	usage :: "usage: brain bullet list | check '<bullet>' | write '<bullet>' [--to MEMORY|LEARNINGS|TUNINGS] | replace <handle> '<bullet>' [--at FILE:LINE] | drop <handle> [--at FILE:LINE] | touch <handle> [--at FILE:LINE] | show <handle> [--at FILE:LINE]"
	if len(args) == 0 {
		return fail(cli, usage)
	}
	switch args[0] {
	case "list":
		return bullet_list(cli)
	case "check":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		errors, warnings := check_bullet(cli, args[1])
		return bullet_report(cli, "checked", "", "", 0, errors, warnings)
	case "write":
		if len(args) != 2 && len(args) != 4 {
			return fail(cli, usage)
		}
		rel, ok := approve_target(args[2:])
		if !ok {
			return fail(cli, usage)
		}
		return bullet_write(cli, args[1], rel)
	case "replace":
		if len(args) < 3 {
			return fail(cli, usage)
		}
		at, ok := at_flag(args[3:])
		if !ok {
			return fail(cli, usage)
		}
		return bullet_replace(cli, args[1], args[2], at)
	case "drop":
		if len(args) < 2 {
			return fail(cli, usage)
		}
		at, ok := at_flag(args[2:])
		if !ok {
			return fail(cli, usage)
		}
		return bullet_drop(cli, args[1], at)
	case "touch":
		if len(args) < 2 {
			return fail(cli, usage)
		}
		at, ok := at_flag(args[2:])
		if !ok {
			return fail(cli, usage)
		}
		return bullet_touch(cli, args[1], at)
	case "show":
		if len(args) < 2 {
			return fail(cli, usage)
		}
		at, ok := at_flag(args[2:])
		if !ok {
			return fail(cli, usage)
		}
		return bullet_show(cli, args[1], at)
	}
	return fail(cli, usage)
}

// bullet_list is every bullet the index holds but the inbox's, in file
// order, and the core files a bullet may be written to.
bullet_list :: proc(cli: ^Cli) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	db, oerr := open_index(cli)
	if oerr != "" {
		return fail(cli, oerr)
	}
	defer sqlite3.close(&db)
	stmt, err := sqlite3.query(db, "select file, line, section, handle, aliases, fact, source, date from bullets where file != ? order by file, line", INBOX_FILE)
	if err != nil {
		return fail(cli, sql_err(err))
	}
	defer sqlite3.finish(&stmt)
	if !cli.json {
		for sqlite3.next(&stmt) {
			outf(cli, "%s:%d **%s** — %s\n", sqlite3.text(stmt, 0), sqlite3.integer(stmt, 1), sqlite3.text(stmt, 3), sqlite3.text(stmt, 5))
		}
		return 0
	}
	w := jw_make()
	jw_obj(&w)
	jw_key(&w, "bullets")
	jw_arr(&w)
	for sqlite3.next(&stmt) {
		jw_obj(&w)
		jw_field(&w, "file", sqlite3.text(stmt, 0))
		jw_field_int(&w, "line", sqlite3.integer(stmt, 1))
		jw_field(&w, "section", sqlite3.text(stmt, 2))
		jw_field(&w, "handle", sqlite3.text(stmt, 3))
		jw_field(&w, "aliases", sqlite3.text(stmt, 4))
		jw_field(&w, "fact", sqlite3.text(stmt, 5))
		jw_field(&w, "source", sqlite3.text(stmt, 6))
		jw_field(&w, "date", sqlite3.text(stmt, 7))
		jw_end_obj(&w)
	}
	jw_end_arr(&w)
	jw_key(&w, "files")
	jw_arr(&w)
	for c in CORE {
		jw_str(&w, c)
	}
	jw_end_arr(&w)
	jw_end_obj(&w)
	jw_flush(cli, &w)
	return 0
}

// check_bullet is what lint would say of line as a core bullet: errors,
// which stop it being written, and warnings, which do not.
check_bullet :: proc(cli: ^Cli, line: string) -> (errors, warnings: [dynamic]string) {
	errors = make([dynamic]string)
	warnings = make([dynamic]string)
	b, ok := parse_bullet(line, "")
	if !ok {
		switch {
		case b.handle == "":
			append(&errors, "it needs a handle, as - **handle**")
		case:
			append(&errors, "it needs a date at the end, YYYY-MM-DD")
		}
		return
	}
	if strings.trim_space(b.fact) == "" {
		append(&errors, "it says nothing: the fact is empty")
	}
	if b.date > today_iso() {
		append(&errors, fmt.aprintf("it is dated in the future (%s)", b.date))
	}
	if strings.contains(line, "\n") {
		append(&errors, "it is more than one line")
	}
	guard: Guard
	guard_init(&guard, worktree_strict(cli.vault))
	defer guard_destroy(&guard)
	if why := guard_line(&guard, line); why != "" {
		append(&errors, fmt.aprintf("it %s", why))
	}
	if why := scratch_path(line); why != "" {
		append(&errors, fmt.aprintf("it %s", why))
	}
	secret_re, _ := regex.create(`(password|secret|token|api[_-]?key)\s*[:=]\s*[A-Za-z0-9/+_-]{16,}`, {.Case_Insensitive})
	placeholder_re, _ := regex.create(`\$[A-Z_]{3,}|<[a-z]`)
	key_re, _ := regex.create(`BEGIN [A-Z ]*PRIVATE KEY`)
	if (matches(secret_re, line) && !matches(placeholder_re, line)) || matches(key_re, line) {
		append(&errors, "it looks like it carries a secret")
	}
	if n := utf8.rune_count_in_string(b.fact); n > MAXLEN {
		append(&warnings, fmt.aprintf("the fact is %d characters (cap %d); say one fact, and spill the rest to a note", n, MAXLEN))
	}
	if b.aliases == "" {
		append(&warnings, "it has no aliases: name the words a future searcher will type")
	}
	return
}

// bullet_report says how a bullet command went: its status and where the
// bullet is, or why it was refused.
bullet_report :: proc(cli: ^Cli, status, handle, file: string, line: int, errors, warnings: [dynamic]string) -> int {
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "status", len(errors) > 0 ? "refused" : status)
		jw_field(&w, "handle", handle)
		jw_field(&w, "file", file)
		jw_field_int(&w, "line", i64(line))
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
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return len(errors) > 0 ? 1 : 0
	}
	for e in errors {
		errf(cli, "brain bullet: %s\n", e)
	}
	for x in warnings {
		outf(cli, "note: %s\n", x)
	}
	if len(errors) > 0 {
		return 1
	}
	if handle != "" {
		outf(cli, "%s **%s** at %s:%d\n", status, handle, file, line)
	} else {
		outf(cli, "%s\n", status)
	}
	return 0
}

// bullet_write appends line to the core file rel, unless it would be
// refused or its handle is taken.
bullet_write :: proc(cli: ^Cli, line, rel: string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	errors, warnings := check_bullet(cli, line)
	b, _ := parse_bullet(line, "")
	if len(errors) == 0 {
		if f, l := first_with_handle(cli, b.handle); f != "" {
			append(&errors, fmt.aprintf("**%s** is taken, by %s:%d; give this one another handle, or edit that one", b.handle, f, l))
		}
	}
	if len(errors) > 0 {
		return bullet_report(cli, "refused", b.handle, rel, 0, errors, warnings)
	}
	if err := append_bullets(cli, rel, {{text = line, bullet = b}}); err != "" {
		return fail(cli, err)
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	f, l := first_with_handle(cli, b.handle)
	return bullet_report(cli, "written", b.handle, f, l, errors, warnings)
}

// bullet_replace puts line in the place of the bullet named handle; its
// own handle may differ, if no other bullet has that one.
bullet_replace :: proc(cli: ^Cli, handle, line, place: string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	file, at, lerr := bullet_place(cli, handle, place)
	if lerr != "" {
		return fail(cli, lerr)
	}
	errors, warnings := check_bullet(cli, line)
	b, _ := parse_bullet(line, "")
	if len(errors) == 0 && b.handle != handle {
		if f, l := first_with_handle(cli, b.handle); f != "" {
			append(&errors, fmt.aprintf("**%s** is taken, by %s:%d", b.handle, f, l))
		}
	}
	if len(errors) > 0 {
		return bullet_report(cli, "refused", handle, file, at, errors, warnings)
	}
	if err := set_line(cli, file, at, handle, line); err != "" {
		return fail(cli, err)
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	return bullet_report(cli, "replaced", b.handle, file, at, errors, warnings)
}

// bullet_drop takes the bullet named handle out of its file and keeps it
// in AI/DROPPED.md, so what was dropped stays on record and is not
// proposed again.
bullet_drop :: proc(cli: ^Cli, handle, place: string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	file, at, lerr := bullet_place(cli, handle, place)
	if lerr != "" {
		return fail(cli, lerr)
	}
	full := path.join(cli.vault, file)
	text, _ := read_text(full)
	lines := strings.split_lines(text)
	old := lines[at - 1]
	if err := set_line(cli, file, at, handle, ""); err != "" {
		return fail(cli, err)
	}
	dropped, _ := read_text(path.join(cli.vault, DROPPED_FILE))
	if dropped != "" && !strings.has_suffix(dropped, "\n") {
		dropped = strings.concatenate({dropped, "\n"})
	}
	path.write(path.join(cli.vault, DROPPED_FILE), strings.concatenate({dropped, old, "\n"}))
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	return bullet_report(cli, "dropped", handle, file, at, {}, {})
}

// bullet_touch dates the bullet named handle today: it was checked and
// still holds, so it is no longer stale.
bullet_touch :: proc(cli: ^Cli, handle, place: string) -> int {
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	file, at, lerr := bullet_place(cli, handle, place)
	if lerr != "" {
		return fail(cli, lerr)
	}
	text, _ := read_text(path.join(cli.vault, file))
	lines := strings.split_lines(text)
	if at < 1 || at > len(lines) {
		return fail(cli, fmt.aprintf("%s has no line %d; reindex and try again", file, at))
	}
	old := strings.trim_right_space(lines[at - 1])
	b, ok := parse_bullet(old, "")
	if !ok || !strings.has_suffix(old, b.date) {
		return fail(cli, fmt.aprintf("%s:%d does not end in its date", file, at))
	}
	line := strings.concatenate({old[:len(old) - len(b.date)], today_iso()})
	if err := set_line(cli, file, at, handle, line); err != "" {
		return fail(cli, err)
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	return bullet_report(cli, "touched", handle, file, at, {}, {})
}

// at_flag reads an optional --at FILE:LINE from rest, which must hold
// nothing else.
at_flag :: proc(rest: []string) -> (place: string, ok: bool) {
	switch len(rest) {
	case 0:
		return "", true
	case 2:
		return rest[1], rest[0] == "--at"
	}
	return "", false
}

// bullet_place is the file and line of the bullet named handle: the one
// at place, FILE:LINE, when it is given, which set_line checks still
// holds that handle; else the one bullet so named.
bullet_place :: proc(cli: ^Cli, handle, place: string) -> (file: string, line: int, err: string) {
	if place == "" {
		file, line, _, err = locate_bullet(cli, handle)
		return
	}
	i := strings.last_index_byte(place, ':')
	if i <= 0 {
		return "", 0, fmt.aprintf("--at wants FILE:LINE, got %s", place)
	}
	n, ok := strconv.parse_int(place[i + 1:])
	if !ok || n < 1 {
		return "", 0, fmt.aprintf("--at wants FILE:LINE, got %s", place)
	}
	return place[:i], n, ""
}

// set_line rewrites line at of file, which must still be the bullet named
// handle, to text; "" removes the line.
set_line :: proc(cli: ^Cli, file: string, at: int, handle, text: string) -> string {
	full := path.join(cli.vault, file)
	body, ok := read_text(full)
	if !ok {
		return fmt.aprintf("cannot read %s", file)
	}
	lines := make([dynamic]string)
	append(&lines, ..strings.split_lines(body))
	if at < 1 || at > len(lines) {
		return fmt.aprintf("%s has no line %d; reindex and try again", file, at)
	}
	if b, is := parse_bullet(lines[at - 1], ""); !is || b.handle != handle {
		return fmt.aprintf("%s:%d is no longer **%s**; reindex and try again", file, at, handle)
	}
	if text == "" {
		ordered_remove(&lines, at - 1)
	} else {
		lines[at - 1] = text
	}
	if err := path.write(full, strings.join(lines[:], "\n")); err != nil {
		return fmt.aprintf("cannot write %s: %v", file, err)
	}
	return ""
}

// first_with_handle is the file and line of the first bullet named handle,
// or "": unlike locate_bullet it does not refuse a handle two bullets share,
// as a check that a handle is free needs.
first_with_handle :: proc(cli: ^Cli, handle: string) -> (file: string, line: int) {
	db, err := open_index(cli)
	if err != "" {
		return "", 0
	}
	defer sqlite3.close(&db)
	file = scalar_text(db, "select file from bullets where handle=? and file != ? limit 1", handle, INBOX_FILE)
	line = scalar_int(db, "select line from bullets where handle=? and file != ? limit 1", handle, INBOX_FILE)
	return
}
