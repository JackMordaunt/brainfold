package brain

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "jm:path"
import "jm:sqlite3"

// An agent proposes a bullet and a person reviews it. Proposals land in
// AI/INBOX.md. When review comes after, the default, the index reads the
// inbox too, so a proposal answers a find at once, marked unreviewed; when
// it comes before, the index skips the inbox and nothing an agent wrote
// answers a find until a person moved it into a core file. `brain inbox`
// lists the proposals, `brain inbox approve <n>|all [--to LEARNINGS]` moves one or all
// into a core file, and `brain inbox drop <n>` moves one to AI/DROPPED.md,
// which the index never reads and propose checks, so the same fact is not
// proposed again.

INBOX_FILE   :: "AI/INBOX.md"
DROPPED_FILE :: "AI/DROPPED.md"
INBOX_HEAD   :: "# Inbox\n\nBullets agents proposed that no person has reviewed yet. `brain inbox` lists them,\n`brain inbox approve <n> [--to LEARNINGS]` moves one into memory, `approve all` every one,\n`brain inbox drop <n>` rejects it.\n\n"
DROPPED_HEAD :: "# Dropped\n\nProposals a person rejected. `brain propose` refuses the same fact again.\n\n"

// UNREVIEWED follows the locator of a hit still in the inbox.
UNREVIEWED :: "(unreviewed)"

// Review is when a person reviews what agents propose: After lets a
// proposal answer finds until it is dropped, Before holds it back until it
// is approved.
Review :: enum {
	After,
	Before,
}

// review_mode reads BRAIN_REVIEW, then the setting `brain review` wrote,
// and defaults to After.
review_mode :: proc(cli: ^Cli) -> Review {
	v := getenv(cli, "BRAIN_REVIEW")
	if v == "" {
		v = strings.trim_space(first_line(path.join(cli.conf_dir, "review")))
	}
	return v == "before" ? .Before : .After
}

review_name :: proc(r: Review) -> string {
	return r == .Before ? "before" : "after"
}

// cmd_review shows or sets when proposals are reviewed, and reindexes so
// the setting takes effect on the next find.
cmd_review :: proc(cli: ^Cli, args: []string) -> int {
	usage := phrase(cli, .Usage_Review)
	if len(args) > 1 {
		return fail(cli, usage)
	}
	if len(args) == 1 {
		if args[0] != "after" && args[0] != "before" {
			return fail(cli, usage)
		}
		if err := path.mkdirs(cli.conf_dir); err != nil {
			return fail(cli, phrase(cli, .Cannot_Create, cli.conf_dir, fmt.tprintf("%v", err)))
		}
		conf := path.join(cli.conf_dir, "review")
		if err := path.write(conf, strings.concatenate({args[0], "\n"})); err != nil {
			return fail(cli, phrase(cli, .Cannot_Write, conf, fmt.tprintf("%v", err)))
		}
		if cli.vault != "" {
			if err := sync(cli, quiet = true); err != "" {
				return fail(cli, err)
			}
		}
	}
	mode := review_mode(cli)
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "review", review_name(mode))
		jw_end_obj(&w)
		jw_flush(cli, &w)
	} else if mode == .After {
		said(cli, .Review_After_Long)
	} else {
		said(cli, .Review_Before_Long)
	}
	return 0
}

// scratch_path says why a bullet is tied to where it was written: it names
// the working directory by its absolute path, or a path under the system's
// temporary directory. A durable fact survives the directory it was found
// in; the proof's task sessions (2026-10-02) proposed bullets about the
// script they had just written, located by such paths.
scratch_path :: proc(line: string) -> string {
	if cwd, err := os.get_working_directory(context.allocator); err == nil && cwd != "" && cwd != "/" && strings.contains(line, cwd) {
		return strings.concatenate({"names this working directory (", cwd, "); a durable fact does not depend on where it was found"})
	}
	for tmp in ([?]string{"/tmp/", "/var/tmp/", "/private/tmp/"}) {
		if strings.contains(line, tmp) {
			return strings.concatenate({"names a path under ", tmp, "; nothing durable lives there"})
		}
	}
	return ""
}

cmd_propose :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	force := false
	rest := make([dynamic]string)
	for a in args {
		if a == "--force" {
			force = true
		} else {
			append(&rest, a)
		}
	}
	line := strings.trim_space(strings.join(rest[:], " "))
	if line == "" {
		return fail(cli, phrase(cli, .Usage_Propose))
	}
	// settle says "reply none"; agents run it as a command. Nothing to record.
	if strings.to_lower(strings.trim(line, "'\"")) == "none" {
		said(cli, .Nothing_Proposed)
		return 0
	}
	code, _ := propose_line(cli, complete_bullet(line, caller_id(cli)), force)
	return code
}

// propose_line queues one completed bullet line, or says why not.
// RESTATE_SHARE is the share of a proposed fact's distinctive words a current
// bullet must hold to count as already saying it.
RESTATE_SHARE :: 0.6

// restating_bullet finds a current bullet, in a core file, that already says what a
// proposed bullet says: it holds RESTATE_SHARE of the fact's distinctive
// words (four letters or more, not query noise), words meeting as the
// stemmed index meets them. Settle drew proposals out of the proof's task
// sessions (2026-10-02) that restated bullets the vault held; a proposal
// is checked against the index before the inbox is written.
restating_bullet :: proc(cli: ^Cli, b: Bullet) -> Hit {
	if ensure_db(cli) != "" {
		return {}
	}
	db, oerr := open_index(cli)
	if oerr != "" {
		return {}
	}
	defer sqlite3.close(&db)
	words := make([dynamic]string)
	stop := PRIME_STOP
	for t in query_terms(b.fact) {
		if utf8.rune_count_in_string(t) >= 4 && !slice.contains(stop[:], t) && !slice.contains(words[:], t) {
			append(&words, t)
		}
	}
	if len(words) < 4 {
		return {}
	}
	m, ok := build_match(db, strings.join(words[:], " "))
	if !ok {
		return {}
	}
	need := int(f64(len(words)) * RESTATE_SHARE + 0.5)
	for h in query_fts(db, m.or, FIND_LIMIT * 2) {
		if h.file == INBOX_FILE || h.handle == "" {
			continue
		}
		if count_met_terms(strings.concatenate({h.handle, " ", h.aliases, " ", h.fact}), words[:]) >= need {
			return h
		}
	}
	return {}
}

propose_line :: proc(cli: ^Cli, line: string, force := false) -> (int, bool) {
	b, ok := parse_bullet(line, "")
	if !ok {
		return fail(cli, phrase(cli, .Not_A_Bullet, line)), false
	}
	guard: Guard
	guard_init(&guard, worktree_strict(cli.vault))
	defer guard_destroy(&guard)
	if why := guard_line(&guard, line); why != "" {
		return fail(cli, phrase(cli, .Not_Proposed, why)), false
	}
	if why := scratch_path(line); why != "" {
		return fail(cli, phrase(cli, .Not_Proposed, why)), false
	}
	if !force {
		if dup := restating_bullet(cli, b); dup.handle != "" {
			return fail(cli, phrase(cli, .Not_Proposed, strings.concatenate({
				"restates **",
				dup.handle,
				"** (",
				dup.file,
				":",
				int_str(dup.line),
				"); if it corrects that bullet, propose again with --force and say what changed",
			}))), false
		}
	}
	return inbox_write(cli, line, b)
}

// proposal_fate is what proposing line would do, writing nothing: "new"
// when it would be proposed; else "refused" (not a bullet, or the guard
// stops it), "restates" (the vault says it already), "dropped" (a person
// dropped the same fact) or "waiting" (its handle is in the inbox).
proposal_fate :: proc(cli: ^Cli, line: string) -> string {
	b, ok := parse_bullet(line, "")
	if !ok {
		return "refused"
	}
	guard: Guard
	guard_init(&guard, worktree_strict(cli.vault))
	defer guard_destroy(&guard)
	if guard_line(&guard, line) != "" || scratch_path(line) != "" {
		return "refused"
	}
	if dup := restating_bullet(cli, b); dup.handle != "" {
		return "restates"
	}
	dropped, _ := read_text(path.join(cli.vault, DROPPED_FILE))
	for l in strings.split_lines(dropped) {
		if d, dok := parse_bullet(l, ""); dok && d.handle == b.handle && d.fact == b.fact {
			return "dropped"
		}
	}
	waiting, _ := read_text(path.join(cli.vault, INBOX_FILE))
	for l in strings.split_lines(waiting) {
		if q, qok := parse_bullet(l, ""); qok && q.handle == b.handle {
			return "waiting"
		}
	}
	return "new"
}

// inbox_write appends a parsed bullet to the inbox unless a person dropped
// the same fact before or the same handle is already waiting; tend's
// hygiene items take this path too, past the checks a fact gets.
// inbox_write reports whether the line is a new proposal. Dropped and
// already-waiting facts print a reason and come back unproposed, so a
// counter does not have to read the translated sentence.
inbox_write :: proc(cli: ^Cli, line: string, b: Bullet) -> (code: int, proposed: bool) {
	dropped, _ := read_text(path.join(cli.vault, DROPPED_FILE))
	for l in strings.split_lines(dropped) {
		d, dok := parse_bullet(l, "")
		if dok && d.handle == b.handle && d.fact == b.fact {
			if cli.json {
				propose_json(cli, "dropped", 0, b.handle)
			} else {
				said(cli, .Dropped_Before, l)
			}
			return 0, false
		}
	}
	inbox := path.join(cli.vault, INBOX_FILE)
	text, exists := read_text(inbox)
	if !exists {
		text = INBOX_HEAD
	}
	n := 0
	for l in strings.split_lines(text) {
		q, qok := parse_bullet(l, "")
		if !qok {
			continue
		}
		n += 1
		if q.handle == b.handle {
			if cli.json {
				propose_json(cli, "already", n, b.handle)
			} else {
				said(cli, .Already_Proposed, fmt.tprint(n), b.handle)
			}
			return 0, false
		}
	}
	if !strings.has_suffix(text, "\n") {
		text = strings.concatenate({text, "\n"})
	}
	if werr := path.write(inbox, strings.concatenate({text, line, "\n"})); werr != nil {
		return fail(cli, phrase(cli, .Cannot_Write, inbox, fmt.tprintf("%v", werr))), false
	}
	n += 1
	if cli.json {
		propose_json(cli, "proposed", n, b.handle)
	} else if is_tend(b) {
		said(cli, .Proposed_Approve, fmt.tprint(n), b.handle, fmt.tprint(n))
	} else if review_mode(cli) == .After {
		said(cli, .Proposed_Live, fmt.tprint(n), b.handle)
	} else {
		said(cli, .Proposed_Wait, fmt.tprint(n), b.handle, fmt.tprint(n))
	}
	return 0, true
}

propose_json :: proc(cli: ^Cli, status: string, n: int, handle: string) {
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "status", status)
	jw_field_int(&w, "n", i64(n))
	jw_field(&w, "handle", handle)
	jw_end_obj(&w)
	jw_flush(cli, &w)
}

// complete_bullet fills what an agent may leave off: a source, which
// becomes the caller, and today's date. A line that already ends in a date
// is taken as written.
complete_bullet :: proc(line, caller: string) -> string {
	f := strings.split(line, SEP)
	n := len(f)
	if n >= 2 && is_iso_date(f[n - 1]) {
		return line
	}
	if n == 2 {
		who := caller != "" ? caller : "agent"
		return strings.concatenate({line, SEP, who, SEP, today_iso()})
	}
	return strings.concatenate({line, SEP, today_iso()})
}

// inbox_from is where a proposal came from: the first word of its source,
// split on a space or a colon. tend and settle are named; everything else
// was proposed. "tender" is not tend. The word is not translated, and the
// stored source is left as written.
inbox_from :: proc(source: string) -> string {
	s := strings.trim_space(source)
	end := len(s)
	for i in 0 ..< len(s) {
		if s[i] == ' ' || s[i] == ':' {
			end = i
			break
		}
	}
	word := s[:end]
	if strings.equal_fold(word, "tend") {
		return "tend"
	}
	if strings.equal_fold(word, "settle") {
		return "settle"
	}
	return "propose"
}

// Inbox_Line is one line of the inbox file, and whether it is a proposal.
Inbox_Line :: struct {
	text:   string,
	bullet: Bullet,
	is:     bool,
}

read_inbox :: proc(cli: ^Cli) -> (lines: []Inbox_Line, exists: bool) {
	text, ok := read_text(path.join(cli.vault, INBOX_FILE))
	if !ok {
		return nil, false
	}
	all := make([dynamic]Inbox_Line)
	for l in strings.split_lines(text) {
		b, is := parse_bullet(l, "")
		append(&all, Inbox_Line{text = l, bullet = b, is = is})
	}
	// split_lines leaves an empty last element after the final newline.
	if len(all) > 0 && all[len(all) - 1].text == "" {
		pop(&all)
	}
	return all[:], true
}

write_inbox :: proc(cli: ^Cli, lines: []Inbox_Line) -> string {
	b := strings.builder_make()
	for l in lines {
		strings.write_string(&b, l.text)
		strings.write_string(&b, "\n")
	}
	inbox := path.join(cli.vault, INBOX_FILE)
	if werr := path.write(inbox, strings.to_string(b)); werr != nil {
		return phrase(cli, .Cannot_Write, inbox, fmt.tprintf("%v", werr))
	}
	return ""
}

cmd_inbox :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	lines, exists := read_inbox(cli)
	if len(args) == 0 {
		n := 0
		w := jw_make()
		if cli.json {
			jw_obj(&w)
			jw_key(&w, "proposals")
			jw_arr(&w)
		}
		for l in lines {
			if !l.is {
				continue
			}
			n += 1
			if cli.json {
				jw_obj(&w)
				jw_field_int(&w, "n", i64(n))
				jw_field(&w, "handle", l.bullet.handle)
				jw_field(&w, "aliases", l.bullet.aliases)
				jw_field(&w, "fact", l.bullet.fact)
				jw_field(&w, "source", l.bullet.source)
				jw_field(&w, "from", inbox_from(l.bullet.source))
				jw_field(&w, "date", l.bullet.date)
				jw_field(&w, "line", l.text)
				jw_end_obj(&w)
			} else {
				outf(cli, "#%d  %s  %s\n", n, inbox_from(l.bullet.source), l.text)
			}
		}
		if cli.json {
			jw_end_arr(&w)
			jw_end_obj(&w)
			jw_flush(cli, &w)
		} else if n == 0 {
			said(cli, .Inbox_Empty)
		}
		return 0
	}
	if !exists {
		return fail(cli, phrase(cli, .Inbox_Empty))
	}
	usage := phrase(cli, .Usage_Inbox)
	if len(args) < 2 {
		return fail(cli, usage)
	}
	if args[1] == "all" {
		if args[0] != "approve" {
			return fail(cli, usage)
		}
		return inbox_approve_all(cli, lines, args[2:], usage)
	}
	want, ok := strconv.parse_int(args[1])
	if !ok || want < 1 {
		return fail(cli, usage)
	}
	at := -1
	n := 0
	for l, i in lines {
		if l.is {
			n += 1
			if n == want {
				at = i
				break
			}
		}
	}
	if at < 0 {
		return fail(cli, phrase(cli, .No_Proposal, fmt.tprint(want)))
	}
	chosen := lines[at]
	switch args[0] {
	case "review":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		return inbox_review(cli, chosen, want)
	case "merge":
		return inbox_merge(cli, lines, at, want, args[2:], usage)
	case "approve":
		// A hygiene item from tend is an action, not a fact: approving it
		// applies the action and logs it, and nothing moves into a core file.
		if is_tend(chosen.bullet) {
			if err := tend_apply(cli, chosen.bullet); err != "" {
				return fail(cli, err)
			}
			if err := write_inbox(cli, drop_at(lines, at)); err != "" {
				return fail(cli, err)
			}
			tend_log(cli, chosen.text)
			if err := sync(cli, quiet = true); err != "" {
				return fail(cli, err)
			}
			if cli.json {
				inbox_json(cli, "applied", want, chosen.bullet.handle, "")
			} else {
				said(cli, .Applied, fmt.tprint(want), chosen.bullet.handle)
			}
			return 0
		}
		rel, valid := approve_target(args[2:])
		if !valid {
			return fail(cli, usage)
		}
		if err := append_bullets(cli, rel, {chosen}); err != "" {
			return fail(cli, err)
		}
		if err := write_inbox(cli, drop_at(lines, at)); err != "" {
			return fail(cli, err)
		}
		if err := sync(cli, quiet = true); err != "" {
			return fail(cli, err)
		}
		if cli.json {
			inbox_json(cli, "approved", want, chosen.bullet.handle, rel)
		} else {
			said(cli, .Approved_To, fmt.tprint(want), chosen.bullet.handle, rel)
		}
	case "drop":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		dropped := path.join(cli.vault, DROPPED_FILE)
		text, dexists := read_text(dropped)
		if !dexists {
			text = DROPPED_HEAD
		}
		if !strings.has_suffix(text, "\n") {
			text = strings.concatenate({text, "\n"})
		}
		if werr := path.write(dropped, strings.concatenate({text, chosen.text, "\n"})); werr != nil {
			return fail(cli, phrase(cli, .Cannot_Write, dropped, fmt.tprintf("%v", werr)))
		}
		if err := write_inbox(cli, drop_at(lines, at)); err != "" {
			return fail(cli, err)
		}
		if cli.json {
			inbox_json(cli, "dropped", want, chosen.bullet.handle, "")
		} else {
			said(cli, .Dropped_N, fmt.tprint(want), chosen.bullet.handle)
		}
	case:
		return fail(cli, usage)
	}
	return 0
}

// approve_target reads the optional `--to MEMORY|LEARNINGS|TUNINGS` that
// follows an approve and names the core file, relative to the vault.
approve_target :: proc(args: []string) -> (rel: string, ok: bool) {
	to := "MEMORY"
	if len(args) == 2 && args[0] == "--to" {
		to = strings.to_upper(args[1])
	} else if len(args) != 0 {
		return "", false
	}
	if to != "MEMORY" && to != "LEARNINGS" && to != "TUNINGS" {
		return "", false
	}
	return strings.concatenate({"AI/", to, ".md"}), true
}

// append_bullets adds the inbox lines to the end of the core file rel,
// in order, and says what went wrong.
append_bullets :: proc(cli: ^Cli, rel: string, chosen: []Inbox_Line) -> string {
	target := path.join(cli.vault, rel)
	text, _ := read_text(target)
	b := strings.builder_make()
	strings.write_string(&b, text)
	if text != "" && !strings.has_suffix(text, "\n") {
		strings.write_string(&b, "\n")
	}
	for l in chosen {
		strings.write_string(&b, l.text)
		strings.write_string(&b, "\n")
	}
	if werr := path.write(target, strings.to_string(b)); werr != nil {
		return phrase(cli, .Cannot_Write, target, fmt.tprintf("%v", werr))
	}
	return ""
}

// inbox_approve_all moves every proposal into one core file with a single
// write and a single sync, leaving the inbox with only its header.
inbox_approve_all :: proc(cli: ^Cli, lines: []Inbox_Line, args: []string, usage: string) -> int {
	rel, ok := approve_target(args)
	if !ok {
		return fail(cli, usage)
	}
	chosen := make([dynamic]Inbox_Line)
	kept := make([dynamic]Inbox_Line)
	for l in lines {
		// Hygiene items change the vault; each is approved on its own.
		if l.is && !is_tend(l.bullet) {
			append(&chosen, l)
		} else {
			append(&kept, l)
		}
	}
	if len(chosen) == 0 {
		return fail(cli, phrase(cli, .Inbox_Empty))
	}
	if err := append_bullets(cli, rel, chosen[:]); err != "" {
		return fail(cli, err)
	}
	if err := write_inbox(cli, kept[:]); err != "" {
		return fail(cli, err)
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "action", "approved")
		jw_field_int(&w, "count", i64(len(chosen)))
		jw_field(&w, "to", rel)
		jw_key(&w, "handles")
		jw_arr(&w)
		for l in chosen {
			jw_str(&w, l.bullet.handle)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
	} else {
		for l, i in chosen {
			said(cli, .Approved_To, fmt.tprint(i + 1), l.bullet.handle, rel)
		}
	}
	return 0
}

// drop_at is lines without the one at index at.
drop_at :: proc(lines: []Inbox_Line, at: int) -> []Inbox_Line {
	kept := make([dynamic]Inbox_Line)
	for l, i in lines {
		if i != at {
			append(&kept, l)
		}
	}
	return kept[:]
}

inbox_json :: proc(cli: ^Cli, action: string, n: int, handle, to: string) {
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "action", action)
	jw_field_int(&w, "n", i64(n))
	jw_field(&w, "handle", handle)
	if to != "" {
		jw_field(&w, "to", to)
	}
	jw_end_obj(&w)
	jw_flush(cli, &w)
}
