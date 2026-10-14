/*
Package view is the desk's ui, drawn with jm:ui/primer as an application,
not a page: the rail on the left, and beside it the page's title, its
toolbar and its body, which fills the window and never scrolls. A body
is panes side by side, a list and the detail of what is chosen in it, and
each pane scrolls on its own. It is a function of the shapes it needs and
the Model it keeps; it asks for every answer with ui.need and changes the
vault only with ui.command, so it runs the same over the real CLI, in a
hot-reloaded child, or in a probe fed canned shapes.

What a page shows is what it needs this frame: the rail's counts need the
inbox and the log on every page, Recall needs the search typed and the
conversation around the turn chosen, and a command waits on its Outcome.
Leaving a page releases its needs.
*/
package desk_view

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"

import "jm:i18n"
import "jm:ui"
import "jm:ui/base"
import "jm:ui/design"
import "jm:ui/ops"
import "jm:ui/primer"
import tok "jm:ui/primer/tokens"

import "../../../msg"
import "../shapes"

NAV_WIDTH :: 248 // the rail's width until it is dragged
NAV_MIN :: 180
NAV_MAX :: 360
RAIL :: 56 // the rail collapsed to its icons
MIN_WINDOW :: ops.Size{800, 560} // the smallest window the desk is laid out for
NARROW :: 950 // a body narrower than this folds Doctor's lists into a menu
RAIL_BODY :: 800 // the rail collapses rather than leave the body narrower than this
LIST_MAX :: 420 // a list pane's widest; its detail takes the rest
PANE_MIN :: ops.Size{260, 150} // the smallest a pane is laid out at
GUTTER :: 24 // around the body; GUTTER_TIGHT in a window under 1100 wide
GUTTER_TIGHT :: 16
GAP :: 16 // between panes
RECALL_LIMIT :: 30
MAX_PENDING :: 16
MAX_HANDLE :: 160
MAX_KEY :: 256 // the longest query, handle or id a selection holds
LOADING_DELAY :: 0.15 // seconds before a wait is shown, so a quick answer never flashes

Page :: enum u8 {
	Activity,
	Savings,
	Misses,
	Recall,
	Inbox,
	Bullets,
	Doctor,
	Vault,
	Setup,
}

PAGE_TITLES := [Page]string {
	.Activity = "Activity",
	.Savings  = "Savings",
	.Misses   = "Misses",
	.Recall   = "Recall",
	.Inbox    = "Inbox",
	.Bullets  = "Bullets",
	.Doctor   = "Doctor",
	.Vault    = "Vault",
	.Setup    = "Setup",
}

// WATCH_PAGES is how many pages, from the first, the rail groups under
// Watch; the rest are under Tend.
WATCH_PAGES :: 4

// PAGE_NOTES is the line under each title that says what the page is for.
PAGE_NOTES := [Page]string {
	.Activity = "What your agents asked, and what it cost them.",
	.Savings  = "What your agents cost, and what the vault saved them.",
	.Misses   = "Queries that still find nothing. Each is a bullet or an alias away.",
	.Recall   = "What was said, across every agent's transcripts.",
	.Inbox    = "Facts your agents proposed. Approve to keep, drop to forget.",
	.Bullets  = "Every fact in the vault. Search it, correct it, re-date it, or write a new one.",
	.Doctor   = "What is stale, thin, oversized, orphaned, or no longer true.",
	.Vault    = "Where the vault lives, and how it travels between machines.",
	.Setup    = "Get the vault working on this machine, a step at a time.",
}

// PAGE_MSG and PAGE_NOTE are the titles and notes as the catalog names
// them. PAGE_TITLES stays the English -page flag.
PAGE_MSG := [Page]msg.Msg {
	.Activity = .Page_Activity,
	.Savings  = .Page_Savings,
	.Misses   = .Page_Misses,
	.Recall   = .Page_Recall,
	.Inbox    = .Page_Inbox,
	.Bullets  = .Page_Bullets,
	.Doctor   = .Page_Doctor,
	.Vault    = .Page_Vault,
	.Setup    = .Page_Setup,
}

PAGE_NOTE := [Page]msg.Msg {
	.Activity = .Note_Activity,
	.Savings  = .Note_Savings,
	.Misses   = .Note_Misses,
	.Recall   = .Note_Recall,
	.Inbox    = .Note_Inbox,
	.Bullets  = .Note_Bullets,
	.Doctor   = .Note_Doctor,
	.Vault    = .Note_Vault,
	.Setup    = .Note_Setup,
}

PAGE_ICONS := [Page]primer.Icon {
	.Activity = .Pulse,
	.Savings  = .Fiscal_Host,
	.Misses   = .Question,
	.Recall   = .Comment_Discussion,
	.Inbox    = .Inbox,
	.Bullets  = .Book,
	.Doctor   = .Shield_Check,
	.Vault    = .Database,
	.Setup    = .Checklist,
}

// Pane_Id names a pane, so each keeps its own scroll.
Pane_Id :: enum u8 {
	Lookups,
	Days,
	Misses,
	Miss_Detail,
	Turns,
	Around,
	Proposals,
	Proposal,
	Findings_Kinds,
	Findings,
	Finding,
	Vault,
	Vault_Travel,
	Bullets,
	Bullet,
	Chart_Lookups,
	Chart_Saved,
	Chart_Spend,
	Chart_Finds,
	Spend_Models,
	Spend_Agents,
	Setup,
	Setup_Step,
	Provenance, // its scrolling part; not a pane of its own
}

// Pending is a command sent and not yet answered: its id, which Outcome
// it waits on, and the proposals it is about, if any, in the model's
// allocator.
Pending :: struct {
	id:      u64,
	kind:    Pending_Kind,
	handles: []string,
}

Pending_Kind :: enum u8 {
	Approve,
	Drop,
	Sync,
	Reindex,
	Review,
	Doctor,
	Add_Alias,
	Remove_Alias,
	Write_Bullet,
	Replace_Bullet,
	Drop_Bullet,
	Touch_Bullet,
	Unlink,
	Set_Price,
	Import,
	Merge,
	Connect,
	New_Vault,
	Set_Vault,
}

// Chosen is what a list has picked, held by value: a handle, a query or a
// turn's id. Empty is the first item.
Chosen :: struct {
	buf: [MAX_KEY]u8,
	len: int,
}

chosen :: proc(c: ^Chosen) -> string {
	return string(c.buf[:c.len])
}

choose :: proc(c: ^Chosen, s: string) {
	c.len = copy(c.buf[:], s)
}

Model :: struct {
	page:      Page,
	theme:     primer.Theme,
	scheme:    primer.Scheme,
	panes:     [Pane_Id]ui.Scroll_Offset,
	search:    ui.Text_State, // what Recall searches for
	alias:     ui.Text_State, // a name being added to a thin bullet
	bullet:    Chosen, // the bullet Bullets shows
	filter:    ui.Text_State, // what Bullets searches for
	file_filter: int, // which file Bullets shows: 0 every one, else an index into the list's files, plus one
	editor:    Editor, // the bullet being edited or written
	bullet_list: ui.List_State, // the bullets list's scroll; ui.list lays out only the rows in view
	haystacks: Haystacks, // the bullets' text as the search reads it
	moving:    bool, // the change-vault dialog is open
	vault_path: ui.Text_State, // the path it would move to
	shown:     Chosen, // the last terms Recall had an answer for, drawn while newer ones load
	turn:      Chosen, // the turn Recall shows the conversation around
	miss:      Chosen, // the miss Misses shows
	proposal:  Chosen, // the proposal Inbox shows
	findings:  Finding_List, // the list Doctor shows
	finding:   Chosen, // the item in it, by what it says, so a fresh report keeps it
	findings_chosen: bool, // the person chose the list, rather than the page
	toasts:    primer.Toasts,
	next_id:   u64,
	pending:   [MAX_PENDING]Pending,
	n_pending: int,
	selected:  [dynamic]string, // the proposals ticked, by handle, in the model's allocator
	confirm:   bool, // the bulk confirmation is open
	bulk:      Pending_Kind, // what it confirms: Approve or Drop
	window:    ops.Size,
	nav_width: f32, // the rail's dragged width; 0 is NAV_WIDTH
	collapsed: bool, // the person collapsed the rail
	dragging:  bool, // the rail's edge is being dragged
	history:   History, // the pages jumped from, for Ctrl+O and Ctrl+I
	fix:       Fix, // the finding Doctor shows, and the fix it is asked to confirm
	rename:    ui.Text_State, // a duplicate's new handle
	bullet_tab: int, // the bullet shown: 0 edited, 1 its provenance
	pin:       Chosen, // the Recall search under which m.turn stays shown, found or not
	reveal:    bool, // scroll the conversation to its matching turn once it has drawn
	seen:      [Page]int, // what was waiting on each page when it was last open: its dot shows only more
	spend_window: int, // Savings' days: an index into SPEND_WINDOWS
	spend_gen: int, // bumped when a price is set, so spend is read again
	pricing:   Chosen, // the model Savings is setting a price for
	price_in:  ui.Text_State, // its dollars per million input tokens
	price_out: ui.Text_State, // and output tokens
	import_pick: Import_Pick, // the import dialog
	merge:     Merge_Edit, // the dialog folding a proposal into a bullet
	setup_gen: int, // bumped when a step is taken, so setup is read again
	setup_offered: bool, // Setup has been opened by itself once
	setup_step: Setup_Step, // the step Setup shows, once chosen
	setup_chosen: bool, // the person chose a step, rather than the first not done
	try:       ui.Text_State, // Setup's first find
	allocator: mem.Allocator,
	strings:   msg.Strings, // the catalog in the locale in use
	language_open: bool, // the globe's menu
	language_dir: string, // where a choice is saved; empty in a test
}

// model_init readies m in locale. The toasts' memory is allocator's.
// A test leaves locale at English and language_dir empty, so it neither
// reads nor writes a person's saved tag.
model_init :: proc(m: ^Model, allocator := context.allocator, locale := i18n.Locale.English) {
	m.allocator = allocator
	m.toasts.allocator = allocator
	m.search.buf = make([dynamic]u8, allocator)
	m.alias.buf = make([dynamic]u8, allocator)
	m.filter.buf = make([dynamic]u8, allocator)
	m.vault_path.buf = make([dynamic]u8, allocator)
	m.rename.buf = make([dynamic]u8, allocator)
	m.price_in.buf = make([dynamic]u8, allocator)
	m.price_out.buf = make([dynamic]u8, allocator)
	m.import_pick.ticked = make([dynamic]string, allocator)
	merge_init(&m.merge, allocator)
	m.try.buf = make([dynamic]u8, allocator)
	m.spend_window = 1
	editor_init(&m.editor, allocator)
	m.selected = make([dynamic]string, allocator)
	m.history.places = make([dynamic]Place, allocator)
	msg.init(&m.strings, locale)
}

// tr is key in the locale m is showing.
tr :: proc(m: ^Model, key: msg.Msg) -> string {
	return msg.tr(&m.strings, key)
}

// tf is key with its arguments filled in.
tf :: proc(m: ^Model, key: msg.Msg, args: ..i18n.Arg) -> string {
	return msg.trf(&m.strings, key, ..args)
}

// choose_language puts locale in use and, when a directory was given,
// saves the tag for the next desk start and the CLI.
choose_language :: proc(m: ^Model, locale: i18n.Locale) {
	msg.use(&m.strings, locale)
	msg.use_global(locale)
	if m.language_dir != "" {
		msg.save_tag(m.language_dir, locale)
	}
}

model_destroy :: proc(m: ^Model) {
	primer.toasts_destroy(&m.toasts)
	delete(m.history.places)
	delete(m.search.buf)
	delete(m.alias.buf)
	delete(m.filter.buf)
	delete(m.vault_path.buf)
	delete(m.rename.buf)
	delete(m.price_in.buf)
	delete(m.price_out.buf)
	for p in m.import_pick.ticked {
		delete(p, m.allocator)
	}
	delete(m.import_pick.ticked)
	merge_destroy(&m.merge)
	delete(m.try.buf)
	editor_destroy(&m.editor)
	for x in m.haystacks.text {
		delete(x, m.allocator)
	}
	delete(m.haystacks.text)
	for p in m.pending[:m.n_pending] {
		free_handles(p.handles, m.allocator)
	}
	for h in m.selected {
		delete(h, m.allocator)
	}
	delete(m.selected)
}

// Session is what a hot reload keeps: the page, the theme, the panes'
// scroll and Doctor's list.
Session :: struct {
	page:      Page,
	nav_width: f32,
	collapsed: bool,
	theme:    primer.Theme,
	panes:    [Pane_Id]ui.Scroll_Offset,
	findings: Finding_List,
	seen:     [Page]int,
	offered:  bool,
}

view :: proc(gtx: ^ui.Ctx, user: rawptr) {
	m := (^Model)(user)
	if s := (Session{m.page, m.nav_width, m.collapsed, m.theme, m.panes, m.findings, m.seen, m.setup_offered}); ui.restore_struct(gtx, &s, gtx.allocator) {
		m.page, m.nav_width, m.collapsed, m.theme, m.panes, m.findings, m.seen, m.setup_offered = s.page, s.nav_width, s.collapsed, s.theme, s.panes, s.findings, s.seen, s.offered
	}
	setup_offer(gtx, m)
	m.scheme = primer.theme_scheme(m.theme)
	primer.use(&m.scheme, m.theme)
	primer.use_fonts({0, 1, 2, 3})
	s := &m.scheme
	m.window = gtx.constraints.max
	ops.fill(gtx.scene, ops.Rect{0, 0, m.window.x, m.window.y}, s[.Bg_Color_Inset])
	history_keys(gtx, m)

	{
		ui.row(gtx, align = .Fill)
		nav(gtx, m)
		ui.flexible(gtx, 1)
		ui.column(gtx, align = .Fill)
		header(gtx, m)
		toolbar(gtx, m)
		ui.flexible(gtx, 1)
		page := m.page
		ui.scope(gtx, int(page))
		g := gutter(m)
		ui.inset(gtx, {g, 0, g, g})
		switch page {
		case .Activity:
			page_activity(gtx, m)
		case .Misses:
			page_misses(gtx, m)
		case .Recall:
			page_recall(gtx, m)
		case .Inbox:
			page_inbox(gtx, m)
		case .Bullets:
			page_bullets(gtx, m)
		case .Doctor:
			page_doctor(gtx, m)
		case .Vault:
			page_vault(gtx, m)
		case .Savings:
			page_savings(gtx, m)
		case .Setup:
			page_setup(gtx, m)
		}
	}
	// After the pages, so a command sent this frame needs its outcome now.
	settle_outcomes(gtx, m)
	primer.toaster(gtx, &m.toasts)
	ui.persist_struct(gtx, Session{m.page, m.nav_width, m.collapsed, m.theme, m.panes, m.findings, m.seen, m.setup_offered})
}

// rail_collapsed is whether the rail shows only its icons: the person
// collapsed it, or open it would leave the body too narrow for panes side
// by side, which a collapsed rail may save.
rail_collapsed :: proc(m: ^Model) -> bool {
	return m.collapsed || m.window.x - open_width(m) - 2 * gutter(m) < RAIL_BODY
}

// open_width is the rail's width when open: as dragged, within bounds.
open_width :: proc(m: ^Model) -> f32 {
	return clamp(m.nav_width > 0 ? m.nav_width : NAV_WIDTH, NAV_MIN, NAV_MAX)
}

// nav_width is the rail's width now.
nav_width :: proc(m: ^Model) -> f32 {
	if rail_collapsed(m) {
		return RAIL
	}
	return open_width(m)
}

// body_width is the room a page has beside the rail, inside its gutters.
body_width :: proc(m: ^Model) -> f32 {
	return max(max(m.window.x, MIN_WINDOW.x) - nav_width(m) - 2 * gutter(m), 320)
}

// gutter is the space around the body: less in a small window, where every
// pixel goes to the panes.
gutter :: proc(m: ^Model) -> f32 {
	return m.window.x < 1100 ? GUTTER_TIGHT : GUTTER
}

// arrange opens the body's panes: always a row. A pane scrolls inside
// itself; the panes never stack, which would leave each a strip. The
// guard closes it.
@(deferred_in = arrange_close)
arrange :: proc(gtx: ^ui.Ctx, m: ^Model, loc := #caller_location) -> bool {
	ui.row_open(gtx, gap = GAP, align = .Start, loc = loc)
	return true
}

@(private)
arrange_close :: proc(gtx: ^ui.Ctx, m: ^Model, loc: runtime.Source_Code_Location) {
	ui.innermost_close(gtx, .Flex)
}

// split is the size of each pane: its fraction of the body's width, at the
// body's height, none narrower than PANE_MIN. Called inside arrange.
split :: proc(gtx: ^ui.Ctx, m: ^Model, fractions: ..f32) -> []ops.Size {
	out := make([]ops.Size, len(fractions), context.temp_allocator)
	h := gtx.constraints.max.y
	if !ui.is_finite(h) {
		h = 480
	}
	room := body_width(m) - GAP * f32(len(fractions) - 1)
	for f, i in fractions {
		out[i] = {math.floor(room * f), h}
	}
	// A pane short of PANE_MIN takes the difference from the widest.
	for &o in out {
		if o.x < PANE_MIN.x {
			widest := 0
			for w, k in out {
				if w.x > out[widest].x {
					widest = k
				}
			}
			out[widest].x -= PANE_MIN.x - o.x
			o.x = PANE_MIN.x
		}
	}
	return out
}

// split_list is a list pane and its detail: the list 38% of the width,
// within PANE_MIN and LIST_MAX, the detail the rest.
split_list :: proc(gtx: ^ui.Ctx, m: ^Model) -> []ops.Size {
	room := body_width(m) - GAP
	list := clamp(math.floor(room * 0.38), PANE_MIN.x, LIST_MAX)
	return split(gtx, m, list / room, 1 - list / room)
}

// nav is the rail: the product's mark and name, then the pages, each with
// what is waiting on it. The counts are needs of their own, so they move
// while another page is open. Its edge drags to resize it; a button
// collapses it to its icons, as a narrow window does.
nav :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := &m.scheme
	w := nav_width(m)
	h := gtx.constraints.max.y
	ui.sized(gtx, {min = {w, 0}, max = {w, ui.INF}})
	ops.fill(gtx.scene, ops.Rect{0, 0, w, h}, s[.Bg_Color_Inset])
	ops.fill(gtx.scene, ops.Rect{w - 1, 0, 1, h}, s[.Border_Color_Default])
	counts: [Page]string
	waiting: [Page]int
	if log, st := ui.need(gtx, shapes.Log{}, shapes.Log_Result); ready(st) {
		waiting[.Misses] = len(log.backlog)
	}
	if inbox, st := ui.need(gtx, shapes.Inbox{}, shapes.Inbox_Result); ready(st) {
		waiting[.Inbox] = len(inbox.proposals)
	}
	if setup, st := ui.need(gtx, shapes.Setup{gen = m.setup_gen}, shapes.Setup_Result); ready(st) && setup.error == "" {
		waiting[.Setup] = setup_left(setup)
	}
	// A page's dot is news: more waiting than when it was last open.
	// Opening the page clears it; the count beside its name stays.
	fresh: [Page]bool
	for p in Page {
		if waiting[p] > 0 {
			counts[p] = digits(m, waiting[p])
		}
		if p == m.page || waiting[p] < m.seen[p] {
			m.seen[p] = waiting[p]
		}
		fresh[p] = waiting[p] > m.seen[p]
	}
	if rail_collapsed(m) {
		rail(gtx, m, waiting, fresh)
		return
	}
	nav_edge(gtx, m, w, h)
	ui.column(gtx, gap = 8, align = .Fill)
	{
		ui.inset(gtx, {16, 20, 8, 4})
		ui.row(gtx, gap = 8, align = .Center)
		mark(gtx, 36, s[.Fg_Color_Default])
		primer.heading(gtx, tr(m, .App_Name), 3, .Small)
		ui.fill_space(gtx)
		if icon_action(gtx, .Sidebar_Collapse, tr(m, .Collapse_Sidebar), .Invisible, .Small) {
			m.collapsed = true
		}
	}
	watch := make([]primer.Nav_Item, WATCH_PAGES, context.temp_allocator)
	tend := make([]primer.Nav_Item, len(Page) - WATCH_PAGES, context.temp_allocator)
	for p in Page {
		it := primer.Nav_Item {
			label         = tr(m, PAGE_MSG[p]),
			leading       = PAGE_ICONS[p],
			trailing_text = counts[p],
			current       = p == m.page,
		}
		if int(p) < WATCH_PAGES {
			watch[int(p)] = it
		} else {
			tend[int(p) - WATCH_PAGES] = it
		}
	}
	groups := []primer.Nav_Group{{title = tr(m, .Nav_Watch), items = watch}, {title = tr(m, .Nav_Tend), items = tend}}
	if it := primer.nav_list(gtx, groups, label = tr(m, .Nav_Pages)); it != nil {
		for &item, i in watch {
			if it == &item {
				go(m, Page(i))
			}
		}
		for &item, i in tend {
			if it == &item {
				go(m, Page(i + WATCH_PAGES))
			}
		}
	}
	// The globe sits under the pages, so the title row stays the height
	// the panes were laid out against.
	{
		ui.inset(gtx, {12, 4, 12, 12})
		language_menu(gtx, m)
	}
}

// rail is the collapsed rail: the mark, then a button per page with its
// name as a tooltip and a dot when something waits on it. Expanding it is
// offered only when the person collapsed it; a narrow window keeps it so.
rail :: proc(gtx: ^ui.Ctx, m: ^Model, waiting: [Page]int, fresh: [Page]bool) {
	s := &m.scheme
	ui.column(gtx, gap = 6, align = .Center)
	ui.spacer(gtx, 18)
	mark(gtx, 32, s[.Fg_Color_Default])
	ui.spacer(gtx, 10)
	for p in Page {
		desc := waiting[p] > 0 ? tf(m, .Waiting, waiting[p]) : ""
		if icon_action(gtx, PAGE_ICONS[p], tr(m, PAGE_MSG[p]), p == m.page ? .Default : .Invisible, dot = fresh[p] ? .Button : .None, description = desc, direction = .E, key = u64(p) + 1) {
			go(m, p)
		}
	}
	if m.collapsed && m.window.x - open_width(m) - 2 * gutter(m) >= RAIL_BODY {
		ui.spacer(gtx, 10)
		if icon_action(gtx, .Sidebar_Expand, tr(m, .Expand_Sidebar), .Invisible, .Small, direction = .E, key = 99) {
			m.collapsed = false
		}
	}
	ui.spacer(gtx, 10)
	language_menu(gtx, m, icon_only = true)
}

// nav_edge is the rail's right edge as a handle: dragging it sets the
// rail's width, within NAV_MIN and NAV_MAX.
nav_edge :: proc(gtx: ^ui.Ctx, m: ^Model, w, h: f32) {
	id := ui.claim_id(gtx, 0xed6e)
	ops.input_area(gtx.scene, id, ops.Rect{w - 4, 0, 8, h}, {.Press, .Release, .Move}, .Resize_EW)
	ops.tag(gtx.scene, id, tr(m, .Resize_Sidebar))
	for e in ui.events(gtx, id) {
		#partial switch e.kind {
		case .Press:
			m.dragging = true
			m.nav_width = w
		case .Release:
			m.dragging = false
		case .Move:
			if m.dragging {
				m.nav_width = clamp(m.nav_width + e.travel.x, NAV_MIN, NAV_MAX)
			}
		}
	}
	if m.dragging {
		ops.fill(gtx.scene, ops.Rect{w - 2, 0, 3, h}, m.scheme[.Border_Color_Accent_Emphasis])
	}
}

// header is the page's title and what it is for, with the actions every
// page shares: sync now, and light or dark. The language control is on
// the rail, so this row stays the height the panes were measured against.
header :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := &m.scheme
	ui.inset(gtx, {gutter(m), 20, gutter(m) - 8, 12})
	ui.row(gtx, gap = 8, align = .Start)
	{
		// The page's own controls take room from the title on the right.
		// What the page's controls take: Doctor's report time shows only
		// in a wide body.
		controls: f32
		#partial switch m.page {
		case .Doctor:
			controls = body_width(m) >= NARROW ? 360 : 150
		case .Vault:
			controls = 160
		case .Bullets:
			controls = 150
		case .Savings:
			controls = 140
		case .Inbox:
			controls = 190
		}
		w := body_width(m) - 120 - controls
		ui.sized(gtx, {min = {w, 0}, max = {w, ui.INF}})
		ui.column(gtx, gap = 4, align = .Fill)
		primer.heading(gtx, tr(m, PAGE_MSG[m.page]), 1, .Medium)
		primer.text(gtx, tr(m, PAGE_NOTE[m.page]), color = s[.Fg_Color_Muted])
	}
	ui.fill_space(gtx)
	#partial switch m.page {
	case .Doctor:
		ui.row(gtx, gap = 12, align = .Center)
		doctor_control(gtx, m)
	case .Vault:
		ui.row(gtx, gap = 12, align = .Center)
		vault_control(gtx, m)
	case .Bullets:
		ui.row(gtx, gap = 12, align = .Center)
		bullets_control(gtx, m)
	case .Savings:
		ui.row(gtx, gap = 12, align = .Center)
		savings_control(gtx, m)
	case .Inbox:
		ui.row(gtx, gap = 12, align = .Center)
		inbox_control(gtx, m)
	}
	// An icon button's tooltip is its name and description.
	syncing := waiting_on(m, .Sync)
	if icon_action(gtx, .Sync, tr(m, .Sync_Now), loading = syncing, description = tr(m, .Sync_Now_Tip)) && !syncing {
		send(gtx, m, .Sync)
	}
	dark := primer.mode_of(m.theme) == .Dark
	if icon_action(gtx, dark ? .Sun : .Moon, tr(m, dark ? .Light_Theme : .Dark_Theme), .Invisible, description = tr(m, .Theme_Tip)) {
		m.theme = dark ? .Light : .Dark
	}
}

// language_menu is the globe: the language in use, in its own name, and
// every shipped locale the same way. Choosing one reloads the table and
// saves the tag. The layout stays left to right. On the collapsed rail
// the button is the icon alone; its name is still the endonym.
language_menu :: proc(gtx: ^ui.Ctx, m: ^Model, icon_only := false) {
	current := msg.locale(&m.strings)
	ui.stack(gtx, key = 0x6c61)
	side := primer.Anchor_Side.Outside_Bottom
	if icon_only {
		side = .Outside_Right
		if icon_action(gtx, .Globe, i18n.locale_name(current), .Invisible, direction = .E, key = 1) {
			m.language_open = !m.language_open
		}
	} else {
		primer.action_menu_button(gtx, i18n.locale_name(current), &m.language_open, .Globe, .Invisible, .Small, key = 1)
	}
	menu := primer.action_menu_open(gtx, &m.language_open, ui.last_widget(gtx), selection = .Single, side = side, align = .Start, name = tr(m, .Language), key = 2)
	if primer.action_menu_group(&menu, tr(m, .Language_Menu_Title)) {
		for locale in i18n.Locale {
			if !msg.shipped(locale) {
				continue
			}
			if primer.action_menu_item(&menu, i18n.locale_name(locale), description = i18n.locale_english(locale), selected = locale == current) {
				choose_language(m, locale)
			}
		}
	}
	primer.action_menu_close(&menu)
}

// toolbar is the page's controls, fixed under its title: what the page
// does is never scrolled away.
toolbar :: proc(gtx: ^ui.Ctx, m: ^Model) {
	#partial switch m.page {
	case .Recall:
	case:
		return
	}
	ui.inset(gtx, {gutter(m), 0, gutter(m), 12})
	w := body_width(m)
	ui.sized(gtx, {min = {w, 0}, max = {w, ui.INF}})
	#partial switch m.page {
	case .Recall:
		recall_bar(gtx, m)
	}
}

// --- panes ------------------------------------------------------------------------

// Pane_Bar draws a pane's controls, fixed under its title.
Pane_Bar :: proc(gtx: ^ui.Ctx, m: ^Model)

// pane is a bordered panel of size, its height the body's when size.y is
// 0, titled when title is set; bar, when set, is the pane's own controls,
// under the title and never scrolled. Its content scrolls inside it when
// scroll is set: long or growing content, a list or a conversation. A
// pane of known size, figures or charts or settings, does not scroll, and
// a virtual list (ui.list) scrolls itself. The guard closes it.
@(deferred_in = pane_close)
pane :: proc(gtx: ^ui.Ctx, m: ^Model, id: Pane_Id, size: ops.Size, title := "", count := -1, bar: Pane_Bar = nil, scroll := true, footer: Pane_Bar = nil, loc := #caller_location) -> bool {
	s := &m.scheme
	width, h := size.x, size.y
	if h == 0 {
		h = gtx.constraints.max.y
	}
	if !ui.is_finite(h) {
		h = 480
	}
	ui.sized_open(gtx, {min = {width, h}, max = {width, h}}, u64(id) + 1, loc)
	// Named with its bounds, so a probe can measure it (the layout sweep).
	ops.tag(gtx.scene, ui.claim_id(gtx, u64(id) + 0x9a9e), fmt.tprintf("pane:%v", id), ops.Rect{0, 0, width, h})
	ui.box_open(gtx, {fill = s[.Bg_Color_Default], outline = s[.Border_Color_Default], stroke = 1, radius = 6}, u64(id) + 1, loc)
	ui.column_open(gtx, align = .Fill, key = u64(id) + 1, loc = loc)
	// The body's height is what the title, bar and footer leave, measured
	// as they are placed: a flexible body above a footer would be laid out
	// from the last frame's sizes, and a pane's first frame would put its
	// footer in the wrong place.
	used: f32
	if title != "" {
		{
			ui.inset(gtx, {16, 12, 16, 10})
			ui.row(gtx, gap = 8, align = .Center)
			primer.heading(gtx, title, 3, .Small)
			if count >= 0 {
				primer.counter_label(gtx, digits(m, count))
			}
		}
		used += ui.last_widget(gtx).size.y
		base.divider(gtx, s[.Border_Color_Muted], key = u64(id) + 1)
		used += ui.last_widget(gtx).size.y
	}
	if bar != nil {
		{
			ui.inset(gtx, {16, 8, 16, 8})
			bar(gtx, m)
		}
		used += ui.last_widget(gtx).size.y
		base.divider(gtx, s[.Border_Color_Muted], key = u64(id) + 2)
		used += ui.last_widget(gtx).size.y
	}
	if footer != nil {
		used += FOOTER_HEIGHT + 1
	}
	body := max(h - used, 0)
	ui.sized_open(gtx, {min = {width, body}, max = {width, body}}, u64(id) + 3, loc)
	if scroll {
		ui.scroll_box_open(gtx, u64(id) + 1, 0, &m.panes[id], loc)
	}
	ui.column_open(gtx, align = .Fill, key = u64(id) + 2, loc = loc)
	return true
}

@(private)
pane_close :: proc(gtx: ^ui.Ctx, m: ^Model, id: Pane_Id, size: ops.Size, title: string, count: int, bar: Pane_Bar, scroll: bool, footer: Pane_Bar, loc: runtime.Source_Code_Location) {
	ui.innermost_close(gtx, .Flex)
	if scroll {
		ui.innermost_close(gtx, .Scroll)
	}
	ui.innermost_close(gtx, .Inset) // the body's sized
	// The pane's actions, under its body and never scrolled with it, in a
	// strip of FOOTER_HEIGHT.
	if footer != nil {
		base.divider(gtx, m.scheme[.Border_Color_Muted], key = u64(id) + 3)
		{
			ui.sized(gtx, {min = {size.x, FOOTER_HEIGHT}, max = {size.x, FOOTER_HEIGHT}}, key = u64(id) + 5)
			ui.inset(gtx, {16, 10, 16, 10}, key = u64(id) + 4)
			footer(gtx, m)
		}
	}
	ui.innermost_close(gtx, .Flex)
	ui.innermost_close(gtx, .Box)
	ui.innermost_close(gtx, .Inset)
}

// TOOLTIP_DELAY is how long the pointer rests before a tooltip shows:
// Primer's 400ms, not the 50ms it gives an icon button, which flashes
// tooltips at a pointer only passing over.
TOOLTIP_DELAY :: primer.Tooltip_Delay.Medium

// icon_action is an icon button whose tooltip, its name and what it does,
// waits TOOLTIP_DELAY.
icon_action :: proc(
	gtx: ^ui.Ctx,
	ic: primer.Icon,
	name: string,
	variant := primer.Button_Variant.Default,
	size := primer.Button_Size.Medium,
	loading := false,
	dot := primer.Unread_Dot.None,
	description := "",
	direction := primer.Tooltip_Direction.S,
	key: u64 = 0,
	loc := #caller_location,
) -> bool {
	st := ui.stack_open(gtx, key ~ 0x5ac7, loc)
	defer ui.close(&st)
	clicked := primer.icon_button(gtx, ic, name, variant, size, loading = loading, dot = dot, description = description, no_tooltip = true, key = key, loc = loc)
	tip := description != "" ? fmt.tprintf("%s. %s", name, description) : name
	primer.tooltip(gtx, tip, ui.last_widget(gtx), direction = direction, delay = TOOLTIP_DELAY)
	return clicked
}

// FOOTER_HEIGHT is a pane footer's strip: a row of buttons, padded.
FOOTER_HEIGHT :: 52

// row_button is a list row that picks: a borderless button the pane's
// width, the current one filled. A label too long for the row ends in an
// ellipsis; the button's name is the whole of it.
row_button :: proc(gtx: ^ui.Ctx, label: string, current: bool, leading := primer.Icon.None, count := "", key: u64 = 0, loc := #caller_location) -> bool {
	room := gtx.constraints.max.x - 2 * tok.CONTROL_MEDIUM_PADDING_INLINE_NORMAL
	if leading != .None {
		room -= 16 + tok.CONTROL_MEDIUM_GAP
	}
	if count != "" {
		room -= 36
	}
	shown := fit(gtx, label, room)
	return primer.button(gtx, shown, current ? .Default : .Invisible, .Medium, leading = leading, count = count, block = true, align = .Start, name = label, key = key, loc = loc)
}

// fit is s, or as much of it as fits width with an ellipsis after, at a
// button's label style.
fit :: proc(gtx: ^ui.Ctx, s: string, width: f32) -> string {
	if !ui.is_finite(width) {
		return s
	}
	st := tok.Type_Style{weight = tok.BASE_TEXT_WEIGHT_MEDIUM, size = tok.TEXT_BODY_SIZE_MEDIUM, line_height = tok.TEXT_BODY_SIZE_MEDIUM * tok.TEXT_BODY_LINE_HEIGHT_MEDIUM}
	font := primer.font_for(gtx, st.weight)
	if design.shape_style(gtx, s, st, font).width <= width {
		return s
	}
	cuts := make([dynamic]int, context.temp_allocator)
	for _, i in s {
		append(&cuts, i)
	}
	lo, hi := 0, len(cuts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if design.shape_style(gtx, fmt.tprintf("%s…", s[:cuts[mid]]), st, font).width <= width {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return fmt.tprintf("%s…", strings.trim_right_space(s[:cuts[lo]]))
}

// --- commands and their outcomes ----------------------------------------------

// send issues a command and remembers it, so the page can show it running
// and the toaster can say how it went. handles are the proposals it is
// about; arg is a review mode or an alias.
send :: proc(gtx: ^ui.Ctx, m: ^Model, kind: Pending_Kind, handles: []string = nil, arg := "", arg2 := "") {
	if m.n_pending == MAX_PENDING {
		primer.toast_push(&m.toasts, tr(m, .Too_Much), .Warning)
		return
	}
	m.next_id += 1
	id := m.next_id
	switch kind {
	case .Approve:
		ui.command(gtx, shapes.Command(shapes.Approve{id = id, handles = handles, to = arg}))
	case .Drop:
		ui.command(gtx, shapes.Command(shapes.Drop{id = id, handles = handles}))
	case .Sync:
		ui.command(gtx, shapes.Command(shapes.Sync_Now{id = id}))
	case .Reindex:
		ui.command(gtx, shapes.Command(shapes.Reindex{id = id}))
	case .Review:
		ui.command(gtx, shapes.Command(shapes.Set_Review{id = id, mode = arg}))
	case .Doctor:
		ui.command(gtx, shapes.Command(shapes.Run_Doctor{id = id}))
	case .Add_Alias:
		ui.command(gtx, shapes.Command(shapes.Add_Alias{id = id, handle = handles[0], term = arg}))
	case .Remove_Alias:
		ui.command(gtx, shapes.Command(shapes.Remove_Alias{id = id, handle = handles[0], term = arg}))
	case .Write_Bullet:
		ui.command(gtx, shapes.Command(shapes.Write_Bullet{id = id, line = arg, to = arg2}))
	case .Replace_Bullet:
		ui.command(gtx, shapes.Command(shapes.Replace_Bullet{id = id, handle = handles[0], line = arg, at = arg2}))
	case .Drop_Bullet:
		ui.command(gtx, shapes.Command(shapes.Drop_Bullet{id = id, handle = handles[0], at = arg}))
	case .Touch_Bullet:
		ui.command(gtx, shapes.Command(shapes.Touch_Bullet{id = id, handle = handles[0], at = arg}))
	case .Import:
		ui.command(gtx, shapes.Command(shapes.Import{id = id, paths = handles}))
	case .Connect:
		ui.command(gtx, shapes.Command(shapes.Connect{id = id, agent = handles[0]}))
	case .New_Vault:
		ui.command(gtx, shapes.Command(shapes.New_Vault{id = id, path = arg}))
	case .Merge:
		ui.command(gtx, shapes.Command(shapes.Merge{id = id, proposal = handles[0], into = handles[1], line = arg, at = arg2}))
	case .Set_Price:
		ui.command(gtx, shapes.Command(shapes.Set_Price{id = id, prefix = handles[0], input = arg, output = arg2}))
	case .Unlink:
		line, _ := strconv.parse_int(arg2)
		ui.command(gtx, shapes.Command(shapes.Unlink{id = id, file = arg, line = line, target = handles[0]}))
	case .Set_Vault:
		ui.command(gtx, shapes.Command(shapes.Set_Vault{id = id, path = arg}))
	}
	p := &m.pending[m.n_pending]
	m.n_pending += 1
	p^ = {id = id, kind = kind, handles = make([]string, len(handles), m.allocator)}
	for h, i in handles {
		p.handles[i] = strings.clone(h, m.allocator)
	}
}

free_handles :: proc(hs: []string, allocator: mem.Allocator) {
	for h in hs {
		delete(h, allocator)
	}
	delete(hs, allocator)
}

// settle_outcomes needs the Outcome of every command in flight, and turns
// each that has landed into a toast.
settle_outcomes :: proc(gtx: ^ui.Ctx, m: ^Model) {
	for i := 0; i < m.n_pending; {
		p := &m.pending[i]
		o, st := ui.need(gtx, shapes.Outcome{id = p.id}, shapes.Outcome_Result)
		if !ready(st) || !o.done {
			i += 1
			continue
		}
		primer.toast_push(&m.toasts, o.message, o.ok ? .Success : .Error)
		if o.ok {
			// A bullet written or renamed is shown once the list holds it.
			#partial switch p.kind {
			case .Write_Bullet:
				choose(&m.editor.awaiting, p.handles[0])
			case .Replace_Bullet:
				choose(&m.editor.awaiting, p.handles[len(p.handles) - 1])
			case .Drop_Bullet:
				m.bullet.len = 0
				m.editor.loaded.len = 0
			case .Set_Price:
				m.spend_gen += 1
				m.pricing.len = 0
			case .Import:
				m.import_pick.gen += 1
				m.setup_gen += 1
			case .Connect, .New_Vault, .Set_Vault:
				m.setup_gen += 1
			}
		}
		free_handles(p.handles, m.allocator)
		m.pending[i] = m.pending[m.n_pending - 1]
		m.n_pending -= 1
	}
}

// waiting_on is whether a command of kind is in flight, about handle when
// one is named.
waiting_on :: proc(m: ^Model, kind: Pending_Kind, handle := "") -> bool {
	for &p in m.pending[:m.n_pending] {
		if p.kind != kind {
			continue
		}
		if handle == "" {
			return true
		}
		for h in p.handles {
			if h == handle {
				return true
			}
		}
	}
	return false
}

// --- shared pieces --------------------------------------------------------------

ready :: proc(st: ui.Status) -> bool {
	return st == .Ready || st == .Stale
}

// Wait is a placeholder's memory of when it began waiting.
@(private)
Wait :: struct {
	since: f64,
	set:   bool,
}

// loading stands in for a shape not yet delivered: nothing for
// LOADING_DELAY, then skeleton lines.
loading :: proc(gtx: ^ui.Ctx, lines := 3, key: u64 = 0, loc := #caller_location) {
	id := ui.claim_id(gtx, key, loc)
	w := ui.widget_data(gtx, id, Wait)
	if !w.set {
		w.since, w.set = gtx.time, true
	}
	if waited := gtx.time - w.since; waited < LOADING_DELAY {
		ui.request_frame(gtx, f32(LOADING_DELAY - waited))
		return
	}
	ui.inset(gtx, ui.pad_all(16))
	ui.column(gtx, gap = 12, align = .Fill)
	for i in 0 ..< lines {
		primer.skeleton_box(gtx, height = 20, key = u64(i + 1))
	}
}

// failed is the banner for a CLI call that did not answer. It reports
// whether there was one, so the page can stop there.
failed :: proc(gtx: ^ui.Ctx, m: ^Model, err: string) -> bool {
	if err == "" {
		return false
	}
	primer.banner(gtx, tr(m, .Vault_Did_Not_Answer), err, .Critical)
	return true
}

// empty is a pane's blank state: what would be here, and why it is not.
empty :: proc(gtx: ^ui.Ctx, heading, description: string, icon: primer.Icon) {
	ui.inset(gtx, ui.pad_all(16))
	primer.blankslate(gtx, heading, description, icon, size = .Small)
}

// mark is brainfold's mark as a widget, size square, in color: bullet
// lines filling a disc, split by a wandering fissure. The geometry is
// the one branding/mark-*.svg was exported from.
mark :: proc(gtx: ^ui.Ctx, size: f32, color: ops.Color) {
	ui.sized(gtx, {min = {size, size}, max = {size, size}})
	R :: 38 // the disc's radius, in the mark's 100 box
	H :: 8 // a bar's height; its ends are semicircles
	BAR_GAP :: 8 // the fissure's width
	ys := [?]f32{20, 32, 44, 56, 68, 80}
	xf := [?]f32{56, 46, 54, 44, 55, 47} // where the fissure crosses each row
	k := size / 100
	for y, i in ys {
		w := math.sqrt(R * R - (y - 50) * (y - 50))
		l, r := 50 - w, 50 + w
		gl, gr := xf[i] - BAR_GAP / 2, xf[i] + BAR_GAP / 2
		for piece in ([2][2]f32{{l, gl}, {gr, r}}) {
			if piece[1] - piece[0] >= 10 {
				ops.fill(gtx.scene, ops.Round_Rect{{piece[0] * k, (y - H / 2) * k, (piece[1] - piece[0]) * k, H * k}, H / 2 * k}, color)
			}
		}
	}
}

// boxed is Primer's Box: a bordered, rounded panel on the page's colour.
boxed :: proc(gtx: ^ui.Ctx, padding: f32 = 0, key: u64 = 0, loc := #caller_location) -> ui.Box {
	s := primer.scheme()
	return ui.box_open(gtx, {fill = s[.Bg_Color_Default], outline = s[.Border_Color_Default], stroke = 1, radius = 6, padding = ui.pad_all(padding)}, key, loc)
}

// stat is one figure in a box: what it counts, the number, and a note on
// one line, so every card in a row is one height; the whole note shows
// on hover. A figure too wide for its card is set smaller, on a line as
// tall as a large one, rather than wrapped.
stat :: proc(gtx: ^ui.Ctx, label, value, note: string, width: f32, key: u64, compact := false) {
	s := primer.scheme()
	pad: f32 = compact ? 12 : 16
	ui.sized(gtx, {min = {width, 0}, max = {width, ui.INF}}, key = key)
	sp := new(Stat_Paint, gtx.allocator)
	sp^ = {ui.claim_id(gtx, key + 0x57a7), fmt.tprintf("stat:%s", label), s[.Bg_Color_Default], s[.Border_Color_Default]}
	b := ui.box_open(gtx, {padding = ui.pad_all(pad), paint = paint_stat, user = sp})
	defer ui.close(&b)
	ui.column(gtx, gap = 4, align = .Fill)
	primer.text(gtx, label, .Small, .Medium, color = s[.Fg_Color_Muted])
	{
		line := primer.heading_style(.Large).line_height
		ui.sized(gtx, {min = {0, line}, max = {ui.INF, line}}, key = 2)
		primer.heading(gtx, value, 3, figure_size(gtx, value, width - 2 * pad))
	}
	if !compact {
		primer.truncate(gtx, note, title = note, max_width = width - 32, size = .Small, color = s[.Fg_Color_Muted], key = 1)
	}
}

// figure_size is the largest heading a figure fits width at, on one line.
figure_size :: proc(gtx: ^ui.Ctx, value: string, width: f32) -> primer.Heading_Variant {
	for v in ([2]primer.Heading_Variant{.Large, .Medium}) {
		st := primer.heading_style(v)
		if design.shape_style(gtx, value, st, primer.font_for(gtx, st.weight)).width <= width {
			return v
		}
	}
	return .Small
}

// Stat_Paint is a figure's box, drawn once its size is known, and named
// with its bounds so a probe can measure it (the layout sweep).
@(private)
Stat_Paint :: struct {
	id:         ops.Area_Id,
	name:       string,
	fill, edge: ops.Color,
}

@(private)
paint_stat :: proc(gtx: ^ui.Ctx, _: ops.Area_Id, size: ops.Size, user: rawptr) {
	sp := (^Stat_Paint)(user)
	ops.fill(gtx.scene, ops.Round_Rect{{0, 0, size.x, size.y}, 6}, sp.fill)
	ops.stroke(gtx.scene, ops.Round_Rect{{0.5, 0.5, size.x - 1, size.y - 1}, 5.5}, sp.edge, {width = 1})
	ops.tag(gtx.scene, sp.id, sp.name, ops.Rect{0, 0, size.x, size.y})
}

// stats is figures sharing width, in one row: at the narrowest body a
// card is still 160 wide, and two rows would take the height the panes
// under them need.
stats :: proc(gtx: ^ui.Ctx, width: f32, items: [][3]string, compact := false) {
	per := len(items)
	w := math.floor((width - GAP * f32(per - 1)) / f32(per))
	ui.column(gtx, gap = GAP)
	for i := 0; i < len(items); i += per {
		ui.row(gtx, gap = GAP, key = u64(i + 1))
		for it, k in items[i:min(i + per, len(items))] {
			stat(gtx, it[0], it[1], it[2], w, u64(i + k + 1), compact)
		}
	}
}

// thousands is n in locale's digits and grouping. English groups from
// four digits: 14219700 is 14,219,700 and 611 stays 611.
thousands :: proc(n: int, locale := i18n.Locale.English) -> string {
	return i18n.number(locale, n)
}

// digits is n in the locale the desk is showing.
digits :: proc(m: ^Model, n: int) -> string {
	return thousands(n, msg.locale(&m.strings))
}

// compact is n at a glance: 14.2M, 378k, 611. The short forms stay;
// a count under 10,000 uses the locale's digits.
compact :: proc(n: int, locale := i18n.Locale.English) -> string {
	switch {
	case n >= 10_000_000:
		return fmt.tprintf("%dM", n / 1_000_000)
	case n >= 1_000_000:
		return fmt.tprintf("%.1fM", f64(n) / 1_000_000)
	case n >= 10_000:
		return fmt.tprintf("%dk", n / 1000)
	}
	return thousands(n, locale)
}

// percent is part of whole, rounded, or "–" for nothing.
percent :: proc(part, whole: int, locale := i18n.Locale.English) -> string {
	if whole == 0 {
		return "–"
	}
	return fmt.tprintf("%s%%", i18n.number(locale, (part * 100 + whole / 2) / whole))
}

// clock is a timestamp to the minute: "2026-10-07 21:59:08" reads
// "2026-10-07 21:59".
clock :: proc(ts: string) -> string {
	return ts[:min(len(ts), 16)]
}

bytes :: proc(n: int) -> string {
	switch {
	case n >= 1 << 20:
		return fmt.tprintf("%.1f MB", f64(n) / (1 << 20))
	case n >= 1 << 10:
		return fmt.tprintf("%.0f KB", f64(n) / (1 << 10))
	}
	return fmt.tprintf("%d B", n)
}
