package brain

import "core:fmt"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// cmd_alias shows, adds to or takes from one bullet's aliases, in the
// markdown, and reindexes:
//
//	brain alias <handle>                 its aliases
//	brain alias add <handle> <term>...   add each term not already a name of it
//	brain alias remove <handle> <term>... take each out
//
// A term is a name a searcher might use: no commas or parentheses, which
// would break the bullet's header, and no em dash, which separates its
// fields. A handle carried by more than one bullet is refused; which one
// was meant is not this command's to guess.
cmd_alias :: proc(cli: ^Cli, args: []string) -> int {
	verb := ""
	rest := args
	if len(rest) > 0 && (rest[0] == "add" || rest[0] == "remove") {
		verb, rest = rest[0], rest[1:]
	}
	if len(rest) == 0 || (verb != "" && len(rest) < 2) {
		return fail(cli, "usage: brain alias [add|remove] <handle> [<term>...]")
	}
	handle, terms := rest[0], rest[1:]
	if verb == "" && len(terms) > 0 {
		return fail(cli, "usage: brain alias [add|remove] <handle> [<term>...]")
	}
	// Only a name being added is held to the form: one already there, that
	// an older hand wrote with a parenthesis in it, can still be taken out.
	if verb == "add" {
		for t in terms {
			if msg := alias_refusal(t); msg != "" {
				return fail(cli, msg)
			}
		}
	}
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	file, line, aliases, err := locate_bullet(cli, handle)
	if err != "" {
		return fail(cli, err)
	}
	names := alias_list(aliases)
	changed := 0
	switch verb {
	case "add":
		outer: for raw in terms {
			t := strings.trim_space(raw)
			if strings.equal_fold(t, handle) {
				continue
			}
			for n in names {
				if strings.equal_fold(n, t) {
					continue outer
				}
			}
			append(&names, t)
			changed += 1
		}
	case "remove":
		for raw in terms {
			t := strings.trim_space(raw)
			for i := len(names) - 1; i >= 0; i -= 1 {
				if strings.equal_fold(names[i], t) {
					ordered_remove(&names, i)
					changed += 1
				}
			}
		}
	}
	if changed > 0 {
		if werr := write_aliases(cli, file, line, handle, names[:]); werr != "" {
			return fail(cli, werr)
		}
		if serr := sync(cli, quiet = true); serr != "" {
			return fail(cli, serr)
		}
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "handle", handle)
		jw_field(&w, "file", file)
		jw_field_int(&w, "line", i64(line))
		jw_field_int(&w, "changed", i64(changed))
		jw_key(&w, "aliases")
		jw_arr(&w)
		for n in names {
			jw_str(&w, n)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	if verb != "" {
		outf(cli, "%s: %d changed\n", handle, changed)
	}
	outf(cli, "%s:%d **%s** (aliases: %s)\n", file, line, handle, strings.join(names[:], ", "))
	return 0
}

// alias_refusal says why term cannot be an alias, or "".
alias_refusal :: proc(term: string) -> string {
	t := strings.trim_space(term)
	switch {
	case t == "":
		return "brain alias: an empty alias"
	case strings.contains_any(t, ",()\n\r*"):
		return fmt.aprintf("brain alias: %q holds a comma, parenthesis, asterisk or line break, which would break the bullet", t)
	case strings.contains(t, "—"):
		return fmt.aprintf("brain alias: %q holds an em dash, which separates a bullet's fields", t)
	}
	return ""
}

// alias_list splits a bullet's alias text into its terms.
alias_list :: proc(aliases: string) -> [dynamic]string {
	out := make([dynamic]string)
	for a in strings.split(aliases, ",") {
		if t := strings.trim_space(a); t != "" {
			append(&out, t)
		}
	}
	return out
}

// locate_bullet is where the one bullet with this handle is, by the index.
locate_bullet :: proc(cli: ^Cli, handle: string) -> (file: string, line: int, aliases: string, err: string) {
	db, oerr := open_index(cli)
	if oerr != "" {
		return "", 0, "", oerr
	}
	defer sqlite3.close(&db)
	n := scalar_int(db, "select count(*) from bullets where handle=?", handle)
	switch {
	case n == 0:
		return "", 0, "", fmt.aprintf("no bullet **%s**", handle)
	case n > 1:
		return "", 0, "", fmt.aprintf("%d bullets are **%s**; give one another handle first", n, handle)
	}
	file = scalar_text(db, "select file from bullets where handle=?", handle)
	line = scalar_int(db, "select line from bullets where handle=?", handle)
	aliases = scalar_text(db, "select aliases from bullets where handle=?", handle)
	return
}

// write_aliases rewrites the header of the bullet at file:line to carry
// names, dropping the alias list when it is empty.
write_aliases :: proc(cli: ^Cli, file: string, line: int, handle: string, names: []string) -> string {
	full := path.join(cli.vault, file)
	text, ok := read_text(full)
	if !ok {
		return fmt.aprintf("brain alias: cannot read %s", file)
	}
	lines := strings.split_lines(text)
	if line < 1 || line > len(lines) {
		return fmt.aprintf("brain alias: %s has no line %d; reindex and try again", file, line)
	}
	l := lines[line - 1]
	b, is := parse_bullet(l, "")
	if !is || b.handle != handle {
		return fmt.aprintf("brain alias: %s:%d is no longer **%s**; reindex and try again", file, line, handle)
	}
	head := strings.concatenate({"- **", handle, "**"})
	i := strings.index(l, head)
	if i < 0 {
		return fmt.aprintf("brain alias: %s:%d does not start with %s", file, line, head)
	}
	after := l[i + len(head):]
	// The alias list, if any, sits between the handle and the first field,
	// to its matching parenthesis: an alias may hold a pair of its own.
	if strings.has_prefix(after, " (") {
		depth := 0
		for c, k in after {
			if c == '(' {
				depth += 1
			} else if c == ')' {
				depth -= 1
				if depth == 0 {
					after = after[k + 1:]
					break
				}
			}
		}
	}
	list := ""
	if len(names) > 0 {
		list = strings.concatenate({" (aliases: ", strings.join(names, ", "), ")"})
	}
	lines[line - 1] = strings.concatenate({l[:i], head, list, after})
	if err := path.write(full, strings.join(lines, "\n")); err != nil {
		return fmt.aprintf("brain alias: cannot write %s: %v", file, err)
	}
	return ""
}
