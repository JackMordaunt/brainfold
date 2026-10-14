/*
The window half of `just desk`: it owns the window and the application,
and respawns the desk's view, tools/desk, whenever the pointer file names
a new build. The application lives here, not in the child, so a reload
keeps every answer it has and the view's needs and commands cross the
wire; a result that lands while the window is idle wakes it.

	desk-host build/desk.watch [title] [WxH]
	desk-host build/debug/desk                   a fixed child

BRAIN names the CLI binary, "brain" on PATH by default.
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "jm:ui/shell"

import "../../../msg"
import "../app"
import "../cli"

main :: proc() {
	conf := msg.config_dir()
	msg.boot(conf, msg.system_tags())
	if len(os.args) < 2 || len(os.args) > 4 {
		fmt.eprintln(msg.text(.Host_Usage))
		os.exit(2)
	}
	h := new(app.Host)
	defer free(h)
	exe := os.get_env("BRAIN", context.allocator)
	// What the desk itself asks the vault is the desk's, not the agent's
	// whose terminal started it: the query log says who asked, and brain
	// takes BRAIN_CALLER over the agent's own variables (caller_id).
	os.set_env("BRAIN_CALLER", "desk")
	app.init(h, cli.Client{exe = exe != "" ? exe : "brain"}, shell.wake)
	defer app.stop(h)

	a := shell.Host_App {
		title  = msg.text(.App_Name),
		width  = 1280,
		height = 840,
		clear  = {255, 255, 255, 255}, // Primer light's --bgColor-default
		data   = app.data_host(h),
		// The view's MIN_WINDOW; the host does not link the view.
		min_width  = 800,
		min_height = 560,
	}
	if len(os.args) >= 3 {
		a.title = os.args[2]
	}
	if len(os.args) == 4 {
		w, _, ht := strings.partition(os.args[3], "x")
		wi, wok := strconv.parse_int(w)
		hi, hok := strconv.parse_int(ht)
		if !wok || !hok || wi <= 0 || hi <= 0 {
			fmt.eprintln(msg.textf(.Host_Bad_Size, os.args[3]))
			os.exit(2)
		}
		a.width, a.height = wi, hi
	}
	if strings.has_suffix(os.args[1], ".watch") {
		a.watch = os.args[1]
	} else {
		a.child = os.args[1:2]
	}
	shell.run_host(a)
}
