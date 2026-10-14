package desk_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/primer"

import "../shapes"

// Doctor's fixes: each finding offers what sets it right, a click each,
// in its pane's footer; a bullet's duplicates are each shown with their
// own. A fix is a command; doctor runs again after it, and a finding
// fixed leaves its list.

// Fix is the finding the Doctor page shows, for its footer, and the fixes
// in progress there.
Fix :: struct {
	list:     Finding_List,
	at:       int, // the item shown in list
	dropping: bool, // the drop confirmation is open
	handle:   Chosen, // the bullet it would drop
	place:    Chosen, // where that bullet is, FILE:LINE, or empty for the one so named
	renaming: Chosen, // the place of the duplicate whose handle is being changed
}

// has_fixes is whether list's findings have a footer of fixes: thin
// aliases are fixed in the alias editor, duplicates copy by copy.
has_fixes :: proc(l: Finding_List) -> bool {
	return l != .Thin_Aliases && l != .Duplicates
}

// fix_bar is the shown finding's fixes, the pane's footer.
fix_bar :: proc(gtx: ^ui.Ctx, m: ^Model) {
	d, st := ui.need(gtx, shapes.Doctor{}, shapes.Doctor_Result)
	if !ready(st) {
		return
	}
	l, i := m.fix.list, m.fix.at
	if i >= finding_count(d, l) {
		return
	}
	ui.row(gtx, gap = 8, align = .Center)
	#partial switch l {
	case .Failed_Claims:
		h := d.failed_claims[i].handle
		edit_fix(gtx, m, h, "Open it in Bullets to correct what it says.", .Primary)
		ui.fill_space(gtx)
		drop_fix(gtx, m, h)
	case .Stale:
		h := d.stale[i].handle
		busy := waiting_on(m, .Touch_Bullet, h)
		if fix_button(gtx, "Confirm", "Date it today: you checked, and it still holds.", .Primary, .Check, loading = busy) && !busy {
			send(gtx, m, .Touch_Bullet, {h})
		}
		edit_fix(gtx, m, h, "Open it in Bullets to rewrite what no longer holds.")
		ui.fill_space(gtx)
		drop_fix(gtx, m, h)
	case .Dead_Links:
		x := d.dead_links[i]
		busy := waiting_on(m, .Unlink, x.target)
		if fix_button(gtx, "Unlink", fmt.tprintf("Make [[%s]] plain text in %s: the words stay, the link goes.", x.target, x.file), .Primary, .Unlink, loading = busy) && !busy {
			send(gtx, m, .Unlink, {x.target}, x.file, fmt.tprint(x.line))
		}
		if fix_button(gtx, "Write", "Write the bullet the link names, so it leads somewhere.", .Default, .Plus) {
			// The link resolves to a bullet whose handle is its target with
			// spaces for dashes, as doctor matches them.
			named, _ := strings.replace_all(x.target, "-", " ", context.temp_allocator)
			draft(m, named, x.target)
		}
	case .Oversized:
		edit_fix(gtx, m, d.oversized[i].handle, "Open it in Bullets to cut it to one fact; write the rest as bullets of their own.", .Primary)
	case .Orphans:
		file := d.orphan_artifacts[i].file
		if fix_button(gtx, "Write", "Write a bullet whose source is this note, so a find leads an agent to it.", .Primary, .Plus) {
			draft(m, source = file)
		}
	case .Promote:
		edit_fix(gtx, m, d.promote[i].handle, "Open it in Bullets: copy it into the project's own files, then drop or shorten it here.", .Primary)
	case .Never_Returned:
		h := d.never_returned[i].handle
		edit_fix(gtx, m, h, "Open it in Bullets: a handle in other words may be what finds it.")
		ui.fill_space(gtx)
		drop_fix(gtx, m, h)
	}
}

// fix_button is a fix: a button, and what it does in a tooltip.
fix_button :: proc(gtx: ^ui.Ctx, label, tip: string, variant: primer.Button_Variant, icon: primer.Icon, loading := false, inactive := false, key: u64 = 0, loc := #caller_location) -> bool {
	st := ui.stack_open(gtx, key, loc)
	defer ui.close(&st)
	clicked := primer.button(gtx, label, variant, leading = icon, loading = loading, inactive = inactive, key = key, loc = loc)
	primer.tooltip(gtx, tip, ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	return clicked
}

// edit_fix opens the bullet named handle in Bullets.
edit_fix :: proc(gtx: ^ui.Ctx, m: ^Model, handle, tip: string, variant := primer.Button_Variant.Default) {
	if fix_button(gtx, "Edit", tip, variant, .Pencil) {
		open_bullet(m, handle)
	}
}

// drop_fix asks to drop the bullet named handle.
drop_fix :: proc(gtx: ^ui.Ctx, m: ^Model, handle: string, place := "", key: u64 = 0) {
	busy := waiting_on(m, .Drop_Bullet, handle)
	if fix_button(gtx, "Drop", "Take it out of the vault. It is kept in AI/DROPPED.md, so it is not lost.", .Danger, .Trash, loading = busy, key = key) && !busy {
		m.fix.dropping = true
		choose(&m.fix.handle, handle)
		choose(&m.fix.place, place)
	}
}

// fix_confirm asks before a fix drops a bullet.
fix_confirm :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.fix.dropping {
		return
	}
	handle := chosen(&m.fix.handle)
	if primer.confirmation_dialog(gtx, &m.fix.dropping, fmt.tprintf("Drop %s?", handle), "It leaves the vault and no find returns it again. It is kept in AI/DROPPED.md, so it is not lost.", confirm_content = "Drop", confirm_type = .Danger) == .Confirm {
		send(gtx, m, .Drop_Bullet, {handle}, chosen(&m.fix.place))
	}
}

// open_bullet shows the bullet named handle in Bullets, to read or edit.
open_bullet :: proc(m: ^Model, handle: string) {
	go(m, .Bullets)
	choose(&m.bullet, handle)
	m.editor.drafting = false
}

// duplicate_copies is every bullet named handle, whatever its case, each
// with what tells it apart and the fixes for it: another handle, or out;
// and a proposal waiting with it, which the bullet list does not hold.
duplicate_copies :: proc(gtx: ^ui.Ctx, m: ^Model, handle: string) {
	s := &m.scheme
	res, st := ui.need(gtx, shapes.Bullets{}, shapes.Bullets_Result)
	ui.column(gtx, gap = 8, align = .Fill, key = 0xd0)
	primer.text(gtx, "The bullets that share it", .Small, .Medium, color = s[.Fg_Color_Muted])
	if !ready(st) {
		loading(gtx, 2)
		return
	}
	n := 0
	for b in res.bullets {
		if !strings.equal_fold(b.handle, handle) {
			continue
		}
		n += 1
		at := place(b)
		card := boxed(gtx, 12, key = u64(n))
		defer ui.close(&card)
		ui.column(gtx, gap = 8, align = .Fill)
		primer.text(gtx, fmt.tprintf("%s · %s", at, b.date), .Small, color = s[.Fg_Color_Muted])
		primer.text(gtx, b.fact)
		if chosen(&m.fix.renaming) == at {
			rename_copy(gtx, m, b)
			continue
		}
		ui.row(gtx, gap = 8, align = .Center)
		busy := waiting_on(m, .Replace_Bullet, b.handle)
		if fix_button(gtx, "Rename", "Give this one a handle of its own, so a find can tell the two apart.", .Default, .Pencil, loading = busy, key = 1) && !busy {
			choose(&m.fix.renaming, at)
			ui.text_set(&m.rename, b.handle)
		}
		ui.fill_space(gtx)
		drop_fix(gtx, m, b.handle, at, key = 2)
	}
	n += inbox_copy(gtx, m, handle)
	if n == 0 {
		primer.text(gtx, "Not in the bullet list; it may have been fixed since the report.", .Small, color = s[.Fg_Color_Muted])
	}
}

// inbox_copy is the proposal in the inbox named handle, which repeats a
// bullet already in the vault, with what settles it there; it is how many
// it showed, 0 or 1.
inbox_copy :: proc(gtx: ^ui.Ctx, m: ^Model, handle: string) -> int {
	s := &m.scheme
	in_, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result)
	if !ready(st) {
		return 0
	}
	for p in in_.proposals {
		if !strings.equal_fold(p.handle, handle) {
			continue
		}
		card := boxed(gtx, 12, key = 0x1b0)
		defer ui.close(&card)
		ui.column(gtx, gap = 8, align = .Fill)
		primer.text(gtx, fmt.tprintf("the inbox · a proposal, not yet reviewed · %s", p.date), .Small, color = s[.Fg_Color_Muted])
		primer.text(gtx, p.fact)
		ui.row(gtx, gap = 8, align = .Center)
		if fix_button(gtx, "Review", "Review it beside the other proposals: approve it to another file, or edit it first.", .Default, .Inbox, key = 1) {
			go(m, .Inbox)
			choose(&m.proposal, p.handle)
		}
		ui.fill_space(gtx)
		busy := waiting_on(m, .Drop, p.handle)
		if fix_button(gtx, "Drop", "The vault has this handle already: drop the proposal. It is kept in AI/DROPPED.md and not proposed again.", .Danger, .Trash, loading = busy, key = 2) && !busy {
			send(gtx, m, .Drop, {p.handle})
		}
		return 1
	}
	return 0
}

// rename_copy is a field for a duplicate's new handle, and its save.
rename_copy :: proc(gtx: ^ui.Ctx, m: ^Model, b: shapes.Bullet) {
	ui.row(gtx, gap = 8, align = .Center)
	name := strings.trim_space(ui.text_string(&m.rename))
	ok := name != "" && !strings.equal_fold(name, b.handle) && alias_ok(name)
	e: primer.Field_Edit
	{
		w := max(gtx.constraints.max.x - 170, 120)
		ui.sized(gtx, {min = {w, 0}, max = {w, ui.INF}})
		e = primer.text_input(gtx, &m.rename, placeholder = "A handle of its own", size = .Small, name = "New handle")
	}
	save := primer.button(gtx, "Save", .Primary, .Small, inactive = !ok)
	if (save || e.submitted) && ok {
		send(gtx, m, .Replace_Bullet, {b.handle, name}, bullet_line(b, name), place(b))
		m.fix.renaming.len = 0
	}
	if primer.button(gtx, "Cancel", .Default, .Small) {
		m.fix.renaming.len = 0
	}
}

// bullet_line is b as it is written, under handle.
bullet_line :: proc(b: shapes.Bullet, handle: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "- **%s**", handle)
	if b.aliases != "" {
		fmt.sbprintf(&sb, " (aliases: %s)", b.aliases)
	}
	fmt.sbprintf(&sb, " — %s", b.fact)
	if b.source != "" {
		fmt.sbprintf(&sb, " — %s", b.source)
	}
	fmt.sbprintf(&sb, " — %s", b.date)
	return strings.to_string(sb)
}
