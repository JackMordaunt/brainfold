package brain

import "core:os"
import "core:slice"
import "core:strings"

import "jm:path"

// `brain import` reads what an agent remembered on its own and proposes it,
// one bullet per memory, into the inbox: nothing enters the vault until a
// person approves it.
//
//	brain import --list            every source on this machine, with its memories and how many are new
//	brain import claude [--all]    this repository's Claude Code memories, or every project's
//	brain import gemini            what Gemini CLI saved under "## Gemini Added Memories"
//	brain import <path>            one source: a Claude Code memory directory, or a markdown file
//
// Claude Code keeps one file per memory under ~/.claude/projects/<slug>/
// memory/ with MEMORY.md as the index; Gemini CLI's save_memory tool
// appends a line per memory to a section of ~/.gemini/GEMINI.md (as known
// in 2026-06; no machine here has one to read); any other markdown file is
// read as a list, one proposal per bullet line. A memory the vault already
// says, one a person dropped, and one already waiting are not proposed
// again (proposal_fate), so importing twice proposes nothing new.

// Import_Source is one place an agent's memories are kept.
Import_Source :: struct {
	kind:  string, // "claude", "gemini" or "file"
	label: string, // what a person knows it by: the project, or the file
	path:  string, // the memory directory, or the file
	lines: []string, // its memories as bullet lines
}

GEMINI_SECTION :: "## Gemini Added Memories"

cmd_import :: proc(cli: ^Cli, args: []string) -> int {
	usage :: "usage: brain import --list | claude [--all] | gemini | <memory dir or file.md>"
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	if len(args) == 0 {
		return fail(cli, usage)
	}
	sources := make([dynamic]Import_Source)
	switch args[0] {
	case "--list":
		if len(args) != 1 {
			return fail(cli, usage)
		}
		return import_list(cli)
	case "claude":
		switch {
		case len(args) == 2 && args[1] == "--all":
			for src in import_sources(cli) {
				if src.kind == "claude" {
					append(&sources, src)
				}
			}
		case len(args) == 1:
			root, _ := repo_here(cli)
			dir := path.join(claude_root(cli), claude_slug(root), "memory")
			if src, ok := claude_source(dir, cli.home); ok {
				append(&sources, src)
			}
		case:
			return fail(cli, usage)
		}
		if len(sources) == 0 {
			return fail(cli, strings.concatenate({"no Claude Code memories under ", claude_root(cli)}))
		}
	case "gemini":
		src, ok := gemini_source(cli)
		if !ok || len(args) != 1 {
			return fail(cli, ok ? usage : strings.concatenate({"no Gemini CLI memories in ", gemini_file(cli)}))
		}
		append(&sources, src)
	case:
		if len(args) != 1 {
			return fail(cli, usage)
		}
		src, err := path_source(cli, args[0])
		if err != "" {
			return fail(cli, err)
		}
		append(&sources, src)
	}

	memories, queued := 0, 0
	quiet := cli.json
	cli.json = false
	for src in sources {
		for l in src.lines {
			memories += 1
			line := complete_bullet(l, src.label)
			if proposal_fate(cli, line) != "new" {
				continue
			}
			if code := propose_line(cli, line); code == 0 {
				queued += 1
			}
		}
	}
	cli.json = quiet
	if cli.json {
		// The per-proposal lines were for a person; the object is the answer.
		strings.builder_reset(&cli.out)
		w := jw_make()
		jw_obj(&w)
		jw_field_int(&w, "sources", i64(len(sources)))
		jw_field_int(&w, "memories", i64(memories))
		jw_field_int(&w, "proposed", i64(queued))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	outf(cli, "%d proposal(s) from %d memories in %d source(s); brain inbox lists them\n", queued, memories, len(sources))
	return 0
}

// import_list says what each source holds and how much of it is new.
import_list :: proc(cli: ^Cli) -> int {
	sources := import_sources(cli)
	w := jw_make()
	jw_obj(&w)
	jw_key(&w, "sources")
	jw_arr(&w)
	for src in sources {
		fresh := 0
		for l in src.lines {
			if proposal_fate(cli, complete_bullet(l, src.label)) == "new" {
				fresh += 1
			}
		}
		if cli.json {
			jw_obj(&w)
			jw_field(&w, "kind", src.kind)
			jw_field(&w, "label", src.label)
			jw_field(&w, "path", src.path)
			jw_field_int(&w, "memories", i64(len(src.lines)))
			jw_field_int(&w, "new", i64(fresh))
			jw_end_obj(&w)
		} else {
			outf(cli, "%-7s %d memories, %d new  %s  (%s)\n", src.kind, len(src.lines), fresh, src.label, src.path)
		}
	}
	jw_end_arr(&w)
	jw_end_obj(&w)
	if cli.json {
		jw_flush(cli, &w)
	} else if len(sources) == 0 {
		outf(cli, "no agent memories on this machine\n")
	}
	return 0
}

// import_sources is every source of memories on this machine: each Claude
// Code project with any, then Gemini CLI's.
import_sources :: proc(cli: ^Cli) -> []Import_Source {
	out := make([dynamic]Import_Source)
	root := claude_root(cli)
	if entries, err := os.read_all_directory_by_path(root, context.allocator); err == nil {
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for e in entries {
			if e.type != .Directory {
				continue
			}
			if src, ok := claude_source(path.join(root, e.name, "memory"), cli.home); ok {
				append(&out, src)
			}
		}
	}
	if src, ok := gemini_source(cli); ok {
		append(&out, src)
	}
	return out[:]
}

// claude_source is a Claude Code memory directory as a source, labelled
// with the project it belongs to: the working directory its transcripts
// record, under home written from ~, else its directory's name.
claude_source :: proc(dir, home: string) -> (src: Import_Source, ok: bool) {
	project := claude_project(path.dir(dir))
	lines := claude_bullets(dir, path.base(project))
	if len(lines) == 0 {
		return {}, false
	}
	label := project
	if home != "" && strings.has_prefix(project, home) {
		label = strings.concatenate({"~", project[len(home):]})
	}
	return {kind = "claude", label = label, path = dir, lines = lines}, true
}

// claude_project is the project a Claude Code project directory is for.
claude_project :: proc(dir: string) -> string {
	for f in files_with_suffix(dir, ".jsonl") {
		text, ok := read_text(f)
		if !ok {
			continue
		}
		for l in strings.split_lines(text) {
			if strings.contains(l, `"cwd":"`) {
				if cwd := json_string(parse_line(l), "cwd"); cwd != "" {
					return cwd
				}
			}
		}
	}
	return path.base(dir)
}

// gemini_file is where Gemini CLI keeps the memories it saves.
gemini_file :: proc(cli: ^Cli) -> string {
	return path.join(cli.home, ".gemini", "GEMINI.md")
}

// gemini_source is Gemini CLI's saved memories: the list under
// GEMINI_SECTION, to the next heading.
gemini_source :: proc(cli: ^Cli) -> (src: Import_Source, ok: bool) {
	file := gemini_file(cli)
	text, rok := read_text(file)
	if !rok {
		return {}, false
	}
	i := strings.index(text, GEMINI_SECTION)
	if i < 0 {
		return {}, false
	}
	section := text[i + len(GEMINI_SECTION):]
	if j := strings.index(section, "\n#"); j >= 0 {
		section = section[:j]
	}
	lines := list_bullets(section)
	if len(lines) == 0 {
		return {}, false
	}
	for &l in lines {
		if len(strings.split(l, SEP)) == 2 {
			l = strings.concatenate({l, SEP, "gemini memory"})
		}
	}
	return {kind = "gemini", label = "gemini memory", path = file, lines = lines}, true
}

// path_source is one source named by its path: a Claude Code memory
// directory, Gemini CLI's file, or any markdown file read as a list.
path_source :: proc(cli: ^Cli, p: string) -> (src: Import_Source, err: string) {
	if os.is_dir(p) {
		if s, ok := claude_source(p, cli.home); ok {
			return s, ""
		}
		return {}, strings.concatenate({"no Claude Code memories in ", p})
	}
	if p == gemini_file(cli) {
		if s, ok := gemini_source(cli); ok {
			return s, ""
		}
	}
	text, ok := read_text(p)
	if !ok {
		return {}, strings.concatenate({"cannot read ", p})
	}
	lines := list_bullets(text)
	if len(lines) == 0 {
		return {}, strings.concatenate({"no bullet lines in ", p})
	}
	label := strings.concatenate({"imported from ", path.base(p)})
	return {kind = "file", label = label, path = p, lines = lines}, ""
}

// claude_slug is the directory name Claude Code gives a project: its path
// with every character that is not a letter or digit turned into a dash.
claude_slug :: proc(root: string) -> string {
	buf := make([]byte, len(root))
	for c, i in transmute([]byte)root {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'):
			buf[i] = c
		case:
			buf[i] = '-'
		}
	}
	return string(buf)
}

// claude_bullets turns a Claude Code memory directory into bullet lines.
// Each index line is `- [Title](file.md) — hook`; the file holds
// frontmatter (name, description, type) and a body, which becomes the fact,
// one line. A memory with no file keeps its hook.
claude_bullets :: proc(dir: string, project := "") -> []string {
	index, ok := read_text(path.join(dir, "MEMORY.md"))
	if !ok {
		return nil
	}
	out := make([dynamic]string)
	for l in strings.split_lines(index) {
		if !strings.has_prefix(l, "- [") {
			continue
		}
		title, found := between(l, "- [", "]")
		if !found || title == "" {
			continue
		}
		file, _ := between(l, "](", ")")
		fact := ""
		if i := strings.index(l, SEP); i >= 0 {
			fact = strings.trim_space(l[i + len(SEP):])
		}
		kind := ""
		if file != "" {
			if text, fok := read_text(path.join(dir, file)); fok {
				body, fm := split_frontmatter(text)
				if b := one_line(body); b != "" {
					fact = b
				}
				kind = fm["type"]
			}
		}
		if fact == "" {
			continue
		}
		who := kind != "" ? strings.concatenate({"claude memory (", kind, ")"}) : "claude memory"
		if project != "" {
			who = strings.concatenate({who, " in ", project})
		}
		append(&out, strings.concatenate({"- **", title, "**", SEP, fact, SEP, who}))
	}
	return out[:]
}

// split_frontmatter separates a leading `---` block into its `key: value`
// lines and the body after it.
split_frontmatter :: proc(text: string) -> (body: string, fields: map[string]string) {
	fields = make(map[string]string)
	if !strings.has_prefix(text, "---\n") {
		return text, fields
	}
	rest := text[4:]
	end := strings.index(rest, "\n---")
	if end < 0 {
		return text, fields
	}
	for l in strings.split_lines(rest[:end]) {
		if i := strings.index(l, ":"); i > 0 {
			fields[strings.trim_space(l[:i])] = strings.trim_space(l[i + 1:])
		}
	}
	body = rest[end + len("\n---"):]
	return strings.trim_space(body), fields
}

// one_line joins a body's lines with spaces.
one_line :: proc(body: string) -> string {
	return strings.join(strings.fields(body), " ")
}

// list_bullets reads every `- ` or `* ` line of a markdown file as a fact,
// with its first words as the handle. A line that is a bullet in the
// vault's own shape is kept as it is.
list_bullets :: proc(text: string) -> []string {
	out := make([dynamic]string)
	for raw in strings.split_lines(text) {
		l := strings.trim_space(raw)
		if !strings.has_prefix(l, "- ") && !strings.has_prefix(l, "* ") {
			continue
		}
		if strings.has_prefix(l, "- **") {
			append(&out, l)
			continue
		}
		fact := strings.trim_space(l[2:])
		if fact == "" {
			continue
		}
		words := strings.fields(fact)
		n := min(len(words), 5)
		handle := strings.trim_right(strings.join(words[:n], " "), ".,;:")
		append(&out, strings.concatenate({"- **", handle, "**", SEP, fact}))
	}
	return out[:]
}
