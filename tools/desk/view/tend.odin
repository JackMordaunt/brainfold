package desk_view

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../shapes"

// --- Inbox ---------------------------------------------------------------------

MAX_PILL :: 40 // the longest source shown as a pill

// proposals_bar is the bulk controls, at the head of the proposals:
// tick or untick every one, and approve or drop the ticked, each after a
// confirmation. It lets go of ticks for proposals that have left the
// inbox.
proposals_bar :: proc(gtx: ^ui.Ctx, m: ^Model) {
	inbox, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result)
	if !ready(st) || inbox.error != "" {
		return
	}
	ps := inbox.proposals
	for i := len(m.selected) - 1; i >= 0; i -= 1 {
		if !has_handle(ps, m.selected[i]) {
			delete(m.selected[i], m.allocator)
			ordered_remove(&m.selected, i)
		}
	}
	n := len(m.selected)
	ui.row(gtx, gap = 8, align = .Center)
	all := n == len(ps) && n > 0
	if primer.checkbox(gtx, &all, "Select all", indeterminate = n > 0 && n < len(ps), state = len(ps) == 0 ? .Disabled : .Live) {
		for p in ps {
			select(m, p.handle, all)
		}
	}
	ui.fill_space(gtx)
	none := n == 0
	// In a narrow pane the buttons keep their icons and counts and give up
	// their words; their names still say what they do.
	words := gtx.constraints.max.x >= 330
	if primer.button(gtx, words ? "Approve" : "", .Primary, .Small, leading = .Check, count = none ? "" : fmt.tprint(n), inactive = none, name = "Approve selected") && !none {
		m.confirm, m.bulk = true, .Approve
	}
	if primer.button(gtx, words ? "Drop" : "", .Danger, .Small, leading = .X, count = none ? "" : fmt.tprint(n), inactive = none, name = "Drop selected") && !none {
		m.confirm, m.bulk = true, .Drop
	}
}

// page_inbox is the proposals, each with a tick for the bulk controls,
// and the one chosen in full, to approve or drop.
page_inbox :: proc(gtx: ^ui.Ctx, m: ^Model) {
	inbox, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result)
	// Drawn last, over the panes.
	defer bulk_confirm(gtx, m)
	arrange(gtx, m)
	w := split_list(gtx, m)
	if !ready(st) {
		pane(gtx, m, .Proposals, w[0], "Proposals")
		loading(gtx, 4)
		return
	}
	ps := inbox.proposals
	current := chosen(&m.proposal)
	idx := -1
	for p, i in ps {
		if p.handle == current {
			idx = i
		}
	}
	if idx < 0 && len(ps) > 0 {
		idx = 0
		choose(&m.proposal, ps[0].handle)
	}
	list: {
		pane(gtx, m, .Proposals, w[0], "Proposals", len(ps), bar = len(ps) > 0 ? proposals_bar : nil)
		if failed(gtx, inbox.error) {
			return
		}
		if len(ps) == 0 {
			empty(gtx, "Nothing waiting", "When an agent proposes a fact, it waits here for you.", .Inbox)
		}
		ui.inset(gtx, {8, 8, 8, 8})
		ui.column(gtx, gap = 2, align = .Fill)
		for p, i in ps {
			ui.scope(gtx, p.handle)
			busy := waiting_on(m, .Approve, p.handle) || waiting_on(m, .Drop, p.handle)
			ui.row(gtx, gap = 8, align = .Center)
			ticked := is_selected(m, p.handle)
			{
				ui.inset(gtx, {8, 0, 0, 0})
				if primer.checkbox(gtx, &ticked, state = busy ? .Disabled : .Live, key = 5) {
					select(m, p.handle, ticked)
				}
			}
			bw := w[0].x - 16 - 8 - 8 - CHECKBOX
			ui.sized(gtx, {min = {bw, 0}, max = {bw, ui.INF}})
			if row_button(gtx, p.handle, i == idx, key = 6) {
				choose(&m.proposal, p.handle)
				m.panes[.Proposal] = {}
			}
		}
	}
	{
		pane(gtx, m, .Proposal, w[1], footer = idx >= 0 ? proposal_actions : nil)
		if idx < 0 {
			empty(gtx, "Nothing to review", "Choose a proposal to read it in full.", .Inbox)
			return
		}
		proposal(gtx, m, ps[idx])
	}
}

CHECKBOX :: 16 // Primer's checkbox, square

// proposal_actions is the proposal's footer: approve it or drop it.
proposal_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	handle := chosen(&m.proposal)
	if handle == "" {
		return
	}
	approving := waiting_on(m, .Approve, handle)
	dropping := waiting_on(m, .Drop, handle)
	busy := approving || dropping
	ui.row(gtx, gap = 8, align = .Center)
	if primer.button(gtx, "Approve", .Primary, leading = .Check, loading = approving, inactive = dropping, name = fmt.tprintf("Approve %s", handle)) && !busy {
		send(gtx, m, .Approve, {handle})
	}
	if primer.button(gtx, "Drop", .Danger, leading = .X, loading = dropping, inactive = approving, name = fmt.tprintf("Drop %s", handle)) && !busy {
		send(gtx, m, .Drop, {handle})
	}
}

// proposal is one proposal in full.
proposal :: proc(gtx: ^ui.Ctx, m: ^Model, p: shapes.Proposal) {
	s := &m.scheme
	ui.inset(gtx, ui.pad_all(16))
	ui.column(gtx, gap = 12, align = .Fill)
	primer.heading(gtx, p.handle, 2, .Medium)
	pill := p.source != "" && strings.rune_count(p.source) <= MAX_PILL
	{
		ui.wrap(gtx, gap = 8, line_gap = 4, align = .Center)
		if pill {
			primer.label(gtx, p.source, .Secondary)
		}
		primer.text(gtx, fmt.tprintf("proposed %s", p.date), .Small, color = s[.Fg_Color_Muted], key = 1)
	}
	if p.source != "" && !pill {
		primer.text(gtx, fmt.tprintf("source: %s", p.source), .Small, color = s[.Fg_Color_Muted], key = 4)
	}
	primer.text(gtx, p.fact, .Large, key = 2)
	if p.aliases != "" {
		primer.text(gtx, fmt.tprintf("also found as: %s", p.aliases), .Small, color = s[.Fg_Color_Muted], key = 3)
	}
	if p.line != "" {
		primer.text(gtx, "As it will be written", .Small, .Medium, color = s[.Fg_Color_Muted], key = 5)
		b := boxed(gtx, 12, key = 6)
		defer ui.close(&b)
		primer.text(gtx, p.line, .Small, key = 7)
	}
}

has_handle :: proc(ps: []shapes.Proposal, handle: string) -> bool {
	for p in ps {
		if p.handle == handle {
			return true
		}
	}
	return false
}

// is_selected, select keep the inbox's ticks, by handle.
is_selected :: proc(m: ^Model, handle: string) -> bool {
	for h in m.selected {
		if h == handle {
			return true
		}
	}
	return false
}

select :: proc(m: ^Model, handle: string, on: bool) {
	for h, i in m.selected {
		if h == handle {
			if !on {
				delete(h, m.allocator)
				ordered_remove(&m.selected, i)
			}
			return
		}
	}
	if on {
		append(&m.selected, strings.clone(handle, m.allocator))
	}
}

// bulk_confirm asks before a bulk approve or drop, naming what it will
// touch; confirmed, it sends one command for all of them and clears the
// ticks.
bulk_confirm :: proc(gtx: ^ui.Ctx, m: ^Model) {
	if !m.confirm {
		return
	}
	n := len(m.selected)
	if n == 0 {
		m.confirm = false
		return
	}
	names := strings.join(m.selected[:min(n, 5)], ", ", context.temp_allocator)
	if n > 5 {
		names = fmt.tprintf("%s and %d more", names, n - 5)
	}
	what := n == 1 ? "1 proposal" : fmt.tprintf("%d proposals", n)
	title, body, verb: string
	variant: primer.Button_Variant
	if m.bulk == .Approve {
		title = fmt.tprintf("Approve %s?", what)
		body = fmt.tprintf("They join the vault and answer every agent's finds: %s.", names)
		verb, variant = "Approve", .Primary
	} else {
		title = fmt.tprintf("Drop %s?", what)
		body = fmt.tprintf("They leave the inbox and are not proposed again: %s.", names)
		verb, variant = "Drop", .Danger
	}
	if primer.confirmation_dialog(gtx, &m.confirm, title, body, confirm_content = verb, confirm_type = variant) == .Confirm {
		send(gtx, m, m.bulk, m.selected[:])
		for h in m.selected {
			delete(h, m.allocator)
		}
		clear(&m.selected)
	}
}

// --- Doctor --------------------------------------------------------------------

// Finding_List is one of doctor's lists, as the Doctor page offers them,
// most urgent first.
Finding_List :: enum u8 {
	Failed_Claims,
	Stale,
	Dead_Links,
	Duplicates,
	Thin_Aliases,
	Oversized,
	Orphans,
	Promote,
	Never_Returned,
}

FINDING_TITLES := [Finding_List]string {
	.Failed_Claims  = "Failed claims",
	.Stale          = "Stale",
	.Dead_Links     = "Dead links",
	.Duplicates     = "Duplicate handles",
	.Thin_Aliases   = "Thin aliases",
	.Oversized      = "Oversized",
	.Orphans        = "Orphaned notes",
	.Promote        = "Worth promoting",
	.Never_Returned = "Never returned",
}

FINDING_NOTES := [Finding_List]string {
	.Failed_Claims  = "A bullet says something this machine can no longer confirm.",
	.Stale          = "Not verified in a long while.",
	.Dead_Links     = "A wikilink that names nothing.",
	.Duplicates     = "One handle on two bullets.",
	.Thin_Aliases   = "Fewer than two other names; a searcher's words may miss it.",
	.Oversized      = "A bullet that says more than one fact.",
	.Orphans        = "A note no bullet points at.",
	.Promote        = "Asked for so often a project file could carry it.",
	.Never_Returned = "No query has found it yet.",
}

// FINDING_HELP is what each list means, why it matters and what settles
// it, for the tooltip on its row.
FINDING_HELP := [Finding_List]string {
	.Failed_Claims  = "brain verify checks what bullets name: paths, vault files, subcommands, commits. These name something this machine does not have. Fix the bullet, or drop it if it is no longer true.",
	.Stale          = "Not dated in 90 days. A bullet's date says when it was last known true; re-date what still holds, rewrite what does not.",
	.Dead_Links     = "A [[wikilink]] in a note that names no note or bullet. Point it at the right handle, or take it out.",
	.Duplicates     = "Two bullets carry the same handle, so a find cannot tell them apart. Merge them, or give one a handle of its own.",
	.Thin_Aliases   = "Fewer than two other names. An agent that asks in different words may miss the bullet; add the names a searcher would use.",
	.Oversized      = "A bullet long enough to hold more than one fact. Split it, so each fact is found and dated on its own.",
	.Orphans        = "A note under AI/artifacts that no bullet links to, so nothing leads an agent to it. Link it from a bullet, or move it out.",
	.Promote        = "Returned by many queries across many sessions. A fact asked for that often belongs in the project's own files, where an agent reads it without a lookup.",
	.Never_Returned = "No query has returned this bullet yet. It may be named in words nobody uses: check its handle and aliases.",
}

FINDING_ICONS := [Finding_List]primer.Icon {
	.Failed_Claims  = .Alert,
	.Stale          = .Clock,
	.Dead_Links     = .Link,
	.Duplicates     = .Duplicate,
	.Thin_Aliases   = .Tag,
	.Oversized      = .Fold,
	.Orphans        = .File,
	.Promote        = .Arrow_Up,
	.Never_Returned = .Eye_Closed,
}

finding_count :: proc(d: ^shapes.Doctor_Result, l: Finding_List) -> int {
	switch l {
	case .Failed_Claims:
		return len(d.failed_claims)
	case .Stale:
		return len(d.stale)
	case .Dead_Links:
		return len(d.dead_links)
	case .Duplicates:
		return len(d.duplicate_handles)
	case .Thin_Aliases:
		return len(d.thin_aliases)
	case .Oversized:
		return len(d.oversized)
	case .Orphans:
		return len(d.orphan_artifacts)
	case .Promote:
		return len(d.promote)
	case .Never_Returned:
		return len(d.never_returned)
	}
	return 0
}

// finding_key is what names item i of list l across reports.
finding_key :: proc(d: ^shapes.Doctor_Result, l: Finding_List, i: int) -> string {
	title, note := finding_row(d, l, i)
	return fmt.tprintf("%s\x1f%s", title, note)
}

// finding_row is item i of list l as a list row: its name and a line.
finding_row :: proc(d: ^shapes.Doctor_Result, l: Finding_List, i: int) -> (title, note: string) {
	switch l {
	case .Failed_Claims:
		c := d.failed_claims[i]
		return c.handle, fmt.tprintf("%s %s: %s", c.kind, c.text, c.why)
	case .Stale:
		f := d.stale[i]
		return f.handle, fmt.tprintf("last dated %s", f.date)
	case .Dead_Links:
		x := d.dead_links[i]
		return x.target, fmt.tprintf("%s:%d", x.file, x.line)
	case .Duplicates:
		f := d.duplicate_handles[i]
		return f.handle, f.file
	case .Thin_Aliases:
		f := d.thin_aliases[i]
		return f.handle, f.aliases == "" ? "no aliases" : fmt.tprintf("only: %s", f.aliases)
	case .Oversized:
		f := d.oversized[i]
		return f.handle, fmt.tprintf("%d characters", f.len)
	case .Orphans:
		return d.orphan_artifacts[i].file, "nothing links to it"
	case .Promote:
		f := d.promote[i]
		return f.handle, fmt.tprintf("%d queries in %d sessions", f.queries, f.sessions)
	case .Never_Returned:
		f := d.never_returned[i]
		return f.handle, fmt.tprintf("since %s", f.date)
	}
	return "", ""
}

// doctor_control runs doctor again on request, beside the page's other
// controls, and says when the report on screen was made and how long it
// took. What a run changed comes back as its toast.
doctor_control :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := &m.scheme
	d, st := ui.need(gtx, shapes.Doctor{}, shapes.Doctor_Result)
	running := waiting_on(m, .Doctor)
	said := ""
	switch {
	case running:
		said = "Checking the vault…"
	case ready(st) && d.ran_at != "":
		said = fmt.tprintf("Report from %s · took %.1f s", d.ran_at, f64(d.took_ms) / 1000)
	}
	if body_width(m) >= NARROW {
		primer.text(gtx, said, .Small, color = s[.Fg_Color_Muted])
	}
	button := ui.stack_open(gtx)
	defer ui.close(&button)
	if primer.button(gtx, "Run doctor", .Primary, .Medium, leading = .Sync, loading = running) && !running {
		send(gtx, m, .Doctor)
	}
	primer.tooltip(gtx, "Check the vault again: what is stale, thin, oversized, orphaned or no longer verifies. It takes a second or two; the toast says what changed since the last check.", ui.last_widget(gtx), delay = TOOLTIP_DELAY)
}

// page_doctor is doctor's lists, the items of the one chosen, and the
// item chosen in full.
page_doctor :: proc(gtx: ^ui.Ctx, m: ^Model) {
	d, st := ui.need(gtx, shapes.Doctor{}, shapes.Doctor_Result)
	arrange(gtx, m)
	KINDS :: PANE_MIN.x
	// Too narrow for three panes, the lists fold into a menu over the
	// items; narrower still, the two panes stack.
	narrow := body_width(m) < NARROW
	kinds_size := ops.Size{KINDS, 0}
	items_size, detail_size: ops.Size
	if narrow {
		w := split_list(gtx, m)
		items_size, detail_size = w[0], w[1]
	} else {
		room := body_width(m) - KINDS - 2 * GAP
		items_size, detail_size = {math.floor(room * 0.4), 0}, {math.floor(room * 0.6), 0}
	}
	if !ready(st) {
		pane(gtx, m, .Findings_Kinds, narrow ? items_size : kinds_size, "Findings")
		loading(gtx, 6)
		return
	}
	if d.error != "" {
		pane(gtx, m, .Findings_Kinds, {body_width(m), 0})
		failed(gtx, d.error)
		return
	}
	kinds: if !narrow {
		pane(gtx, m, .Findings_Kinds, kinds_size, "Findings", scroll = false)
		ui.inset(gtx, ui.pad_all(8))
		ui.column(gtx, gap = 2, align = .Fill)
		for l in Finding_List {
			n := finding_count(d, l)
			// The row and its tooltip share a stack, so the tooltip watches
			// the row's own box.
			st := ui.stack_open(gtx, key = u64(l) + 100)
			if row_button(gtx, FINDING_TITLES[l], l == m.findings, FINDING_ICONS[l], n > 0 ? fmt.tprint(n) : "", key = u64(l) + 1) {
				m.findings, m.findings_chosen = l, true
				m.finding.len = 0
				m.panes[.Findings], m.panes[.Finding] = {}, {}
			}
			primer.tooltip(gtx, FINDING_HELP[l], ui.last_widget(gtx), direction = .E, delay = TOOLTIP_DELAY)
			ui.close(&st)
		}
	}
	// Until a list is chosen, the first with something in it.
	if !m.findings_chosen && finding_count(d, m.findings) == 0 {
		for l in Finding_List {
			if finding_count(d, l) > 0 {
				m.findings = l
				break
			}
		}
	}
	n := finding_count(d, m.findings)
	// The item chosen is found by what it says; a fresh report may order
	// the list differently, or no longer hold it, when the first is shown.
	current := 0
	for i in 0 ..< n {
		if finding_key(d, m.findings, i) == chosen(&m.finding) {
			current = i
		}
	}
	{
		pane(gtx, m, .Findings, items_size, narrow ? "" : FINDING_TITLES[m.findings], n, bar = narrow ? findings_menu : nil)
		if n == 0 {
			empty(gtx, fmt.tprintf("No %s", strings.to_lower(FINDING_TITLES[m.findings], context.temp_allocator)), FINDING_NOTES[m.findings], .Check_Circle)
		} else {
			l := primer.action_list_open(gtx, .Full, dividers = true, name = FINDING_TITLES[m.findings])
			for i in 0 ..< n {
				title, note := finding_row(d, m.findings, i)
				if primer.action_list_item(&l, title, description = note, description_variant = .Block, truncate = true, leading = FINDING_ICONS[m.findings], active = i == current) {
					choose(&m.finding, finding_key(d, m.findings, i))
					m.panes[.Finding] = {}
				}
			}
			primer.action_list_close(&l)
		}
	}
	{
		pane(gtx, m, .Finding, detail_size)
		if n == 0 {
			empty(gtx, "Nothing to look at", FINDING_NOTES[m.findings], .Shield_Check)
			return
		}
		finding_detail(gtx, m, d, m.findings, current)
	}
}

// findings_menu is Doctor's lists as a menu, for a body too narrow for
// a pane of them.
findings_menu :: proc(gtx: ^ui.Ctx, m: ^Model) {
	d, st := ui.need(gtx, shapes.Doctor{}, shapes.Doctor_Result)
	if !ready(st) {
		return
	}
	options := make([]primer.Select_Option, len(Finding_List), context.temp_allocator)
	for l in Finding_List {
		n := finding_count(d, l)
		options[int(l)] = {label = n > 0 ? fmt.tprintf("%s (%d)", FINDING_TITLES[l], n) : FINDING_TITLES[l]}
	}
	list := int(m.findings)
	if primer.select(gtx, options, &list, size = .Small, block = true, name = "Findings") {
		m.findings, m.findings_chosen = Finding_List(list), true
		m.finding.len = 0
		m.panes[.Findings], m.panes[.Finding] = {}, {}
	}
}

// finding_detail is one finding in full: what is wrong, where, and what
// would set it right.
finding_detail :: proc(gtx: ^ui.Ctx, m: ^Model, d: ^shapes.Doctor_Result, l: Finding_List, i: int) {
	s := &m.scheme
	ui.inset(gtx, ui.pad_all(16))
	ui.column(gtx, gap = 12, align = .Fill)
	title, note := finding_row(d, l, i)
	primer.label(gtx, FINDING_TITLES[l], l == .Failed_Claims ? .Danger : .Secondary)
	primer.heading(gtx, title, 2, .Medium)
	primer.text(gtx, FINDING_NOTES[l], color = s[.Fg_Color_Muted])
	#partial switch l {
	case .Failed_Claims:
		c := d.failed_claims[i]
		fields(gtx, {{"file", c.file}, {"claim", fmt.tprintf("%s %s", c.kind, c.text)}, {"why it failed", c.why}, {"checked", c.checked}})
	case .Dead_Links:
		x := d.dead_links[i]
		fields(gtx, {{"in", fmt.tprintf("%s, line %d", x.file, x.line)}, {"links to", x.target}})
	case:
		_ = note
		f: shapes.Finding
		#partial switch l {
		case .Stale:
			f = d.stale[i]
		case .Duplicates:
			f = d.duplicate_handles[i]
		case .Thin_Aliases:
			f = d.thin_aliases[i]
		case .Oversized:
			f = d.oversized[i]
		case .Orphans:
			f = d.orphan_artifacts[i]
		case .Promote:
			f = d.promote[i]
		case .Never_Returned:
			f = d.never_returned[i]
		}
		if l == .Thin_Aliases {
			alias_editor(gtx, m, f.handle, f.aliases)
		}
		rows := make([dynamic][2]string, context.temp_allocator)
		append(&rows, [2]string{"file", f.file})
		if f.aliases != "" && l != .Thin_Aliases {
			append(&rows, [2]string{"aliases", f.aliases})
		}
		if f.date != "" {
			append(&rows, [2]string{"dated", f.date})
		}
		if f.len > 0 {
			append(&rows, [2]string{"length", fmt.tprintf("%d characters", f.len)})
		}
		if f.queries > 0 {
			append(&rows, [2]string{"asked for", fmt.tprintf("%d queries in %d sessions", f.queries, f.sessions)})
		}
		fields(gtx, rows[:])
	}
}

// days_since is the days from date, YYYY-MM-DD, to today, or -1 for no date.
days_since :: proc(date: string) -> int {
	if len(date) < 10 {
		return -1
	}
	y, yok := strconv.parse_int(date[0:4])
	mo, mok := strconv.parse_int(date[5:7])
	d, dok := strconv.parse_int(date[8:10])
	if !yok || !mok || !dok {
		return -1
	}
	t, ok := time.components_to_time(y, mo, d, 0, 0, 0)
	if !ok {
		return -1
	}
	return max(int(time.duration_hours(time.diff(t, time.now())) / 24), 0)
}

// age is days as a person says it.
age :: proc(days: int) -> string {
	switch {
	case days == 0:
		return "today"
	case days == 1:
		return "1 day old"
	case days < 60:
		return fmt.tprintf("%d days old", days)
	case days < 730:
		return fmt.tprintf("%d months old", days / 30)
	}
	return fmt.tprintf("%d years old", days / 365)
}

// alias_editor is a bullet's other names, each removable, and a field
// for another: a thin bullet is one with fewer than two, which an agent
// asking in other words may miss. Each edit is a command; doctor is run
// again after it, so the list shows what is still thin.
alias_editor :: proc(gtx: ^ui.Ctx, m: ^Model, handle, aliases: string) {
	s := &m.scheme
	busy := waiting_on(m, .Add_Alias, handle) || waiting_on(m, .Remove_Alias, handle)
	ui.column(gtx, gap = 8, align = .Fill)
	primer.text(gtx, "Other names", .Small, .Medium, color = s[.Fg_Color_Muted])
	names := make([dynamic]string, context.temp_allocator)
	for raw in strings.split(aliases, ",", context.temp_allocator) {
		if a := strings.trim_space(raw); a != "" {
			append(&names, a)
		}
	}
	{
		ui.wrap(gtx, gap = 6, line_gap = 6, align = .Center)
		if len(names) == 0 {
			primer.text(gtx, "none yet", .Small, color = s[.Fg_Color_Muted])
		}
		for a, i in names {
			r := primer.token(gtx, a, removable = true, state = busy ? .Disabled : .Live, key = u64(i + 1))
			if r.removed && !busy {
				send(gtx, m, .Remove_Alias, {handle}, a)
			}
		}
	}
	{
		ui.row(gtx, gap = 8, align = .Center)
		w := max(gtx.constraints.max.x - 90, 160)
		term := strings.trim_space(ui.text_string(&m.alias))
		ok := term != "" && alias_ok(term)
		e: primer.Field_Edit
		{
			ui.sized(gtx, {min = {w, 0}, max = {w, ui.INF}})
			e = primer.text_input(gtx, &m.alias, placeholder = "Another name a searcher might use", size = .Small, validation = term != "" && !ok ? .Error : .None, name = "New alias")
		}
		add := primer.button(gtx, "Add", .Primary, .Small, leading = .Plus, loading = busy, inactive = !ok)
		if (add || e.submitted) && ok && !busy {
			send(gtx, m, .Add_Alias, {handle}, term)
			ui.text_set(&m.alias, "")
		}
	}
	term := strings.trim_space(ui.text_string(&m.alias))
	if term != "" && !alias_ok(term) {
		primer.inline_message(gtx, "A name cannot hold a comma, parenthesis, asterisk or em dash: they would break the bullet.", .Critical, .Small)
	}
}

// sync_time is the CLI's last sync, "2026-10-08T11:39:06Z sent 1 ...",
// with its time as a person reads it: "2026-10-08 11:39 UTC sent 1 ...".
sync_time :: proc(last: string) -> string {
	if len(last) >= 20 && last[10] == 'T' && last[19] == 'Z' {
		return fmt.tprintf("%s %s UTC%s", last[:10], last[11:16], last[20:] != "" ? fmt.tprintf(" ·%s", last[20:]) : "")
	}
	return last
}

// alias_ok is whether term can be an alias, as brain alias judges it.
alias_ok :: proc(term: string) -> bool {
	return !strings.contains_any(term, ",()\n\r*") && !strings.contains(term, "—")
}

// fields is name and value pairs, one a line.
fields :: proc(gtx: ^ui.Ctx, rows: [][2]string) {
	s := primer.scheme()
	ui.column(gtx, gap = 8, align = .Fill)
	for r, i in rows {
		ui.column(gtx, gap = 2, align = .Fill, key = u64(i + 1))
		primer.text(gtx, r[0], .Small, .Medium, color = s[.Fg_Color_Muted])
		primer.text(gtx, r[1], key = 1)
	}
}

// --- Vault ---------------------------------------------------------------------

// vault_control is what can be done to the vault as a whole, beside the
// page's other controls, each with a tooltip saying what it does.
vault_control :: proc(gtx: ^ui.Ctx, m: ^Model) {
	reindexing := waiting_on(m, .Reindex)
	{
		st := ui.stack_open(gtx)
		defer ui.close(&st)
		if primer.button(gtx, "Rebuild index", .Default, .Medium, leading = .Database, loading = reindexing) && !reindexing {
			send(gtx, m, .Reindex)
		}
		primer.tooltip(gtx, "Read every note again and rebuild what finds search. It happens on its own when a note changes; use it if answers look out of date.", ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	}
}

// where_actions is the Where pane's footer: move this machine to another
// vault.
where_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	v, st := ui.need(gtx, shapes.Vault{}, shapes.Vault_Result)
	moving := waiting_on(m, .Set_Vault)
	ui.row(gtx, gap = 8, align = .Center)
	st2 := ui.stack_open(gtx)
	if primer.button(gtx, "Change vault…", .Default, leading = .File_Directory, loading = moving) && !moving {
		ui.text_set(&m.vault_path, ready(st) ? v.vault : "")
		m.moving, m.focus_path = true, true
	}
	primer.tooltip(gtx, "Use the vault in another folder on this machine: its notes answer every agent from then on.", ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	ui.close(&st2)
}

// move_dialog asks for the folder of another vault, shows what binding
// this machine to it would change, as `brain install --dry-run` says,
// and binds it on confirmation.
move_dialog :: proc(gtx: ^ui.Ctx, m: ^Model, current: string) {
	if !m.moving {
		return
	}
	s := &m.scheme
	path := strings.trim_space(ui.text_string(&m.vault_path))
	asked := path != "" && path != current
	plan: ^shapes.Install_Plan_Result
	ok := false
	if asked {
		r, st := ui.need(gtx, shapes.Install_Plan{path = path}, shapes.Install_Plan_Result)
		if ready(st) {
			plan, ok = r, r.ok
		}
	}
	use, cancel: bool
	footer := []primer.Dialog_Button{{content = "Cancel", clicked = &cancel}, {content = "Use this vault", type = .Primary, disabled = !ok, clicked = &use}}
	dl := primer.dialog_open(gtx, &m.moving, "Change vault", "The folder whose notes answer your agents on this machine.", footer, width = .Large)
	if dl.visible {
		ui.column(gtx, gap = 12, align = .Fill)
		e := primer.text_input(gtx, &m.vault_path, placeholder = "/path/to/vault", leading = .File_Directory, block = true, name = "Vault folder")
		// The field takes the focus once the dialog has placed it.
		if m.focus_path {
			ui.focus_request(gtx, e.id)
			if e.focused {
				m.focus_path = false
			}
		}
		switch {
		case !asked:
			primer.text(gtx, "Type the folder of the vault to use; the current one is filled in.", .Small, color = s[.Fg_Color_Muted])
		case plan == nil:
			primer.text(gtx, "Checking…", .Small, color = s[.Fg_Color_Muted])
		case !plan.ok:
			primer.inline_message(gtx, plan.error, .Critical, .Small)
		case:
			// Its warnings first, where they are seen; then the plan, a
			// line each, as install wrote it.
			lines := strings.split_lines(plan.plan, context.temp_allocator)
			for l, i in lines {
				if strings.contains(l, "warning:") {
					primer.inline_message(gtx, strings.trim_space(strings.trim_prefix(strings.trim_space(l), "warning:")), .Warning, .Small, key = u64(100 + i))
				}
			}
			primer.text(gtx, "Using it changes this:", .Small, .Medium, color = s[.Fg_Color_Muted])
			b := boxed(gtx, 12)
			{
				ui.column(gtx, gap = 2, align = .Fill)
				for l, i in lines {
					if t := strings.trim_space(l); t != "" && !strings.contains(l, "warning:") {
						primer.text(gtx, t, .Small, key = u64(200 + i))
					}
				}
			}
			ui.close(&b)
		}
	}
	primer.dialog_close(&dl)
	if cancel {
		m.moving = false
	}
	if use && ok {
		send(gtx, m, .Set_Vault, nil, path)
		m.moving = false
	}
}

page_vault :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := &m.scheme
	v, st := ui.need(gtx, shapes.Vault{}, shapes.Vault_Result)
	defer move_dialog(gtx, m, ready(st) ? v.vault : "")
	arrange(gtx, m)
	w := split(gtx, m, 0.5, 0.5)
	location: {
		pane(gtx, m, .Vault, w[0], "Where", scroll = false, footer = ready(st) ? where_actions : nil)
		if !ready(st) {
			loading(gtx, 3)
			break location
		}
		failed(gtx, v.error)
		ui.inset(gtx, ui.pad_all(16))
		version := v.version
		if v.commit != "" {
			version = fmt.tprintf("%s · %s", v.version, v.commit)
		}
		fields(gtx, {{"vault", v.vault}, {"brain", version}, {"checkout", v.tool}})
	}
	pane(gtx, m, .Vault_Travel, w[1], "Sync and review", scroll = false)
	if !ready(st) {
		loading(gtx, 3)
		return
	}
	ui.inset(gtx, ui.pad_all(16))
	ui.column(gtx, gap = 16, align = .Fill)
	{
		ui.column(gtx, gap = 8, align = .Fill)
		{
			ui.row(gtx, gap = 8, align = .Center)
			on := v.sync == "on"
			primer.state_label(gtx, on ? "On" : "Off", on ? .Open : .Closed, .Small)
			primer.text(gtx, v.remote != "" ? v.remote : "no remote yet", weight = .Medium)
		}
		waiting := v.changed == 0 ? "nothing waiting to send" : v.changed == 1 ? "1 change waiting to send" : fmt.tprintf("%d changes waiting to send", v.changed)
		primer.text(gtx, fmt.tprintf("Last: %s · %s", v.last != "" ? sync_time(v.last) : "never", waiting), .Small, color = s[.Fg_Color_Muted])
	}
	{
		ui.column(gtx, gap = 8, align = .Fill)
		primer.heading(gtx, "Review", 3, .Small)
		primer.text(gtx, "When may an agent's proposal answer a find: at once, marked unreviewed, or only once you approve it?", .Small, color = s[.Fg_Color_Muted])
		segments := []primer.Segment{{label = "At once"}, {label = "Once approved"}}
		mode := v.review == "before" ? 1 : 0
		if primer.segmented_control(gtx, segments, &mode, "Review") && !waiting_on(m, .Review) {
			send(gtx, m, .Review, nil, mode == 1 ? "before" : "after")
		}
	}
}
