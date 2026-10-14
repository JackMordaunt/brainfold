package brain

import "core:os"
import "core:strings"

import "jm:path"
import "jm:sqlite3"

// `brain setup` is how far this machine is from a working vault, for a
// person setting it up (the desk's Setup page): the vault bound, each
// agent this machine has and whether brain is connected to it (its hooks
// on, its transcripts read), what agents have asked so far, the memories
// waiting to be imported, and whether the vault syncs. It reads only, and
// answers with no vault bound at all, since that is where setup starts.
//
//	brain setup [--json]

// Setup_Agent is one agent brain can serve.
Setup_Agent :: struct {
	name:      string,
	installed: bool, // this machine has it
	hooks:     bool, // every brain hook is on for it
	reading:   bool, // its transcripts are read (recall, spend)
}

cmd_setup :: proc(cli: ^Cli, args: []string) -> int {
	if len(args) != 0 {
		return fail(cli, phrase(cli, .Usage_Setup))
	}
	vault := cli.vault
	exists := vault != "" && os.is_dir(path.join(vault, "AI"))
	bullets, lookups, fresh, sources := 0, 0, 0, 0
	if exists {
		cli.vault = vault
		if ensure_db(cli) == "" {
			if db, err := open_index(cli); err == "" {
				bullets = scalar_int(
					db,
					"select count(*) from bullets where file != ?",
					INBOX_FILE,
				)
				lookups = scalar_int(db, "select count(*) from queries")
				sqlite3.close(&db)
			}
		}
		for src in import_sources(cli) {
			n := 0
			for l in src.lines {
				if proposal_fate(cli, complete_bullet(l, src.label)) == "new" {
					n += 1
				}
			}
			if n > 0 {
				sources += 1
				fresh += n
			}
		}
	}
	agents := make([dynamic]Setup_Agent)
	reading := adapters_on(cli)
	for h in HARNESSES {
		a := Setup_Agent {
			name      = h.name,
			installed = h.detect(cli),
			hooks     = true,
		}
		regs := h.status(cli)
		a.hooks = len(regs) > 0
		for r in regs {
			a.hooks &&= r.on
		}
		for o in reading {
			a.reading ||= o == h.transcripts
		}
		append(&agents, a)
	}
	syncs := exists && sync_enabled(cli)

	if !cli.json {
		switch {
		case vault == "":
			said(cli, .Setup_Vault_None)
		case !exists:
			said(cli, .Setup_Vault_Bad, vault)
		case:
			said(cli, .Setup_Vault, vault, bullets)
		}
		for a in agents {
			state := "not on this machine"
			if a.installed {
				state =
					a.hooks && a.reading ? "connected" : a.hooks ? "hooks on; transcripts not read" : "not connected"
			}
			outf(cli, "%-7s %s\n", a.name, state)
		}
		said(cli, .Setup_Lookups, lookups)
		said(cli, .Setup_Import, fresh, sources)
		said(cli, .Setup_Sync, syncs ? "on" : "off")
		return 0
	}
	w := jw_make()
	jw_obj(&w)
	jw_key(&w, "vault")
	jw_obj(&w)
	jw_field(&w, "path", vault)
	jw_field_bool(&w, "exists", exists)
	jw_field_int(&w, "bullets", i64(bullets))
	jw_end_obj(&w)
	jw_key(&w, "agents")
	jw_arr(&w)
	for a in agents {
		jw_obj(&w)
		jw_field(&w, "name", a.name)
		jw_field_bool(&w, "installed", a.installed)
		jw_field_bool(&w, "hooks", a.hooks)
		jw_field_bool(&w, "reading", a.reading)
		jw_end_obj(&w)
	}
	jw_end_arr(&w)
	jw_field_int(&w, "lookups", i64(lookups))
	jw_key(&w, "memories")
	jw_obj(&w)
	jw_field_int(&w, "sources", i64(sources))
	jw_field_int(&w, "new", i64(fresh))
	jw_end_obj(&w)
	jw_field_bool(&w, "sync", syncs)
	jw_end_obj(&w)
	jw_flush(cli, &w)
	return 0
}

// prepare_vault_dir readies dir for a new vault, as `brain install --new`
// asks: made when it does not exist, refused when it holds a vault or
// anything else a person keeps there, so a starter vault never lands on
// someone's files.
prepare_vault_dir :: proc(dir: string) -> string {
	if !os.exists(dir) {
		if err := path.mkdirs(dir); err != nil {
			return strings.concatenate({"install: cannot create ", dir})
		}
		return ""
	}
	if !os.is_dir(dir) {
		return strings.concatenate({"install: ", dir, " is not a directory"})
	}
	if os.is_dir(path.join(dir, "AI")) {
		return strings.concatenate(
			{"install: ", dir, " is a vault already; install it without --new"},
		)
	}
	entries, _ := os.read_all_directory_by_path(dir, context.allocator)
	for e in entries {
		if !strings.has_prefix(e.name, ".") {
			return strings.concatenate(
				{"install: ", dir, " is not empty; choose an empty folder for a new vault"},
			)
		}
	}
	return ""
}
