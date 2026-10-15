package brain

import "core:os"
import "core:strings"

import "jm:path"

// The Grok harness (grok 1.0.52; ~/.grok/docs/user-guide/10-hooks.md and
// 12-project-rules.md). Grok runs command hooks from $GROK_HOME/hooks/*.json
// at session_start, user_prompt_submit, stop and session_end, and the event
// arrives on stdin as JSON with both camelCase and snake_case names. What a
// hook prints does not enter model context: a SessionStart systemMessage is
// only a scrollback annotation, and an allowing UserPromptSubmit drops
// additionalContext. Rules under $GROK_HOME/rules are read before any hook
// runs, so a hook that writes one is too late for the session that just
// started. Two channels do reach the model, both checked with `grok -p`
// against 1.0.52: `grok --rules <text>` is in the instructions, and a Stop
// reply `{"decision":"block","reason":...}` is fed back and the turn
// continues. Brain registers one hook script, and a `grok` function in the
// shell rc install already edits, which runs `brain pack` and execs the real
// grok with that text as `--rules`. The script records prime at
// user_prompt_submit and returns it on the end_turn Stop; a later end_turn
// runs settle. Grok's transcript is updates.jsonl, which no recall adapter
// reads, so settle stays quiet. Commands that do not open a session
// (version, help, doctor, …) are left alone.

GROK_MARK :: "# brainfold hooks: written by `brain hooks on`; `brain hooks off` removes it"

// grok_detect: the harness is here when its config directory is.
grok_detect :: proc(cli: ^Cli) -> bool {
	return os.is_dir(grok_home(cli))
}

// grok_home is $GROK_HOME, or ~/.grok when that is unset.
grok_home :: proc(cli: ^Cli) -> string {
	return getenv(cli, "GROK_HOME", path.join(cli.home, ".grok"))
}

grok_script :: proc(cli: ^Cli) -> string {
	return path.join(grok_home(cli), "hooks", "brain.sh")
}

grok_hooks_file :: proc(cli: ^Cli) -> string {
	return path.join(grok_home(cli), "hooks", "brain.json")
}

// grok_parse reads a hook's JSON. Grok sends camelCase and snake_case for
// the same fields; stopHookActive has no snake_case twin on 1.0.52, and
// stop_hook_active is accepted so a later build is not missed.
grok_parse :: proc(text: string) -> (ev: Hook_Event, ok: bool) {
	v, is := hook_input(text)
	if !is {
		return
	}
	name := json_string(v, "hook_event_name")
	if name == "" {
		name = json_string(v, "hookEventName")
	}
	if name == "" {
		return
	}
	ev.prompt = json_string(v, "prompt")
	ev.session = json_string(v, "session_id")
	if ev.session == "" {
		ev.session = json_string(v, "sessionId")
	}
	ev.transcript = json_string(v, "transcript_path")
	if ev.transcript == "" {
		ev.transcript = json_string(v, "transcriptPath")
	}
	ev.cwd = json_string(v, "cwd")
	ev.continuing = json_bool(v, "stop_hook_active") || json_bool(v, "stopHookActive")
	return ev, true
}

// grok_reply is the Stop decision Grok reads. The vocabulary is Claude's,
// and a block continues the turn with reason as the model's next input.
grok_reply :: proc(reason: string) -> string {
	w := jw_make()
	jw_obj(&w)
	jw_field(&w, "decision", "block")
	jw_field(&w, "reason", reason)
	jw_end_obj(&w)
	return strings.concatenate({strings.to_string(w.b), "\n"})
}

// sh_quote is a single-quoted shell word.
sh_quote :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, "'", `'\''`)
	return strings.concatenate({"'", escaped, "'"})
}

grok_script_body :: proc(exe: string) -> string {
	body, _ := strings.replace_all(GROK_SCRIPT, "__BRAIN__", sh_quote(exe))
	return strings.concatenate({GROK_MARK, "\n", body})
}

grok_function_body :: proc(exe: string) -> string {
	body, _ := strings.replace_all(GROK_FUNCTION, "__BRAIN__", sh_quote(exe))
	return body
}

grok_hooks_body :: proc(script: string) -> string {
	cmd := json_quote(strings.concatenate({"sh ", sh_quote(script)}))
	body, _ := strings.replace_all(GROK_HOOKS, "__CMD__", cmd)
	return body
}

grok_register :: proc(cli: ^Cli, exe: string) {
	script := grok_script(cli)
	body := grok_script_body(exe)
	if text, ok := read_text(script); ok && text == body {
		say(cli, "%s: brain hooks present", script)
	} else if cli.dry {
		say(cli, "%s: brain hooks would be written", script)
	} else {
		path.mkdirs(path.dir(script))
		if err := path.write(script, body); err != nil {
			note(cli, "cannot write %s: %v", script, err)
			return
		}
		say(cli, "%s: brain hooks written (pack, prime, settle)", script)
	}
	file := grok_hooks_file(cli)
	hooks := grok_hooks_body(script)
	if text, ok := read_text(file); ok && text == hooks {
		say(cli, "%s: brain hooks present", file)
	} else if cli.dry {
		say(cli, "%s: brain hooks would be written", file)
	} else {
		path.mkdirs(path.dir(file))
		if err := path.write(file, hooks); err != nil {
			note(cli, "cannot write %s: %v", file, err)
			return
		}
		say(cli, "%s: brain hooks written (pack, prime, settle)", file)
	}
	fn := grok_function_body(exe)
	for rc in path_rc_files(cli) {
		rc_block(cli, rc, fn, "grok", "brain hooks on")
	}
}

grok_unregister :: proc(cli: ^Cli) {
	script := grok_script(cli)
	if text, ok := read_text(script); ok && strings.has_prefix(text, GROK_MARK) {
		say(cli, "%s: brain hooks removed", script)
		if !cli.dry {
			os.remove(script)
		}
	}
	file := grok_hooks_file(cli)
	if text, ok := read_text(file); ok && strings.contains(text, "brain.sh") {
		say(cli, "%s: brain hooks removed", file)
		if !cli.dry {
			os.remove(file)
		}
	}
	pending := path.join(grok_home(cli), "brain-pending")
	if !cli.dry && os.is_dir(pending) {
		os.remove_all(pending)
	}
	for rc in path_rc_files(cli) {
		block_remove(cli, rc, "grok")
	}
}

grok_status :: proc(cli: ^Cli) -> []Hook_Registration {
	text, ok := read_text(grok_script(cli))
	hooks, hok := read_text(grok_hooks_file(cli))
	on := ok && strings.has_prefix(text, GROK_MARK) && hok && strings.contains(hooks, "brain.sh")
	out := make([dynamic]Hook_Registration)
	append(&out, Hook_Registration{event = "SessionStart", sub = "pack", on = on})
	append(&out, Hook_Registration{event = "UserPromptSubmit", sub = "prime", on = on})
	append(&out, Hook_Registration{event = "Stop", sub = "settle", on = on})
	return out[:]
}

// GROK_SCRIPT is the hook body; __BRAIN__ becomes the quoted binary path.
// The shell function delivers the pack. This script only records prime and
// returns it, or settle, on Stop. A shutdown or channel_closed Stop is
// observe-only, so anything but end_turn exits before either runs.
GROK_SCRIPT :: `BRAIN=__BRAIN__
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
PENDING="$ROOT/brain-pending"
EVENT=${1:-$GROK_HOOK_EVENT}
sid=${GROK_SESSION_ID:-session}

json_quote() {
  awk 'BEGIN { ORS=""; printf "\"" }
  {
    if (NR > 1) printf "\\n"
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    gsub(/\r/, "\\r")
    gsub(/\t/, "\\t")
    printf "%s", $0
  }
  END { printf "\"" }'
}

case "$EVENT" in
  session_start)
    BRAIN_CALLER=grok BRAIN_SESSION="$sid" "$BRAIN" pack >/dev/null 2>&1 || true
    ;;
  user_prompt_submit)
    out=$(BRAIN_CALLER=grok BRAIN_SESSION="$sid" "$BRAIN" prime --harness grok 2>/dev/null) || true
    if [ -n "$out" ]; then
      mkdir -p "$PENDING"
      printf '%s\n' "$out" > "$PENDING/$sid"
    else
      rm -f "$PENDING/$sid"
    fi
    ;;
  stop)
    json=$(cat)
    case "$json" in
      *'"reason":"end_turn"'*) ;;
      *) exit 0 ;;
    esac
    pend="$PENDING/$sid"
    if [ -s "$pend" ]; then
      printf '{"decision":"block","reason":%s}\n' "$(json_quote < "$pend")"
      rm -f "$pend"
      exit 0
    fi
    trans=$(printf '%s' "$json" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p')
    BRAIN_CALLER=grok BRAIN_SESSION="$sid" "$BRAIN" settle --harness grok --session "$sid" --transcript "$trans" 2>/dev/null || true
    ;;
  session_end)
    rm -f "$PENDING/$sid"
    ;;
esac
exit 0
`

// GROK_FUNCTION is the shell function. __BRAIN__ becomes the quoted binary
// path. It runs in bash and zsh, the shells whose rc files install edits.
// Non-session commands are forwarded unchanged so `grok version` stays a
// version print. --cwd names the directory the pack is for.
GROK_FUNCTION :: `grok() {
  case "${1-}" in
    version|v|help|completions|doctor|update|login|logout|mcp|models|plugin|setup|du|disk-usage|leader|export|inspect|memory|sessions|trace|usage|worktree|wrap|clone|cursor-worker|-h|--help|--version|-V)
      command grok "$@"
      return
      ;;
  esac
  local _cwd="$PWD" _prev="" _a _pack
  for _a in "$@"; do
    if [ "$_prev" = "--cwd" ]; then
      _cwd=$_a
    fi
    _prev=$_a
  done
  _pack=$(cd "$_cwd" 2>/dev/null && __BRAIN__ pack 2>/dev/null) || _pack=$(PWD="$_cwd" __BRAIN__ pack 2>/dev/null) || true
  if [ -n "$_pack" ]; then
    command grok --rules "$_pack" "$@"
  else
    command grok "$@"
  fi
}`

// GROK_HOOKS is the matcher-group file. __CMD__ becomes the JSON string of
// the shell command. No SessionStart matcher: Claude's startup|clear|compact
// never matches Grok, whose source is new or load. Stop is longer than the
// five-second default and shorter than Stop's ten-minute one.
GROK_HOOKS :: `{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": __CMD__, "timeout":10}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": __CMD__, "timeout":10}]}],
    "Stop": [{"hooks": [{"type": "command", "command": __CMD__, "timeout":30}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": __CMD__, "timeout":10}]}]
  }
}
`