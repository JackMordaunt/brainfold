package brain

import "core:os"
import "core:strings"
import "core:time"

import git "jm:git"
import "jm:sh"

// The vault's history goes through jm:git, libgit2 linked into the
// binary, so a machine without git still versions, syncs and checks its
// vault. The git hooks are the one exception: git runs them, so they
// only exist where git does.

// vault_repo opens the vault's repository; ok is false when the vault is
// not versioned.
vault_repo :: proc(cli: ^Cli) -> (repo: git.Repo, ok: bool) {
	if !os.exists(cli.vault) {
		return
	}
	r, err := git.open(cli.vault)
	return r, err == nil
}

// identity is who the vault's commits are by: the person's own git
// identity when they have one, else brain on this machine, so a machine
// with no name set up still writes down what changed. A write-down is
// the machine's, not a signed statement of the person's, and jm:git's
// commit gives libgit2 nothing to sign with: a machine set to sign every
// commit (2026-10-02, "gpg failed to sign the data") writes down all the
// same.
identity :: proc(repo: git.Repo) -> git.Signature {
	email, found := git.config_get(repo, "user.email")
	if found && strings.trim_space(email) != "" {
		name, _ := git.config_get(repo, "user.name")
		if strings.trim_space(name) == "" {
			name = "brain"
		}
		return {name, email}
	}
	return {"brain", strings.concatenate({"brain@", host_name()})}
}

// remote_url is where the remote name points, "" when there is none.
remote_url :: proc(repo: git.Repo, name: string) -> string {
	rs, _ := git.remotes(repo)
	for r in rs {
		if r.name == name {
			return r.url
		}
	}
	return ""
}

// sync_creds answers an HTTPS remote that asks who is pushing: the token
// in BRAIN_SYNC_TOKEN, else, for GitHub, the one the gh command is
// signed in with. An ssh remote needs none; ssh and its agent answer.
sync_creds :: proc(cli: ^Cli, url: string) -> git.Credentials {
	if tok := strings.trim_space(getenv(cli, "BRAIN_SYNC_TOKEN")); tok != "" {
		return {token = tok}
	}
	if strings.has_prefix(url, "https://github.com/") {
		if _, found := sh.which("gh"); found {
			if r := sh.exec({"gh", "auth", "token"}, {timeout = 3 * time.Second}); r.ok {
				return {token = strings.trim_space(r.stdout)}
			}
		}
	}
	return {}
}

// fault_text is what a failed git call said, for a person.
fault_text :: proc(err: git.Error) -> string {
	if f, is_fault := err.(git.Fault); is_fault {
		return f.message
	}
	return ""
}
