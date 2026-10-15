package brain

import "core:fmt"
import "core:os"
import "core:strings"

import git "jm:git"
import "jm:i18n"
import "jm:path"

import "../msg"

// Everything install writes to a file the user owns goes inside a tagged
// block, so it can be replaced on re-install and removed by `brain uninstall`
// without touching a line the user wrote.

EXE :: ".exe" when ODIN_OS == .Windows else ""

os_kind :: proc() -> string {
	when ODIN_OS == .Windows {
		return "windows"
	} else when ODIN_OS == .Darwin {
		return "macos"
	} else when ODIN_OS == .Linux {
		return "linux"
	} else {
		return "unknown"
	}
}

say :: proc(cli: ^Cli, format: string, args: ..any) {
	if cli.json {
		return
	}
	out(cli, cli.dry ? "  [dry] " : "  ")
	outf(cli, format, ..args)
	out(cli, "\n")
}

note :: proc(cli: ^Cli, format: string, args: ..any) {
	if cli.json {
		return
	}
	out(cli, "  ")
	outf(cli, format, ..args)
	out(cli, "\n")
}

// told is a dry-run line of the install report, in the language in use.
told :: proc(cli: ^Cli, key: msg.Msg, args: ..i18n.Arg) {
	say(cli, "%s", phrase(cli, key, ..args))
}

// aside is a note of the install report, in the language in use.
aside :: proc(cli: ^Cli, key: msg.Msg, args: ..i18n.Arg) {
	note(cli, "%s", phrase(cli, key, ..args))
}

block_begin :: proc(co, tag, cc: string, by := "brain install") -> string {
	return fmt.aprintf("%s brain:%s >>> managed by `%s`; edit the vault, not this block %s", co, tag, by, cc)
}

block_end :: proc(co, tag, cc: string) -> string {
	return fmt.aprintf("%s brain:%s <<< %s", co, tag, cc)
}

read_text :: proc(p: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(p, context.allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

backup :: proc(p: string) {
	os.copy_file(strings.concatenate({p, ".brain-backup"}), p)
}

// block_apply writes body between the tag's markers in file, adding the
// block at the top when it is absent and replacing it when it differs.
block_apply :: proc(cli: ^Cli, file, tag, co, cc, body: string, by := "brain install") -> (status: string) {
	b := block_begin(co, tag, cc, by)
	e := block_end(co, tag, cc)
	open_mark := strings.concatenate({"brain:", tag, " >>>"})
	close_mark := strings.concatenate({"brain:", tag, " <<<"})
	want := strings.concatenate({b, "\n", body, "\n", e})
	text, exists := read_text(file)
	if exists && strings.contains(text, open_mark) {
		cur := make([dynamic]string)
		in_block := false
		for l in strings.split_lines(text) {
			if strings.contains(l, open_mark) {
				in_block = true
			}
			if in_block {
				append(&cur, l)
			}
			if in_block && strings.contains(l, close_mark) {
				in_block = false
			}
		}
		if strings.join(cur[:], "\n") == want {
			told(cli, .Install_Current, file)
			return "current"
		}
		told(cli, .Install_Refreshed, file)
		if cli.dry {
			return "refreshed"
		}
		backup(file)
		path.write(file, replace_block(text, open_mark, close_mark, want))
		return "refreshed"
	}
	told(cli, .Install_Added, file)
	if cli.dry {
		return "added"
	}
	if exists && text != "" {
		backup(file)
	}
	path.mkdirs(path.dir(file))
	path.write(file, strings.concatenate({want, "\n\n", text}))
	return "added"
}

// replace_block swaps the lines from the open marker to the close marker for
// replacement; an empty replacement removes them.
replace_block :: proc(text, open_mark, close_mark, replacement: string) -> string {
	lines := make([dynamic]string)
	skip := false
	for l in strings.split_lines(text) {
		if strings.contains(l, open_mark) {
			if replacement != "" {
				append(&lines, replacement)
			}
			skip = true
			continue
		}
		if skip {
			if strings.contains(l, close_mark) {
				skip = false
			}
			continue
		}
		append(&lines, l)
	}
	return strings.join(lines[:], "\n")
}

block_remove :: proc(cli: ^Cli, file, tag: string) {
	text, exists := read_text(file)
	open_mark := strings.concatenate({"brain:", tag, " >>>"})
	if !exists || !strings.contains(text, open_mark) {
		return
	}
	told(cli, .Install_Removed, file)
	if cli.dry {
		return
	}
	path.write(file, replace_block(text, open_mark, strings.concatenate({"brain:", tag, " <<<"}), ""))
}

// In .bashrc the block must sit above the interactive early-return, or shells
// that source the file non-interactively never reach it.
rc_block :: proc(cli: ^Cli, rc, body, tag: string, by := "brain install") {
	GUARD :: "[[ $- != *i* ]] && return"
	text, exists := read_text(rc)
	if exists && strings.contains(text, GUARD) && !strings.contains(text, strings.concatenate({"brain:", tag, " >>>"})) {
		told(cli, .Install_Added_Above, rc)
		if cli.dry {
			return
		}
		backup(rc)
		lines := make([dynamic]string)
		done := false
		for l in strings.split_lines(text) {
			if !done && strings.has_prefix(l, GUARD) {
				append(&lines, block_begin("#", tag, "", by), body, block_end("#", tag, ""), "")
				done = true
			}
			append(&lines, l)
		}
		path.write(rc, strings.join(lines[:], "\n"))
		return
	}
	block_apply(cli, rc, tag, "#", "", body, by)
}

// posix_path is the form a PATH entry takes in a file Git Bash reads: on
// Windows C:\a\b becomes /c/a/b, since bash splits PATH on the colon.
posix_path :: proc(p: string) -> string {
	when ODIN_OS == .Windows {
		fwd, _ := strings.replace_all(p, "\\", "/")
		if len(fwd) >= 2 && fwd[1] == ':' && is_drive_letter(fwd[0]) {
			drive := fwd[0] + ('a' - 'A') if fwd[0] <= 'Z' else fwd[0]
			return fmt.aprintf("/%c%s", drive, fwd[2:])
		}
		return fwd
	} else {
		return p
	}
}

on_path :: proc(cli: ^Cli, dir: string) -> bool {
	sep := ";" when ODIN_OS == .Windows else ":"
	for d in strings.split(getenv(cli, "PATH"), sep) {
		if d != "" && path.same(d, dir) {
			return true
		}
	}
	return false
}

// The same preference order the justfile standard uses for `install`.
pick_bindir :: proc(cli: ^Cli) -> string {
	candidates := [5]string {
		path.join(cli.home, ".local", "bin"),
		path.join(cli.home, "bin"),
		getenv(cli, "GOBIN"),
		getenv(cli, "GOPATH") != "" ? path.join(getenv(cli, "GOPATH"), "bin") : "",
		"/usr/local/bin",
	}
	for d in candidates {
		if d != "" && os.is_dir(d) && writable_dir(d) {
			return d
		}
	}
	d := path.join(cli.home, ".local", "bin")
	if !cli.dry {
		path.mkdirs(d)
	}
	return d
}

writable_dir :: proc(d: string) -> bool {
	probe := path.join(d, ".brain-write-probe")
	if path.write(probe, "") != nil {
		return false
	}
	os.remove(probe)
	return true
}

// Which files a login shell reads differs per platform: zsh is the macOS
// default and reads .zshenv for every invocation, Git Bash reads .bashrc.
path_rc_files :: proc(cli: ^Cli) -> []string {
	files := make([dynamic]string)
	when ODIN_OS == .Darwin {
		append(&files, path.join(cli.home, ".zshenv"), path.join(cli.home, ".bash_profile"))
	} else {
		append(&files, path.join(cli.home, ".bashrc"))
	}
	return files[:]
}

// The tool's data files that hooks and scans read live beside the checkout,
// so install records where that is for the installed copy to find.
record :: proc(cli: ^Cli, file, value: string) {
	path.mkdirs(path.dir(file))
	path.write(file, strings.concatenate({value, "\n"}))
}

// canonical_vault is where a vault lives when nobody has said otherwise.
canonical_vault :: proc(cli: ^Cli) -> string {
	return path.join(cli.home, "Documents", "Brain")
}

// install_vault is the vault install binds, in order of authority: the path
// given, BRAIN_VAULT, the vault an earlier install recorded, and the
// canonical path. Nothing is searched for. created is true when the
// canonical path does not exist yet and install has to make it.
install_vault :: proc(cli: ^Cli, given: string, fresh := false) -> (vault: string, created: bool, err: string) {
	named := given
	if named == "" {
		named = getenv(cli, "BRAIN_VAULT")
	}
	if named != "" {
		if !os.is_dir(named) && !(fresh && cli.dry) {
			return "", false, phrase(cli, .Install_No_Dir, named)
		}
		abs, aerr := path.abs(named)
		return aerr == nil ? abs : clean(named), fresh, ""
	}
	if v := recorded_path(cli.conf_vault); v != "" && os.is_dir(v) {
		return clean(v), false, ""
	}
	v := canonical_vault(cli)
	if os.exists(v) && !os.is_dir(v) {
		return "", false, phrase(cli, .Install_Not_Dir, v)
	}
	return v, !os.exists(v), ""
}

// create_vault writes the starter vault and makes it a git repository, since
// the hooks install binds are git hooks.
create_vault :: proc(cli: ^Cli, vault: string) -> string {
	for f in STARTER {
		file := path.join(vault, f.name)
		if err := path.mkdirs(path.dir(file)); err != nil {
			return phrase(cli, .Install_Cannot_Create, vault, fmt.tprintf("%v", err))
		}
		if err := path.write(file, f.body); err != nil {
			return phrase(cli, .Install_Cannot_Write, file, fmt.tprintf("%v", err))
		}
	}
	if repo, err := git.init(vault); err != nil {
		aside(cli, .Install_Unversioned, vault, fault_text(err))
	} else {
		git.close(&repo)
	}
	return ""
}

cmd_install :: proc(cli: ^Cli, args: []string) -> int {
	cli.dry = false
	given := ""
	fresh := false
	for arg in args {
		switch {
		case arg == "--dry-run":
			cli.dry = true
		case arg == "--new":
			fresh = true
		case strings.has_prefix(arg, "-"):
			return fail(cli, phrase(cli, .Install_Unknown, arg))
		case arg == "":
		case:
			given = arg
		}
	}
	// --new <dir>: a starter vault in a folder a person chose, made when it
	// is not there yet; never over one that holds anything.
	if fresh {
		if given == "" {
			return fail(cli, phrase(cli, .Install_New))
		}
		if !cli.dry {
			if err := prepare_vault_dir(given); err != "" {
				return fail(cli, err)
			}
		}
	}
	vault, created, verr := install_vault(cli, given, fresh)
	if verr != "" {
		return fail(cli, verr)
	}
	cli.vault = vault
	kind := os_kind()
	hooks := path.join(cli.conf_dir, "hooks")
	bindir := pick_bindir(cli)

	outf(cli, "%s\n", phrase(cli, .Install_Tool, cli.tool))
	outf(cli, "%s\n", phrase(cli, .Install_Vault_Line, vault, kind))
	if created {
		if !cli.dry {
			if err := create_vault(cli, vault); err != "" {
				return fail(cli, err)
			}
		}
		told(cli, .Install_Created)
	} else if !os.is_dir(path.join(vault, "AI")) {
		aside(cli, .Install_No_Ai, vault)
	}
	if !cli.dry {
		path.mkdirs(cli.state)
		record(cli, cli.conf_vault, vault)
		record(cli, path.join(cli.conf_dir, "tool"), cli.tool)
	}
	told(cli, .Install_Recorded, cli.conf_vault)

	outf(cli, "%s\n", phrase(cli, .Install_Head_Cli))
	installed := install_binary(cli, bindir)
	// The hooks are compiled into the binary and written out here, with the
	// binary's own path inside each: git runs hooks with whatever PATH it
	// has, which in a GUI or a service is not the user's shell PATH.
	if !cli.dry {
		hook_files := HOOKS
		if err := write_executables(hooks, hook_files[:], posix_path(installed)); err != nil {
			aside(cli, .Cannot_Write, hooks, fmt.tprintf("%v", err))
		}
	}
	told(cli, .Install_Hooks_Under, hooks)
	if on_path(cli, bindir) {
		aside(cli, .Install_On_Path, bindir)
	} else {
		for rc in path_rc_files(cli) {
			rc_block(cli, rc, fmt.aprintf("export PATH=\"%s:$PATH\"", posix_path(bindir)), "path")
		}
		aside(cli, .Install_New_Shell, posix_path(bindir))
		if kind == "windows" {
			aside(cli, .Install_Windows_Path, bindir)
		}
	}

	outf(cli, "%s\n", phrase(cli, .Install_Head_Git))
	// The hooks live outside the vault, so this path has to be absolute.
	if !cli.dry {
		if repo, err := git.open(vault); err == nil {
			git.config_set(repo, "core.hooksPath", hooks)
			git.close(&repo)
		}
	}
	told(cli, .Install_Hooks_Path, hooks)

	// Earlier versions installed PATH shims that refused commands the vault
	// recorded as traps. The guarded commands were vault knowledge hard-coded
	// into the tool, so the shims went; what they left behind is removed.
	remove_guards(cli)

	outf(cli, "%s\n", phrase(cli, .Install_Head_Agents))
	// ~/.agents/AGENTS.md is the canonical binding: pi and Codex already
	// symlink to it, so pointing it at this vault is all a new machine needs.
	agents := path.join(cli.home, ".agents", "AGENTS.md")
	target := path.join(vault, "AI", "AGENTS.md")
	if cli.dry {
		told(cli, .Install_Agents_Link, agents, target)
	} else {
		path.mkdirs(path.dir(agents))
		if link_or_copy(agents, target) {
			told(cli, .Install_Agents_Link, agents, target)
		} else if os.copy_file(agents, target) == nil {
			told(cli, .Install_Copied_Agents, agents)
		} else {
			told(cli, .Install_Could_Not_Link, agents)
		}
	}
	// Tilde imports are supported, so this block is identical on every machine.
	claude_md := path.join(cli.home, ".claude", "CLAUDE.md")
	block_apply(cli, claude_md, "claude", "<!--", "-->", CLAUDE_BLOCK)
	hooks_apply(cli, posix_path(installed))
	// BRAIN_CONNECT=<url> on a second machine: one install that ends with the
	// first machine's vault.
	if where_ := getenv(cli, "BRAIN_CONNECT"); where_ != "" {
		sync_connect(cli, where_)
	}
	// An absolute import of the same file would load it a second time.
	if text, ok := read_text(claude_md); ok {
		dup := strings.concatenate({vault, "/AI/AGENTS.md"})
		kept := make([dynamic]string)
		dropped := false
		for l in strings.split_lines(text) {
			if strings.has_prefix(l, "@") && strings.has_suffix(l, dup) {
				dropped = true
				continue
			}
			append(&kept, l)
		}
		if dropped {
			told(cli, .Install_Drop_Import, claude_md)
			if !cli.dry {
				path.write(claude_md, strings.join(kept[:], "\n"))
			}
		}
	}
	// pi and Codex are pointer-only by design; verify rather than edit them.
	for a in ([2]string{path.join(cli.home, ".pi", "agent", "AGENTS.md"), path.join(cli.home, ".codex", "AGENTS.md")}) {
		if os.exists(a) {
			if _, ok := read_text(a); ok {
				aside(cli, .Install_Resolves, a)
			} else {
				aside(cli, .Install_Unreadable, a)
			}
		} else {
			aside(cli, .Install_Absent, a, agents)
		}
	}

	outf(cli, "%s\n", phrase(cli, .Install_Head_Scanner))
	if gl, found := find_gitleaks(cli); found {
		aside(cli, .Install_Gitleaks, gl)
	} else {
		aside(cli, .Install_Gitleaks_Missing)
	}

	if cli.dry {
		outf(cli, "\n%s\n", phrase(cli, .Install_Dry))
		return 0
	}
	return cmd_reindex(cli, nil)
}

// The block describes brain and leaves the asking to the hooks: an
// imperative "find before acting" line, tried on 2026-10-02, made the agent
// call pack and find on every task, right or not, for +55K tokens a task
// where the hooks already primed it for +35K; the line lives in what
// `brain export` writes for agents without hooks (ASK_HEAD).
CLAUDE_BLOCK :: "@~/.agents/AGENTS.md\n\nThe Brain is this machine's shared agent memory. `brain locate` prints its path,\n`brain find <handle>` searches it, and `brain recall <terms>` searches what was\nsaid in past agent conversations. Do not hard-code the path. A session opens\nwith `brain pack`, the vault's bullets about this repository. When work settles\na durable fact, `brain propose '- **handle** (aliases: ...) — fact'` records it\nfor a person to review; never edit the vault's core files directly."

// install_binary puts this executable on PATH as `brain`. A symlink keeps an
// installed command current with its checkout; where links are refused
// (Windows without Developer Mode) the file is copied and the recorded tool
// path keeps it pointed at the checkout. The shell version's wrappers are
// removed, because Git Bash would run a `brain` script before `brain.exe`.
install_binary :: proc(cli: ^Cli, bindir: string) -> (dest: string) {
	dest = path.join(bindir, strings.concatenate({"brain", EXE}))
	// BRAIN_EXE names another build to install, for a script that installs
	// a release binary and for the tests, whose running executable is the
	// test runner.
	exe := getenv(cli, "BRAIN_EXE")
	if exe == "" {
		found, err := os.get_executable_path(context.allocator)
		if err != nil {
			aside(cli, .Install_No_Exe, fmt.tprintf("%v", err))
			return
		}
		exe = found
	}
	if cli.dry {
		told(cli, .Install_Cli_Arrow, dest, exe)
		return
	}
	when ODIN_OS == .Windows {
		for stale in ([2]string{path.join(bindir, "brain"), path.join(bindir, "brain.cmd")}) {
			if os.is_file(stale) && os.remove(stale) == nil {
				told(cli, .Install_Removed_Wrapper, stale)
			}
		}
	}
	if path.same(dest, exe) {
		told(cli, .Install_Cli_Same, dest)
		return
	}
	if link_or_copy(dest, exe) {
		told(cli, .Install_Cli_Linked, dest, exe)
	} else if os.copy_file(dest, exe) == nil {
		os.change_mode(dest, os.Permissions_All - os.Permissions_Write_All + {.Write_User})
		told(cli, .Install_Copied_Cli, dest)
	} else {
		told(cli, .Install_Could_Not_Install, dest)
	}
	return
}

// link_or_copy replaces link with a symlink to target and reports whether
// the result is a link. A refusal leaves nothing behind.
link_or_copy :: proc(link, target: string) -> bool {
	if os.exists(link) || is_link(link) {
		os.remove(link)
	}
	if !symlink(target, link) {
		return false
	}
	return is_link(link)
}

is_link :: proc(p: string) -> bool {
	_, err := os.read_link(p, context.temp_allocator)
	return err == nil
}

// remove_guards undoes what the shell-era guard shims installed: the rc
// block that put them on PATH, the environment.d entry, the written shims,
// and the still older shell-function guard line in .bashrc. Nothing is
// printed when there is nothing to remove.
remove_guards :: proc(cli: ^Cli) {
	for rc in path_rc_files(cli) {
		block_remove(cli, rc, "guards")
	}
	bashrc := path.join(cli.home, ".bashrc")
	if text, ok := read_text(bashrc); ok && strings.contains(text, "brain-guards.sh") {
		told(cli, .Install_Remove_Guard, bashrc)
		if !cli.dry {
			kept := make([dynamic]string)
			for l in strings.split_lines(text) {
				if strings.contains(l, "brain-guards.sh") || strings.has_prefix(l, "# Brain guards: refuse") {
					continue
				}
				append(&kept, l)
			}
			path.write(bashrc, strings.join(kept[:], "\n"))
		}
	}
	envd := path.join(cli.home, ".config", "environment.d", "10-brain-shims.conf")
	if os.exists(envd) {
		told(cli, .Install_Remove, envd)
		if !cli.dry {
			os.remove(envd)
		}
	}
	shims := path.join(cli.conf_dir, "shims")
	if os.is_dir(shims) {
		told(cli, .Install_Remove, shims)
		if !cli.dry {
			os.remove_all(shims)
		}
	}
}

cmd_uninstall :: proc(cli: ^Cli, args: []string) -> int {
	cli.dry = len(args) > 0 && args[0] == "--dry-run"
	outf(cli, "%s\n", phrase(cli, .Install_Uninstall))
	for rc in path_rc_files(cli) {
		block_remove(cli, rc, "path")
	}
	remove_guards(cli)
	block_remove(cli, path.join(cli.home, ".claude", "CLAUDE.md"), "claude")
	hooks_remove(cli)
	bindir := pick_bindir(cli)
	for f in ([5]string {
			cli.conf_vault,
			path.join(cli.conf_dir, "tool"),
			path.join(bindir, "brain"),
			path.join(bindir, "brain.exe"),
			path.join(bindir, "brain.cmd"),
		}) {
		if !os.exists(f) && !is_link(f) {
			continue
		}
		told(cli, .Install_Remove, f)
		if !cli.dry {
			os.remove(f)
		}
	}
	hooks := path.join(cli.conf_dir, "hooks")
	if os.is_dir(hooks) {
		told(cli, .Install_Remove, hooks)
		if !cli.dry {
			os.remove_all(hooks)
		}
	}
	aside(cli, .Install_Left, cli.state)
	if cli.dry {
		outf(cli, "%s\n", phrase(cli, .Install_Dry))
	}
	return 0
}
