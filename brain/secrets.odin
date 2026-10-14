package brain

import "core:os"
import "core:strings"
import "core:text/regex"

import git "jm:git"
import "jm:path"
import "jm:sh"

// ~/go/bin is not on a non-interactive PATH on every machine, and the hook
// runs non-interactively, so the scanner is resolved explicitly. A gate that
// silently fails to run is worse than no gate.
find_gitleaks :: proc(cli: ^Cli) -> (string, bool) {
	exe := "gitleaks.exe" when ODIN_OS == .Windows else "gitleaks"
	for c in ([4]string {
			path.join(cli.home, "go", "bin", exe),
			"/usr/bin/gitleaks",
			"/usr/local/bin/gitleaks",
			"/opt/homebrew/bin/gitleaks",
		}) {
		if os.is_file(c) {
			return c, true
		}
	}
	return sh.which("gitleaks")
}

// A vault may carry its own allowlist; otherwise the tool's default ruleset
// applies, so a fresh clone is still scanned. gitleaks reads a file, so the
// embedded ruleset is written under the state directory on every run.
gitleaks_config :: proc(cli: ^Cli) -> string {
	own := path.join(cli.vault, ".gitleaks.toml")
	if os.is_file(own) {
		return own
	}
	path.mkdirs(cli.state)
	p := path.join(cli.state, "gitleaks.toml")
	path.write(p, GITLEAKS_TOML)
	return p
}

// A floor for machines without gitleaks: only patterns that cannot plausibly
// be anything else. No 40-hex rule — that is a git SHA, and a vault is full
// of them.
FALLBACK_PATTERNS :: [6]string {
	`BEGIN [A-Z ]*PRIVATE KEY`,
	`AKIA[0-9A-Z]{16}`,
	`gh[pousr]_[A-Za-z0-9]{36,}`,
	`xox[baprs]-[A-Za-z0-9-]{10,}`,
	`eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`,
	`[0-9a-f]{64,}`,
}

cmd_secrets :: proc(cli: ^Cli, args: []string) -> int {
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	mode := len(args) > 0 ? args[0] : "--staged"
	cfg := gitleaks_config(cli)
	patch := secrets_patch(cli, mode == "--history")

	if gl, found := find_gitleaks(cli); found {
		// gitleaks reads what was added, as its own git mode does, so a
		// change that removes a secret is never refused for it.
		r := sh.exec({gl, "stdin", "--no-banner", "--redact", "--config", cfg}, {stdin = added_lines(patch)})
		if r.err != nil {
			return fail(cli, sh.error(r))
		}
		if cli.json {
			w := jw_make()
			jw_obj(&w)
			jw_field_bool(&w, "clean", r.code == 0)
			jw_field(&w, "scanner", "gitleaks")
			jw_field(&w, "mode", mode)
			jw_field(&w, "output", strings.trim_space(strings.concatenate({r.stdout, r.stderr})))
			jw_end_obj(&w)
			jw_flush(cli, &w)
			return r.code
		}
		out(cli, r.stdout)
		errf(cli, "%s", r.stderr)
		if r.code == 0 {
			said(cli, .Secrets_Clean, mode)
		}
		return r.code
	}

	errf(cli, "%s\n", phrase(cli, .Secrets_Fallback))
	errf(cli, "  %s\n", phrase(cli, .Secrets_Install))
	hits := fallback_hits(patch)
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field_bool(&w, "clean", len(hits) == 0)
		jw_field(&w, "scanner", "built-in")
		jw_field(&w, "mode", mode)
		jw_key(&w, "findings")
		jw_arr(&w)
		for h, i in hits {
			if i == 20 {
				break
			}
			jw_str(&w, h)
		}
		jw_end_arr(&w)
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return len(hits) == 0 ? 0 : 1
	}
	if len(hits) > 0 {
		errf(cli, "%s\n", phrase(cli, .Secrets_Found))
		for h, i in hits {
			if i == 20 {
				break
			}
			errf(cli, "%s\n", h)
		}
		return 1
	}
	said(cli, .Secrets_Clean_Builtin, mode)
	return 0
}

// secrets_patch is what is scanned: the staged change, or with history
// every commit's change, newest first, as `git log -p` prints them.
secrets_patch :: proc(cli: ^Cli, history: bool) -> string {
	repo, ok := vault_repo(cli)
	if !ok {
		return ""
	}
	defer git.close(&repo)
	if !history {
		patch, _ := git.diff(repo, staged = true, context_lines = 0)
		return patch
	}
	b := strings.builder_make()
	commits, _ := git.log(repo)
	for c in commits {
		_, patch, _ := git.changes(repo, c.id, context_lines = 0)
		strings.write_string(&b, patch)
	}
	return strings.to_string(b)
}

// added_lines is the lines a patch adds, without their markers.
added_lines :: proc(patch: string) -> string {
	b := strings.builder_make()
	rest := patch
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "+") && !strings.has_prefix(line, "+++") {
			strings.write_string(&b, line[1:])
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

// fallback_hits returns every line matching a built-in pattern, numbered the
// way `grep -n` numbers them.
fallback_hits :: proc(text: string) -> []string {
	res := make([]regex.Regular_Expression, len(FALLBACK_PATTERNS))
	for p, i in FALLBACK_PATTERNS {
		res[i], _ = regex.create(p)
	}
	hits := make([dynamic]string)
	rest := text
	n := 0
	for raw in strings.split_lines_iterator(&rest) {
		n += 1
		line := strings.trim_suffix(raw, "\r")
		for re in res {
			if matches(re, line) {
				append(&hits, strings.concatenate({int_str(i64(n)), ":", line}))
				break
			}
		}
	}
	return hits[:]
}
