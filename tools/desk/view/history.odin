package desk_view

import "jm:ui"

// The jump list, as a modal editor keeps one: every move to another page
// is a jump, and Ctrl+O goes back along them, Ctrl+I forward again, as do
// the mouse's back and forward buttons. A place is a page and what was
// chosen on it, so going back returns to the item left, not only the
// page. A jump made after going back drops the places ahead of it.

HISTORY_MAX :: 100 // places kept; the oldest go first

// Place is where the person was: the page and each list's choice.
Place :: struct {
	page:            Page,
	search:          Chosen, // Recall's terms
	turn:            Chosen,
	bullet:          Chosen,
	miss:            Chosen,
	proposal:        Chosen,
	finding:         Chosen,
	findings:        Finding_List,
	findings_chosen: bool,
	pin:             Chosen,
}

// History is the places jumped from, oldest first, and at, the one shown
// while going back and forth; at is len(places) when none is, the page
// shown being where the last jump went.
History :: struct {
	places: [dynamic]Place,
	at:     int,
}

// go jumps to page, recording where it leaves. A caller that also chooses
// something on the page goes first, so the place left keeps its choice.
go :: proc(m: ^Model, page: Page) {
	if page == m.page {
		return
	}
	h := &m.history
	resize(&h.places, h.at)
	if len(h.places) == HISTORY_MAX {
		ordered_remove(&h.places, 0)
	}
	append(&h.places, here(m))
	h.at = len(h.places)
	m.page = page
}

// back returns to the place before the one shown, keeping the one shown
// to come forward to. It is whether there was one.
back :: proc(m: ^Model) -> bool {
	h := &m.history
	if h.at == 0 {
		return false
	}
	if h.at == len(h.places) {
		append(&h.places, here(m))
	} else {
		h.places[h.at] = here(m)
	}
	h.at -= 1
	restore(m, h.places[h.at])
	return true
}

// forward undoes a back. It is whether there was a place ahead.
forward :: proc(m: ^Model) -> bool {
	h := &m.history
	if h.at >= len(h.places) - 1 {
		return false
	}
	h.places[h.at] = here(m)
	h.at += 1
	restore(m, h.places[h.at])
	return true
}

// here is the place shown.
here :: proc(m: ^Model) -> Place {
	p := Place {
		page            = m.page,
		turn            = m.turn,
		bullet          = m.bullet,
		miss            = m.miss,
		proposal        = m.proposal,
		finding         = m.finding,
		findings        = m.findings,
		findings_chosen = m.findings_chosen,
		pin             = m.pin,
	}
	choose(&p.search, ui.text_string(&m.search))
	return p
}

// restore shows place p.
restore :: proc(m: ^Model, p: Place) {
	p := p
	m.page = p.page
	m.turn, m.bullet, m.miss, m.proposal, m.finding = p.turn, p.bullet, p.miss, p.proposal, p.finding
	m.findings, m.findings_chosen = p.findings, p.findings_chosen
	m.pin = p.pin
	if terms := chosen(&p.search); terms != ui.text_string(&m.search) {
		ui.text_set(&m.search, terms)
	}
}

// history_keys moves along the history on Ctrl+O and Ctrl+I, and on the
// mouse's back and forward buttons, wherever the focus is.
history_keys :: proc(gtx: ^ui.Ctx, m: ^Model) {
	id := ui.claim_id(gtx, 0x415)
	ui.key_interest(gtx, id, .O, {.Ctrl})
	ui.key_interest(gtx, id, .I, {.Ctrl})
	ui.key_interest(gtx, id, .Browser_Back)
	ui.key_interest(gtx, id, .Browser_Forward)
	for e in ui.events(gtx, id) {
		if e.kind != .Key {
			continue
		}
		#partial switch e.key {
		case .O, .Browser_Back:
			back(m)
		case .I, .Browser_Forward:
			forward(m)
		}
	}
}
