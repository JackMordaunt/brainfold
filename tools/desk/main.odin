/*
desk is brainfold's control room over a vault: what agents asked and
what missed, what they said, what they proposed, and the vault's health
and sync, drawn with jm:ui/primer. Every page is a need the application
answers by asking the brain CLI (`brain <command> --json`), on worker
threads, and every button a command it carries out; see app/.

	view     the ui: needs and commands, never the CLI     (ui)
	shapes   the needs, their answers and the commands     (leaf)
	cli      the brain CLI as shapes                        (io)
	app      the host: ports, workers, refresh, delivery    (io)
	host     the window and the application, for `just desk`

	desk                              the hot-reload child: host/ owns the window and the application
	desk -window                      one process, window and application
	desk -page Inbox -png out.png     render a page headlessly, once the vault has answered
	desk -theme dark -size 960x1030 -page Doctor -png out.png
	desk -brain build/minimal/brain ... another CLI binary than the one on PATH

Headless, the flags run in order: the settings (-page, -theme, -size,
-brain) and then ui/render's steps (-png, -dump, -click, -key, ...), each
step after the application has gone quiet.
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "jm:ui"
import "jm:ui/child"
import "jm:ui/ops"
import "jm:ui/primer"
import "jm:ui/render"
import "jm:ui/shell"

import "../../msg"
import "app"
import "cli"
import "fonts"
import "view"

WIDTH :: 1280
HEIGHT :: 840
SETTLE_LIMIT :: 30 * time.Second

main :: proc() {
	conf := msg.config_dir()
	system := msg.system_tags()
	msg.boot(conf, system)
	m: view.Model
	view.model_init(&m, locale = msg.locale_now())
	m.language_dir = conf
	defer view.model_destroy(&m)
	faces := fonts.fonts()

	if len(os.args) == 1 {
		child.run({ui = view.view, user = &m, fonts = faces, fallbacks = fonts.FALLBACKS})
		return
	}

	// What the desk itself asks the vault is the desk's, not the agent's
	// whose terminal started it: the query log says who asked, and brain
	// takes BRAIN_CALLER over the agent's own variables (caller_id).
	os.set_env("BRAIN_CALLER", "desk")
	client := cli.Client{exe = "brain"}
	size := ops.Size{WIDTH, HEIGHT}
	args := os.args[1:]
	// The settings first, wherever they are; then the window, or the steps.
	steps := make([dynamic]string)
	window := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-window":
			window = true
		case "-page":
			name := value(args, &i)
			found := false
			for title, p in view.PAGE_TITLES {
				if strings.equal_fold(title, name) {
					m.page, found = p, true
				}
			}
			if !found {
				fmt.eprintln(msg.textf(.Desk_No_Page, name))
				os.exit(2)
			}
			// The page asked for is the page shown: Setup's offer to a
			// machine with no agent connected would replace it.
			m.setup_offered = true
		case "-theme":
			name := value(args, &i)
			found := false
			for title, t in primer.THEME_NAMES {
				if strings.equal_fold(title, name) {
					m.theme, found = t, true
				}
			}
			if !found {
				fmt.eprintln(msg.textf(.Desk_No_Theme, name))
				os.exit(2)
			}
		case "-size":
			v := value(args, &i)
			w, _, h := strings.partition(v, "x")
			wi, wok := strconv.parse_int(w)
			hi, hok := strconv.parse_int(h)
			if !wok || !hok || wi <= 0 || hi <= 0 {
				fmt.eprintln(msg.textf(.Desk_Bad_Size, v))
				os.exit(2)
			}
			size = {f32(wi), f32(hi)}
		case "-brain":
			client.exe = value(args, &i)
		case:
			append(&steps, args[i])
		}
	}

	h := new(app.Host)
	defer free(h)
	if window {
		app.init(h, client, shell.wake)
		defer app.stop(h)
		shell.run({title = msg.text(.App_Name), width = int(size.x), height = int(size.y), min_width = int(view.MIN_WINDOW.x), min_height = int(view.MIN_WINDOW.y), ui = view.view, user = &m, fonts = faces, fallbacks = fonts.FALLBACKS, data = app.data_host(h)})
		return
	}
	app.init(h, client)
	defer app.stop(h)
	data := app.data_host(h)
	hl: render.Headless
	render.headless_init(&hl, view.view, &m, size, faces, data = &data, fallbacks = fonts.FALLBACKS)
	defer render.headless_destroy(&hl)
	for i := 0; i < len(steps); i += 1 {
		if !settle(&hl, h) {
			fmt.eprintln(msg.text(.Desk_No_Answer))
			os.exit(1)
		}
		handled, ok := render.headless_step(&hl, steps[:], &i)
		if !handled {
			fmt.eprintln(msg.textf(.Desk_Unknown_Flag, steps[i]))
			os.exit(2)
		}
		if !ok {
			os.exit(1)
		}
	}
}

// settle runs frames until the application has answered every need and
// nothing new is asked: a page that needs more once it has an answer
// (the rail's counts, then the page) takes more than one round.
settle :: proc(hl: ^render.Headless, h: ^app.Host) -> bool {
	deadline := time.tick_now()._nsec + i64(SETTLE_LIMIT)
	ui.probe_frame(&hl.p)
	for time.tick_now()._nsec < deadline {
		if app.idle(h) {
			ui.probe_frame(&hl.p)
			if app.idle(h) {
				// A wait shown for a loading need is drawn once its delay has
				// passed; nothing is loading now, so one more frame is the page.
				ui.probe_frame(&hl.p)
				return true
			}
		}
		time.sleep(10 * time.Millisecond)
		ui.probe_frame(&hl.p)
	}
	return false
}

value :: proc(args: []string, i: ^int) -> string {
	if i^ + 1 >= len(args) {
		fmt.eprintln(msg.textf(.Desk_Needs_Value, args[i^]))
		os.exit(2)
	}
	i^ += 1
	return args[i^]
}
