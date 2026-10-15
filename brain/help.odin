package brain

import "core:fmt"
import "core:strings"

import "../msg"
import "../term"

// print_usage prints the help. Plain, it is the English USAGE constant,
// byte for byte: an agent, a pipe, and --color=never. Styled, a person
// sees the catalog in the saved language, with headings and command names
// bold, the repeated `brain` and the closing notes dim. The command lines
// keep their English indent, which the catalog trims.
print_usage :: proc(cli: ^Cli) {
	if !term.styled(cli.style) {
		out(cli, USAGE)
		return
	}
	text := usage_text(cli)
	s := cli.style
	b := &cli.out
	blanks := 0
	first := true
	for line in strings.split_lines_iterator(&text) {
		switch {
		case first:
			first = false
			name, _, rest := strings.partition(line, " ")
			term.paint(b, s, {.Bold}, name)
			strings.write_byte(b, ' ')
			strings.write_string(b, rest)
		case line == "":
			// The blank after the title opens the commands; the next one
			// closes them.
			blanks += 1
		case blanks >= 2:
			term.paint(b, s, {.Dim}, line)
		case line[0] != ' ':
			term.paint(b, s, {.Bold}, line)
		case strings.has_prefix(line, "  brain "):
			cmd, desc := line[2:], ""
			if i := strings.index(cmd, "  "); i >= 0 {
				cmd, desc = cmd[:i], cmd[i:]
			}
			_, _, rest := strings.partition(cmd, " ")
			sub, sp, args := strings.partition(rest, " ")
			strings.write_string(b, "  ")
			term.paint(b, s, {.Dim}, "brain")
			strings.write_byte(b, ' ')
			term.paint(b, s, {.Bold}, sub)
			strings.write_string(b, sp)
			strings.write_string(b, args)
			strings.write_string(b, desc)
		case:
			strings.write_string(b, line)
		}
		strings.write_byte(b, '\n')
	}
}

// usage_text is the help, one catalog line per row of USAGE. A blank
// follows the title and the version line.
@(private)
usage_text :: proc(cli: ^Cli) -> string {
	b := strings.builder_make(context.temp_allocator)
	key := msg.Msg.Help_Title
	for key <= .Help_Foot_C {
		if key == .Help_Ask || key == .Help_Foot_A {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, help_indent(key))
		strings.write_string(&b, phrase(cli, key))
		strings.write_byte(&b, '\n')
		key = msg.Msg(int(key) + 1)
	}
	return strings.to_string(b)
}

// help_indent is the leading spaces of key's English line. The catalog
// trims them; the help printer puts them back so a command stays aligned.
@(private)
help_indent :: proc(key: msg.Msg) -> string {
	want := strings.to_lower(fmt.tprint(key), context.temp_allocator)
	src := msg.SOURCES[.English]
	for line in strings.split_lines_iterator(&src) {
		head, _, val := strings.partition(line, " = ")
		stem := head
		if i := strings.index_byte(stem, '.'); i >= 0 {
			stem = stem[:i]
		}
		if stem != want {
			continue
		}
		n := 0
		for n < len(val) && val[n] == ' ' {
			n += 1
		}
		return val[:n]
	}
	return ""
}
