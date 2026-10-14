package desk_view

import "core:fmt"
import "core:strings"
import "core:time"

import "jm:ui"
import "jm:ui/ops"
import "jm:ui/primer"

import "../shapes"

// Editor is the bullet being written or edited: its fields as typed, and
// which bullet they were loaded from. A new bullet has no handle loaded.
Editor :: struct {
	loaded:   Chosen, // the handle whose values the fields hold; empty for a new bullet
	drafting: bool, // a new bullet, not yet written
	to:       int, // a new bullet's core file, an index into the list's files
	evidence: Chosen, // the miss a new bullet answers, whose transcripts are shown beside it
	handle:   ui.Text_State,
	aliases:  ui.Text_State,
	fact:     ui.Text_State,
	source:   ui.Text_State,
	date:     ui.Text_State,
	dropping: bool, // the drop confirmation is open
	awaiting: Chosen, // a bullet just written or renamed, chosen once the list holds it
	frame:    Editor_Frame, // what the editor worked out this frame, for its footer
}

// Editor_Frame is the editor's state as the frame found it: the line the
// fields make, and whether it may be written.
Editor_Frame :: struct {
	line:    string,
	dirty:   bool,
	ok:      bool,
	busy:    bool,
	handle:  string, // the bullet edited; "" for a new one
	to:      string, // a new bullet's file, as brain bullet write names it
	current: shapes.Bullet,
}

// editor_actions is the editor's footer: write or discard a new bullet;
// save, revert or drop one that exists.
editor_actions :: proc(gtx: ^ui.Ctx, m: ^Model) {
	e := &m.editor
	f := &e.frame
	ui.row(gtx, gap = 8, align = .Center)
	if e.drafting {
		if fix_button(gtx, "Write", "Write the bullet into the vault.", .Primary, .Check, loading = waiting_on(m, .Write_Bullet), inactive = !f.ok) && f.ok {
			send(gtx, m, .Write_Bullet, {strings.trim_space(ui.text_string(&e.handle))}, f.line, f.to)
		}
		if primer.button(gtx, "Discard", .Default, inactive = f.busy) && !f.busy {
			e.drafting = false
			e.loaded.len = 0
		}
		return
	}
	if f.handle == "" {
		return
	}
	if primer.button(gtx, "Save", .Primary, leading = .Check, loading = waiting_on(m, .Replace_Bullet), inactive = !f.ok) && f.ok {
		send(gtx, m, .Replace_Bullet, {f.handle, strings.trim_space(ui.text_string(&e.handle))}, f.line, place(f.current))
	}
	if primer.button(gtx, "Revert", .Default, inactive = !f.dirty || f.busy) && f.dirty && !f.busy {
		load(e, f.current)
	}
	ui.fill_space(gtx)
	if primer.button(gtx, "Drop", .Danger, leading = .Trash, loading = waiting_on(m, .Drop_Bullet), inactive = f.busy) && !f.busy {
		e.dropping = true
	}
}

editor_init :: proc(e: ^Editor, allocator := context.allocator) {
	for f in ([5]^ui.Text_State{&e.handle, &e.aliases, &e.fact, &e.source, &e.date}) {
		f.buf = make([dynamic]u8, allocator)
	}
}

editor_destroy :: proc(e: ^Editor) {
	for f in ([5]^ui.Text_State{&e.handle, &e.aliases, &e.fact, &e.source, &e.date}) {
		delete(f.buf)
	}
}

// load puts b's values in the fields.
load :: proc(e: ^Editor, b: shapes.Bullet) {
	ui.text_set(&e.handle, b.handle)
	ui.text_set(&e.aliases, b.aliases)
	ui.text_set(&e.fact, b.fact)
	ui.text_set(&e.source, b.source)
	ui.text_set(&e.date, b.date)
	choose(&e.loaded, b.handle)
	e.drafting = false
}

// draft starts a new bullet, named for what it answers when it answers a
// miss, dated today; source, when set, is where it came from.
draft :: proc(m: ^Model, handle := "", evidence := "", source := "") {
	go(m, .Bullets)
	e := &m.editor
	ui.text_set(&e.handle, handle)
	ui.text_set(&e.aliases, "")
	ui.text_set(&e.fact, "")
	ui.text_set(&e.source, source)
	ui.text_set(&e.date, today())
	e.loaded.len = 0
	e.drafting = true
	choose(&e.evidence, evidence)
	m.panes[.Bullet] = {}
}

// place is where b is, FILE:LINE, which names it where two bullets share
// its handle; "" for no bullet.
place :: proc(b: shapes.Bullet) -> string {
	if b.file == "" {
		return ""
	}
	return fmt.tprintf("%s:%d", b.file, b.line)
}

// today is the date as a bullet carries it, YYYY-MM-DD.
today :: proc() -> string {
	y, mo, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
}

// compose is the bullet the fields make, as it is written: the handle, its
// aliases, the fact, the source when there is one, and the date.
compose :: proc(e: ^Editor) -> string {
	handle := strings.trim_space(ui.text_string(&e.handle))
	aliases := strings.trim_space(ui.text_string(&e.aliases))
	fact := strings.trim_space(ui.text_string(&e.fact))
	source := strings.trim_space(ui.text_string(&e.source))
	date := strings.trim_space(ui.text_string(&e.date))
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "- **%s**", handle)
	if aliases != "" {
		fmt.sbprintf(&b, " (aliases: %s)", aliases)
	}
	fmt.sbprintf(&b, " — %s", fact)
	if source != "" {
		fmt.sbprintf(&b, " — %s", source)
	}
	fmt.sbprintf(&b, " — %s", date)
	return strings.to_string(b)
}

// changed is whether the fields differ from b.
changed :: proc(e: ^Editor, b: shapes.Bullet) -> bool {
	return(
		strings.trim_space(ui.text_string(&e.handle)) != b.handle ||
		strings.trim_space(ui.text_string(&e.aliases)) != b.aliases ||
		strings.trim_space(ui.text_string(&e.fact)) != b.fact ||
		strings.trim_space(ui.text_string(&e.source)) != b.source ||
		strings.trim_space(ui.text_string(&e.date)) != b.date \
	)
}

// bullets_control is the Bullets page's own control: a new bullet.
bullets_control :: proc(gtx: ^ui.Ctx, m: ^Model) {
	st := ui.stack_open(gtx)
	defer ui.close(&st)
	if primer.button(gtx, "New", .Primary, .Medium, leading = .Plus) {
		draft(m)
	}
	primer.tooltip(gtx, "Write a bullet by hand: a handle, the names it answers to, one fact, where it came from and when.", ui.last_widget(gtx), delay = TOOLTIP_DELAY)
}

// bullets_bar is the list's search and file filter, fixed over it.
bullets_bar :: proc(gtx: ^ui.Ctx, m: ^Model) {
	ui.column(gtx, gap = 8, align = .Fill)
	primer.text_input(gtx, &m.filter, placeholder = "Search bullets", size = .Small, leading = .Search, name = "Search bullets")
	list, st := ui.need(gtx, shapes.Bullets{}, shapes.Bullets_Result)
	if !ready(st) {
		return
	}
	options := make([]primer.Select_Option, len(list.files) + 1, context.temp_allocator)
	options[0] = {label = "Every file"}
	for f, i in list.files {
		options[i + 1] = {label = f}
	}
	m.file_filter = clamp(m.file_filter, 0, len(list.files))
	primer.select(gtx, options, &m.file_filter, size = .Small, block = true, name = "File")
}

// Haystacks is each bullet's handle, aliases and fact in lower case, what
// the search reads, made once a delivery of the list: making them every
// frame was most of a frame.
Haystacks :: struct {
	version: u64,
	text:    [dynamic]string,
}

haystacks :: proc(m: ^Model, list: ^shapes.Bullets_Result, version: u64) -> []string {
	h := &m.haystacks
	if h.version == version && len(h.text) == len(list.bullets) {
		return h.text[:]
	}
	for x in h.text {
		delete(x, m.allocator)
	}
	clear(&h.text)
	if h.text == nil {
		h.text = make([dynamic]string, m.allocator)
	}
	for b in list.bullets {
		joined := strings.concatenate({b.handle, " ", b.aliases, " ", b.fact}, context.temp_allocator)
		append(&h.text, strings.to_lower(joined, m.allocator))
	}
	h.version = version
	return h.text[:]
}

// matching is the bullets the search and file filter let through.
matching :: proc(m: ^Model, list: ^shapes.Bullets_Result, version: u64) -> []shapes.Bullet {
	terms := strings.fields(strings.to_lower(ui.text_string(&m.filter), context.temp_allocator), context.temp_allocator)
	file := m.file_filter > 0 && m.file_filter <= len(list.files) ? list.files[m.file_filter - 1] : ""
	if len(terms) == 0 && file == "" {
		return list.bullets
	}
	hay := haystacks(m, list, version)
	out := make([dynamic]shapes.Bullet, context.temp_allocator)
	outer: for b, i in list.bullets {
		if file != "" && b.file != file {
			continue
		}
		text := hay[i]
		for t in terms {
			if !strings.contains(text, t) {
				continue outer
			}
		}
		append(&out, b)
	}
	return out[:]
}

// page_bullets is the vault's bullets, searched, and the one chosen in an
// editor: change it, re-date it, drop it, or write a new one.
page_bullets :: proc(gtx: ^ui.Ctx, m: ^Model) {
	list, st, version := ui.need_versioned(gtx, shapes.Bullets{}, shapes.Bullets_Result)
	defer drop_confirm(gtx, m)
	arrange(gtx, m)
	w := split_list(gtx, m)
	if !ready(st) {
		pane(gtx, m, .Bullets, w[0], "Bullets")
		loading(gtx, 6)
		return
	}
	shown := matching(m, list, version)
	e := &m.editor
	if want := chosen(&e.awaiting); want != "" {
		for b in list.bullets {
			if b.handle == want {
				choose(&m.bullet, want)
				e.drafting = false
				e.loaded.len = 0
				e.awaiting.len = 0
				break
			}
		}
	}
	current: ^shapes.Bullet
	if !e.drafting {
		for &b in list.bullets {
			if b.handle == chosen(&m.bullet) {
				current = &b
			}
		}
		if current == nil && chosen(&e.awaiting) == "" && len(shown) > 0 {
			choose(&m.bullet, shown[0].handle)
			current = &shown[0]
		}
		if current != nil && chosen(&e.loaded) != current.handle {
			load(e, current^)
		}
	}
	list_pane: {
		pane(gtx, m, .Bullets, w[0], "Bullets", len(shown), bar = bullets_bar, scroll = false)
		if failed(gtx, list.error) {
			break list_pane
		}
		if len(shown) == 0 {
			empty(gtx, "No bullet matches", "Try fewer words, or every file.", .Search)
			break list_pane
		}
		// Only the rows in view are laid out: 300 bullets wrapped in full
		// every frame cost 95 ms a frame.
		rows := new(Rows, gtx.allocator)
		rows^ = {m, shown}
		ui.list(gtx, &m.bullet_list, len(shown), bullet_row, rows)
	}
	editing := e.drafting || current != nil
	// A bullet that exists has a provenance as well as fields; a draft has
	// only fields.
	tabs := !e.drafting && current != nil
	story := tabs && m.bullet_tab == 1
	pane(gtx, m, .Bullet, w[1], bar = tabs ? bullet_tabs : nil, scroll = !story, footer = editing && !story ? editor_actions : nil)
	if !editing {
		empty(gtx, "Nothing chosen", "Choose a bullet to read and edit it, or write a new one.", .Book)
		return
	}
	if story {
		provenance(gtx, m, current^)
		return
	}
	editor(gtx, m, list, current)
}

// Rows is what the bullets list's rows read: the model and the bullets shown.
@(private)
Rows :: struct {
	m:     ^Model,
	shown: []shapes.Bullet,
}

// ROW_HEIGHT is a bullet row: its handle and its fact, a line each.
ROW_HEIGHT :: 56

// Row_Hover is whether the pointer is over a bullet row.
@(private)
Row_Hover :: struct {
	over: bool,
}

// bullet_row is one bullet in the list: its handle and the start of its
// fact, one line each, so every row is ROW_HEIGHT and the list can place
// rows it has not laid out. A click chooses it.
bullet_row :: proc(gtx: ^ui.Ctx, i: int, user: rawptr) {
	r := (^Rows)(user)
	m := r.m
	b := r.shown[i]
	s := &m.scheme
	w := gtx.constraints.max.x
	current := !m.editor.drafting && b.handle == chosen(&m.bullet)
	id := ui.claim_id(gtx)
	hover := ui.widget_data(gtx, id, Row_Hover)
	for e in ui.events(gtx, id) {
		#partial switch e.kind {
		case .Enter:
			hover.over = true
		case .Leave:
			hover.over = false
		case .Release:
			choose(&m.bullet, b.handle)
			m.editor.drafting = false
			m.panes[.Bullet] = {}
		}
	}
	ui.sized(gtx, {min = {w, ROW_HEIGHT}, max = {w, ROW_HEIGHT}})
	if current {
		ops.fill(gtx.scene, ops.Rect{0, 0, w, ROW_HEIGHT}, s[.Bg_Color_Neutral_Muted])
		ops.fill(gtx.scene, ops.Round_Rect{{0, 8, 3, ROW_HEIGHT - 16}, 1.5}, s[.Bg_Color_Accent_Emphasis])
	} else if hover.over {
		ops.fill(gtx.scene, ops.Rect{0, 0, w, ROW_HEIGHT}, s[.Bg_Color_Neutral_Muted])
	}
	ops.fill(gtx.scene, ops.Rect{12, ROW_HEIGHT - 1, w - 24, 1}, s[.Border_Color_Muted])
	ops.input_area(gtx.scene, id, ops.Rect{0, 0, w, ROW_HEIGHT}, {.Press, .Release, .Enter, .Leave}, .Pointer)
	ops.tag(gtx.scene, id, b.handle, ops.Rect{0, 0, w, ROW_HEIGHT})
	ui.inset(gtx, {16, 9, 16, 0})
	ui.column(gtx, gap = 2, align = .Fill)
	primer.truncate(gtx, b.handle, max_width = w - 32, weight = .Semibold, key = 1)
	primer.truncate(gtx, b.fact, max_width = w - 32, size = .Small, color = s[.Fg_Color_Muted], key = 2)
}

// editor is the fields of the bullet chosen or being written, what lint
// says of them, and what can be done.
editor :: proc(gtx: ^ui.Ctx, m: ^Model, list: ^shapes.Bullets_Result, current: ^shapes.Bullet) {
	s := &m.scheme
	e := &m.editor
	line := compose(e)
	dirty := e.drafting || (current != nil && changed(e, current^))
	busy := waiting_on(m, .Write_Bullet) || waiting_on(m, .Replace_Bullet) || waiting_on(m, .Drop_Bullet) || chosen(&e.awaiting) != ""
	ui.inset(gtx, ui.pad_all(16))
	ui.column(gtx, gap = 12, align = .Fill)
	{
		ui.wrap(gtx, gap = 8, line_gap = 4, align = .Center)
		if e.drafting {
			primer.heading(gtx, "New bullet", 2, .Medium)
		} else if current != nil {
			primer.heading(gtx, current.handle, 2, .Medium)
			primer.label(gtx, fmt.tprintf("%s:%d", current.file, current.line), .Secondary)
			if days := days_since(current.date); days >= 0 {
				primer.label(gtx, age(days), days > 90 ? .Attention : .Secondary, key = 1)
			}
		}
	}
	if e.drafting && len(list.files) > 0 {
		ui.column(gtx, gap = 4, align = .Fill, key = 1)
		primer.text(gtx, "File", .Small, .Medium, color = s[.Fg_Color_Muted])
		options := make([]primer.Select_Option, len(list.files), context.temp_allocator)
		for f, i in list.files {
			options[i] = {label = f}
		}
		e.to = clamp(e.to, 0, len(list.files) - 1)
		primer.select(gtx, options, &e.to, size = .Small, block = true, name = "File", key = 2)
	}
	field(gtx, "Handle", "the name it is found by", &e.handle, key = 3)
	{
		// Wrapped, not one line: an alias list runs long, and a field that
		// scrolls sideways hides most of it.
		ui.column(gtx, gap = 4, align = .Fill, key = 4)
		primer.text(gtx, "Aliases", .Small, .Medium, color = s[.Fg_Color_Muted])
		primer.textarea(gtx, &e.aliases, placeholder = "other names, comma-separated", rows = 1, resize = .None, auto_size = true, block = true, name = "Aliases")
	}
	{
		ui.column(gtx, gap = 4, align = .Fill, key = 5)
		primer.text(gtx, "Fact", .Small, .Medium, color = s[.Fg_Color_Muted])
		primer.textarea(gtx, &e.fact, placeholder = "One fact, stated once", rows = 4, resize = .None, block = true, name = "Fact")
	}
	field(gtx, "Source", "a file, commit or session", &e.source, key = 6)
	{
		ui.row(gtx, gap = 8, align = .End, key = 7)
		{
			w := max(gtx.constraints.max.x - 100, 160)
			ui.sized(gtx, {min = {w, 0}, max = {w, ui.INF}})
			field(gtx, "Date", "when it was last known true", &e.date, key = 8)
		}
		st := ui.stack_open(gtx, key = 9)
		if primer.button(gtx, "Today", .Default, .Medium, leading = .Calendar) {
			ui.text_set(&e.date, today())
		}
		primer.tooltip(gtx, "Date it today: it was checked and still holds.", ui.last_widget(gtx), delay = TOOLTIP_DELAY)
		ui.close(&st)
	}

	// What lint says, once there is something new to say it of.
	errors := 0
	if dirty && strings.trim_space(ui.text_string(&e.handle)) != "" {
		c, cst := ui.need(gtx, shapes.Bullet_Check{line = line}, shapes.Bullet_Check_Result)
		if ready(cst) {
			errors = len(c.errors)
			for x, i in c.errors {
				primer.inline_message(gtx, x, .Critical, .Small, key = u64(20 + i))
			}
			for x, i in c.warnings {
				primer.inline_message(gtx, x, .Warning, .Small, key = u64(40 + i))
			}
		} else {
			errors = -1 // not checked yet
		}
	}
	// What the footer's actions need, for this frame.
	filled := strings.trim_space(ui.text_string(&e.handle)) != "" && strings.trim_space(ui.text_string(&e.fact)) != ""
	e.frame = {
		line    = line,
		dirty   = dirty,
		ok      = dirty && filled && errors == 0 && !busy,
		busy    = busy,
		handle  = current != nil ? current.handle : "",
		to      = len(list.files) > 0 ? strings.trim_suffix(strings.trim_prefix(list.files[e.to], "AI/"), ".md") : "MEMORY",
		current = current != nil ? current^ : {},
	}
	{
		ui.column(gtx, gap = 4, align = .Fill, key = 11)
		primer.text(gtx, "As it will be written", .Small, .Medium, color = s[.Fg_Color_Muted])
		b := boxed(gtx, 12)
		defer ui.close(&b)
		primer.text(gtx, line, .Small, key = 12)
	}
	if e.drafting && chosen(&e.evidence) != "" {
		evidence(gtx, m, chosen(&e.evidence))
	}
}

// field is a labelled one-line text field.
field :: proc(gtx: ^ui.Ctx, label, caption: string, s: ^ui.Text_State, key: u64) {
	sc := primer.scheme()
	ui.column(gtx, gap = 4, align = .Fill, key = key)
	primer.text(gtx, label, .Small, .Medium, color = sc[.Fg_Color_Muted])
	primer.text_input(gtx, s, placeholder = caption, size = .Medium, block = true, name = label)
}

// evidence is what the transcripts say about the miss a new bullet
// answers, to write its fact from.
evidence :: proc(gtx: ^ui.Ctx, m: ^Model, query: string) {
	res, st := ui.need(gtx, shapes.Recall{terms = query, limit = 5}, shapes.Recall_Result)
	ui.column(gtx, gap = 8, align = .Fill, key = 13)
	primer.heading(gtx, fmt.tprintf("What was said about \"%s\"", query), 3, .Small)
	if !ready(st) {
		loading(gtx, 2)
		return
	}
	if res.error != "" || len(res.turns) == 0 {
		primer.text(gtx, "Nothing in the transcripts; the fact is yours to write.", .Small, color = m.scheme[.Fg_Color_Muted])
		return
	}
	b := boxed(gtx)
	defer ui.close(&b)
	l := primer.action_list_open(gtx, .Full, dividers = true, name = "Evidence")
	for t in res.turns {
		primer.action_list_item(&l, t.title, description = fmt.tprintf("%s · %s · %s", t.agent, t.date, t.snippet), description_variant = .Block, leading = .Comment_Discussion)
	}
	primer.action_list_close(&l)
}

// drop_confirm asks before a bullet leaves the vault.
drop_confirm :: proc(gtx: ^ui.Ctx, m: ^Model) {
	e := &m.editor
	if !e.dropping {
		return
	}
	handle := chosen(&e.loaded)
	if primer.confirmation_dialog(gtx, &e.dropping, fmt.tprintf("Drop %s?", handle), "It leaves the vault and no find returns it again. It is kept in AI/DROPPED.md, so it is not lost.", confirm_content = "Drop", confirm_type = .Danger) == .Confirm {
		send(gtx, m, .Drop_Bullet, {handle}, place(e.frame.current))
	}
}
