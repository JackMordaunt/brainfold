package desk_view

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../../../msg"
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
	facts := fact_handles(m, ps)
	ui.row(gtx, gap = 8, align = .Center)
	all := n == len(ps) && n > 0
	if primer.checkbox(gtx, &all, tr(m, .Select_All), indeterminate = n > 0 && n < len(ps), state = len(ps) == 0 ? .Disabled : .Live) {
		for p in ps {
			select(m, p.handle, all)
		}
	}
	ui.fill_space(gtx)
	none := len(facts) == 0
	// In a narrow pane the buttons keep their icons and give up their words;
	// their names still say what they do.
	words := gtx.constraints.max.x >= 330
	dating := waiting_on(m, .Date)
	// An icon, so Approve and Drop keep their words in the list's widest pane.
	if icon_action(gtx, .Calendar, tr(m, .Date), .Default, .Small, loading = dating, description = tr(m, .Date_Verified)) && !dating {
		m.confirm, m.bulk = true, .Date
	}
	// No count badge: the list pane is already full once Date sits beside
	// these, and the dialog names how many.
	if primer.button(gtx, words ? tr(m, .Approve) : "", .Primary, .Small, leading = .Check, inactive = none, name = tr(m, .Approve_Selected)) && !none {
		m.confirm, m.bulk = true, .Approve
	}
	drop_none := n == 0
	if primer.button(gtx, words ? tr(m, .Drop) : "", .Danger, .Small, leading = .X, inactive = drop_none, name = tr(m, .Drop_Selected)) && !drop_none {
		m.confirm, m.bulk = true, .Drop
	}
}

// page_inbox is the proposals, each with a tick for the bulk controls,
// and the one chosen in full, to approve or drop.
page_inbox :: proc(gtx: ^ui.Ctx, m: ^Model) {
	inbox, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result)
	// Drawn last, over the panes.
	defer bulk_confirm(gtx, m)
	defer import_dialog(gtx, m)
	defer merge_dialog(gtx, m)
	arrange(gtx, m)
	w := split_list(gtx, m)
	if !ready(st) {
		pane(gtx, m, .Proposals, w[0], tr(m, .Proposals))
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
		pane(gtx, m, .Proposals, w[0], tr(m, .Proposals), len(ps), bar = len(ps) > 0 ? proposals_bar : nil)
		if failed(gtx, m, inbox.error) {
			return
		}
		if len(ps) == 0 {
			empty(gtx, tr(m, .Nothing_Waiting), tr(m, .Nothing_Waiting_Body), .Inbox)
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
			{
				ui.sized(gtx, {min = {FROM_W, 0}, max = {FROM_W, ui.INF}})
				primer.text(gtx, inbox_from(p.source), .Small, color = m.scheme[.Fg_Color_Muted], key = 7)
			}
			bw := w[0].x - 16 - 8 - 8 - CHECKBOX - 8 - FROM_W
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
			empty(gtx, tr(m, .Nothing_To_Review), tr(m, .Nothing_To_Review_Body), .Inbox)
			return
		}
		proposal(gtx, m, ps[idx])
	}
}

CHECKBOX :: 16 // Primer's checkbox, square
FROM_W :: 64 // room for tend, settle, or propose beside the handle

// proposal_actions is the proposal's footer: approve it or drop it. The
// date reminder's action is Date, which dates the verified set at once.
proposal_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	handle := chosen(&m.proposal)
	if handle == "" {
		return
	}
	p, _ := proposal_by(gtx, handle)
	dating := waiting_on(m, .Date)
	approving := waiting_on(m, .Approve, handle)
	dropping := waiting_on(m, .Drop, handle)
	busy := approving || dropping || dating
	ui.row(gtx, gap = 8, align = .Center)
	if is_date_source(p.source) {
		if primer.button(gtx, tr(m, .Date), .Primary, leading = .Calendar, loading = dating, inactive = dropping, name = tr(m, .Date_Verified)) && !busy {
			send(gtx, m, .Date, {handle})
		}
	} else if primer.button(gtx, tr(m, .Approve), .Primary, leading = .Check, loading = approving, inactive = dropping || dating, name = tf(m, .Approve_One, handle)) && !busy {
		send(gtx, m, .Approve, {handle})
	}
	if primer.button(gtx, tr(m, .Drop), .Danger, leading = .X, loading = dropping, inactive = approving || dating, name = tf(m, .Drop_One, handle)) && !busy {
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
		primer.text(gtx, tf(m, .Proposed_When, p.date), .Small, color = s[.Fg_Color_Muted], key = 1)
	}
	if p.source != "" && !pill {
		primer.text(gtx, tf(m, .Source_Line, p.source), .Small, color = s[.Fg_Color_Muted], key = 4)
	}
	primer.text(gtx, p.fact, .Large, key = 2)
	if p.aliases != "" {
		primer.text(gtx, tf(m, .Also_Found, p.aliases), .Small, color = s[.Fg_Color_Muted], key = 3)
	}
	if p.line != "" {
		primer.text(gtx, tr(m, .As_Written), .Small, .Medium, color = s[.Fg_Color_Muted], key = 5)
		b := boxed(gtx, 12, key = 6)
		primer.text(gtx, p.line, .Small, key = 7)
		ui.close(&b)
	}
	proposal_review(gtx, m, p)
}

// inbox_from is where a proposal came from: the first word of its source.
// tend and settle are named; everything else was proposed. "tender" is
// not tend. The word is not translated.
inbox_from :: proc(source: string) -> string {
	s := strings.trim_space(source)
	end := len(s)
	for i in 0 ..< len(s) {
		if s[i] == ' ' || s[i] == ':' {
			end = i
			break
		}
	}
	word := s[:end]
	if strings.equal_fold(word, "tend") {
		return "tend"
	}
	if strings.equal_fold(word, "settle") {
		return "settle"
	}
	return "propose"
}

is_tend_source :: proc(source: string) -> bool {
	return inbox_from(source) == "tend"
}

// is_date_source is the tend reminder that dates the verified set.
is_date_source :: proc(source: string) -> bool {
	s := strings.trim_space(source)
	return s == "tend date" || strings.has_prefix(s, "tend date ")
}

proposal_by :: proc(gtx: ^ui.Ctx, handle: string) -> (p: shapes.Proposal, ok: bool) {
	inbox, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result)
	if !ready(st) {
		return
	}
	for q in inbox.proposals {
		if q.handle == handle {
			return q, true
		}
	}
	return
}

// fact_handles is the ticked proposals approve may take. Hygiene stays
// for its own action. A tick whose row has left is still named, so the
// batch can say it left.
fact_handles :: proc(m: ^Model, ps: []shapes.Proposal) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for h in m.selected {
		src := ""
		for p in ps {
			if p.handle == h {
				src = p.source
				break
			}
		}
		if !is_tend_source(src) {
			append(&out, h)
		}
	}
	return out[:]
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
	inbox, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result)
	ps := ready(st) ? inbox.proposals : nil
	facts := fact_handles(m, ps)
	named := m.bulk == .Approve ? facts : m.selected[:]
	n := len(named)
	if m.bulk != .Date && n == 0 {
		m.confirm = false
		return
	}
	names := strings.join(named[:min(n, 5)], ", ", context.temp_allocator)
	if n > 5 {
		names = tf(m, .And_More, names, n - 5)
	}
	what := tf(m, .Proposal, n)
	title, body, verb: string
	variant: primer.Button_Variant
	#partial switch m.bulk {
	case .Date:
		title = tr(m, .Date_Ask)
		body = tr(m, .Date_Body)
		verb, variant = tr(m, .Date), .Primary
	case .Approve:
		title = tf(m, .Approve_Ask, what)
		body = tf(m, .Approve_Body, names)
		verb, variant = tr(m, .Approve), .Primary
	case .Drop:
		title = tf(m, .Drop_Ask, what)
		body = tf(m, .Drop_Inbox_Body, names)
		verb, variant = tr(m, .Drop), .Danger
	}
	if verb == "" {
		m.confirm = false
		return
	}
	if primer.confirmation_dialog(gtx, &m.confirm, title, body, confirm_content = verb, confirm_type = variant) == .Confirm {
		if m.bulk == .Date {
			send(gtx, m, .Date)
		} else {
			send(gtx, m, m.bulk, named)
			for h in m.selected {
				delete(h, m.allocator)
			}
			clear(&m.selected)
		}
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
	.Orphans        = "A note under AI/artifacts that no bullet links to, so nothing leads an agent to it. Write a bullet whose source is the note, or move it out.",
	.Promote        = "Returned by many queries across many sessions. A fact asked for that often belongs in the project's own files, where an agent reads it without a lookup.",
	.Never_Returned = "No query has returned this bullet yet. It may be named in words nobody uses: check its handle and aliases.",
}

FINDING_MSG := [Finding_List]msg.Msg {
	.Failed_Claims  = .Finding_Failed,
	.Stale          = .Finding_Stale,
	.Dead_Links     = .Finding_Links,
	.Duplicates     = .Finding_Dupes,
	.Thin_Aliases   = .Finding_Thin,
	.Oversized      = .Finding_Over,
	.Orphans        = .Finding_Orphans,
	.Promote        = .Finding_Promote,
	.Never_Returned = .Finding_Never,
}

FINDING_NOTE := [Finding_List]msg.Msg {
	.Failed_Claims  = .Note_Failed,
	.Stale          = .Note_Stale,
	.Dead_Links     = .Note_Links,
	.Duplicates     = .Note_Dupes,
	.Thin_Aliases   = .Note_Thin,
	.Oversized      = .Note_Over,
	.Orphans        = .Note_Orphans,
	.Promote        = .Note_Promote,
	.Never_Returned = .Note_Never,
}

FINDING_TIP := [Finding_List]msg.Msg {
	.Failed_Claims  = .Help_Failed,
	.Stale          = .Help_Stale,
	.Dead_Links     = .Help_Links,
	.Duplicates     = .Help_Dupes,
	.Thin_Aliases   = .Help_Thin,
	.Oversized      = .Help_Over,
	.Orphans        = .Help_Orphans,
	.Promote        = .Help_Promote,
	.Never_Returned = .Help_Never,
}

FINDING_NONE := [Finding_List]msg.Msg {
	.Failed_Claims  = .No_Failed,
	.Stale          = .No_Stale,
	.Dead_Links     = .No_Links,
	.Duplicates     = .No_Dupes,
	.Thin_Aliases   = .No_Thin,
	.Oversized      = .No_Over,
	.Orphans        = .No_Orphans,
	.Promote        = .No_Promote,
	.Never_Returned = .No_Never,
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
finding_key :: proc(m: ^Model, d: ^shapes.Doctor_Result, l: Finding_List, i: int) -> string {
	title, note := finding_row(m, d, l, i)
	return fmt.tprintf("%s\x1f%s", title, note)
}

// finding_row is item i of list l as a list row: its name and a line.
// A file and a line stay text, so a locale's digits do not rewrite them.
finding_row :: proc(m: ^Model, d: ^shapes.Doctor_Result, l: Finding_List, i: int) -> (title, note: string) {
	switch l {
	case .Failed_Claims:
		c := d.failed_claims[i]
		return c.handle, fmt.tprintf("%s %s: %s", c.kind, c.text, c.why)
	case .Stale:
		f := d.stale[i]
		return f.handle, tf(m, .Last_Dated, f.date)
	case .Dead_Links:
		x := d.dead_links[i]
		return x.target, tf(m, .Place, x.file, fmt.tprint(x.line))
	case .Duplicates:
		f := d.duplicate_handles[i]
		return f.handle, f.file
	case .Thin_Aliases:
		f := d.thin_aliases[i]
		return f.handle, f.aliases == "" ? tr(m, .No_Aliases) : tf(m, .Only_Aliases, f.aliases)
	case .Oversized:
		f := d.oversized[i]
		return f.handle, tf(m, .Characters, f.len)
	case .Orphans:
		return d.orphan_artifacts[i].file, tr(m, .Nothing_Links)
	case .Promote:
		f := d.promote[i]
		return f.handle, tf(m, .Queries_Sessions, f.queries, f.sessions)
	case .Never_Returned:
		f := d.never_returned[i]
		return f.handle, tf(m, .Since_Date, f.date)
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
		said = tr(m, .Checking_Vault)
	case ready(st) && d.ran_at != "":
		said = tf(m, .Report_From, d.ran_at, fmt.tprintf("%.1f", f64(d.took_ms) / 1000))
	}
	if body_width(m) >= NARROW {
		primer.text(gtx, said, .Small, color = s[.Fg_Color_Muted])
	}
	button := ui.stack_open(gtx)
	defer ui.close(&button)
	if primer.button(gtx, tr(m, .Check), .Primary, .Medium, leading = .Sync, loading = running) && !running {
		send(gtx, m, .Doctor)
	}
	primer.tooltip(gtx, tr(m, .Check_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
}

// page_doctor is doctor's lists, the items of the one chosen, and the
// item chosen in full.
page_doctor :: proc(gtx: ^ui.Ctx, m: ^Model) {
	d, st := ui.need(gtx, shapes.Doctor{}, shapes.Doctor_Result)
	fix_confirm(gtx, m)
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
		pane(gtx, m, .Findings_Kinds, narrow ? items_size : kinds_size, tr(m, .Findings))
		loading(gtx, 6)
		return
	}
	if d.error != "" {
		pane(gtx, m, .Findings_Kinds, {body_width(m), 0})
		failed(gtx, m, d.error)
		return
	}
	kinds: if !narrow {
		pane(gtx, m, .Findings_Kinds, kinds_size, tr(m, .Findings), scroll = false)
		ui.inset(gtx, ui.pad_all(8))
		ui.column(gtx, gap = 2, align = .Fill)
		for l in Finding_List {
			n := finding_count(d, l)
			// The row and its tooltip share a stack, so the tooltip watches
			// the row's own box.
			st := ui.stack_open(gtx, key = u64(l) + 100)
			if row_button(gtx, tr(m, FINDING_MSG[l]), l == m.findings, FINDING_ICONS[l], n > 0 ? digits(m, n) : "", key = u64(l) + 1) {
				m.findings, m.findings_chosen = l, true
				m.finding.len = 0
				m.panes[.Findings], m.panes[.Finding] = {}, {}
			}
			primer.tooltip(gtx, tr(m, FINDING_TIP[l]), ui.last_widget(gtx), direction = .E, delay = TOOLTIP_DELAY)
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
	// The list is read once: the narrow layout's menu, drawn inside the
	// pane, may choose another, which shows from the next frame, not
	// halfway through this one's rows.
	list := m.findings
	n := finding_count(d, list)
	// The item chosen is found by what it says; a fresh report may order
	// the list differently, or no longer hold it, when the first is shown.
	current := 0
	for i in 0 ..< n {
		if finding_key(m, d, list, i) == chosen(&m.finding) {
			current = i
		}
	}
	{
		pane(gtx, m, .Findings, items_size, narrow ? "" : tr(m, FINDING_MSG[list]), n, bar = narrow ? findings_menu : nil)
		if n == 0 {
			empty(gtx, tr(m, FINDING_NONE[list]), tr(m, FINDING_NOTE[list]), .Check_Circle)
		} else {
			l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, FINDING_MSG[list]))
			for i in 0 ..< n {
				title, note := finding_row(m, d, list, i)
				if primer.action_list_item(&l, title, description = note, description_variant = .Block, truncate = true, leading = FINDING_ICONS[list], active = i == current) {
					choose(&m.finding, finding_key(m, d, list, i))
					m.panes[.Finding] = {}
				}
			}
			primer.action_list_close(&l)
		}
	}
	{
		m.fix.list, m.fix.at = list, current
		pane(gtx, m, .Finding, detail_size, footer = n > 0 && has_fixes(list) ? fix_bar : nil)
		if n == 0 {
			empty(gtx, tr(m, .Nothing_To_Look_At), tr(m, FINDING_NOTE[list]), .Shield_Check)
			return
		}
		finding_detail(gtx, m, d, list, current)
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
		title := tr(m, FINDING_MSG[l])
		options[int(l)] = {label = n > 0 ? tf(m, .Kind_Count, title, n) : title}
	}
	list := int(m.findings)
	if primer.select(gtx, options, &list, size = .Small, block = true, name = tr(m, .Findings)) {
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
	title, note := finding_row(m, d, l, i)
	primer.label(gtx, tr(m, FINDING_MSG[l]), l == .Failed_Claims ? .Danger : .Secondary)
	primer.heading(gtx, title, 2, .Medium)
	primer.text(gtx, tr(m, FINDING_NOTE[l]), color = s[.Fg_Color_Muted])
	#partial switch l {
	case .Failed_Claims:
		c := d.failed_claims[i]
		fields(gtx, {{tr(m, .Label_File), c.file}, {tr(m, .Label_Claim), fmt.tprintf("%s %s", c.kind, c.text)}, {tr(m, .Why_Failed), c.why}, {tr(m, .Label_Checked), c.checked}})
	case .Dead_Links:
		x := d.dead_links[i]
		fields(gtx, {{tr(m, .Label_In), tf(m, .Line_At, x.file, fmt.tprint(x.line))}, {tr(m, .Links_To), x.target}})
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
		// What an agent searches for finds a bullet by its names: a thin
		// one or one never found is given more where it is shown.
		if l == .Thin_Aliases || l == .Never_Returned {
			alias_editor(gtx, m, f.handle, f.aliases)
		}
		// Each copy says where it is.
		if l == .Duplicates {
			duplicate_copies(gtx, m, f.handle)
			return
		}
		rows := make([dynamic][2]string, context.temp_allocator)
		append(&rows, [2]string{tr(m, .Label_File), f.file})
		if f.aliases != "" && l != .Thin_Aliases {
			append(&rows, [2]string{tr(m, .Label_Aliases), f.aliases})
		}
		if f.date != "" {
			append(&rows, [2]string{tr(m, .Label_Dated), f.date})
		}
		if f.len > 0 {
			append(&rows, [2]string{tr(m, .Label_Length), tf(m, .Characters, f.len)})
		}
		if f.queries > 0 {
			append(&rows, [2]string{tr(m, .Asked_For), tf(m, .Queries_Sessions, f.queries, f.sessions)})
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

// age is days as a person says it: how old a thing is, "12 days old",
// or with ago how long since it happened, short enough for a figure,
// "12d ago"; a negative count is never.
age :: proc(m: ^Model, days: int, ago := false) -> string {
	switch {
	case days < 0:
		return tr(m, .Word_Never)
	case days == 0:
		return tr(m, .Word_Today)
	case days == 1:
		return ago ? tr(m, .Word_Yesterday) : tf(m, .Age_Day, 1)
	case days < 60:
		return ago ? tf(m, .Ago_Day, days) : tf(m, .Age_Day, days)
	case days < 730:
		months := days / 30
		return ago ? tf(m, .Ago_Month, months) : tf(m, .Age_Month, months)
	}
	years := days / 365
	return ago ? tf(m, .Ago_Year, years) : tf(m, .Age_Year, years)
}

// alias_editor is a bullet's other names, each removable, and a field
// for another: a thin bullet is one with fewer than two, which an agent
// asking in other words may miss. Each edit is a command; doctor is run
// again after it, so the list shows what is still thin.
alias_editor :: proc(gtx: ^ui.Ctx, m: ^Model, handle, aliases: string) {
	s := &m.scheme
	busy := waiting_on(m, .Add_Alias, handle) || waiting_on(m, .Remove_Alias, handle)
	ui.column(gtx, gap = 8, align = .Fill)
	primer.text(gtx, tr(m, .Other_Names), .Small, .Medium, color = s[.Fg_Color_Muted])
	names := make([dynamic]string, context.temp_allocator)
	for raw in strings.split(aliases, ",", context.temp_allocator) {
		if a := strings.trim_space(raw); a != "" {
			append(&names, a)
		}
	}
	{
		ui.wrap(gtx, gap = 6, line_gap = 6, align = .Center)
		if len(names) == 0 {
			primer.text(gtx, tr(m, .None_Yet), .Small, color = s[.Fg_Color_Muted])
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
			e = primer.text_input(gtx, &m.alias, placeholder = tr(m, .Alias_Ph), size = .Small, validation = term != "" && !ok ? .Error : .None, name = tr(m, .New_Alias))
		}
		add := primer.button(gtx, tr(m, .Add), .Primary, .Small, leading = .Plus, loading = busy, inactive = !ok)
		if (add || e.submitted) && ok && !busy {
			send(gtx, m, .Add_Alias, {handle}, term)
			ui.text_set(&m.alias, "")
		}
	}
	term := strings.trim_space(ui.text_string(&m.alias))
	if term != "" && !alias_ok(term) {
		primer.inline_message(gtx, tr(m, .Alias_Bad), .Critical, .Small)
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

// file_url is path as a file: URL, which the platform opens with its file
// manager: a Windows path's backslashes turned and a drive letter given
// its leading slash, and the characters a URL reserves escaped.
file_url :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	if !strings.has_prefix(path, "/") {
		strings.write_byte(&b, '/')
	}
	for c in transmute([]u8)path {
		switch c {
		case '\\':
			strings.write_byte(&b, '/')
		case ' ', '#', '%', '?', '"':
			fmt.sbprintf(&b, "%%%02X", c)
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// vault_control is what can be done to the vault as a whole, beside the
// page's other controls, each with a tooltip saying what it does.
vault_control :: proc(gtx: ^ui.Ctx, m: ^Model) {
	reindexing := waiting_on(m, .Reindex)
	{
		st := ui.stack_open(gtx)
		defer ui.close(&st)
		if primer.button(gtx, tr(m, .Reindex), .Default, .Medium, leading = .Database, loading = reindexing) && !reindexing {
			send(gtx, m, .Reindex)
		}
		primer.tooltip(gtx, tr(m, .Reindex_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	}
}

// where_actions is the Where pane's footer: move this machine to another
// vault.
where_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	v, st := ui.need(gtx, shapes.Vault{}, shapes.Vault_Result)
	moving := waiting_on(m, .Set_Vault)
	ui.row(gtx, gap = 8, align = .Center)
	st2 := ui.stack_open(gtx)
	// The system's own folder dialog chooses; what it would change is then
	// shown before it is used.
	if primer.button(gtx, tr(m, .Change), .Default, leading = .File_Directory, loading = moving) && !moving {
		ui.pick_folder(gtx, VAULT_PICK, ready(st) ? v.vault : "")
	}
	primer.tooltip(gtx, tr(m, .Change_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	ui.close(&st2)
}

// VAULT_PICK is the area a vault folder pick answers: the Change button
// and the dialog's Browse both ask under it.
VAULT_PICK :: ops.Area_Id(0x7a17_f01d)

// vault_picked opens the change dialog on the folder the system dialog
// chose; a cancel changes nothing.
vault_picked :: proc(gtx: ^ui.Ctx, m: ^Model) {
	for e in ui.events(gtx, VAULT_PICK) {
		if e.kind == .Picked && e.text != "" {
			ui.text_set(&m.vault_path, e.text)
			m.moving = true
		}
	}
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
	footer := []primer.Dialog_Button{{content = tr(m, .Cancel), clicked = &cancel}, {content = tr(m, .Use_This_Vault), type = .Primary, disabled = !ok, clicked = &use}}
	dl := primer.dialog_open(gtx, &m.moving, tr(m, .Change_Vault), tr(m, .Change_Vault_Body), footer, width = .Large)
	if dl.visible {
		ui.column(gtx, gap = 12, align = .Fill)
		{
			ui.row(gtx, gap = 8, align = .Center)
			{
				fw := max(gtx.constraints.max.x - 110, 160)
				ui.sized(gtx, {min = {fw, 0}, max = {fw, ui.INF}})
				primer.text_input(gtx, &m.vault_path, placeholder = "/path/to/vault", leading = .File_Directory, block = true, name = tr(m, .Vault_Folder))
			}
			if primer.button(gtx, tr(m, .Browse), .Default) {
				ui.pick_folder(gtx, VAULT_PICK, path != "" ? path : current)
			}
		}
		switch {
		case !asked:
			primer.text(gtx, tr(m, .Choose_Folder), .Small, color = s[.Fg_Color_Muted])
		case plan == nil:
			primer.text(gtx, tr(m, .Checking), .Small, color = s[.Fg_Color_Muted])
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
			primer.text(gtx, tr(m, .Using_Changes), .Small, .Medium, color = s[.Fg_Color_Muted])
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
	vault_picked(gtx, m)
	defer move_dialog(gtx, m, ready(st) ? v.vault : "")
	arrange(gtx, m)
	w := split(gtx, m, 0.5, 0.5)
	location: {
		pane(gtx, m, .Vault, w[0], tr(m, .Where), scroll = false, footer = ready(st) ? where_actions : nil)
		if !ready(st) {
			loading(gtx, 3)
			break location
		}
		failed(gtx, m, v.error)
		ui.inset(gtx, ui.pad_all(16))
		version := v.version
		if v.commit != "" {
			version = tf(m, .Join_Dot, v.version, v.commit)
		}
		ui.column(gtx, gap = 8, align = .Fill)
		{
			ui.column(gtx, gap = 2, align = .Fill, key = 1)
			primer.text(gtx, tr(m, .Label_Vault), .Small, .Medium, color = m.scheme[.Fg_Color_Muted])
			// The folder opens in the system's file manager.
			st := ui.stack_open(gtx, key = 2)
			if primer.link(gtx, v.vault) {
				ui.open_url(gtx, file_url(v.vault))
			}
			primer.tooltip(gtx, tr(m, .Open_Folder_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
			ui.close(&st)
		}
		fields(gtx, {{"brain", version}, {tr(m, .Label_Checkout), v.tool}})
	}
	pane(gtx, m, .Vault_Travel, w[1], tr(m, .Sync_And_Review), scroll = false)
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
			primer.state_label(gtx, on ? tr(m, .On) : tr(m, .Off), on ? .Open : .Closed, .Small)
			primer.text(gtx, v.remote != "" ? v.remote : tr(m, .No_Remote), weight = .Medium)
		}
		waiting := v.changed == 0 ? tr(m, .Nothing_To_Send) : tf(m, .Changes_Waiting, v.changed)
		last := v.last != "" ? sync_time(v.last) : tr(m, .Word_Never)
		primer.text(gtx, tf(m, .Last_Sync, last, waiting), .Small, color = s[.Fg_Color_Muted])
	}
	{
		ui.column(gtx, gap = 8, align = .Fill)
		primer.heading(gtx, tr(m, .Review), 3, .Small)
		primer.text(gtx, tr(m, .Review_Question), .Small, color = s[.Fg_Color_Muted])
		segments := []primer.Segment{{label = tr(m, .At_Once)}, {label = tr(m, .Once_Approved)}}
		mode := v.review == "before" ? 1 : 0
		if primer.segmented_control(gtx, segments, &mode, tr(m, .Review)) && !waiting_on(m, .Review) {
			send(gtx, m, .Review, nil, mode == 1 ? "before" : "after")
		}
	}
}
