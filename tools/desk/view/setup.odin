package desk_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../shapes"

// --- Setup ------------------------------------------------------------------------

// Setup is the way from nothing to a vault that answers your agents, a
// step at a time, each a click or two: a vault, the agents connected to
// it, the memories they kept on their own brought in, sync between
// machines, and a first find. It opens by itself the first time the
// essential steps are not done.

SETUP_WIDTH :: 760 // the checklist's widest; a wider body centres it

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

// page_setup is the steps, each with what is done and what to do.
page_setup :: proc(gtx: ^ui.Ctx, m: ^Model) {
	r, st := ui.need(gtx, shapes.Setup{gen = m.setup_gen}, shapes.Setup_Result)
	vault_picked(gtx, m)
	create_picked_vault(gtx, m)
	defer import_dialog(gtx, m)
	defer move_dialog(gtx, m, ready(st) ? r.vault.path : "")
	// The checklist is a column a person reads down: no wider than
	// SETUP_WIDTH, centred in a wide body.
	w := min(body_width(m), SETUP_WIDTH)
	ui.row(gtx, align = .Start)
	ui.fill_space(gtx)
	{
		pane(gtx, m, .Setup, {w, 0})
		setup_checklist(gtx, m, r, st)
	}
	ui.fill_space(gtx)
}

// setup_checklist is the steps, inside Setup's pane.
@(private = "file")
setup_checklist :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result, st: ui.Status) {
	if !ready(st) {
		loading(gtx, 6)
		return
	}
	if failed(gtx, r.error) {
		return
	}
	s := &m.scheme
	ui.inset(gtx, ui.pad_all(20))
	ui.column(gtx, gap = 16, align = .Fill)
	left := setup_left(r)
	{
		ui.column(gtx, gap = 8, align = .Fill, key = 1)
		primer.heading(
			gtx,
			left == 0 ? "Your vault is working" : "Get your vault working",
			2,
			.Medium,
		)
		primer.text(
			gtx,
			left == 0 ? "Every step that matters is done. The rest is optional." : fmt.tprintf("%d of 3 steps left. Each is a click or two.", left),
			color = s[.Fg_Color_Muted],
		)
		primer.progress_bar(gtx, f32(3 - left) / 3 * 100, label = "Setup")
	}
	setup_vault(gtx, m, r)
	setup_agents(gtx, m, r)
	setup_memories(gtx, m, r)
	setup_sync(gtx, m, r)
	setup_try(gtx, m, r)
}

// step_head is the top of a step's card: whether it is done, its title
// and what it is for. The caller opens the card and its column around it,
// and draws what can be done under it.
@(private = "file")
step_head :: proc(gtx: ^ui.Ctx, m: ^Model, title, note: string, done: bool, optional := false) {
	s := &m.scheme
	{
		ui.row(gtx, gap = 10, align = .Center)
		glyph(
			gtx,
			done ? .Check_Circle_Fill : .Circle,
			20,
			done ? s[.Fg_Color_Success] : s[.Fg_Color_Muted],
		)
		primer.text(gtx, title, .Medium, .Semibold)
		if optional {
			primer.label(gtx, "optional", .Secondary, key = 1)
		}
	}
	primer.text(gtx, note, .Small, color = s[.Fg_Color_Muted], key = 2)
}

// glyph is an icon as a widget, size square.
glyph :: proc(gtx: ^ui.Ctx, i: primer.Icon, size: f32, color: ops.Color) {
	ui.sized(gtx, {min = {size, size}, max = {size, size}})
	primer.icon(gtx, i, {0, 0}, size, color)
}

// setup_vault is the vault: the one bound, or a new or existing one.
@(private = "file")
setup_vault :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	v := r.vault
	note := "A folder of markdown you own: your agents' memory. Make a new one, or use one you have."
	if v.exists {
		note = fmt.tprintf("%s · %s bullets", v.path, thousands(v.bullets))
	}
	b := boxed(gtx, 16, key = 10)
	defer ui.close(&b)
	ui.column(gtx, gap = 10, align = .Fill)
	step_head(gtx, m, "A vault", note, v.exists)
	ui.row(gtx, gap = 8, align = .Center)
	making := waiting_on(m, .New_Vault)
	if !v.exists {
		if primer.button(
			   gtx,
			   "Create a new vault…",
			   .Primary,
			   leading = .Plus,
			   loading = making,
		   ) &&
		   !making {
			ui.pick_folder(gtx, VAULT_NEW_PICK)
		}
	}
	if primer.button(
		   gtx,
		   v.exists ? "Use another vault…" : "Use an existing vault…",
		   .Default,
		   leading = .File_Directory,
		   inactive = making,
	   ) &&
	   !making {
		ui.pick_folder(gtx, VAULT_PICK, v.path)
	}
}

// create_picked_vault makes a new vault in the folder the system dialog chose.
@(private = "file")
create_picked_vault :: proc(gtx: ^ui.Ctx, m: ^Model) {
	for e in ui.events(gtx, VAULT_NEW_PICK) {
		if e.kind == .Picked && e.text != "" {
			send(gtx, m, .New_Vault, nil, e.text)
		}
	}
}

// setup_agents is each agent: connected, or a click from it.
@(private = "file")
setup_agents :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	s := &m.scheme
	b := boxed(gtx, 16, key = 20)
	defer ui.close(&b)
	ui.column(gtx, gap = 10, align = .Fill)
	step_head(
		gtx,
		m,
		"Your agents",
		"Connected, an agent is given the vault as it works and can propose what it learns; its transcripts are read on this machine, for recall and savings, and never leave it.",
		agent_connected(r),
	)
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
	if !r.vault.exists {
		primer.text(gtx, "Connect once there is a vault.", .Small, color = s[.Fg_Color_Muted])
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
	mem := r.memories
	note := "What your agents remembered on their own is in the vault."
	if mem.new > 0 {
		note = fmt.tprintf(
			"%s your agents kept on their own %s not in the vault yet. Each comes in as a proposal for you to approve.",
			mem.new == 1 ? "1 memory" : fmt.tprintf("%d memories", mem.new),
			mem.new == 1 ? "is" : "are",
		)
	}
	b := boxed(gtx, 16, key = 30)
	defer ui.close(&b)
	ui.column(gtx, gap = 10, align = .Fill)
	step_head(gtx, m, "Your agents' memories", note, mem.new == 0)
	if mem.new > 0 {
		ui.row(gtx, align = .Center)
		busy := waiting_on(m, .Import)
		if primer.button(
			   gtx,
			   mem.new == 1 ? "Import 1 memory…" : fmt.tprintf("Import %d memories…", mem.new),
			   .Primary,
			   leading = .Download,
			   loading = busy,
		   ) &&
		   !busy {
			open_import(m)
		}
	}
}

// setup_sync is whether the vault travels between machines.
@(private = "file")
setup_sync :: proc(gtx: ^ui.Ctx, m: ^Model, r: ^shapes.Setup_Result) {
	v, st := ui.need(gtx, shapes.Vault{}, shapes.Vault_Result)
	remote := ready(st) ? v.remote : ""
	done := r.sync && remote != ""
	note := "Use the vault on your other machines: every change here is sent there, and theirs come back."
	if done {
		note = fmt.tprintf("On, with %s.", remote)
	}
	b := boxed(gtx, 16, key = 40)
	defer ui.close(&b)
	ui.column(gtx, gap = 10, align = .Fill)
	step_head(gtx, m, "Your other machines", note, done, optional = true)
	if !done {
		ui.row(gtx, align = .Center)
		if primer.button(gtx, "Set up sync in Vault", .Default, leading = .Sync) {
			go(m, .Vault)
		}
	}
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
	b := boxed(gtx, 16, key = 50)
	defer ui.close(&b)
	ui.column(gtx, gap = 10, align = .Fill)
	step_head(gtx, m, "Try it", note, r.lookups > 0, optional = true)
	if !r.vault.exists {
		primer.text(gtx, "Make or choose a vault first.", .Small, color = s[.Fg_Color_Muted])
		return
	}
	primer.text_input(
		gtx,
		&m.try,
		placeholder = "how do I run the tests",
		leading = .Search,
		block = true,
		name = "Ask the vault",
	)
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
		for h, i in f.hits[:min(len(f.hits), 3)] {
			ui.column(gtx, gap = 2, align = .Fill, key = u64(100 + i))
			primer.text(gtx, h.handle, .Medium, .Semibold)
			primer.text(gtx, h.fact, .Small, key = 1)
		}
	}
}
