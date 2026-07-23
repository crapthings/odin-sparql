package lexer

import "core:strings"
import "core:unicode/utf8"

// Escape records one codepoint escape after it has been substituted into the
// lexical input. The scanner uses it to report positions in the original query
// rather than in the transformed byte stream.
@(private) Escape :: struct {
	text_start: int,
	text_end:   int,
	raw_end:    Position,
}

// Source owns transformed text only when the request contains a SPARQL
// codepoint escape. raw always borrows the caller input.
@(private) Source :: struct {
	raw:        string,
	text:       string,
	owned_text: string,
	escapes:    [dynamic]Escape,
}

@(private) source_error :: proc(code: Error_Code, at: Position) -> Error {
	return Error{code = code, span = {start = at, end = at}}
}

@(private) hex_value :: proc(value: byte) -> (u32, bool) {
	switch {
	case value >= '0' && value <= '9': return u32(value - '0'), true
	case value >= 'a' && value <= 'f': return u32(value - 'a' + 10), true
	case value >= 'A' && value <= 'F': return u32(value - 'A' + 10), true
	}
	return 0, false
}

@(private) advance_raw_ascii :: proc(input: string, offset: ^int, at: ^Position) {
	if input[offset^] == '\r' && offset^ + 1 < len(input) && input[offset^ + 1] == '\n' {
		offset^ += 2
	} else {
		offset^ += 1
	}
	at.byte_offset = offset^
	at.line += 1
	at.column = 1
}

@(private) advance_raw_rune :: proc(input: string, offset: ^int, at: ^Position) -> Error {
	value := input[offset^]
	if value == '\r' || value == '\n' {
		advance_raw_ascii(input, offset, at)
		return {}
	}
	if value < 0x80 {
		offset^ += 1
		at.byte_offset = offset^
		at.column += 1
		return {}
	}
	r, width := utf8.decode_rune_in_string(input[offset^:])
	if width == 0 || (r == utf8.RUNE_ERROR && width == 1) do return source_error(.Invalid_UTF8, at^)
	offset^ += width
	at.byte_offset = offset^
	at.column += 1
	return {}
}

@(private) read_codepoint_escape :: proc(input: string, offset: int, at: Position) -> (rune, int, Error) {
	if offset + 2 > len(input) || input[offset] != '\\' do return 0, 0, source_error(.Invalid_Unicode_Escape, at)
	digits := 0
	if input[offset + 1] == 'u' {
		digits = 4
	} else if input[offset + 1] == 'U' {
		digits = 8
	} else {
		return 0, 0, source_error(.Invalid_Unicode_Escape, at)
	}

	value: u32
	for index in 0..<digits {
		position := offset + 2 + index
		if position >= len(input) do return 0, 0, source_error(.Invalid_Unicode_Escape, at)
		nibble, valid := hex_value(input[position])
		if !valid do return 0, 0, source_error(.Invalid_Unicode_Escape, at)
		value = value * 16 + nibble
	}
	if value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff) {
		return 0, 0, source_error(.Invalid_Unicode_Escape, at)
	}
	return rune(value), 2 + digits, {}
}

// source_init implements SPARQL 1.1 section 19.2 before tokenization. It
// keeps escape boundaries so diagnostics continue to use original byte, line,
// and column locations.
@(private) source_init :: proc(input: string) -> (Source, Error) {
	result := Source{raw = input, text = input, escapes = make([dynamic]Escape)}
	raw_offset := 0
	raw_position := Position{line = 1, column = 1}
	builder: strings.Builder
	builder_started := false

	defer if builder_started do strings.builder_destroy(&builder)

	for raw_offset < len(input) {
		if input[raw_offset] == '\\' && raw_offset + 1 < len(input) && (input[raw_offset + 1] == 'u' || input[raw_offset + 1] == 'U') {
			decoded, width, error := read_codepoint_escape(input, raw_offset, raw_position)
			if error.code != .None do return result, error
			if !builder_started {
				builder = strings.builder_make()
				strings.write_string(&builder, input[:raw_offset])
				builder_started = true
			}
			text_start := len(builder.buf)
			strings.write_rune(&builder, decoded)
			text_end := len(builder.buf)
			raw_offset += width
			raw_position.byte_offset = raw_offset
			raw_position.column += width
			_, append_error := append(&result.escapes, Escape{text_start = text_start, text_end = text_end, raw_end = raw_position})
			if append_error != nil do return result, source_error(.Out_Of_Memory, raw_position)
			continue
		}

		start := raw_offset
		error := advance_raw_rune(input, &raw_offset, &raw_position)
		if error.code != .None do return result, error
		if builder_started do strings.write_string(&builder, input[start:raw_offset])
	}

	if builder_started {
		owned_text, clone_error := strings.clone(strings.to_string(builder))
		if clone_error != nil do return result, source_error(.Out_Of_Memory, raw_position)
		result.owned_text = owned_text
		result.text = result.owned_text
	}
	return result, {}
}

@(private) source_destroy :: proc(source: ^Source) {
	if len(source.owned_text) > 0 do delete(source.owned_text)
	delete(source.escapes)
	source^ = {}
}
