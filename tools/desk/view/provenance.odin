package desk_view

import "core:fmt"
import "core:strings"

import "jm:ui"
import "jm:ui/plot"
import plot_primer "jm:ui/plot/primer"
import "jm:ui/primer"

import "../shapes"

// A bullet's provenance, the Bullets page's second view of it: how it has
// been served, which never scrolls, then where it came from (the agent
// session that proposed it, the vault commits that changed it, what
// brain verify found of its claims), which does.

PROVENANCE_CHART :: 120 // the serves-a-day chart's height

// bullet_tabs switches the bullet shown between editing it and its
// provenance, fixed over the pane.
bullet_tabs :: proc(gtx: ^ui.Ctx, m: ^Model) {
	segments := []primer.Segment{{label = tr(m, .Edit), icon = .Pencil}, {label = tr(m, .Provenance), icon = .History}}
	primer.segmented_control(gtx, segments, &m.bullet_tab, tr(m, .Bullet_View), size = .Small)
}

// provenance is the bullet b's story: what it was served, and where it
// came from.
provenance :: proc(gtx: ^ui.Ctx, m: ^Model, b: shapes.Bullet) {
	s := &m.scheme
	p, st := ui.need(gtx, shapes.Bullet_Show{handle = b.handle, at = place(b)}, shapes.Bullet_Show_Result)
	room := gtx.constraints.max
	ui.inset(gtx, {16, 16, 16, 0})
	ui.column(gtx, gap = GAP, align = .Fill)
	if !ready(st) {
		loading(gtx, 4)
		return
	}
	if failed(gtx, m, p.error) {
		return
	}
	w := room.x - 32
	sv := &p.served
	// What it was served: fixed figures and a chart, a known quantity.
	figures := make([dynamic][3]string, context.temp_allocator)
	append(&figures, [3]string{tr(m, .Usage), digits(m, sv.times), tf(m, .In_Sessions, sv.sessions)})
	append(&figures, [3]string{tr(m, .Last_Served), sv.last != "" ? age(m, days_since(sv.last), ago = true) : tr(m, .Word_Never), sv.first != "" ? tf(m, .First_Served, sv.first[:min(10, len(sv.first))]) : tr(m, .Never_Served)})
	if w >= 480 {
		append(&figures, [3]string{tr(m, .First_Answer), digits(m, sv.top), tf(m, .Of_Serves, sv.times)})
	}
	stats(gtx, w, figures[:], compact = true)
	{
		ui.sized(gtx, {min = {w, PROVENANCE_CHART}, max = {w, PROVENANCE_CHART}})
		serves_chart(gtx, m, sv.days)
	}
	// Where it came from: as long as its history, so it scrolls.
	rest := room.y - 16 - STAT_COMPACT - PROVENANCE_CHART - 2 * GAP
	ui.sized(gtx, {min = {w, max(rest, 0)}, max = {w, max(rest, 0)}})
	ui.scroll_box(gtx, 0x9e0, offset = &m.panes[.Provenance])
	ui.column(gtx, gap = 20, align = .Fill)
	origin(gtx, m, p, b)
	if len(sv.queries) > 0 {
		ui.column(gtx, gap = 4, align = .Fill, key = 2)
		section(gtx, tr(m, .Found_By))
		for q, i in sv.queries {
			ui.row(gtx, gap = 8, align = .Center, key = u64(i + 1))
			{
				ui.sized(gtx, {min = {w - 70, 0}, max = {w - 70, ui.INF}})
				primer.text(gtx, q.query, .Small)
			}
			ui.fill_space(gtx)
			primer.text(gtx, tf(m, .Times, q.times), .Small, color = s[.Fg_Color_Muted])
		}
		callers := make([dynamic]string, context.temp_allocator)
		for c in sv.callers {
			append(&callers, fmt.tprintf("%s %s", c.caller, digits(m, c.times)))
		}
		primer.text(gtx, tf(m, .Served_To, strings.join(callers[:], ", ", context.temp_allocator)), .Small, color = s[.Fg_Color_Muted], key = 99)
	}
	claims(gtx, m, p.claims)
	history(gtx, m, p.history)
}

// section is a heading inside the provenance.
section :: proc(gtx: ^ui.Ctx, title: string) {
	primer.text(gtx, title, .Small, .Medium, color = primer.scheme()[.Fg_Color_Muted])
}

// serves_chart is the bullet's serves a day, the last 30 days.
serves_chart :: proc(gtx: ^ui.Ctx, m: ^Model, days: []shapes.Day_Count) {
	if len(days) == 0 {
		empty(gtx, tr(m, .Not_Served_Lately), tr(m, .Not_Served_Body), .Graph)
		return
	}
	style := plot_primer.style(gtx)
	cats := make([]string, len(days), context.temp_allocator)
	values := make([]f64, len(days), context.temp_allocator)
	for d, i in days {
		cats[i] = len(d.day) >= 10 ? d.day[5:10] : d.day
		values[i] = f64(d.times)
	}
	chart := plot.Bar_Chart {
		label      = tr(m, .Serves_A_Day),
		categories = cats,
		series     = []plot.Bar_Series{{name = tr(m, .Serves), values = values, slot = 0}},
	}
	plot.bar_chart(gtx, &chart, &style)
}

// origin is how the bullet came to be: the session that proposed it, with
// a way to read it, or what the bullet itself says of its source.
origin :: proc(gtx: ^ui.Ctx, m: ^Model, p: ^shapes.Bullet_Show_Result, b: shapes.Bullet) {
	s := &m.scheme
	ui.column(gtx, gap = 8, align = .Fill, key = 1)
	section(gtx, tr(m, .Where_From))
	if p.proposed.session == "" {
		said := b.source != "" ? tf(m, .Source_Says, b.source) : tr(m, .No_Source)
		primer.text(gtx, tf(m, .No_Transcript_Written, said), .Small, color = s[.Fg_Color_Muted])
		return
	}
	pr := &p.proposed
	card := boxed(gtx, 12)
	defer ui.close(&card)
	ui.column(gtx, gap = 8, align = .Fill)
	primer.text(gtx, pr.title != "" ? pr.title : tr(m, .Untitled_Session), .Medium, .Semibold)
	when_ := len(pr.ts) >= 16 ? fmt.tprintf("%s %s", pr.ts[:10], pr.ts[11:16]) : pr.ts
	primer.text(gtx, tf(m, .Proposed_By, pr.agent != "" ? pr.agent : tr(m, .An_Agent), when_), .Small, color = s[.Fg_Color_Muted])
	ui.row(gtx, align = .Center)
	st := ui.stack_open(gtx)
	defer ui.close(&st)
	if primer.button(gtx, tr(m, .Read), .Default, .Small, leading = .Comment_Discussion) {
		read_conversation(m, b.handle, pr.turn)
	}
	primer.tooltip(gtx, tr(m, .Read_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
}

// read_conversation opens Recall on the conversation around turn, kept
// in view while Recall's search is handle, whatever that search finds.
read_conversation :: proc(m: ^Model, handle, turn: string) {
	go(m, .Recall)
	ui.text_set(&m.search, handle)
	choose(&m.turn, turn)
	choose(&m.pin, handle)
	m.panes[.Around] = {}
	m.reveal = true
}

// claims is what brain verify last found of each thing the bullet names.
claims :: proc(gtx: ^ui.Ctx, m: ^Model, cs: []shapes.Claim) {
	s := &m.scheme
	ui.column(gtx, gap = 6, align = .Fill, key = 3)
	section(gtx, tr(m, .Its_Claims))
	if len(cs) == 0 {
		primer.text(gtx, tr(m, .No_Claims), .Small, color = s[.Fg_Color_Muted])
		return
	}
	for c, i in cs {
		ui.row(gtx, gap = 8, align = .Center, key = u64(i + 1))
		primer.label(gtx, c.verdict, c.verdict == "passed" ? .Success : c.verdict == "failed" ? .Danger : .Secondary)
		said := c.why != "" ? fmt.tprintf("%s %s: %s", c.kind, c.text, c.why) : fmt.tprintf("%s %s", c.kind, c.text)
		primer.text(gtx, said, .Small)
		ui.fill_space(gtx)
		primer.text(gtx, c.checked, .Small, color = s[.Fg_Color_Muted])
	}
}

// history is the vault commits that added, changed or moved the bullet,
// newest first.
history :: proc(gtx: ^ui.Ctx, m: ^Model, cs: []shapes.Change) {
	s := &m.scheme
	ui.column(gtx, gap = 6, align = .Fill, key = 4)
	section(gtx, tr(m, .Its_History))
	if len(cs) == 0 {
		primer.text(gtx, tr(m, .No_History), .Small, color = s[.Fg_Color_Muted])
		return
	}
	for c, i in cs {
		ui.column(gtx, gap = 2, align = .Fill, key = u64(i + 1))
		primer.text(gtx, tf(m, .Join_Dot, c.date, c.subject), .Small)
		primer.text(gtx, tf(m, .Join_Dot, c.commit, strings.join(c.files, ", ", context.temp_allocator)), .Small, color = s[.Fg_Color_Muted], key = 1)
	}
}
