package brain

import "core:os"
import "core:strings"
import "core:time"

import git "jm:git"
import "jm:path"
import "jm:sh"

// Sync keeps every machine's vault the same vault. It is on by default and
// needs nothing set up on one machine; on two, `brain sync connect <url>`
// (or `connect github`) names the place they meet. It runs when a session
// starts (receive what other machines wrote) and when an agent stops
// (write down what changed here, send it), inside the hooks' time budget
// and never failing a hook, and `brain sync` runs it by hand. The vault is
// versioned underneath; the surface speaks in outcomes: up to date, sent,
// received, changes waiting, not connected, offline. `brain sync off`
// turns it off for this machine.

SYNC_CONF :: "sync" // ~/.config/brain/sync: on or off
SYNC_RECEIVE_TIMEOUT :: 4 * time.Second // a session start waits this long at most
SYNC_SEND_TIMEOUT :: 8 * time.Second
SYNC_OFFLINE_HOLD :: 10 * time.Minute // after a failed reach, do not try again before this

// SYNC_ATTRIBUTES makes the fact files merge line by line: two machines that
// each appended bullets never conflict.
SYNC_ATTRIBUTES :: "AI/*.md merge=union\n"

Sync_Mode :: enum {
	Receive, // bring other machines' changes in
	Full, // write down what changed here, receive, send
}

Sync_Report :: struct {
	off, no_repo, connected, offline: bool,
	remote:                           string,
	wrote:                            int, // files written down here
	sent, received:                   int, // changes sent and received
	waiting:                          string, // why the changes here could not be written down
	conflict:                         string, // files both sides changed
	err:                              string, // why the other machines' changes could not be taken in
}

// sync_enabled reads BRAIN_SYNC, then the setting `brain sync on|off`
// wrote, and defaults to on.
sync_enabled :: proc(cli: ^Cli) -> bool {
	v := getenv(cli, "BRAIN_SYNC")
	if v == "" {
		v = strings.trim_space(first_line(path.join(cli.conf_dir, SYNC_CONF)))
	}
	return v != "off"
}

cmd_sync :: proc(cli: ^Cli, args: []string) -> int {
	usage := "usage: brain sync [on|off|status|connect <url>|connect github]"
	if err := need_vault(cli); err != "" {
		return fail(cli, err)
	}
	if len(args) == 0 {
		r := vault_sync(cli, .Full, force = true)
		return sync_say(cli, r)
	}
	// The child the hooks start: one pass, no words.
	if args[0] == "--quiet" {
		// Detached, so the hook's process group ending does not end it.
		leave_session()
		mode := Sync_Mode.Full
		if len(args) > 1 && args[1] == "--receive" {
			mode = .Receive
		}
		if !sync_lock(cli) {
			return 0
		}
		defer sync_unlock(cli)
		vault_sync(cli, mode)
		return 0
	}
	switch args[0] {
	case "on", "off":
		if len(args) != 1 {
			return fail(cli, usage)
		}
		if err := path.mkdirs(cli.conf_dir); err != nil {
			return fail(cli, phrase(cli, .Cannot_Create_Dir, cli.conf_dir))
		}
		if err := path.write(path.join(cli.conf_dir, SYNC_CONF), strings.concatenate({args[0], "\n"})); err != nil {
			return fail(cli, phrase(cli, .Sync_Setting_Fail))
		}
		if cli.json {
			w := jw_make()
			jw_obj(&w)
			jw_field(&w, "sync", args[0])
			jw_end_obj(&w)
			jw_flush(cli, &w)
		} else if args[0] == "on" {
			said(cli, .Sync_On)
		} else {
			said(cli, .Sync_Off)
		}
		return 0
	case "status":
		return sync_status(cli)
	case "connect":
		if len(args) != 2 {
			return fail(cli, usage)
		}
		return sync_connect(cli, args[1])
	}
	return fail(cli, usage)
}

// SYNC_LOCK_STALE is how old a lock may be before another pass takes it: a
// pass that died holding it.
SYNC_LOCK_STALE :: 2 * time.Minute

// sync_in_background starts one pass as a process of its own and returns at
// once, so a hook never holds the session for the network. The child is
// detached from the hook's process group (start_detached says how, for
// each platform), inherits what it needs by name, and keeps the time limits as its
// own safety. The checks that cost nothing run here first, so an
// offline machine on hold does not start a process to find out.
sync_in_background :: proc(cli: ^Cli, mode: Sync_Mode) {
	if cli.vault == "" || !sync_enabled(cli) {
		return
	}
	if !os.exists(path.join(cli.vault, ".git")) {
		return
	}
	if until := strings.trim_space(first_line(path.join(cli.state, "sync", "offline-until"))); until != "" && until > now_iso() {
		return
	}
	if sync_locked(cli) {
		return
	}
	exe := getenv(cli, "BRAIN_EXE")
	if exe == "" {
		found, err := os.get_executable_path(context.allocator)
		if err != nil {
			return
		}
		exe = found
	}
	// The child inherits by name what the pass needs, as this process sees
	// it (the tests give their Cli an environment of its own), and the
	// decision already made here: sync is on. Windows' own libraries need
	// SYSTEMROOT, the temporary directories and the profile folders to load
	// and run; the other platforms have none of these, and skip them.
	env := make([dynamic]string)
	names := [?]string {
		"PATH",
		"HOME",
		"USERPROFILE",
		"XDG_CONFIG_HOME",
		"XDG_STATE_HOME",
		"SSH_AUTH_SOCK",
		"SYSTEMROOT",
		"WINDIR",
		"TEMP",
		"TMP",
		"APPDATA",
		"LOCALAPPDATA",
		"PROGRAMDATA",
	}
	for key in names {
		if v := getenv(cli, key); v != "" {
			append(&env, strings.concatenate({key, "=", v}))
		}
	}
	append(&env, strings.concatenate({"BRAIN_VAULT=", cli.vault}))
	append(&env, strings.concatenate({"BRAIN_STATE=", cli.state}))
	append(&env, "BRAIN_SYNC=on")
	append(&env, "BRAIN_NO_UPDATE=1")
	flag := mode == .Receive ? "--receive" : "--full"
	start_detached({exe, "sync", "--quiet", flag}, cli.vault, env[:])
}

// sync_lock takes the one-pass-at-a-time lock, unless a live pass holds it.
sync_lock :: proc(cli: ^Cli) -> bool {
	if sync_locked(cli) {
		return false
	}
	lock := path.join(cli.state, "sync", "lock")
	path.mkdirs(path.dir(lock))
	return path.write(lock, strings.concatenate({now_iso(), "\n"})) == nil
}

sync_unlock :: proc(cli: ^Cli) {
	os.remove(path.join(cli.state, "sync", "lock"))
}

// sync_locked says whether a pass younger than SYNC_LOCK_STALE holds the lock.
sync_locked :: proc(cli: ^Cli) -> bool {
	taken := strings.trim_space(first_line(path.join(cli.state, "sync", "lock")))
	return taken != "" && taken > iso_after(-SYNC_LOCK_STALE)
}

host_name :: proc() -> string {
	for key in ([2]string{"HOSTNAME", "COMPUTERNAME"}) {
		if h := os.get_env(key, context.allocator); h != "" {
			return h
		}
	}
	if r := sh.exec({"hostname"}); r.ok && strings.trim_space(r.stdout) != "" {
		return strings.trim_space(r.stdout)
	}
	return "this machine"
}

// vault_sync is one pass. force runs even when a recent reach failed, for
// the command typed by hand; the hooks respect the offline hold.
vault_sync :: proc(cli: ^Cli, mode: Sync_Mode, force := false) -> (r: Sync_Report) {
	if !sync_enabled(cli) {
		r.off = true
		return
	}
	repo, versioned := vault_repo(cli)
	if !versioned {
		r.no_repo = true
		return
	}
	defer git.close(&repo)
	attrs := path.join(cli.vault, ".gitattributes")
	if !os.exists(attrs) {
		path.write(attrs, SYNC_ATTRIBUTES)
	}
	if mode == .Full {
		r.wrote, r.waiting = sync_write_down(cli, repo)
	}
	name := remote_name(repo)
	if name == "" {
		return
	}
	r.remote = remote_url(repo, name)
	r.connected = true
	hold := path.join(cli.state, "sync", "offline-until")
	if !force {
		if until := strings.trim_space(first_line(hold)); until != "" && until > now_iso() {
			r.offline = true
			return
		}
	}
	branch, _, born := git.head(repo)
	if !born || branch == "" || branch == "HEAD" {
		branch = "main"
	}
	creds := sync_creds(cli, r.remote)
	limit := mode == .Receive ? SYNC_RECEIVE_TIMEOUT : SYNC_SEND_TIMEOUT
	git.set_timeouts(limit, limit)
	before, _ := git.resolve(repo, "HEAD")
	if err := git.fetch(repo, name, creds); err != nil {
		go_offline(&r, hold)
		return
	}
	theirs := strings.concatenate({name, "/", branch})
	_, remote_has := git.resolve(repo, theirs)
	if remote_has {
		// What arrived is what the far side has that this branch did not:
		// counted before the replay, which also rewrites this side's own.
		incoming, _ := git.count(repo, before, theirs)
		r.conflict, r.err = sync_take_in(repo, branch, theirs, born)
		if after, _ := git.resolve(repo, "HEAD"); after != before && r.conflict == "" && r.err == "" {
			r.received = before != "" ? incoming : 0
			sync(cli, quiet = true)
		}
	}
	if mode == .Full && r.conflict == "" && r.err == "" {
		// Until the far side has been seen once, everything here is ahead.
		ahead, _ := git.count(repo, remote_has ? theirs : "", "HEAD")
		if ahead > 0 {
			if err := git.push(repo, name, branch, creds); err == nil {
				r.sent = ahead
				// What `push -u` records, for anyone who runs git here by hand.
				git.config_set(repo, strings.concatenate({"branch.", branch, ".remote"}), name)
				git.config_set(repo, strings.concatenate({"branch.", branch, ".merge"}), strings.concatenate({"refs/heads/", branch}))
			} else {
				go_offline(&r, hold)
			}
		}
	}
	if !r.offline {
		os.remove(hold)
	}
	path.mkdirs(path.join(cli.state, "sync"))
	path.write(path.join(cli.state, "sync", "last"), strings.concatenate({now_iso(), " sent ", int_str(i64(r.sent)), " received ", int_str(i64(r.received)), "\n"}))
	return
}

// go_offline marks the pass offline and holds the next reach back for
// SYNC_OFFLINE_HOLD.
go_offline :: proc(r: ^Sync_Report, hold: string) {
	r.offline = true
	path.mkdirs(path.dir(hold))
	path.write(hold, strings.concatenate({iso_after(SYNC_OFFLINE_HOLD), "\n"}))
}

// sync_take_in brings the other machines' commits onto this branch: this
// machine's own commits are replayed on top of theirs, and whatever has
// not been written down is put aside meanwhile and brought back after.
// When a commit of ours cannot be replayed cleanly nothing changes and
// conflict names the files; the fact files merge line by line
// (SYNC_ATTRIBUTES), so two machines that each appended never get here.
sync_take_in :: proc(repo: git.Repo, branch, theirs: string, born: bool) -> (conflict, err: string) {
	if !born {
		// Nothing here yet: the branch starts where the far side is.
		if e := git.checkout(repo, branch, theirs); e != nil {
			return "", fault_text(e)
		}
		return "", ""
	}
	if behind, _ := git.count(repo, "HEAD", theirs); behind == 0 {
		return "", ""
	}
	who := identity(repo)
	aside, serr := git.stash(repo, "brain sync: not written down yet", who)
	if serr != nil {
		return "", fault_text(serr)
	}
	files, rerr := git.rebase(repo, theirs, who)
	if aside {
		if e := git.unstash(repo); e != nil && rerr == nil && len(files) == 0 {
			err = strings.concatenate({"what was not written down is kept aside (git stash): ", fault_text(e)})
		}
	}
	if len(files) > 0 {
		return strings.join(files, ", "), err
	}
	if rerr != nil {
		return "", fault_text(rerr)
	}
	return "", err
}

// remote_name is where the vault meets other machines: `origin` when there
// is one, else the first remote the vault has (a vault versioned by hand may
// call it `github`), else nothing.
remote_name :: proc(repo: git.Repo) -> string {
	rs, _ := git.remotes(repo)
	for r in rs {
		if r.name == "origin" {
			return r.name
		}
	}
	return len(rs) > 0 ? rs[0].name : ""
}

// sync_write_down commits everything that changed in the vault, through its
// own gates (lint, secrets). When a gate refuses, the first line it said is
// what the person sees.
sync_write_down :: proc(cli: ^Cli, repo: git.Repo) -> (wrote: int, waiting: string) {
	if err := git.add(repo, {"."}); err != nil {
		return 0, fault_text(err)
	}
	entries, _ := git.status(repo)
	files := 0
	for e in entries {
		if e.index != .None {
			files += 1
		}
	}
	if files == 0 {
		return 0, ""
	}
	// The vault's own gates run here, not only as hooks: libgit2 runs no
	// hooks, a vault versioned by hand has none, and a bad line must still
	// wait.
	for gate in ([2]string{"lint", "secrets"}) {
		mark := strings.builder_len(cli.out)
		emark := strings.builder_len(cli.err)
		code := gate == "lint" ? cmd_lint(cli, {"--staged"}) : cmd_secrets(cli, {"--staged"})
		said := strings.concatenate({strings.to_string(cli.out)[mark:], "\n", strings.to_string(cli.err)[emark:]})
		resize(&cli.out.buf, mark)
		resize(&cli.err.buf, emark)
		if code != 0 {
			git.unstage(repo)
			for l in strings.split_lines(said) {
				t := strings.trim_space(l)
				if t != "" && !strings.has_prefix(t, "brain lint:") && !strings.has_prefix(t, "brain secrets:") {
					return 0, t
				}
			}
			return 0, strings.concatenate({"the vault's ", gate, " check refused the change"})
		}
	}
	msg := strings.concatenate({"sync: ", int_str(i64(files)), files == 1 ? " file" : " files", " from ", host_name()})
	if _, err := git.commit(repo, msg, identity(repo)); err != nil {
		git.unstage(repo)
		if t := fault_text(err); t != "" {
			return 0, t
		}
		return 0, "the change could not be written down"
	}
	return files, ""
}

now_iso :: proc() -> string {
	return iso_after(0)
}

iso_after :: proc(d: time.Duration) -> string {
	t := time.time_add(time.now(), d)
	y, mo, da := time.date(t)
	h, mi, s := time.clock(t)
	return strings.clone(
		strings.concatenate(
			{pad4(y), "-", pad2(mo), "-", pad2(da), "T", pad2(h), ":", pad2(mi), ":", pad2(s), "Z"},
		),
	)
}

pad2 :: proc(n: $T) -> string {
	v := int(n)
	s := int_str(i64(v))
	return v < 10 ? strings.concatenate({"0", s}) : s
}

pad4 :: proc(n: int) -> string {
	return int_str(i64(n))
}

// sync_say puts a report into words, the outcome first.
sync_say :: proc(cli: ^Cli, r: Sync_Report) -> int {
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "sync", r.off ? "off" : "on")
		jw_field(&w, "connected", r.connected ? "true" : "false")
		jw_field(&w, "remote", r.remote)
		jw_field_int(&w, "wrote", i64(r.wrote))
		jw_field_int(&w, "sent", i64(r.sent))
		jw_field_int(&w, "received", i64(r.received))
		jw_field(&w, "waiting", r.waiting)
		jw_field(&w, "conflict", r.conflict)
		jw_field(&w, "error", r.err)
		jw_field(&w, "offline", r.offline ? "true" : "false")
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return r.waiting != "" || r.conflict != "" || r.err != "" ? 1 : 0
	}
	switch {
	case r.off:
		said(cli, .Sync_Is_Off)
		return 0
	case r.no_repo:
		said(cli, .Not_Versioned)
		return 0
	}
	if r.wrote > 0 {
		said(cli, .Wrote_Down, r.wrote)
	}
	if r.waiting != "" {
		said(cli, .Changes_Waiting_Line, r.waiting)
	}
	if !r.connected {
		said(cli, .Not_Connected)
		return r.waiting != "" ? 1 : 0
	}
	if r.conflict != "" {
		said(cli, .Conflict, r.conflict)
		return 1
	}
	if r.offline {
		said(cli, .Offline)
		return 0
	}
	if r.err != "" {
		said(cli, .Take_In_Failed, r.err)
		return 1
	}
	switch {
	case r.sent > 0 && r.received > 0:
		said(cli, .Sent_Received, r.sent, r.received)
	case r.sent > 0:
		said(cli, .Sent_Only, r.sent)
	case r.received > 0:
		said(cli, .Received_Only, r.received)
	case:
		said(cli, .Up_To_Date)
	}
	return r.waiting != "" ? 1 : 0
}

sync_status :: proc(cli: ^Cli) -> int {
	on := sync_enabled(cli)
	remote := ""
	changed := 0
	if repo, ok := vault_repo(cli); ok {
		if name := remote_name(repo); name != "" {
			remote = remote_url(repo, name)
		}
		entries, _ := git.status(repo)
		changed = len(entries)
		git.close(&repo)
	}
	last := strings.trim_space(first_line(path.join(cli.state, "sync", "last")))
	if cli.json {
		w := jw_make()
		jw_obj(&w)
		jw_field(&w, "sync", on ? "on" : "off")
		jw_field(&w, "remote", remote)
		jw_field(&w, "last", last)
		jw_field_int(&w, "changed", i64(changed))
		jw_end_obj(&w)
		jw_flush(cli, &w)
		return 0
	}
	said(cli, .Sync_State, phrase(cli, on ? .Word_On : .Word_Off))
	if remote == "" {
		said(cli, .Not_Connected_Short)
	} else {
		said(cli, .Connected_Url, remote)
	}
	if last != "" {
		said(cli, .Last_Line, last)
	}
	if changed > 0 {
		said(cli, .Waiting_Write, changed)
	}
	return 0
}

// sync_connect names where the machines meet: a URL, or a new private
// repository on GitHub made with gh.
sync_connect :: proc(cli: ^Cli, where_: string) -> int {
	repo, versioned := vault_repo(cli)
	if !versioned {
		made, err := git.init(cli.vault)
		if err != nil {
			return fail(cli, phrase(cli, .Could_Not_Version))
		}
		repo = made
	}
	defer git.close(&repo)
	url := where_
	if where_ == "github" {
		if _, found := sh.which("gh"); !found {
			return fail(cli, phrase(cli, .Connect_Github))
		}
		// gh makes the repository and prints its address; the vault is
		// pointed at it here, so gh never has to drive git.
		name := path.base(cli.vault)
		r := sh.exec({"gh", "repo", "create", name, "--private"}, {dir = cli.vault, timeout = 30 * time.Second})
		if !r.ok {
			return fail(cli, phrase(cli, .Github_Failed, strings.trim_space(sh.error(r))))
		}
		url = strings.trim_space(r.stdout)
		if i := strings.last_index_byte(url, '\n'); i >= 0 {
			url = strings.trim_space(url[i + 1:])
		}
		if !strings.has_suffix(url, ".git") {
			url = strings.concatenate({url, ".git"})
		}
	}
	if remote_url(repo, "origin") != "" {
		git.remote_set_url(repo, "origin", url)
	} else if err := git.remote_add(repo, "origin", url); err != nil {
		return fail(cli, phrase(cli, .Could_Not_Connect, fault_text(err)))
	}
	// A vault that is still the starter adopts what is already there: the
	// second machine's first connect should end with the first machine's
	// vault, not a merge of two welcome pages.
	if n, _ := git.count(repo, "", "HEAD"); n <= 1 && vault_is_starter(cli) {
		creds := sync_creds(cli, url)
		git.set_timeouts(SYNC_SEND_TIMEOUT, SYNC_SEND_TIMEOUT)
		if git.fetch(repo, "origin", creds) == nil {
			branch, berr := git.default_branch(repo, "origin", creds)
			if berr != nil || branch == "" {
				branch = "main"
				if _, ok := git.resolve(repo, "origin/master"); ok {
					branch = "master"
				}
			}
			if _, ok := git.resolve(repo, strings.concatenate({"origin/", branch})); ok {
				// The starter files on disk give way to the vault being adopted.
				git.checkout(repo, branch, strings.concatenate({"origin/", branch}))
				sync(cli, quiet = true)
			}
		}
	}
	rep := vault_sync(cli, .Full, force = true)
	if !cli.json {
		said(cli, .Connected_Url, url)
	}
	return sync_say(cli, rep)
}

// vault_is_starter says whether the vault still holds only what `brain
// install` wrote: the starter files, unchanged, and nothing else.
vault_is_starter :: proc(cli: ^Cli) -> bool {
	files, err := list_md(cli.vault)
	if err != nil {
		return false
	}
	for f in files {
		known := false
		for s in STARTER {
			if s.name == f {
				known = true
				text, _ := read_text(path.join(cli.vault, f))
				if text != s.body {
					return false
				}
			}
		}
		if !known {
			return false
		}
	}
	return true
}
