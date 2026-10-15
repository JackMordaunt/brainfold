package brain

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"

@(private = "file")
Setup_Out :: struct {
	vault:    struct {
		path:    string,
		exists:  bool,
		bullets: int,
	},
	agents:   []struct {
		name:                      string,
		installed, hooks, reading: bool,
	},
	lookups:  int,
	memories: struct {
		sources, new: int,
	},
}

@(private = "file")
setup_of :: proc(t: ^testing.T, f: Fixture) -> (s: Setup_Out) {
	o, e, code := exec(f.cli, "--json", "setup")
	testing.expect_value(t, code, 0)
	testing.expect(t, json.unmarshal_string(o, &s) == nil, e)
	return
}

@(private = "file")
agent_state :: proc(s: Setup_Out, name: string) -> (installed, hooks, reading: bool) {
	for a in s.agents {
		if a.name == name {
			return a.installed, a.hooks, a.reading
		}
	}
	return
}

// Setup says what is left: an agent on the machine but not connected,
// memories to import; connecting it and asking once finish them.
@(test)
setup_says_what_is_left_and_sees_it_done :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["CLAUDE_CODE_SESSION_ID"] = ""
	testing.expect_value(t, path.mkdirs(path.join(f.home, ".claude")), nil)
	mem := path.join(f.home, ".claude", "projects", "-src-app", "memory")
	testing.expect_value(t, path.mkdirs(mem), nil)
	testing.expect_value(
		t,
		path.write(
			path.join(mem, "MEMORY.md"),
			"- [Deploys go out on Fridays](d.md) — never on a Friday afternoon\n",
		),
		nil,
	)
	s := setup_of(t, f)
	testing.expect_value(t, s.vault.path, f.vault)
	testing.expect(t, s.vault.exists)
	testing.expect(t, s.vault.bullets > 0)
	installed, hooks, reading := agent_state(s, "claude")
	testing.expect(t, installed && !hooks && !reading, "Claude Code is here, not connected")
	installed, _, _ = agent_state(s, "pi")
	testing.expect(t, !installed, "no pi here")
	installed, _, _ = agent_state(s, "grok")
	testing.expect(t, !installed, "no grok here")
	testing.expect_value(t, s.memories.new, 1)
	testing.expect_value(t, s.lookups, 0)

	_, e, code := exec(f.cli, "hooks", "on", "--harness", "claude")
	testing.expect_value(t, code, 0)
	_, e, code = exec(f.cli, "recall", "--enable", "claude")
	testing.expect_value(t, code, 0)
	_ = e
	exec(f.cli, "import", "claude", "--all")
	exec(f.cli, "find", "fixture")
	s = setup_of(t, f)
	_, hooks, reading = agent_state(s, "claude")
	testing.expect(t, hooks && reading, "connected")
	testing.expect_value(t, s.memories.new, 0)
	testing.expect_value(t, s.lookups, 1)
}

// With no vault bound, setup still answers: that is where it starts.
@(test)
setup_answers_with_no_vault :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.vault = ""
	s := setup_of(t, f)
	testing.expect_value(t, s.vault.path, "")
	testing.expect(t, !s.vault.exists)
	testing.expect_value(t, s.lookups, 0)
	// What does not need a vault is still said: the agents brain serves.
	testing.expect_value(t, len(s.agents), 3)
}

// A new vault goes only into an empty folder, made when it is missing.
@(test)
a_new_vault_needs_an_empty_folder :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	fresh := path.join(f.root, "Notes", "brain")
	testing.expect_value(t, prepare_vault_dir(fresh), "")
	testing.expect(t, os.is_dir(fresh), "made")
	testing.expect_value(t, prepare_vault_dir(fresh), "") // empty: still fine
	testing.expect_value(t, path.write(path.join(fresh, ".DS_Store"), "x"), nil)
	testing.expect_value(t, prepare_vault_dir(fresh), "") // hidden files are not someone's notes
	testing.expect_value(t, path.write(path.join(fresh, "todo.md"), "x"), nil)
	testing.expect(t, strings.contains(prepare_vault_dir(fresh), "not empty"))
	testing.expect(t, strings.contains(prepare_vault_dir(f.vault), "is a vault already"))

	o, e, code := exec(f.cli, "install", "--new", "--dry-run", path.join(f.root, "elsewhere"))
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "created a new vault"), e)
	testing.expect(t, !os.exists(path.join(f.root, "elsewhere")), "a dry run makes nothing")
	_, e, code = exec(f.cli, "install", "--new")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "--new needs the folder"), e)
}
