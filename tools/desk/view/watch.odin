package desk_view

import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "jm:ui"
import "jm:ui/base"
import "jm:ui/ops"
import "jm:ui/plot"
import plot_primer "jm:ui/plot/primer"
import "jm:ui/primer"

import "../../../msg"
import "../shapes"

// --- Activity ------------------------------------------------------------------

// page_activity is the figures across the top, then two panes: the days,
// and who asks; and the lookups as they come in.
page_activity :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := &m.scheme
	ledger, lst := ui.need(gtx, shapes.Ledger{}, shapes.Ledger_Result)
	log, gst := ui.need(gtx, shapes.Log{}, shapes.Log_Result)
	ui.column(gtx, gap = GAP, align = .Fill)
	if !ready(lst) || !ready(gst) {
		loading(gtx, 6)
		return
	}
	if failed(gtx, m, ledger.error) || failed(gtx, m, log.error) {
		return
	}
	lookups, answered, returned, saved: int
	for c in ledger.callers {
		lookups += c.lookups
		answered += c.answered
		returned += c.tokens_returned
		saved += c.tokens_saved
	}
	sessions := 0
	for c in ledger.callers {
		sessions += c.sessions
	}
	// A short window gives the charts the figures' notes.
	short := gtx.constraints.max.y < COMPACT_BELOW
	stats(
		gtx,
		body_width(m),
		{
			{tr(m, .Stat_Lookups), digits(m, lookups), tf(m, .Sessions, sessions)},
			{tr(m, .Stat_Answered), percent(answered, lookups, msg.locale(&m.strings)), tf(m, .Found_Of, answered, lookups)},
			{tr(m, .Stat_Tokens_Served), compact(returned, msg.locale(&m.strings)), tf(m, .Per_Lookup, compact(returned / max(lookups, 1), msg.locale(&m.strings)))},
			{tr(m, .Stat_Tokens_Saved), compact(max(saved, 0), msg.locale(&m.strings)), tf(m, .Against_Reading, compact(ledger.baseline_tokens, msg.locale(&m.strings)))},
		},
		short,
	)
	// The charts are a known quantity: a row of their own that never
	// scrolls, as tall as the window leaves room for beside the lists.
	{
		rest := gtx.constraints.max.y - (short ? STAT_COMPACT : STAT_HEIGHT) - 2 * GAP
		// Half of what is left, within bounds, and never so much that the
		// lists under it fall short of PANE_MIN.
		ch := clamp(math.floor(rest * 0.5), CHART_MIN, 260)
		ch = max(min(ch, rest - PANE_MIN.y), CHART_MIN - 10)
		ui.sized(gtx, {min = {body_width(m), ch}, max = {body_width(m), ch}})
		arrange(gtx, m)
		w := split(gtx, m, 0.5, 0.5)
		trend_charts(gtx, m, ledger, w)
	}
	ui.flexible(gtx, 1)
	arrange(gtx, m)
	w := split(gtx, m, 0.5, 0.5)
	{
		pane(gtx, m, .Lookups, w[0], tr(m, .Recent_Lookups), len(log.recent))
		if len(log.recent) == 0 {
			empty(gtx, tr(m, .No_Lookups), tr(m, .No_Lookups_Body), .Search)
		} else {
			l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, .Recent_Lookups))
			for r in log.recent {
				hits := r.hits == 0 ? tr(m, .No_Hits) : tf(m, .Hits, r.hits)
				// Wrapped, not truncated: a truncated label drew its ellipsis
				// against the trailing count. Who and when go under it, so a
				// long query does not squeeze them into a column of their own.
				if primer.action_list_item(&l, r.query, description = tf(m, .Join_Dot, r.caller, clock(r.ts)), description_variant = .Block, leading = r.hits == 0 ? .Alert : .Search, trailing_text = hits) {
					// A lookup leads to what was said about it.
					go(m, .Recall)
					ui.text_set(&m.search, r.query)
					m.turn.len = 0
				}
			}
			primer.action_list_close(&l)
		}
	}
	pane(gtx, m, .Days, w[1], tr(m, .Most_Served), len(ledger.top_bullets))
	if len(ledger.top_bullets) == 0 {
		empty(gtx, tr(m, .Nothing_Served), tr(m, .Nothing_Served_Body), .Book)
	} else {
		l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, .Most_Served))
		for b in ledger.top_bullets {
			if primer.action_list_item(&l, b.handle, description = tf(m, .File_Sessions, b.file, b.sessions), description_variant = .Block, leading = .Book, trailing_text = tf(m, .Times, b.served)) {
				// A bullet leads to itself, to read or correct.
				open_bullet(m, b.handle)
			}
		}
		primer.action_list_close(&l)
	}
	if len(log.callers) > 0 {
		base.divider(gtx, s[.Border_Color_Default], key = 0xca11)
		{
			ui.inset(gtx, {16, 12, 16, 4}, key = 0xca12)
			primer.heading(gtx, tr(m, .Who_Asks), 3, .Small)
		}
		c := primer.action_list_open(gtx, .Full, name = tr(m, .Callers), key = 0xca13)
		for x in log.callers {
			primer.action_list_item(&c, x.caller, description = tf(m, .Caller_Line, x.queries, x.sessions, x.misses, bytes(x.bytes)), description_variant = .Block, leading = .Copilot)
		}
		primer.action_list_close(&c)
	}
}

// STAT_HEIGHT is a figure card's height: label, number and note, padded;
// STAT_COMPACT the same without the note, in a page under COMPACT_BELOW.
STAT_HEIGHT :: 126
STAT_COMPACT :: 96
COMPACT_BELOW :: 600

// CHART_MIN is the least a chart's pane is given: below it the plot is a
// strip too thin to read.
CHART_MIN :: 170

// trend_charts is the vault's worth over the ledger's days, each chart a
// pane of its own that does not scroll: how many lookups each day
// answered and missed, and the tokens saved so far.
trend_charts :: proc(gtx: ^ui.Ctx, m: ^Model, ledger: ^shapes.Ledger_Result, w: []ops.Size) {
	style := plot_primer.style(gtx)
	n := len(ledger.days)
	// The ledger's days come newest first; the charts read oldest first.
	days := make([]string, n, context.temp_allocator)
	answered := make([]f64, n, context.temp_allocator)
	missed := make([]f64, n, context.temp_allocator)
	xs := make([]f64, n, context.temp_allocator)
	saved := make([]f64, n, context.temp_allocator)
	total: f64
	for k in 0 ..< n {
		d := ledger.days[n - 1 - k]
		days[k] = len(d.day) >= 10 ? d.day[5:10] : d.day
		answered[k] = f64(d.answered)
		missed[k] = f64(d.lookups - d.answered)
		xs[k] = day_seconds(d.day)
		total += f64(max(d.tokens_saved, 0))
		saved[k] = total
	}
	{
		pane(gtx, m, .Chart_Lookups, w[0], tr(m, .Lookups_A_Day), scroll = false)
		ui.inset(gtx, {16, 8, 16, 8})
		if n == 0 {
			empty(gtx, tr(m, .No_Lookups), "", .Pulse)
		} else {
			series := []plot.Bar_Series{{name = tr(m, .Series_Answered), values = answered, slot = 0}, {name = tr(m, .Series_Missed), values = missed, slot = 3}}
			chart := plot.Bar_Chart {
				label      = tr(m, .Chart_Lookups),
				categories = days,
				series     = series,
				stacked    = true,
			}
			plot.bar_chart(gtx, &chart, &style)
		}
	}
	pane(gtx, m, .Chart_Saved, w[1], tr(m, .Tokens_Saved_So_Far), scroll = false)
	ui.inset(gtx, {16, 8, 16, 8})
	if n < 2 {
		empty(gtx, tr(m, .Trend_Needs_Two), tr(m, .Trend_Needs_Two_Body), .Graph)
		return
	}
	series := []plot.Line_Series{{name = tr(m, .Series_Tokens_Saved), ys = saved, slot = 1}}
	chart := plot.Line_Chart {
		label  = tr(m, .Tokens_Saved_So_Far),
		xs     = xs,
		series = series,
		x      = {kind = .Time},
		y      = {format = {short = .Finance}, zero = true},
		fill   = .Area,
	}
	plot.line_chart(gtx, &chart, &style)
}

// day_seconds is a YYYY-MM-DD day as Unix seconds at its UTC midnight.
day_seconds :: proc(day: string) -> f64 {
	if len(day) < 10 {
		return 0
	}
	y, _ := strconv.parse_int(day[0:4])
	mo, _ := strconv.parse_int(day[5:7])
	d, _ := strconv.parse_int(day[8:10])
	t, ok := time.components_to_time(y, mo, d, 0, 0, 0)
	if !ok {
		return 0
	}
	return f64(time.to_unix_seconds(t))
}

// --- Misses --------------------------------------------------------------------

// page_misses is the queries that keep missing, and for the one chosen,
// what the transcripts say about it, so the bullet it wants can be written.
page_misses :: proc(gtx: ^ui.Ctx, m: ^Model) {
	s := &m.scheme
	log, st := ui.need(gtx, shapes.Log{}, shapes.Log_Result)
	arrange(gtx, m)
	w := split_list(gtx, m)
	if !ready(st) {
		pane(gtx, m, .Misses, w[0], tr(m, .Still_Missing))
		loading(gtx)
		return
	}
	current := chosen(&m.miss)
	found := false
	for x in log.backlog {
		found ||= x.query == current
	}
	if !found && len(log.backlog) > 0 {
		choose(&m.miss, log.backlog[0].query)
		current = chosen(&m.miss)
	}
	list: {
		pane(gtx, m, .Misses, w[0], tr(m, .Still_Missing), len(log.backlog))
		if failed(gtx, m, log.error) {
			return
		}
		if len(log.backlog) == 0 {
			empty(gtx, tr(m, .Nothing_Missing), tr(m, .Nothing_Missing_Body), .Check_Circle)
		}
		l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, .Still_Missing))
		for x in log.backlog {
			if primer.action_list_item(&l, x.query, description = tf(m, .Missed_Times, x.misses, clock(x.last)), description_variant = .Block, truncate = true, leading = .Question, active = x.query == current) {
				choose(&m.miss, x.query)
			}
		}
		primer.action_list_close(&l)
		if len(log.answered) > 0 {
			base.divider(gtx, s[.Border_Color_Default], key = 0xa5)
			ui.inset(gtx, {16, 12, 16, 4}, key = 0xa6)
			ui.row(gtx, gap = 8, align = .Center)
			primer.heading(gtx, tr(m, .Answered_Since), 3, .Small)
			primer.counter_label(gtx, digits(m, len(log.answered)))
		}
		if len(log.answered) > 0 {
			a := primer.action_list_open(gtx, .Full, name = tr(m, .Answered_Since), key = 0xa7)
			for q in log.answered {
				primer.action_list_item(&a, q, truncate = true, leading = .Check)
			}
			primer.action_list_close(&a)
		}
	}
	{
		pane(gtx, m, .Miss_Detail, w[1], bar = current != "" ? miss_actions : nil)
		if current == "" {
			if len(log.backlog) == 0 {
				empty(gtx, tr(m, .Nothing_To_Look), tr(m, .Nothing_To_Look_Body), .Question)
			} else {
				empty(gtx, tr(m, .Nothing_To_Look), tr(m, .Nothing_To_Look_Choose), .Question)
			}
			return
		}
		miss_detail(gtx, m, current)
	}
}

// miss_actions is a miss's bar: write the bullet it wants, or read what
// was said about it in Recall.
miss_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	query := chosen(&m.miss)
	if query == "" {
		return
	}
	ui.row(gtx, gap = 8, align = .Center)
	{
		st := ui.stack_open(gtx)
		defer ui.close(&st)
		if primer.button(gtx, tr(m, .Write), .Primary, .Small, leading = .Plus) {
			draft(m, query, query)
		}
		primer.tooltip(gtx, tr(m, .Write_Bullet_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	}
	{
		st := ui.stack_open(gtx)
		defer ui.close(&st)
		if primer.button(gtx, tr(m, .Search), .Default, .Small, leading = .Comment_Discussion) {
			go(m, .Recall)
			ui.text_set(&m.search, query)
			m.turn.len = 0
		}
		primer.tooltip(gtx, tr(m, .Search_Recall_Tip), ui.last_widget(gtx), delay = TOOLTIP_DELAY)
	}
}

// miss_detail is one miss: how often, and what was said about it, each
// turn a way into Recall.
miss_detail :: proc(gtx: ^ui.Ctx, m: ^Model, query: string) {
	s := &m.scheme
	{
		ui.inset(gtx, {16, 16, 16, 8})
		ui.column(gtx, gap = 8, align = .Fill)
		primer.heading(gtx, query, 2, .Small)
		primer.text(gtx, tr(m, .No_Bullet_Yet), .Small, color = s[.Fg_Color_Muted])
	}
	res, st := ui.need(gtx, shapes.Recall{terms = query, limit = 10}, shapes.Recall_Result)
	if !ready(st) {
		loading(gtx, 3)
		return
	}
	if failed(gtx, m, res.error) {
		return
	}
	if len(res.turns) == 0 {
		empty(gtx, tr(m, .Nothing_Said), tr(m, .Nothing_Said_Body), .Comment_Discussion)
		return
	}
	l := primer.action_list_open(gtx, .Full, dividers = true, heading = tr(m, .Said_About), heading_level = 3)
	for t in res.turns {
		if primer.action_list_item(&l, t.title, description = t.snippet, description_variant = .Block, leading = .Comment_Discussion, trailing_text = t.agent) {
			go(m, .Recall)
			ui.text_set(&m.search, query)
			choose(&m.turn, t.id)
		}
	}
	primer.action_list_close(&l)
}

// --- Recall --------------------------------------------------------------------

// recall_bar is the search, fixed above the panes.
recall_bar :: proc(gtx: ^ui.Ctx, m: ^Model) {
	terms := strings.trim_space(ui.text_string(&m.search))
	searching := terms != "" && chosen(&m.shown) != terms
	primer.text_input(gtx, &m.search, placeholder = tr(m, .Search_Placeholder), size = .Large, leading = .Search, loading = searching, name = tr(m, .Search_Transcripts))
}

// page_recall is the turns that match, and the conversation around the
// one chosen. A search being run keeps the last answer up until its own
// lands, so the list never blanks between keys.
page_recall :: proc(gtx: ^ui.Ctx, m: ^Model) {
	terms := strings.trim_space(ui.text_string(&m.search))
	res, st := ui.need(gtx, shapes.Recall{terms = terms, limit = RECALL_LIMIT}, shapes.Recall_Result)
	if ready(st) {
		choose(&m.shown, terms)
	} else if shown := chosen(&m.shown); shown != "" && terms != "" {
		res, st = ui.need(gtx, shapes.Recall{terms = shown, limit = RECALL_LIMIT}, shapes.Recall_Result)
	}
	arrange(gtx, m)
	w := split_list(gtx, m)
	turns: []shapes.Turn
	if ready(st) && res.error == "" {
		turns = res.turns
	}
	current := chosen(&m.turn)
	found := false
	for t in turns {
		found ||= t.id == current
	}
	// A turn opened from elsewhere (a bullet's provenance) stays shown
	// while the search it was opened under does, found by it or not.
	pinned := current != "" && terms != "" && chosen(&m.pin) == terms
	if !found && !pinned && len(turns) > 0 {
		choose(&m.turn, turns[0].id)
		current = chosen(&m.turn)
	}
	list: {
		pane(gtx, m, .Turns, w[0], tr(m, .Turns), ready(st) && terms != "" ? len(turns) : -1)
		switch {
		case terms == "":
			empty(gtx, tr(m, .Search_Agents), tr(m, .Search_Agents_Body), .Comment_Discussion)
		case !ready(st):
			loading(gtx, 4)
		case failed(gtx, m, res.error):
		case len(turns) == 0:
			empty(gtx, tr(m, .Nothing_Said_That), tr(m, .Nothing_Said_That_Body), .Search)
		case:
			l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, .Turns))
			for t in turns {
				if primer.action_list_item(&l, t.title, description = tf(m, .Join_Dot3, t.agent, t.date, t.snippet), description_variant = .Block, leading = .Comment_Discussion, active = t.id == current) {
					choose(&m.turn, t.id)
					m.pin.len = 0
					m.panes[.Around] = {}
					m.reveal = true
				}
			}
			primer.action_list_close(&l)
		}
	}
	{
		pane(gtx, m, .Around, w[1])
		if current == "" || (len(turns) == 0 && !pinned) {
			empty(gtx, tr(m, .Conversation_Here), tr(m, .Conversation_Here_Body), .Comment_Discussion)
			return
		}
		around(gtx, m, current)
	}
}

// around is the conversation a turn sits in, oldest first, the turn
// itself marked.
around :: proc(gtx: ^ui.Ctx, m: ^Model, id: string) {
	s := &m.scheme
	a, st := ui.need(gtx, shapes.Around{id = id}, shapes.Around_Result)
	if !ready(st) {
		loading(gtx, 6)
		return
	}
	if failed(gtx, m, a.error) {
		return
	}
	detail: {
		ui.inset(gtx, {16, 16, 16, 4})
		ui.column(gtx, gap = 4, align = .Fill)
		primer.heading(gtx, a.title != "" ? a.title : tr(m, .Untitled_Session), 2, .Small)
		primer.text(gtx, tf(m, .Session_Id, a.session), .Small, color = s[.Fg_Color_Muted])
	}
	for t, i in a.turns {
		ui.inset(gtx, {16, 8, 16, 8}, key = u64(i + 1))
		fill := t.hit ? s[.Bg_Color_Accent_Muted] : t.role == "user" ? s[.Bg_Color_Muted] : s[.Bg_Color_Default]
		edge := t.hit ? s[.Border_Color_Accent_Emphasis] : s[.Border_Color_Muted]
		b := ui.box_open(gtx, {fill = fill, outline = edge, stroke = 1, radius = 6, padding = ui.pad_all(12)})
		defer ui.close(&b)
		// The turn opened is brought into view once, its top first.
		if t.hit && m.reveal {
			ui.scroll_into_view(gtx, {0, 0, 1, 240})
			m.reveal = false
		}
		ui.column(gtx, gap = 6, align = .Fill)
		{
			ui.row(gtx, gap = 8, align = .Center)
			primer.label(gtx, t.role, t.role == "user" ? .Accent : .Secondary)
			ts, _ := strings.replace_all(t.ts, "T", " ", context.temp_allocator)
			primer.text(gtx, clock(ts), .Small, color = s[.Fg_Color_Muted])
			if t.hit {
				primer.label(gtx, tr(m, .The_Match), .Primary, key = 1)
			}
		}
		primer.text(gtx, t.body, key = 2)
	}
}
