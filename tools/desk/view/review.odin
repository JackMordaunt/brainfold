package desk_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/primer"

import "../shapes"

// Reviewing a proposal before it is approved: what lint says of it, the
// bullets in the vault it may repeat, each a merge away, and the
// conversation that proposed it.

// Merge_Edit is the merge dialog: the proposal folded into the bullet at
// at, named into, through fields filled from that bullet.
Merge_Edit :: struct {
	open:     bool,
	proposal: Chosen,
	into:     Chosen,
	at:       Chosen,
	said:     Chosen, // the proposal's fact, shown beside the fields
	handle:   ui.Text_State,
	aliases:  ui.Text_State,
	fact:     ui.Text_State,
	source:   ui.Text_State,
}

merge_init :: proc(e: ^Merge_Edit, allocator := context.allocator) {
	for f in ([4]^ui.Text_State{&e.handle, &e.aliases, &e.fact, &e.source}) {
		f.buf = make([dynamic]u8, allocator)
	}
}

merge_destroy :: proc(e: ^Merge_Edit) {
	for f in ([4]^ui.Text_State{&e.handle, &e.aliases, &e.fact, &e.source}) {
		delete(f.buf)
	}
}

// proposal_review is what bears on proposal p, under it.
proposal_review :: proc(gtx: ^ui.Ctx, m: ^Model, p: shapes.Proposal) {
	s := &m.scheme
	r, st := ui.need(gtx, shapes.Inbox_Review{handle = p.handle}, shapes.Inbox_Review_Result)
	ui.column(gtx, gap = 16, align = .Fill, key = 0x7e)
	if !ready(st) {
		loading(gtx, 3)
		return
	}
	if failed(gtx, r.error) {
		return
	}
	if len(r.errors) + len(r.warnings) > 0 {
		ui.column(gtx, gap = 6, align = .Fill, key = 1)
		for e, i in r.errors {
			primer.inline_message(gtx, e, .Critical, .Small, key = u64(10 + i))
		}
		for x, i in r.warnings {
			primer.inline_message(gtx, x, .Warning, .Small, key = u64(30 + i))
		}
	}
	repeats: {
		ui.column(gtx, gap = 8, align = .Fill, key = 2)
		section(gtx, "May repeat")
		if len(r.similar) == 0 {
			primer.text(
				gtx,
				"Nothing in the vault says this yet.",
				.Small,
				color = s[.Fg_Color_Muted],
			)
		}
		for b, i in r.similar {
			similar_card(gtx, m, p, b, u64(i + 1))
		}
	}
	origin: {
		ui.column(gtx, gap = 8, align = .Fill, key = 3)
		section(gtx, "Where it came from")
		o := r.origin
		if o.session == "" {
			primer.text(
				gtx,
				"No agent transcript on this machine proposed it: it was imported, written by hand, or proposed on another machine.",
				.Small,
				color = s[.Fg_Color_Muted],
			)
			return
		}
		card := boxed(gtx, 12)
		defer ui.close(&card)
		ui.column(gtx, gap = 8, align = .Fill)
		primer.text(gtx, o.title != "" ? o.title : "Untitled session", .Medium, .Semibold)
		when_ := len(o.ts) >= 16 ? fmt.tprintf("%s %s", o.ts[:10], o.ts[11:16]) : o.ts
		primer.text(
			gtx,
			fmt.tprintf("Proposed by %s, %s", o.agent != "" ? o.agent : "an agent", when_),
			.Small,
			color = s[.Fg_Color_Muted],
		)
		ui.row(gtx, align = .Center)
		if primer.button(
			gtx,
			"Read the conversation",
			.Default,
			.Small,
			leading = .Comment_Discussion,
		) {
			read_conversation(m, p.handle, o.turn)
		}
	}
}

// similar_card is one bullet the proposal may repeat: how close it is,
// what it says, and the merge into it.
similar_card :: proc(gtx: ^ui.Ctx, m: ^Model, p: shapes.Proposal, b: shapes.Near_Match, key: u64) {
	s := &m.scheme
	card := boxed(gtx, 12, key = key)
	defer ui.close(&card)
	ui.column(gtx, gap = 6, align = .Fill)
	{
		ui.wrap(gtx, gap = 8, line_gap = 4, align = .Center)
		primer.text(gtx, b.handle, .Medium, .Semibold)
		if b.same_handle {
			primer.label(gtx, "same handle", .Attention, key = 1)
		}
		primer.label(gtx, fmt.tprintf("%.0f%% shared", b.share * 100), .Secondary, key = 2)
	}
	primer.text(
		gtx,
		fmt.tprintf("%s:%d · %s", b.file, b.line, b.date),
		.Small,
		color = s[.Fg_Color_Muted],
		key = 3,
	)
	primer.text(gtx, b.fact, key = 4)
	ui.row(gtx, gap = 8, align = .Center, key = 5)
	busy := waiting_on(m, .Merge, p.handle)
	st := ui.stack_open(gtx, key = 6)
	if primer.button(
		   gtx,
		   "Merge into this",
		   .Default,
		   .Small,
		   leading = .Git_Merge,
		   loading = busy,
	   ) &&
	   !busy {
		open_merge(m, p, b)
	}
	primer.tooltip(
		gtx,
		"Fold the proposal into this bullet: edit the bullet with what the proposal adds, and the proposal leaves the inbox.",
		ui.last_widget(gtx),
		delay = TOOLTIP_DELAY,
	)
	ui.close(&st)
}

// open_merge fills the merge dialog from b, the proposal's names joined
// to its own.
open_merge :: proc(m: ^Model, p: shapes.Proposal, b: shapes.Near_Match) {
	e := &m.merge
	e.open = true
	choose(&e.proposal, p.handle)
	choose(&e.into, b.handle)
	choose(&e.at, fmt.tprintf("%s:%d", b.file, b.line))
	choose(&e.said, p.fact)
	ui.text_set(&e.handle, b.handle)
	ui.text_set(&e.aliases, merged_aliases(b.handle, b.aliases, p.handle, p.aliases))
	ui.text_set(&e.fact, b.fact)
	ui.text_set(&e.source, b.source)
}

// merged_aliases is a bullet's names with a proposal's added: its own
// aliases, then the proposal's handle and aliases, each once, whatever
// the case, and never the bullet's own handle.
merged_aliases :: proc(handle, aliases, p_handle, p_aliases: string) -> string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, handle, name: string) {
		n := strings.trim_space(name)
		if n == "" || strings.equal_fold(n, handle) {
			return
		}
		for x in out {
			if strings.equal_fold(x, n) {
				return
			}
		}
		append(out, n)
	}
	for a in strings.split(aliases, ",", context.temp_allocator) {
		add(&out, handle, a)
	}
	add(&out, handle, p_handle)
	for a in strings.split(p_aliases, ",", context.temp_allocator) {
		add(&out, handle, a)
	}
	return strings.join(out[:], ", ", context.temp_allocator)
}

// merge_line is the bullet the merge dialog's fields make, dated today.
merge_line :: proc(e: ^Merge_Edit) -> string {
	b := shapes.Near_Match {
		handle  = strings.trim_space(ui.text_string(&e.handle)),
		aliases = strings.trim_space(ui.text_string(&e.aliases)),
		fact    = strings.trim_space(ui.text_string(&e.fact)),
		source  = strings.trim_space(ui.text_string(&e.source)),
	}
	return bullet_line(
		{handle = b.handle, aliases = b.aliases, fact = b.fact, source = b.source, date = today()},
		b.handle,
	)
}

// merge_dialog edits the bullet the proposal folds into, lints it as it
// is typed, and merges on confirmation.
merge_dialog :: proc(gtx: ^ui.Ctx, m: ^Model) {
	e := &m.merge
	if !e.open {
		return
	}
	s := &m.scheme
	line := merge_line(e)
	filled :=
		strings.trim_space(ui.text_string(&e.handle)) != "" &&
		strings.trim_space(ui.text_string(&e.fact)) != ""
	errors := -1
	c: ^shapes.Bullet_Check_Result
	if filled {
		r, st := ui.need(gtx, shapes.Bullet_Check{line = line}, shapes.Bullet_Check_Result)
		if ready(st) {
			c, errors = r, len(r.errors)
		}
	}
	go_, cancel: bool
	footer := []primer.Dialog_Button {
		{content = "Cancel", clicked = &cancel},
		{content = "Merge", type = .Primary, disabled = errors != 0, clicked = &go_},
	}
	dl := primer.dialog_open(
		gtx,
		&e.open,
		fmt.tprintf("Merge into %s", chosen(&e.into)),
		"The bullet keeps its place; the proposal leaves the inbox and is not proposed again.",
		footer,
		width = .Large,
	)
	if dl.visible {
		ui.column(gtx, gap = 12, align = .Fill)
		{
			ui.column(gtx, gap = 4, align = .Fill, key = 1)
			primer.text(gtx, "The proposal says", .Small, .Medium, color = s[.Fg_Color_Muted])
			b := boxed(gtx, 12)
			primer.text(gtx, chosen(&e.said), .Small)
			ui.close(&b)
		}
		field(gtx, "Handle", "what a find names it by", &e.handle, key = 2)
		field(gtx, "Aliases", "other names, comma-separated", &e.aliases, key = 3)
		{
			ui.column(gtx, gap = 4, align = .Fill, key = 4)
			primer.text(gtx, "Fact", .Small, .Medium, color = s[.Fg_Color_Muted])
			primer.textarea(
				gtx,
				&e.fact,
				placeholder = "One fact, stated once",
				rows = 4,
				resize = .None,
				block = true,
				name = "Merged fact",
			)
		}
		field(gtx, "Source", "where it came from", &e.source, key = 5)
		if c != nil {
			for x, i in c.errors {
				primer.inline_message(gtx, x, .Critical, .Small, key = u64(20 + i))
			}
			for x, i in c.warnings {
				primer.inline_message(gtx, x, .Warning, .Small, key = u64(40 + i))
			}
		}
	}
	primer.dialog_close(&dl)
	if cancel {
		e.open = false
	}
	if go_ && errors == 0 {
		send(gtx, m, .Merge, {chosen(&e.proposal), chosen(&e.into)}, line, chosen(&e.at))
		e.open = false
	}
}
