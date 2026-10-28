# Line recipes run through `sh -cu`. Shebangs are `/bin/bash`, which just maps
# through Git Bash's cygpath to Git's bash.exe; `bash` on PATH is the WSL
# launcher. That bash is not a login shell, so System32 stays ahead of Git's
# coreutils and `sort` is Windows sort.exe. Prepend Git's usr\bin. The branch
# is lazy, so a non-Windows parse never runs cygpath. The tool itself is one
# static binary and needs nothing.
export PATH := if os() == "windows" { `cygpath -w /usr/bin` + ";" + env("PATH", "") } else { env("PATH", "") }
#
#   just deps      fetch the jm submodule and build its SQLite archive
#   just build [mode]   the brain binary -> build/<mode>/brain. Default minimal.
#   just run [mode] [args...]  build that mode and run it, arguments after the mode
#   just release   the release binary. Exactly `just build release` -> build/release
#   just publish   the release binary, and where it is. Only the release mode.
#   just test      the package's tests against the fixture vault
#   just check     type-check for linux, darwin and windows, with and without -debug
#   just install   bind this machine to a vault
#   just desk [mode]  open the desk, hot-reloading tools/desk; desk-png, desk-test
#   just hot [mode] DIR TITLE  the loop under the desk: any jm:ui child in a window
#   just proof     what a lookup costs a real agent session: vanilla, plain markdown, brain
#   just suite     every proof experiment in tools/proof/AXES.md, smoke size; SMOKE=0 for all
#   just preview   render README.md, ARCHITECTURE.md and docs/ to build/ and open them
#   just clean     remove build/ and the index
#
# The mode is minimal, speed, asan, tsan or release. build, run and hot
# default to minimal. The flags are minimal_opt and the variables beside
# it. minimal, speed, asan and tsan pass -debug. release does not.
#
#   minimal   -debug -o:minimal, no sanitizer. The daily build.
#   speed     -debug -o:speed, no sanitizer.
#   asan      -debug -o:none -sanitize:address. Always the sanitizer.
#             SAN= does not change this mode.
#   tsan      -debug -o:none -sanitize:thread. Its own binary. Address and
#             thread sanitizers are not combined.
#   release   -o:speed, no -debug. publish accepts only this mode.
#
# just hot adds -define:DEBUG_ALLOC_BACKTRACES=false on every mode but
# release, to the host and the child. A release hot build is -o:speed only.
#
# Test and desk-test still honour SAN, whose default is -sanitize:address.
# SAN= does not change build, run, hot or publish. The tests launch a
# binary built with SAN, not the minimal one.

odin  := env("ODIN", "odin")
root  := replace(justfile_directory(), "\\", "/")
# The jm collection: https://mordaunt.dev/code/jm, pinned as the jm
# submodule. JM=<path> builds against another checkout instead.
jm    := env("JM", root / "jm")
# The commit a binary is built from, with -dirty when the tree has
# uncommitted changes, so `brain version` can say which code it is. The
# value is quoted for odin, since a hash like 21e17ac would otherwise be
# read as a number.
commit := `git rev-parse --short HEAD 2>/dev/null || echo unknown`
dirty  := `git status --porcelain 2>/dev/null | head -c 1`
stamp  := commit + (if dirty != "" { "-dirty" } else { "" })
flags := "-vet -strict-style -collection:jm=" + jm + " -define:BRAIN_TOOL=" + root + " -define:COMMIT='\"" + stamp + "\"'"
# The same without BRAIN_TOOL, which only the CLI reads: a jm:ui child would warn.
uiflags := "-vet -strict-style -collection:jm=" + jm
# Test and desk-test pass SAN through. The default is AddressSanitizer.
# SAN= drops it. build, run, hot and publish ignore it.
san   := env("SAN", "-sanitize:address")
# Compiler flags for each mode. mode_arms is the shell that sets opt from
# the mode. release is -o:speed and is not in the list: it passes no -debug.
minimal_opt := "-debug -o:minimal"
speed_opt := "-debug -o:speed"
asan_opt := "-debug -o:none -sanitize:address"
tsan_opt := "-debug -o:none -sanitize:thread"
mode_arms := "minimal) opt='" + minimal_opt + "' ;; " + "speed) opt='" + speed_opt + "' ;; " + "asan) opt='" + asan_opt + "' ;; " + "tsan) opt='" + tsan_opt + "' ;;"
exe   := if os() == "windows" { ".exe" } else { "" }
# In-script calls. /usr/bin/bash is Git Bash, not the WSL launcher on PATH.
bash  := if os() == "windows" { "/usr/bin/bash" } else { "bash" }
# Blend2D is C++: anything linking jm:ui/render needs the runtime off Windows.
cxx_link := if os() == "windows" { "" } else { "-extra-linker-flags:\"-lstdc++\"" }
targets := "linux_amd64 darwin_arm64 windows_amd64"

default:
    @just --list --unsorted

# The jm submodule, when JM does not name another checkout, the SQLite and
# zstd archives jm:sqlite3 and jm:zstd link (zstd decodes a patched update;
# see jm/selfupdate), and the libgit2 archive jm:git links.
deps:
    #!/bin/bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    if ! ls "{{jm}}"/sqlite3/lib/sqlite3.* >/dev/null 2>&1; then (cd "{{jm}}" && just sqlite); fi
    if ! ls "{{jm}}"/zstd/lib/zstd.* >/dev/null 2>&1; then (cd "{{jm}}" && just zstd); fi
    # libgit2, static, so a binary built here versions the vault with no git
    # on the machine it runs on (jm:git links the system libgit2 without it).
    if ! ls "{{jm}}"/git/lib/*git2.* >/dev/null 2>&1; then (cd "{{jm}}" && just libgit2); fi

# The brain binary -> build/<mode>/brain. The mode is minimal, speed, asan,
# tsan or release, and minimal when it is omitted.
build mode="minimal": deps
    #!/bin/bash
    set -euo pipefail
    case "{{mode}}" in
    {{mode_arms}}
    release) opt="-o:speed" ;;
    *) echo "build: the mode is minimal, speed, asan, tsan or release, not {{mode}}" >&2; exit 1 ;;
    esac
    mkdir -p build/{{mode}}
    {{odin}} build . $opt {{flags}} -out:build/{{mode}}/brain{{exe}}

# A first argument is a mode only when it is exactly one of the five.
# Anything else is an argument of the binary. The default mode is minimal.
#
# Build that mode and run it: just run [mode] [args...]
[positional-arguments]
run *args:
    #!/bin/bash
    set -euo pipefail
    mode=minimal
    case "${1:-}" in
    minimal|speed|asan|tsan|release) mode=$1; shift ;;
    esac
    just build "$mode"
    exec "build/$mode/brain{{exe}}" "$@"

# What test-installer, install, proof and suite already depend on.
# Exactly `just build release`, so those callers still build build/release/brain.
release: (build "release")

# Build the release binary and print where it is. There is no package, and
# this does not install onto PATH. Any other mode is refused before the
# compiler runs.
publish mode="release":
    #!/bin/bash
    set -euo pipefail
    if [ "{{mode}}" != release ]; then
        echo "publish: only release is published, not {{mode}}" >&2
        exit 1
    fi
    just build release
    echo "publish: the release is build/release/brain{{exe}}"

# The proof: what a lookup costs a real agent session with no notes, with the
# vault as plain markdown, and through brain. Needs claude logged in.
# `just proof` runs sonnet once; MODELS and REPEATS widen it.
proof: release
    tools/proof/run.sh

# The suite: recall, cost, calibration, uptake, overhead, capture, round trip
# and robustness, each against vanilla / plain / brain (tools/proof/AXES.md).
# Smoke size by default; SMOKE=0 runs every row, MODELS and REPEATS widen it.
suite: release
    tools/proof/suite.sh

# Type-check every target, with and without -debug.
check: deps
    for t in {{targets}}; do \
      {{odin}} check . {{flags}} -target:$t || exit 1; \
      {{odin}} check . {{flags}} -debug -target:$t || exit 1; \
    done

# The package's tests, which run the built binary through the hooks and an
# install into a throwaway home, then a syntax check of the hooks.
# One thread: tests that spawn git deadlock in parallel on Windows, where a
# child inherits another child's pipe and its parent never reads EOF.
# The binary they launch is build/debug/brain, built here with SAN and not
# by `just build`, which ignores SAN. SAN= leaves AddressSanitizer off; the
# default passes it. The asan mode cannot turn the sanitizer off, so this
# binary is not build/asan and not build/minimal.
test: test-installer
    mkdir -p build/debug build/test
    {{odin}} build . -debug {{san}} {{flags}} -out:build/debug/brain{{exe}}
    {{odin}} test msg {{uiflags}} -out:build/test/msg{{exe}}
    {{odin}} test brain {{san}} {{flags}} -define:ODIN_TEST_THREADS=1 -out:build/test/brain{{exe}}
    {{odin}} test term {{san}} {{uiflags}} -out:build/test/term{{exe}}
    @for f in bin/hooks/*; do "{{bash}}" -n "$f" && echo "ok $f"; done

# The installers against a fake release on disk: the release binary under
# the names CI would publish, a sha256sums.txt beside them, served over
# file://. Each ends in `brain install`, so all of it runs in a throwaway
# home, where the canonical vault gets created. install.sh runs everywhere;
# install.ps1 installs on Windows and, wherever a PowerShell is on PATH,
# must refuse an asset whose checksum no longer matches. Off Windows its
# .exe cannot run, and PowerShell would hand it to xdg-open.
test-installer: release
    #!/bin/bash
    set -euo pipefail
    case "$(uname -s)" in Linux*) os=linux;; Darwin*) os=darwin;; *) os=windows;; esac
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; *) arch=arm64;; esac
    # The installers run before any binary exists, so they repeat the
    # release base the binary owns; all three must agree.
    base=$(sed -n 's/^RELEASE_BASE :: "\(.*\)"$/\1/p' brain/version.odin)
    for f in install.sh install.ps1; do grep -qF "$base" "$f" || { echo "FAIL $f does not name $base"; exit 1; }; done
    echo "ok the installers name the release base"
    rel="$(mktemp -d)/release"; bin="$(mktemp -d)/bin"; home="$(mktemp -d)"
    trap 'rm -rf "$(dirname "$rel")" "$(dirname "$bin")" "$home"' EXIT
    export HOME="$home" USERPROFILE="$(cygpath -w "$home" 2>/dev/null || printf '%s' "$home")"
    export XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.state"
    unset BRAIN_VAULT BRAIN_STATE BRAIN_TOOL GOBIN GOPATH
    mkdir -p "$rel"
    cp "build/release/brain{{exe}}" "$rel/brain-$os-$arch{{exe}}"
    cp "build/release/brain{{exe}}" "$rel/brain-windows-amd64.exe"
    (cd "$rel" && { command -v sha256sum >/dev/null && sha256sum brain-* || shasum -a 256 brain-*; } > sha256sums.txt)
    p=$(cygpath -m "$rel" 2>/dev/null || printf '%s' "$rel")
    export BRAIN_RELEASE_BASE="file:///${p#/}"
    w() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
    ps=$(command -v pwsh || command -v powershell || true)
    ps1() { BRAIN_BINDIR="$(w "$1")" "$ps" -NoProfile -ExecutionPolicy Bypass -File "$(w "$PWD/install.ps1")"; }

    BRAIN_BINDIR="$bin/sh" sh install.sh >/dev/null
    test "$("$bin/sh/brain{{exe}}" locate --tool)" = "$(build/release/brain{{exe}} locate --tool)"
    test "$("$bin/sh/brain{{exe}}" locate)" = "$home/Documents/Brain" && echo "ok install.sh"
    if [ -n "$ps" ] && [ "$os" = windows ]; then
      ps1 "$bin/ps" >/dev/null
      cmp "$bin/ps/brain.exe" "build/release/brain{{exe}}" && echo "ok install.ps1"
    fi

    printf x >> "$rel/brain-$os-$arch{{exe}}"; printf x >> "$rel/brain-windows-amd64.exe"
    if BRAIN_BINDIR="$bin/t" sh install.sh >/dev/null 2>&1; then echo "FAIL install.sh accepted a bad checksum"; exit 1; fi
    echo "ok install.sh refuses a bad checksum"
    if [ -n "$ps" ]; then
      if ps1 "$bin/t2" >/dev/null 2>&1; then echo "FAIL install.ps1 accepted a bad checksum"; exit 1; fi
      echo "ok install.ps1 refuses a bad checksum"
    fi

# Put the CLI on PATH and bind this machine to a vault.
# The line runs in Git Bash, which eats unquoted backslashes, so a Windows
# path has to be quoted and a leading ~ expanded before brain.exe sees it.
install VAULT: release
    #!/bin/bash
    set -euo pipefail
    vault='{{VAULT}}'
    case $vault in '~'/*) vault=$HOME/${vault#'~/'} ;; esac
    if command -v cygpath >/dev/null 2>&1; then vault=$(cygpath -w "$vault"); fi
    build/release/brain{{exe}} install "$vault"

# Hot reload for the windowed tools: HOST owns the window and DIR is the
# jm:ui child that draws into it. The child is rebuilt here every time one
# of the .odin files under DIR changes, into its own timestamped binary
# under build/hot/<mode>, and named in build/hot/<mode>/<name>.watch, which
# the host re-reads and respawns from (ui/shell.run_host). The host is
# rebuilt and restarted when a file it is built from changes: its own
# package and every package it reaches by a relative import, test files
# aside. A host that answers
# the child's needs (tools/desk/host) shares their shapes with it, and one
# built from the shapes before an edit misreads the child's after it. The
# loop is a shell one rather than jm's tools/hot-watch because that build
# omits the C++ runtime Blend2D needs on Linux. GNU stat and date; Linux
# and macOS with coreutils. Under Hyprland the window opens on the
# project's workspace, named <parent>/<repo> the way the rest of the
# desktop is (Personal/brainfold), or on LOGO_WORKSPACE when set; the rule
# lives for the session only.
#
# A first argument is a mode only when it is exactly minimal, speed, asan,
# tsan or release, so `just hot tools/desk brainfold` is still the desk.
# The default mode is minimal. The host lands in build/<mode>/ and the
# child under build/hot/<mode>/. Every mode except release adds
# -define:DEBUG_ALLOC_BACKTRACES=false to the host and the child. release
# is -o:speed only.
#
# Open DIR's child in a hot-reloading window titled TITLE: just hot [mode] DIR TITLE
[positional-arguments]
hot *args: deps ui-deps
    #!/bin/bash
    set -euo pipefail
    mode=minimal
    case "${1:-}" in
    minimal|speed|asan|tsan|release) mode=$1; shift ;;
    esac
    case "$mode" in
    {{mode_arms}}
    release) opt="-o:speed" ;;
    *) echo "hot: the mode is minimal, speed, asan, tsan or release, not $mode" >&2; exit 1 ;;
    esac
    if [ "$mode" != release ]; then
      opt="$opt -define:DEBUG_ALLOC_BACKTRACES=false"
    fi
    if [ $# -lt 2 ]; then
      echo "hot: usage: just hot [mode] DIR TITLE [SIZE [HOST]]" >&2
      exit 1
    fi
    dir=$1
    title=$2
    size=${3:-1440x960}
    host_src=${4:-tools/host}
    mkdir -p "build/$mode" "build/hot/$mode"
    host=build/$mode/$(echo "$host_src" | tr / -){{exe}}
    name=$(basename "$dir")
    pointer=build/hot/$mode/$name.watch
    restart=build/hot/$mode/$name.restart
    hostpid=build/hot/$mode/$name.hostpid
    rm -f "$pointer" "$restart" "$hostpid"
    # The host's sources: its package, then each package a non-test file
    # imports by a relative path, transitively.
    host_sources() {
      local todo=("$host_src") seen=" " d f imp
      while [ ${#todo[@]} -gt 0 ]; do
        d=$(realpath --relative-to=. "${todo[0]}"); todo=("${todo[@]:1}")
        case "$seen" in *" $d "*) continue;; esac
        seen="$seen$d "
        for f in "$d"/*.odin; do
          case "$f" in *_test.odin) continue;; esac
          [ -f "$f" ] || continue
          echo "$f"
          for imp in $(sed -n 's/^import[^"]*"\(\.\{1,2\}\/[^"]*\)".*/\1/p' "$f"); do
            todo+=("$d/$imp")
          done
        done
      done
    }
    host_mt() { host_sources | xargs stat -c %Y | sort -n | tail -1; }
    build_host() { {{odin}} build "$host_src" $opt {{uiflags}} {{cxx_link}} -out:"$host.new" && mv "$host.new" "$host"; }
    build_host
    (
      last="" last_host=$(host_mt)
      while true; do
        mt=$(find "$dir" -name '*.odin' -exec stat -c %Y {} + | sort -n | tail -1)
        if [ "$mt" != "$last" ]; then
          last=$mt
          out=build/hot/$mode/$name-$(date +%s%N){{exe}}
          if {{odin}} build "$dir" $opt {{uiflags}} {{cxx_link}} -out:"$out"; then
            printf '%s' "$out" > "$pointer"
            echo "hot: ready $out"
            ls -t build/hot/$mode/$name-* | tail -n +3 | xargs -r rm -f
          else
            echo "hot: build failed; the window keeps the last good build"
          fi
        fi
        hm=$(host_mt)
        if [ "$hm" != "$last_host" ]; then
          last_host=$hm
          if build_host; then
            echo "hot: host rebuilt; restarting it"
            touch "$restart"
            [ -f "$hostpid" ] && kill "$(cat "$hostpid")" 2>/dev/null || true
          else
            echo "hot: host build failed; the window keeps the running host"
          fi
        fi
        sleep 0.4
      done
    ) &
    watcher=$!
    trap 'kill $watcher 2>/dev/null; rm -f "$hostpid"' EXIT
    while [ ! -f "$pointer" ]; do sleep 0.2; done
    if command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
      ws="${LOGO_WORKSPACE:-$(basename "$(dirname "{{root}}")")/$(basename "{{root}}")}"
      hyprctl eval "hl.window_rule({ match = { title = '^($title)$' }, workspace = 'name:$ws' })" >/dev/null || true
    fi
    # The window closing ends the loop; a restart the watcher asked for
    # starts the host again.
    while true; do
      "$host" "$pointer" "$title" "$size" &
      echo $! > "$hostpid"
      wait $! || true
      [ -f "$restart" ] || break
      rm -f "$restart"
    done

# The native libraries jm:ui links: Blend2D draws, kb shapes text, AccessKit
# serves assistive technology. Each is built or fetched once, into jm.
#
# Build or fetch the native libraries jm:ui links
ui-deps:
    #!/bin/bash
    set -euo pipefail
    cd "{{jm}}"
    [ -e ui/blend2d/lib/libblend2d.a ] && [ -e ui/kb/lib/kb_text_shape.a ] && [ -e ui/accesskit/lib/libaccesskit.a ] || just blend2d kb accesskit

# The desk's window owns the application (tools/desk/host): the brain CLI
# answering the view's needs on worker threads. The view, tools/desk, is
# the hot-reloaded child. BRAIN names another CLI binary than brain on PATH.
#
# Open the desk, hot-reloading tools/desk as it is edited. The mode is the
# same five, minimal when it is omitted, and is passed through to hot.
desk mode="minimal": (hot mode "tools/desk" "brainfold" "1280x840" "tools/desk/host")

# Render a desk page against this machine's vault to build/desk-PAGE.png.
# The binary is build/<mode>/desk. The mode is the same five, minimal when
# it is omitted.
desk-png mode="minimal" PAGE="Activity" THEME="Light": deps ui-deps
    #!/bin/bash
    set -euo pipefail
    case "{{mode}}" in
    {{mode_arms}}
    release) opt="-o:speed" ;;
    *) echo "desk-png: the mode is minimal, speed, asan, tsan or release, not {{mode}}" >&2; exit 1 ;;
    esac
    mkdir -p build/{{mode}}
    {{odin}} build tools/desk $opt {{uiflags}} {{cxx_link}} -out:build/{{mode}}/desk{{exe}}
    build/{{mode}}/desk{{exe}} -theme "{{THEME}}" -page "{{PAGE}}" -png "build/desk-{{PAGE}}.png"

# The desk's suites: the CLI client on canned answers, the view in a probe,
# and the application end to end on its real pipeline and workers. None
# draws pixels or opens a window, so none links Blend2D, kb or AccessKit:
# CI runs them with no ui-deps to build.
#
# Run the desk's suites
desk-test: deps
    #!/bin/bash
    set -euo pipefail
    mkdir -p build/test
    {{odin}} test msg {{uiflags}} -out:build/test/msg{{exe}}
    for p in cli view app; do
      {{odin}} test tools/desk/$p {{san}} {{uiflags}} -out:build/test/desk-$p{{exe}}
    done

# A local look at the docs as GitHub would show them: comrak (GitHub's
# dialect, raw HTML kept so the hero's <picture> survives) into a bare page
# under build/, with <base> pointing back at the repo so branding/ resolves.
# Follows the browser's light or dark scheme.
#
# Render README.md and ARCHITECTURE.md to build/ and open the README
preview:
    #!/bin/bash
    set -euo pipefail
    mkdir -p build
    for src in README.md ARCHITECTURE.md docs/REFERENCE.md docs/PROOF.md; do
      f=$(basename "$src" .md)
      {
        printf '<!doctype html><meta charset=utf-8><meta name=color-scheme content="light dark"><base href="../"><title>%s</title>' "$f"
        printf '<body style="max-width:52em;margin:2em auto;padding:0 1em;font:16px/1.55 system-ui;color-scheme:light dark">'
        printf '<style>pre{overflow:auto;padding:1em;background:#8881;border-radius:6px}code{font:14px ui-monospace,monospace}table{border-collapse:collapse}td,th{border:1px solid #8884;padding:.3em .6em;text-align:left}img{max-width:100%%}blockquote{margin:0;padding:0 1em;border-left:3px solid #8886;color:#888}</style>'
        comrak --gfm --unsafe "$src" 2>/dev/null | sed -E 's|href="(\.\./)?(docs/)?([A-Z]+)\.md"|href="build/\3.html"|g'
      } > "build/$f.html"
    done
    setsid -f xdg-open build/README.html >/dev/null 2>&1 || echo "open build/README.html"

# The index is disposable; the markdown is canonical.
clean:
    rm -rf build "${XDG_STATE_HOME:-$HOME/.local/state}/brain"
