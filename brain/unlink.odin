package brain

import "core:fmt"
import "core:strconv"
import "core:strings"

import "jm:path"

// cmd_unlink turns a wikilink into plain text, for one that leads nowhere:
//
//	brain unlink <file> <line> <target>
//
// Every [[target]] on that line becomes target, and [[target|label]]
// becomes label, so the sentence still reads; the vault is reindexed.
cmd_unlink :: proc(cli: ^Cli, args: []string) -> int {
	usage :: "usage: brain unlink <file> <line> <target>"
	if len(args) != 3 {
		return fail(cli, usage)
	}
	file, target := args[0], args[2]
	at, ok := strconv.parse_int(args[1])
	if !ok || at < 1 || target == "" {
		return fail(cli, usage)
	}
	if err := ensure_db(cli); err != "" {
		return fail(cli, err)
	}
	// A vault-relative path, as doctor names it: nothing outside the vault.
	if strings.has_prefix(file, "/") || strings.contains(file, "..") || strings.contains(file, ":") {
		return fail(cli, fmt.aprintf("%s is not a file in the vault", file))
	}
	full := path.join(cli.vault, file)
	body, rok := read_text(full)
	if !rok {
		return fail(cli, fmt.aprintf("cannot read %s", file))
	}
	lines := strings.split_lines(body)
	if at > len(lines) {
		return fail(cli, fmt.aprintf("%s has no line %d; reindex and try again", file, at))
	}
	line, n := unlink_line(lines[at - 1], target)
	if n == 0 {
		return fail(cli, fmt.aprintf("%s:%d has no [[%s]]; reindex and try again", file, at, target))
	}
	lines[at - 1] = line
	if err := path.write(full, strings.join(lines, "\n")); err != nil {
		return fail(cli, fmt.aprintf("cannot write %s: %v", file, err))
	}
	if err := sync(cli, quiet = true); err != "" {
		return fail(cli, err)
	}
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "status", "unlinked")
		jw_field(&w, "file", file)
		jw_field_int(&w, "line", i64(at))
		jw_field_int(&w, "links", i64(n))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "unlinked [[%s]] at %s:%d\n", target, file, at)
	return 0
}

// unlink_line is line with every link to target as plain text, and how
// many there were.
unlink_line :: proc(line, target: string) -> (out: string, n: int) {
	b := strings.builder_make()
	s := line
	for {
		i := strings.index(s, "[[")
		if i < 0 {
			break
		}
		j := strings.index(s[i + 2:], "]]")
		if j < 0 {
			break
		}
		inner := s[i + 2:][:j]
		t, _, label := strings.partition(inner, "|")
		strings.write_string(&b, s[:i])
		if t == target {
			strings.write_string(&b, label != "" ? label : t)
			n += 1
		} else {
			strings.write_string(&b, s[i:][:j + 4])
		}
		s = s[i + 2 + j + 2:]
	}
	strings.write_string(&b, s)
	return strings.to_string(b), n
}
