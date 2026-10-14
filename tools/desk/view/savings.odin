package desk_view

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "jm:i18n"
import "jm:ui"
import "jm:ui/ops"
import "jm:ui/plot"
import plot_primer "jm:ui/plot/primer"
import "jm:ui/primer"

import "../../../msg"
import "../shapes"

// --- Savings -------------------------------------------------------------------

// SPEND_WINDOWS are the days Savings can look back over.
SPEND_WINDOWS :: [3]int{7, 30, 90}

// savings_control is the window the page looks back over.
savings_control :: proc(gtx: ^ui.Ctx, m: ^Model) {
	segments := []primer.Segment{{label = "7d"}, {label = "30d"}, {label = "90d"}}
	primer.segmented_control(gtx, segments, &m.spend_window, tr(m, .Window))
}

// page_savings is what the agents cost and what the vault did to it:
// figures and two charts that never scroll, then where the money went,
// by model and by agent.
page_savings :: proc(gtx: ^ui.Ctx, m: ^Model) {
	windows := SPEND_WINDOWS
	days := windows[clamp(m.spend_window, 0, len(windows) - 1)]
	sp, st := ui.need(gtx, shapes.Spend{days = days, gen = m.spend_gen}, shapes.Spend_Result)
	ui.column(gtx, gap = GAP, align = .Fill)
	if !ready(st) {
		loading(gtx, 6)
		return
	}
	if failed(gtx, m, sp.error) {
		return
	}
	f := &sp.finds
	short := gtx.constraints.max.y < COMPACT_BELOW
	saved, saved_note := "—", tf(m, .Savings_Need, 5, 5, f.hits, f.misses)
	if f.enough {
		saved = dollars(f.saved, msg.locale(&m.strings))
		saved_note = tf(m, .Savings_Observed, f.hits)
	}
	stats(
		gtx,
		body_width(m),
		{
			{tr(m, .Spent), dollars(sp.cost, msg.locale(&m.strings)), sp.unpriced > 0 ? tf(m, .Sessions_Unpriced, sp.sessions) : tf(m, .Sessions_Priced, sp.sessions)},
			{tr(m, .Vault_Cost), dollars(sp.served_cost, msg.locale(&m.strings)), tf(m, .Tokens_Served_Note, compact(int(sp.served), msg.locale(&m.strings)))},
			{tr(m, .Saved_By_Answers), saved, saved_note},
			{tr(m, .Lookups_Answered), percent(sp.answered, sp.lookups, msg.locale(&m.strings)), tf(m, .Of_Count, sp.answered, sp.lookups)},
		},
		short,
	)
	{
		rest := gtx.constraints.max.y - (short ? STAT_COMPACT : STAT_HEIGHT) - 2 * GAP
		ch := clamp(math.floor(rest * 0.5), CHART_MIN, 260)
		ch = max(min(ch, rest - PANE_MIN.y), CHART_MIN - 10)
		ui.sized(gtx, {min = {body_width(m), ch}, max = {body_width(m), ch}})
		arrange(gtx, m)
		w := split(gtx, m, 0.5, 0.5)
		spend_charts(gtx, m, sp, w)
	}
	ui.flexible(gtx, 1)
	arrange(gtx, m)
	w := split(gtx, m, 0.5, 0.5)
	{
		pane(gtx, m, .Spend_Models, w[0], tr(m, .By_Model), len(sp.by_model))
		if len(sp.by_model) == 0 {
			empty(gtx, tr(m, .No_Replies), tr(m, .No_Replies_Body), .Graph)
		} else {
			spend_models(gtx, m, sp)
		}
	}
	pane(gtx, m, .Spend_Agents, w[1], tr(m, .By_Agent), len(sp.by_agent))
	if len(sp.by_agent) == 0 {
		empty(gtx, tr(m, .No_Agents), tr(m, .No_Agents_Body), .Graph)
		return
	}
	l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, .By_Agent))
	for r in sp.by_agent {
		primer.action_list_item(&l, r.name, description = tf(m, .Agent_Sessions, r.sessions, compact(int(r.tokens), msg.locale(&m.strings))), description_variant = .Block, leading = .Comment_Discussion, trailing_text = r.priced ? dollars(r.cost, msg.locale(&m.strings)) : tf(m, .Price_From, dollars(r.cost, msg.locale(&m.strings))))
	}
	primer.action_list_close(&l)
}

// spend_charts is spend a day, and what finishing a reply cost after a
// find that answered against one that missed.
spend_charts :: proc(gtx: ^ui.Ctx, m: ^Model, sp: ^shapes.Spend_Result, w: []ops.Size) {
	style := plot_primer.style(gtx)
	{
		pane(gtx, m, .Chart_Spend, w[0], tr(m, .Spend_A_Day), scroll = false)
		ui.inset(gtx, {16, 8, 16, 8})
		if len(sp.by_day) == 0 {
			empty(gtx, tr(m, .Nothing_Spent), "", .Graph)
		} else {
			// Days on a time axis: a month of day names as bar labels
			// crowds them.
			xs := make([]f64, len(sp.by_day), context.temp_allocator)
			vals := make([]f64, len(sp.by_day), context.temp_allocator)
			for d, i in sp.by_day {
				xs[i] = day_seconds(d.name)
				vals[i] = d.cost
			}
			chart := plot.Line_Chart {
				label  = tr(m, .Spend_A_Day_Label),
				xs     = xs,
				series = []plot.Line_Series{{name = tr(m, .Series_Spent), ys = vals, slot = 0}},
				x      = {kind = .Time},
				y      = {format = {prefix = "$"}, zero = true},
				fill   = .Area,
			}
			plot.line_chart(gtx, &chart, &style)
		}
	}
	pane(gtx, m, .Chart_Finds, w[1], tr(m, .After_Find), scroll = false)
	ui.inset(gtx, {16, 8, 16, 8})
	f := &sp.finds
	if f.hits + f.misses == 0 {
		empty(gtx, tr(m, .No_Finds), tr(m, .No_Finds_Body), .Search)
		return
	}
	chart := plot.Bar_Chart {
		label      = tr(m, .After_Find_Label),
		categories = []string{tf(m, .Answered_N, f.hits), tf(m, .Missed_N, f.misses)},
		series     = []plot.Bar_Series{{name = tr(m, .Series_Median), values = []f64{f.hit_cost, f.miss_cost}, slot = 1}},
		value      = {format = {prefix = "$"}, zero = true},
	}
	plot.bar_chart(gtx, &chart, &style)
}

// spend_models is spend by model, and a price for a model with none.
spend_models :: proc(gtx: ^ui.Ctx, m: ^Model, sp: ^shapes.Spend_Result) {
	s := &m.scheme
	l := primer.action_list_open(gtx, .Full, dividers = true, name = tr(m, .By_Model))
	for r in sp.by_model {
		trailing := r.priced ? dollars(r.cost) : tr(m, .No_Price)
		if primer.action_list_item(&l, r.name, description = tf(m, .Tokens_N, compact(int(r.tokens), msg.locale(&m.strings))), description_variant = .Block, leading = r.priced ? .Graph : .Alert, trailing_text = trailing) && !r.priced {
			choose(&m.pricing, r.name)
			ui.text_set(&m.price_in, "")
			ui.text_set(&m.price_out, "")
		}
	}
	primer.action_list_close(&l)
	model := chosen(&m.pricing)
	if model == "" {
		if sp.unpriced > 0 {
			ui.inset(gtx, {16, 8, 16, 12})
			primer.text(gtx, tr(m, .No_Price_Note), .Small, color = s[.Fg_Color_Muted])
		}
		return
	}
	price_form(gtx, m, model)
}

// price_form sets a model's list price: dollars per million input and
// output tokens; cache writes and reads follow from input.
price_form :: proc(gtx: ^ui.Ctx, m: ^Model, model: string) {
	ui.inset(gtx, {16, 12, 16, 12})
	ui.column(gtx, gap = 8, align = .Fill)
	primer.text(gtx, tf(m, .Price_Model, model), .Small, .Medium)
	tin := strings.trim_space(ui.text_string(&m.price_in))
	tout := strings.trim_space(ui.text_string(&m.price_out))
	vin, iok := strconv.parse_f64(tin)
	vout, ook := strconv.parse_f64(tout)
	ok := iok && ook && vin >= 0 && vout >= 0
	busy := waiting_on(m, .Set_Price, model)
	ui.row(gtx, gap = 8, align = .Center)
	half := max((gtx.constraints.max.x - 170) / 2, 70)
	{
		ui.sized(gtx, {min = {half, 0}, max = {half, ui.INF}})
		primer.text_input(gtx, &m.price_in, placeholder = tr(m, .Input_Price), size = .Small, name = tr(m, .Input_Price_Name))
	}
	{
		ui.sized(gtx, {min = {half, 0}, max = {half, ui.INF}})
		primer.text_input(gtx, &m.price_out, placeholder = tr(m, .Output_Price), size = .Small, name = tr(m, .Output_Price_Name))
	}
	if primer.button(gtx, tr(m, .Save), .Primary, .Small, loading = busy, inactive = !ok) && ok && !busy {
		send(gtx, m, .Set_Price, {model}, tin, tout)
	}
	if primer.button(gtx, tr(m, .Cancel), .Default, .Small) {
		m.pricing.len = 0
	}
}

// dollars is d as money at a glance: $2,456, $27.34, $0.20.
dollars :: proc(d: f64, locale := i18n.Locale.English) -> string {
	if d >= 100 {
		return fmt.tprintf("$%s", thousands(int(math.round(d)), locale))
	}
	return fmt.tprintf("$%.2f", d)
}
