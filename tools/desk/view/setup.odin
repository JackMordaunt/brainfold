package desk_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/base"
import "jm:ui/ops"
import "jm:ui/primer"

import "../shapes"

// --- Setup ------------------------------------------------------------------------

// Setup is the way from nothing to a vault that answers your agents, a
// step at a time, each a click or two: a vault, the agents connected to
// it, the memories they kept on their own brought in, sync between
// machines, and a first find. It opens by itself the first time the
// essential steps are not done.

// VAULT_NEW_PICK is the area a pick of a folder for a new vault answers.
VAULT_NEW_PICK :: ops.Area_Id(0x7a17_f01e)

// setup_left is how many of the steps that make the vault work are not
// done: a vault, an agent connected to it, and memories waiting to come in.
setup_left :: proc(r: ^shapes.Setup_Result) -> (n: int) {
	if !r.vault.exists {
		n += 1
	}
	if !agent_connected(r) {
		n += 1
	}
	if r.memories.new > 0 {
		n += 1
	}
	return
}

// agent_connected is whether any agent on this machine is connected.
agent_connected :: proc(r: ^shapes.Setup_Result) -> bool {
	for a in r.agents {
		if a.installed && a.hooks && a.reading {
			return true
		}
	}
	return false
}

// setup_offer opens Setup once, the first time a vault or an agent is
// missing, so a new machine starts there.
setup_offer :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if m.setup_offered {
		return
	}
	r, st := ui.need(gtx, shapes.Setup{gen = m.setup_gen}, shapes.Setup_Result)
	if !ready(st) || r.error != "" {
		return
	}
	m.setup_offered = true
	if !r.vault.exists || !agent_connected(r) {
		go(m, .Setup)
	}
}

// Setup_Step is a step of Setup: the three that make the vault work,
// then the two that are optional.
Setup_Step :: enum u8 {
	Vault,
	Agents,
	Memories,
	Sync,
	Try,
}

SETUP_STEP_TITLES := [Setup_Step]string {
	.Vault    = "A vault",
	.Agents   = "Your agents",
	.Memories = "Your agents' memories",
	.Sync     = "Your other machines",
	.Try      = "Try it",
}

// step_done is whether a step is done.
step_done :: proc(gtx: ^ui.Ctx, r: ^shapes.Setup_Result, step: Setup_Step) -> bool {
	switch step {
	case .Vault:
		return r.vault.exists
	case .Agents:
		return agent_connected(r)
	case .Memories:
		return r.memories.new == 0
	case .Sync:
		v, st := ui.need(gtx, shapes.Vault{}, shapes.Vault_Result)
		return r.sync && ready(st) && v.remote != ""
	case .Try:
		return r.lookups > 0
	}
	return false
}

// setup_shown is the step Setup shows: the one chosen, or until one is,
// the first not done.
setup_shown :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) -> Setup_Step {
	if m.setup_chosen {
		return m.setup_step
	}
	for step in Setup_Step {
		if !step_done(gtx, r, step) {
			return step
		}
	}
	return .Vault
}

// page_setup is the steps in a list, each with whether it is done, beside
// the one chosen: what it is for, and what to do.
page_setup :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, st := ui.need(gtx, shapes.Setup{gen = m.setup_gen}, shapes.Setup_Result)
	vault_picked(gtx, m)
	create_picked_vault(gtx, m)
	defer import_dialog(gtx, m)
	defer move_dialog(gtx, m, ready(st) ? r.vault.path : "")
	arrange(gtx, m)
	w := split_list(gtx, m)
	{
		pane(gtx, m, .Setup, w[0], scroll = false)
		setup_steps(gtx, m, r, st)
	}
	if !ready(st) || r.error != "" {
		pane(gtx, m, .Setup_Step, w[1], scroll = false)
		return
	}
	step := setup_shown(gtx, m, r)
	// Only what grows scrolls: the agents and a find's answers.
	scroll := step == .Agents || step == .Try
	footer: Pane_Bar
	switch step {
	case .Vault:
		footer = vault_actions
	case .Memories:
		footer = r.memories.new > 0 ? memories_actions : nil
	case .Sync:
		footer = step_done(gtx, r, .Sync) ? nil : sync_actions
	case .Agents, .Try:
	}
	pane(
		gtx,
		m,
		.Setup_Step,
		w[1],
		SETUP_STEP_TITLES[step],
		bar = step == .Try && r.vault.exists ? try_bar : nil,
		scroll = scroll,
		footer = footer,
	)
	ui.inset(gtx, ui.pad_all(16))
	ui.column(gtx, gap = 12, align = .Fill)
	switch step {
	case .Vault:
		setup_vault(gtx, m, r)
	case .Agents:
		setup_agents(gtx, m, r)
	case .Memories:
		setup_memories(gtx, m, r)
	case .Sync:
		setup_sync(gtx, m, r)
	case .Try:
		setup_try(gtx, m, r)
	}
}

// setup_steps is the list: how many steps are left, then each step, the
// optional ones under their own heading.
@(private = "file")
setup_steps :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result, st: ui.Status) {
	if !ready(st) {
		loading(gtx, 6)
		return
	}
	if failed(gtx, r.error) {
		return
	}
	s := &m.scheme
	left := setup_left(r)
	{
		ui.inset(gtx, {16, 16, 16, 12})
		ui.column(gtx, gap = 8, align = .Fill)
		primer.heading(
			gtx,
			left == 0 ? "Your vault is working" : "Get your vault working",
			3,
			.Small,
		)
		primer.text(
			gtx,
			left == 0 ? "Every step that matters is done. The rest is optional." : fmt.tprintf("%d of 3 steps left. Each is a click or two.", left),
			.Small,
			color = s[.Fg_Color_Muted],
		)
		primer.progress_bar(gtx, f32(3 - left) / 3 * 100, label = "Setup")
	}
	base.divider(gtx, s[.Border_Color_Muted], key = 1)
	shown := setup_shown(gtx, m, r)
	ui.inset(gtx, {8, 8, 8, 8})
	ui.column(gtx, gap = 2, align = .Fill)
	for step in Setup_Step {
		if step == .Sync {
			ui.inset(gtx, {8, 12, 8, 4}, key = 0x0b7)
			primer.text(gtx, "Optional", .Small, .Medium, color = s[.Fg_Color_Muted])
		}
		ui.scope(gtx, u64(step) + 1)
		done := step_done(gtx, r, step)
		if row_button(
			gtx,
			SETUP_STEP_TITLES[step],
			step == shown,
			done ? .Check_Circle_Fill : .Circle,
		) {
			m.setup_step, m.setup_chosen = step, true
			m.panes[.Setup_Step] = {}
		}
	}
}

// setup_vault is the vault: the one bound, or what one is for.
@(private = "file")
setup_vault :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	s := &m.scheme
	v := r.vault
	primer.text(
		gtx,
		"A folder of markdown you own: your agents' memory. Make a new one, or use one you have.",
		color = s[.Fg_Color_Muted],
	)
	if v.exists {
		fields(gtx, {{"folder", v.path}, {"bullets", thousands(v.bullets)}})
	}
}

// vault_actions is the vault step's footer: a new vault, or one there is.
@(private = "file")
vault_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, st := ui.need(gtx, shapes.Setup{gen = m.setup_gen}, shapes.Setup_Result)
	if !ready(st) {
		return
	}
	v := r.vault
	ui.row(gtx, gap = 8, align = .Center)
	making := waiting_on(m, .New_Vault)
	if !v.exists {
		tip := ui.stack_open(gtx, key = 1)
		defer ui.close(&tip)
		if primer.button(gtx, "Create", .Primary, leading = .Plus, loading = making) && !making {
			ui.pick_folder(gtx, VAULT_NEW_PICK)
		}
		primer.tooltip(
			gtx,
			"Make a new vault in a folder you pick.",
			ui.last_widget(gtx),
			delay = TOOLTIP_DELAY,
		)
	}
	tip := ui.stack_open(gtx, key = 2)
	defer ui.close(&tip)
	if primer.button(
		   gtx,
		   v.exists ? "Change" : "Open",
		   .Default,
		   leading = .File_Directory,
		   inactive = making,
	   ) &&
	   !making {
		ui.pick_folder(gtx, VAULT_PICK, v.path)
	}
	primer.tooltip(
		gtx,
		v.exists ? "Use another vault, in a folder you pick: its notes answer every agent from then on." : "Use a vault you already have, in a folder you pick.",
		ui.last_widget(gtx),
		delay = TOOLTIP_DELAY,
	)
}

// create_picked_vault makes a new vault in the folder the system dialog
// chose, and Setup goes on to the next step not done once it is made.
@(private = "file")
create_picked_vault :: proc(gtx: ^ui.Ctx, m: ^Model) {
	for e in ui.events(gtx, VAULT_NEW_PICK) {
		if e.kind == .Picked && e.text != "" {
			send(gtx, m, .New_Vault, nil, e.text)
			m.setup_chosen = false
		}
	}
}

// setup_agents is each agent: connected, or a click from it.
@(private = "file")
setup_agents :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	s := &m.scheme
	primer.text(
		gtx,
		"Connected, an agent is given the vault as it works and can propose what it learns; its transcripts are read on this machine, for recall and savings, and never leave it.",
		color = s[.Fg_Color_Muted],
	)
	if !r.vault.exists {
		primer.inline_message(gtx, "Connect once there is a vault.", .Warning, .Small)
	}
	ui.column(gtx, gap = 8, align = .Fill)
	for a, i in r.agents {
		ui.row(gtx, gap = 10, align = .Center, key = u64(i + 1))
		name := agent_name(a.name)
		primer.text(gtx, name, .Medium, .Medium)
		ui.fill_space(gtx)
		switch {
		case !a.installed:
			primer.text(gtx, "not on this machine", .Small, color = s[.Fg_Color_Muted])
		case a.hooks && a.reading:
			primer.state_label(gtx, "Connected", .Open, .Small)
		case:
			busy := waiting_on(m, .Connect, a.name)
			if primer.button(
				   gtx,
				   "Connect",
				   .Primary,
				   .Small,
				   loading = busy,
				   inactive = !r.vault.exists,
				   name = fmt.tprintf("Connect %s", name),
			   ) &&
			   !busy &&
			   r.vault.exists {
				send(gtx, m, .Connect, {a.name})
			}
		}
	}
}

// agent_name is an agent brain serves as its maker names it.
agent_name :: proc(name: string) -> string {
	switch name {
	case "claude":
		return "Claude Code"
	}
	return name
}

// setup_memories is what agents remembered on their own, to bring in.
@(private = "file")
setup_memories :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	s := &m.scheme
	mem := r.memories
	note := "What your agents remembered on their own is in the vault."
	if mem.new > 0 {
		note = fmt.tprintf(
			"%s your agents kept on their own %s not in the vault yet. Each comes in as a proposal for you to approve.",
			mem.new == 1 ? "1 memory" : fmt.tprintf("%d memories", mem.new),
			mem.new == 1 ? "is" : "are",
		)
	}
	primer.text(gtx, note, color = s[.Fg_Color_Muted])
}

// memories_actions is the memories step's footer: bring them in.
@(private = "file")
memories_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, st := ui.need(gtx, shapes.Setup{gen = m.setup_gen}, shapes.Setup_Result)
	if !ready(st) || r.memories.new == 0 {
		return
	}
	n := r.memories.new
	ui.row(gtx, align = .Center)
	tip := ui.stack_open(gtx)
	defer ui.close(&tip)
	busy := waiting_on(m, .Import)
	if primer.button(gtx, "Import", .Primary, leading = .Download, loading = busy) && !busy {
		open_import(m)
	}
	primer.tooltip(
		gtx,
		n == 1 ? "Bring in the 1 memory your agents kept on their own, as a proposal to approve." : fmt.tprintf("Bring in the %d memories your agents kept on their own, each as a proposal to approve.", n),
		ui.last_widget(gtx),
		delay = TOOLTIP_DELAY,
	)
}

// setup_sync is whether the vault travels between machines.
@(private = "file")
setup_sync :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	s := &m.scheme
	v, st := ui.need(gtx, shapes.Vault{}, shapes.Vault_Result)
	note := "Use the vault on your other machines: every change here is sent there, and theirs come back."
	if step_done(gtx, r, .Sync) {
		note = fmt.tprintf("On, with %s.", ready(st) ? v.remote : "")
	}
	primer.text(gtx, note, color = s[.Fg_Color_Muted])
}

// sync_actions is the sync step's footer: to the Vault page, where sync is set up.
@(private = "file")
sync_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.row(gtx, align = .Center)
	if primer.button(gtx, "Set up sync in Vault", .Default, leading = .Sync) {
		go(m, .Vault)
	}
}

// try_bar is the try step's bar: what an agent would ask.
@(private = "file")
try_bar :: proc(gtx: ^ui.Ctx, m: ^Model) {
	primer.text_input(
		gtx,
		&m.try,
		placeholder = "how do I run the tests",
		leading = .Search,
		block = true,
		name = "Ask the vault",
	)
}

// setup_try is a first find: what an agent is told when it asks.
@(private = "file")
setup_try :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	s := &m.scheme
	note := "Ask what an agent would ask, and see what the vault tells it."
	if r.lookups > 0 {
		note = fmt.tprintf(
			"Your agents have asked %s times. Ask what one would, and see what it is told.",
			thousands(r.lookups),
		)
	}
	primer.text(gtx, note, color = s[.Fg_Color_Muted])
	if !r.vault.exists {
		primer.inline_message(gtx, "Make or choose a vault first.", .Warning, .Small)
		return
	}
	terms := strings.trim_space(ui.text_string(&m.try))
	if terms == "" {
		return
	}
	f, fst := ui.need(gtx, shapes.Find{terms = terms}, shapes.Find_Result)
	switch {
	case !ready(fst):
		loading(gtx, 2)
	case f.error != "":
		primer.inline_message(gtx, f.error, .Critical, .Small)
	case len(f.hits) == 0:
		primer.text(
			gtx,
			"Nothing in the vault for that yet. An agent asking it would be told so, and it would show under Misses.",
			.Small,
			color = s[.Fg_Color_Muted],
		)
	case:
		for h, i in f.hits {
			ui.column(gtx, gap = 2, align = .Fill, key = u64(100 + i))
			primer.text(gtx, h.handle, .Medium, .Semibold)
			primer.text(gtx, h.fact, .Small, key = 1)
		}
	}
}
