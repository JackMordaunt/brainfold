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
		edit_fix(gtx, m, h, tr(m, .Fix_Correct), .Primary)
		ui.fill_space(gtx)
		drop_fix(gtx, m, h)
	case .Stale:
		h := d.stale[i].handle
		busy := waiting_on(m, .Touch_Bullet, h)
		if fix_button(gtx, tr(m, .Confirm), tr(m, .Confirm_Tip), .Primary, .Check, loading = busy) && !busy {
			send(gtx, m, .Touch_Bullet, {h})
		}
		edit_fix(gtx, m, h, tr(m, .Fix_Rewrite))
		ui.fill_space(gtx)
		drop_fix(gtx, m, h)
	case .Dead_Links:
		x := d.dead_links[i]
		busy := waiting_on(m, .Unlink, x.target)
		if fix_button(gtx, tr(m, .Unlink), tf(m, .Unlink_Tip, x.target, x.file), .Primary, .Unlink, loading = busy) && !busy {
			send(gtx, m, .Unlink, {x.target}, x.file, fmt.tprint(x.line))
		}
		if fix_button(gtx, tr(m, .Write), tr(m, .Write_Link_Tip), .Default, .Plus) {
			// The link resolves to a bullet whose handle is its target with
			// spaces for dashes, as doctor matches them.
			named, _ := strings.replace_all(x.target, "-", " ", context.temp_allocator)
			draft(m, named, x.target)
		}
	case .Oversized:
		edit_fix(gtx, m, d.oversized[i].handle, tr(m, .Fix_Split), .Primary)
	case .Orphans:
		file := d.orphan_artifacts[i].file
		if fix_button(gtx, tr(m, .Write), tr(m, .Write_Orphan_Tip), .Primary, .Plus) {
			draft(m, source = file)
		}
	case .Promote:
		edit_fix(gtx, m, d.promote[i].handle, tr(m, .Fix_Promote), .Primary)
	case .Never_Returned:
		h := d.never_returned[i].handle
		edit_fix(gtx, m, h, tr(m, .Fix_Alias))
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
	if fix_button(gtx, tr(m, .Edit), tip, variant, .Pencil) {
		open_bullet(m, handle)
	}
}

// drop_fix asks to drop the bullet named handle.
drop_fix :: proc(gtx: ^ui.Ctx, m: ^Model, handle: string, place := "", key: u64 = 0) {
	busy := waiting_on(m, .Drop_Bullet, handle)
	if fix_button(gtx, tr(m, .Drop), tr(m, .Drop_Tip), .Danger, .Trash, loading = busy, key = key) && !busy {
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
	if primer.confirmation_dialog(gtx, &m.fix.dropping, tf(m, .Drop_Bullet_Ask, handle), tr(m, .Drop_Bullet_Body), confirm_content = tr(m, .Drop), confirm_type = .Danger) == .Confirm {
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
	primer.text(gtx, tr(m, .Share_Bullets), .Small, .Medium, color = s[.Fg_Color_Muted])
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
		primer.text(gtx, tf(m, .Join_Dot, at, b.date), .Small, color = s[.Fg_Color_Muted])
		primer.text(gtx, b.fact)
		if chosen(&m.fix.renaming) == at {
			rename_copy(gtx, m, b)
			continue
		}
		ui.row(gtx, gap = 8, align = .Center)
		busy := waiting_on(m, .Replace_Bullet, b.handle)
		if fix_button(gtx, tr(m, .Rename), tr(m, .Rename_Tip), .Default, .Pencil, loading = busy, key = 1) && !busy {
			choose(&m.fix.renaming, at)
			ui.text_set(&m.rename, b.handle)
		}
		ui.fill_space(gtx)
		drop_fix(gtx, m, b.handle, at, key = 2)
	}
	n += inbox_copy(gtx, m, handle)
	if n == 0 {
		primer.text(gtx, tr(m, .Not_In_List), .Small, color = s[.Fg_Color_Muted])
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
		primer.text(gtx, tf(m, .Inbox_Proposal, p.date), .Small, color = s[.Fg_Color_Muted])
		primer.text(gtx, p.fact)
		ui.row(gtx, gap = 8, align = .Center)
		if fix_button(gtx, tr(m, .Review), tr(m, .Review_Tip), .Default, .Inbox, key = 1) {
			go(m, .Inbox)
			choose(&m.proposal, p.handle)
		}
		ui.fill_space(gtx)
		busy := waiting_on(m, .Drop, p.handle)
		if fix_button(gtx, tr(m, .Drop), tr(m, .Drop_Proposal_Tip), .Danger, .Trash, loading = busy, key = 2) && !busy {
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
		e = primer.text_input(gtx, &m.rename, placeholder = tr(m, .Rename_Ph), size = .Small, name = tr(m, .New_Handle))
	}
	save := primer.button(gtx, tr(m, .Save), .Primary, .Small, inactive = !ok)
	if (save || e.submitted) && ok {
		send(gtx, m, .Replace_Bullet, {b.handle, name}, bullet_line(b, name), place(b))
		m.fix.renaming.len = 0
	}
	if primer.button(gtx, tr(m, .Cancel), .Default, .Small) {
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
