// Package lexer provides the source-positioned lexical layer for SPARQL.
// Tokens borrow their lexemes from the scanner source and remain valid while
// the Scanner remains alive. The lexer performs no RDF term allocation.
package lexer

import "core:unicode/utf8"

// Position identifies one UTF-8 source location. byte_offset is zero-based;
// line and column are one-based.
Position :: struct {
	byte_offset: int,
	line:        int,
	column:      int,
}

// Span is a half-open source range from start through, but not including, end.
Span :: struct {
	start: Position,
	end:   Position,
}

// Keyword identifies the SPARQL keywords recognized by the initial lexical
// layer. The parser owns contextual interpretation of every keyword.
Keyword :: enum {
	None,
	A,
	Base,
	Prefix,
	Select,
	Ask,
	Construct,
	Describe,
	Where,
	Filter,
	Optional,
	Union,
	Graph,
	Values,
	Bind,
	As,
}

// Token_Kind identifies a lexical token. Name covers both SPARQL keywords and
// future prefixed-name components; Token.keyword distinguishes known keywords.
Token_Kind :: enum {
	End,
	Name,
	Variable,
	IRIREF,
	String,
	Integer,
	Decimal,
	Double,
	LangTag,
	Blank_Node_Label,
	PName_NS,
	PName_LN,
	Question,
	Bang,
	Caret,
	Pipe,
	Left_Brace,
	Right_Brace,
	Left_Paren,
	Right_Paren,
	Left_Bracket,
	Right_Bracket,
	Dot,
	Semicolon,
	Comma,
	Star,
	Plus,
	Minus,
	Slash,
	Equals,
	Not_Equals,
	Less,
	Less_Or_Equal,
	Greater,
	Greater_Or_Equal,
	And,
	Or,
	Double_Caret,
}

// Token borrows lexeme from Scanner's private normalized source. keyword is
// None for ordinary names and non-name tokens.
Token :: struct {
	kind:    Token_Kind,
	keyword: Keyword,
	lexeme:  string,
	span:    Span,
}

// Error_Code identifies invalid UTF-8 and token-level syntax failures.
Error_Code :: enum {
	None,
	Invalid_UTF8,
	Invalid_Unicode_Escape,
	Invalid_Variable,
	Invalid_Language_Tag,
	Invalid_Blank_Node,
	Invalid_String_Escape,
	Unterminated_String,
	Out_Of_Memory,
	Unexpected_Character,
}

// Error reports a stable code and the source span where lexical processing
// stopped. Error messages are returned separately without allocation.
Error :: struct {
	code: Error_Code,
	span: Span,
}

// error_message returns a stable allocation-free diagnostic for code.
error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:                   return "no error"
	case .Invalid_UTF8:           return "invalid UTF-8"
	case .Invalid_Unicode_Escape: return "invalid Unicode escape"
	case .Invalid_Variable:       return "expected variable name"
	case .Invalid_Language_Tag:   return "invalid language tag"
	case .Invalid_Blank_Node:     return "invalid blank-node label"
	case .Invalid_String_Escape:  return "invalid string escape"
	case .Unterminated_String:    return "unterminated string literal"
	case .Out_Of_Memory:          return "memory allocation failed"
	case .Unexpected_Character:   return "unexpected character"
	}
	return "unknown lexical error"
}

// Scanner incrementally tokenizes one UTF-8 SPARQL request string.
Scanner :: struct {
	source:          Source,
	pos:             int,
	raw_position:    Position,
	escape_index:    int,
	initial_error:   Error,
}

// init prepares scanner to read input from line 1, column 1.
init :: proc(input: string) -> Scanner {
	source, error := source_init(input)
	return Scanner{source = source, raw_position = {line = 1, column = 1}, initial_error = error}
}

// destroy releases preprocessed source storage. Every successfully initialized
// Scanner must be destroyed after tokenization, including after an error.
destroy :: proc(scanner: ^Scanner) {
	source_destroy(&scanner.source)
	scanner^ = {}
}

@(private) position :: #force_inline proc(scanner: ^Scanner) -> Position {
	return scanner.raw_position
}

@(private) error_at :: #force_inline proc(scanner: ^Scanner, code: Error_Code) -> Error {
	at := position(scanner)
	return Error{code = code, span = {start = at, end = at}}
}

@(private) error_from :: #force_inline proc(start: Position, code: Error_Code) -> Error {
	return Error{code = code, span = {start = start, end = start}}
}

@(private) advance_ascii :: #force_inline proc(scanner: ^Scanner) {
	if advance_escape(scanner) do return
	scanner.pos += 1
	scanner.raw_position.byte_offset += 1
	scanner.raw_position.column += 1
}

@(private) advance_bytes :: #force_inline proc(scanner: ^Scanner, count: int) {
	scanner.pos += count
	scanner.raw_position.byte_offset += count
	scanner.raw_position.column += 1
}

@(private) advance_newline :: proc(scanner: ^Scanner) {
	if advance_escape(scanner) do return
	if scanner.source.text[scanner.pos] == '\r' && scanner.pos + 1 < len(scanner.source.text) && scanner.source.text[scanner.pos + 1] == '\n' {
		scanner.pos += 2
		scanner.raw_position.byte_offset += 2
	} else {
		scanner.pos += 1
		scanner.raw_position.byte_offset += 1
	}
	scanner.raw_position.line += 1
	scanner.raw_position.column = 1
}

@(private) advance_rune :: proc(scanner: ^Scanner) -> Error {
	if advance_escape(scanner) do return {}
	r, width := utf8.decode_rune_in_string(scanner.source.text[scanner.pos:])
	if width == 0 || (r == utf8.RUNE_ERROR && width == 1) do return error_at(scanner, .Invalid_UTF8)
	advance_bytes(scanner, width)
	return {}
}

@(private) advance_escape :: proc(scanner: ^Scanner) -> bool {
	if scanner.escape_index >= len(scanner.source.escapes) do return false
	escape := scanner.source.escapes[scanner.escape_index]
	if escape.text_start != scanner.pos do return false
	scanner.pos = escape.text_end
	scanner.raw_position = escape.raw_end
	scanner.escape_index += 1
	return true
}

@(private) peek_rune :: proc(scanner: ^Scanner) -> (rune, int, Error) {
	if scanner.pos >= len(scanner.source.text) do return 0, 0, error_at(scanner, .Invalid_UTF8)
	value, width := utf8.decode_rune_in_string(scanner.source.text[scanner.pos:])
	if width == 0 || (value == utf8.RUNE_ERROR && width == 1) do return 0, 0, error_at(scanner, .Invalid_UTF8)
	return value, width, {}
}

@(private) is_name_start :: #force_inline proc(value: byte) -> bool {
	return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z') || value == '_'
}

@(private) is_digit :: #force_inline proc(value: byte) -> bool {
	return value >= '0' && value <= '9'
}

@(private) is_name_continue :: #force_inline proc(value: byte) -> bool {
	return is_name_start(value) || (value >= '0' && value <= '9') || value == '-'
}

@(private) is_pn_chars_base :: proc(value: rune) -> bool {
	codepoint := u32(value)
	return (codepoint >= 'A' && codepoint <= 'Z') || (codepoint >= 'a' && codepoint <= 'z') ||
		(codepoint >= 0x00c0 && codepoint <= 0x00d6) || (codepoint >= 0x00d8 && codepoint <= 0x00f6) ||
		(codepoint >= 0x00f8 && codepoint <= 0x02ff) || (codepoint >= 0x0370 && codepoint <= 0x037d) ||
		(codepoint >= 0x037f && codepoint <= 0x1fff) || (codepoint >= 0x200c && codepoint <= 0x200d) ||
		(codepoint >= 0x2070 && codepoint <= 0x218f) || (codepoint >= 0x2c00 && codepoint <= 0x2fef) ||
		(codepoint >= 0x3001 && codepoint <= 0xd7ff) || (codepoint >= 0xf900 && codepoint <= 0xfdcf) ||
		(codepoint >= 0xfdf0 && codepoint <= 0xfffd) || (codepoint >= 0x10000 && codepoint <= 0xeffff)
}

@(private) is_pn_chars_u :: #force_inline proc(value: rune) -> bool {
	return is_pn_chars_base(value) || value == '_'
}

@(private) is_pn_chars :: #force_inline proc(value: rune) -> bool {
	codepoint := u32(value)
	return is_pn_chars_u(value) || value == '-' || (codepoint >= '0' && codepoint <= '9') ||
		codepoint == 0x00b7 || (codepoint >= 0x0300 && codepoint <= 0x036f) ||
		(codepoint >= 0x203f && codepoint <= 0x2040)
}

@(private) is_var_name_start :: #force_inline proc(value: rune) -> bool {
	return is_pn_chars_u(value) || (value >= '0' && value <= '9')
}

@(private) is_var_name_continue :: #force_inline proc(value: rune) -> bool {
	codepoint := u32(value)
	return is_pn_chars_u(value) || (codepoint >= '0' && codepoint <= '9') || codepoint == 0x00b7 ||
		(codepoint >= 0x0300 && codepoint <= 0x036f) || (codepoint >= 0x203f && codepoint <= 0x2040)
}

@(private) is_iriref_forbidden :: #force_inline proc(value: byte) -> bool {
	return value <= ' ' || value == '<' || value == '"' || value == '{' || value == '}' ||
		value == '|' || value == '^' || value == '`' || value == '\\'
}

@(private) ascii_fold :: #force_inline proc(value: byte) -> byte {
	if value >= 'a' && value <= 'z' do return value - ('a' - 'A')
	return value
}

@(private) equals_keyword :: proc(value, expected: string) -> bool {
	if len(value) != len(expected) do return false
	for index in 0..<len(value) {
		if ascii_fold(value[index]) != ascii_fold(expected[index]) do return false
	}
	return true
}

// is_keyword reports whether token is a case-insensitive SPARQL keyword.
// The special lower-case `a` keyword remains case-sensitive as required by the
// SPARQL grammar.
is_keyword :: proc(token: Token, expected: string) -> bool {
	if token.kind != .Name do return false
	if expected == "a" do return token.lexeme == "a"
	return equals_keyword(token.lexeme, expected)
}

@(private) classify_keyword :: proc(value: string) -> Keyword {
	switch {
	case equals_keyword(value, "A"):         return .A
	case equals_keyword(value, "BASE"):      return .Base
	case equals_keyword(value, "PREFIX"):    return .Prefix
	case equals_keyword(value, "SELECT"):    return .Select
	case equals_keyword(value, "ASK"):       return .Ask
	case equals_keyword(value, "CONSTRUCT"): return .Construct
	case equals_keyword(value, "DESCRIBE"):  return .Describe
	case equals_keyword(value, "WHERE"):     return .Where
	case equals_keyword(value, "FILTER"):    return .Filter
	case equals_keyword(value, "OPTIONAL"):  return .Optional
	case equals_keyword(value, "UNION"):     return .Union
	case equals_keyword(value, "GRAPH"):     return .Graph
	case equals_keyword(value, "VALUES"):    return .Values
	case equals_keyword(value, "BIND"):      return .Bind
	case equals_keyword(value, "AS"):        return .As
	}
	return .None
}

@(private) skip_ignored :: proc(scanner: ^Scanner) -> Error {
	for scanner.pos < len(scanner.source.text) {
		switch scanner.source.text[scanner.pos] {
		case ' ', '\t':
			advance_ascii(scanner)
		case '\r', '\n':
			advance_newline(scanner)
		case '#':
			advance_ascii(scanner)
			for scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] != '\r' && scanner.source.text[scanner.pos] != '\n' {
				if scanner.source.text[scanner.pos] < 0x80 {
					advance_ascii(scanner)
				} else if error := advance_rune(scanner); error.code != .None {
					return error
				}
			}
		case:
			return {}
		}
	}
	return {}
}

@(private) token_from :: proc(scanner: ^Scanner, kind: Token_Kind, text_start: int, start: Position, keyword: Keyword = .None) -> Token {
	return Token{
		kind = kind,
		keyword = keyword,
		lexeme = scanner.source.text[text_start:scanner.pos],
		span = {start = start, end = position(scanner)},
	}
}

@(private) read_name :: proc(scanner: ^Scanner, text_start: int, start: Position) -> Token {
	advance_ascii(scanner)
	for scanner.pos < len(scanner.source.text) && is_name_continue(scanner.source.text[scanner.pos]) do advance_ascii(scanner)
	lexeme := scanner.source.text[text_start:scanner.pos]
	return token_from(scanner, .Name, text_start, start, classify_keyword(lexeme))
}

@(private) read_variable :: proc(scanner: ^Scanner, text_start: int, start: Position) -> (Token, Error) {
	advance_ascii(scanner)
	first_value, _, decode_error := peek_rune(scanner)
	if decode_error.code != .None || !is_var_name_start(first_value) {
		return {}, error_from(start, .Invalid_Variable)
	}
	if advance_error := advance_rune(scanner); advance_error.code != .None do return {}, advance_error
	for scanner.pos < len(scanner.source.text) {
		next_value, _, next_error := peek_rune(scanner)
		if next_error.code != .None do return {}, next_error
		if !is_var_name_continue(next_value) do break
		if advance_error := advance_rune(scanner); advance_error.code != .None do return {}, advance_error
	}
	return token_from(scanner, .Variable, text_start, start), {}
}

@(private) one :: proc(scanner: ^Scanner, kind: Token_Kind, text_start: int, start: Position) -> Token {
	advance_ascii(scanner)
	return token_from(scanner, kind, text_start, start)
}

// try_read_iriref chooses IRIREF only when the complete longest-match terminal
// is present. A bare '<' remains the relational operator token.
@(private) try_read_iriref :: proc(scanner: ^Scanner, text_start: int, start: Position) -> (Token, bool, Error) {
	index := scanner.pos + 1
	for index < len(scanner.source.text) {
		value := scanner.source.text[index]
		if value == '>' {
			end := index + 1
			for scanner.pos < end {
				if scanner.source.text[scanner.pos] < 0x80 {
					advance_ascii(scanner)
				} else if error := advance_rune(scanner); error.code != .None {
					return {}, false, error
				}
			}
			return token_from(scanner, .IRIREF, text_start, start), true, {}
		}
		if is_iriref_forbidden(value) do return {}, false, {}
		if value < 0x80 {
			index += 1
			continue
		}
		decoded, width := utf8.decode_rune_in_string(scanner.source.text[index:])
		if width == 0 || (decoded == utf8.RUNE_ERROR && width == 1) do return {}, false, error_from(start, .Invalid_UTF8)
		index += width
	}
	return {}, false, {}
}

@(private) is_string_escape :: #force_inline proc(value: byte) -> bool {
	switch value {
	case 't', 'b', 'n', 'r', 'f', '"', '\'', '\\': return true
	}
	return false
}

@(private) read_string :: proc(scanner: ^Scanner, text_start: int, start: Position) -> (Token, Error) {
	quote := scanner.source.text[scanner.pos]
	long := scanner.pos + 2 < len(scanner.source.text) && scanner.source.text[scanner.pos + 1] == quote && scanner.source.text[scanner.pos + 2] == quote
	delimiter_length := 1
	if long do delimiter_length = 3
	for _ in 0..<delimiter_length do advance_ascii(scanner)

	for scanner.pos < len(scanner.source.text) {
		value := scanner.source.text[scanner.pos]
		if value == quote {
			if !long {
				advance_ascii(scanner)
				return token_from(scanner, .String, text_start, start), {}
			}
			if scanner.pos + 2 < len(scanner.source.text) && scanner.source.text[scanner.pos + 1] == quote && scanner.source.text[scanner.pos + 2] == quote {
				for _ in 0..<3 do advance_ascii(scanner)
				return token_from(scanner, .String, text_start, start), {}
			}
			advance_ascii(scanner)
			continue
		}
		if value == '\r' || value == '\n' {
			if !long do return {}, error_at(scanner, .Unterminated_String)
			advance_newline(scanner)
			continue
		}
		if value == '\\' {
			advance_ascii(scanner)
			if scanner.pos >= len(scanner.source.text) || !is_string_escape(scanner.source.text[scanner.pos]) {
				return {}, error_at(scanner, .Invalid_String_Escape)
			}
			advance_ascii(scanner)
			continue
		}
		if value < 0x80 {
			advance_ascii(scanner)
		} else if error := advance_rune(scanner); error.code != .None {
			return {}, error
		}
	}
	return {}, error_at(scanner, .Unterminated_String)
}

@(private) consume_digits :: proc(scanner: ^Scanner) {
	for scanner.pos < len(scanner.source.text) && is_digit(scanner.source.text[scanner.pos]) do advance_ascii(scanner)
}

@(private) exponent_end :: proc(text: string, start: int) -> int {
	if start >= len(text) || (text[start] != 'e' && text[start] != 'E') do return start
	index := start + 1
	if index < len(text) && (text[index] == '+' || text[index] == '-') do index += 1
	digits_start := index
	for index < len(text) && is_digit(text[index]) do index += 1
	if index == digits_start do return start
	return index
}

@(private) advance_to :: proc(scanner: ^Scanner, end: int) -> Error {
	for scanner.pos < end {
		if scanner.source.text[scanner.pos] < 0x80 {
			advance_ascii(scanner)
		} else if error := advance_rune(scanner); error.code != .None {
			return error
		}
	}
	return {}
}

@(private) starts_unsigned_number :: proc(text: string, index: int) -> bool {
	if index >= len(text) do return false
	if is_digit(text[index]) do return true
	return text[index] == '.' && index + 1 < len(text) && is_digit(text[index + 1])
}

@(private) read_number :: proc(scanner: ^Scanner, text_start: int, start: Position, signed: bool) -> (Token, Error) {
	if signed do advance_ascii(scanner)
	digits_before := scanner.pos
	consume_digits(scanner)
	has_integer := scanner.pos > digits_before
	kind := Token_Kind.Integer

	if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '.' {
		dot := scanner.pos
		after_dot := dot + 1
		if after_dot < len(scanner.source.text) && is_digit(scanner.source.text[after_dot]) {
			advance_ascii(scanner)
			consume_digits(scanner)
			kind = .Decimal
		} else if has_integer && exponent_end(scanner.source.text, after_dot) > after_dot {
			advance_ascii(scanner)
		} else {
			return token_from(scanner, .Integer, text_start, start), {}
		}
	}

	exponent := exponent_end(scanner.source.text, scanner.pos)
	if exponent > scanner.pos {
		if error := advance_to(scanner, exponent); error.code != .None do return {}, error
		kind = .Double
	}
	return token_from(scanner, kind, text_start, start), {}
}

@(private) read_langtag :: proc(scanner: ^Scanner, text_start: int, start: Position) -> (Token, Error) {
	advance_ascii(scanner)
	letters := 0
	for scanner.pos < len(scanner.source.text) && ((scanner.source.text[scanner.pos] >= 'a' && scanner.source.text[scanner.pos] <= 'z') || (scanner.source.text[scanner.pos] >= 'A' && scanner.source.text[scanner.pos] <= 'Z')) {
		advance_ascii(scanner)
		letters += 1
	}
	if letters == 0 do return {}, error_from(start, .Invalid_Language_Tag)
	for scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '-' {
		advance_ascii(scanner)
		part := 0
		for scanner.pos < len(scanner.source.text) {
			value := scanner.source.text[scanner.pos]
			if !((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || is_digit(value)) do break
			advance_ascii(scanner)
			part += 1
		}
		if part == 0 do return {}, error_at(scanner, .Invalid_Language_Tag)
	}
	return token_from(scanner, .LangTag, text_start, start), {}
}

@(private) rune_at :: proc(text: string, index: int) -> (rune, int, bool) {
	if index >= len(text) do return 0, 0, false
	value, width := utf8.decode_rune_in_string(text[index:])
	if width == 0 || (value == utf8.RUNE_ERROR && width == 1) do return 0, 0, false
	return value, width, true
}

@(private) read_blank_node_label :: proc(scanner: ^Scanner, text_start: int, start: Position) -> (Token, Error) {
	advance_ascii(scanner)
	advance_ascii(scanner)
	first_value, _, first_valid := rune_at(scanner.source.text, scanner.pos)
	if !first_valid || !(is_pn_chars_u(first_value) || (first_value >= '0' && first_value <= '9')) {
		return {}, error_from(start, .Invalid_Blank_Node)
	}
	if error := advance_rune(scanner); error.code != .None do return {}, error
	for scanner.pos < len(scanner.source.text) {
		if scanner.source.text[scanner.pos] == '.' {
			next, _, valid := rune_at(scanner.source.text, scanner.pos + 1)
			if !valid || !is_pn_chars(next) do break
			advance_ascii(scanner)
			if error := advance_rune(scanner); error.code != .None do return {}, error
			continue
		}
		continued_value, _, continued_valid := rune_at(scanner.source.text, scanner.pos)
		if !continued_valid || !is_pn_chars(continued_value) do break
		if error := advance_rune(scanner); error.code != .None do return {}, error
	}
	return token_from(scanner, .Blank_Node_Label, text_start, start), {}
}

@(private) is_local_escape :: #force_inline proc(value: byte) -> bool {
	switch value {
	case '_', '~', '.', '-', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '/', '?', '#', '@', '%': return true
	}
	return false
}

@(private) is_percent_escape :: proc(text: string, index: int) -> bool {
	if index + 2 >= len(text) || text[index] != '%' do return false
	_, first := hex_value(text[index + 1])
	_, second := hex_value(text[index + 2])
	return first && second
}

@(private) local_escape_width :: proc(text: string, index: int) -> int {
	if index + 1 >= len(text) || text[index] != '\\' || !is_local_escape(text[index + 1]) do return 0
	return 2
}

@(private) local_first_width :: proc(text: string, index: int) -> int {
	value, width, valid := rune_at(text, index)
	if valid && (is_pn_chars_u(value) || value == ':' || (value >= '0' && value <= '9')) do return width
	if is_percent_escape(text, index) do return 3
	return local_escape_width(text, index)
}

@(private) local_continue_width :: proc(text: string, index: int) -> int {
	value, width, valid := rune_at(text, index)
	if valid && (is_pn_chars(value) || value == ':' || value == '.') do return width
	if is_percent_escape(text, index) do return 3
	return local_escape_width(text, index)
}

@(private) pname_local_end :: proc(text: string, index: int) -> int {
	cursor := index
	first := local_first_width(text, cursor)
	if first == 0 do return cursor
	cursor += first
	last_was_dot := false
	for cursor < len(text) {
		width := local_continue_width(text, cursor)
		if width == 0 do break
		last_was_dot = text[cursor] == '.'
		cursor += width
	}
	if last_was_dot do return cursor - 1
	return cursor
}

// pname_end returns the longest valid PNAME terminal beginning at index.
// A zero end means that no PNAME begins at index.
@(private) pname_end :: proc(text: string, index: int) -> (Token_Kind, int) {
	if index >= len(text) do return .End, 0
	if text[index] == ':' {
		local_end := pname_local_end(text, index + 1)
		if local_end == index + 1 do return .PName_NS, index + 1
		return .PName_LN, local_end
	}

	first, width, valid := rune_at(text, index)
	if !valid || !is_pn_chars_base(first) do return .End, 0
	cursor := index + width
	for cursor < len(text) {
		if text[cursor] == ':' {
			local_end := pname_local_end(text, cursor + 1)
			if local_end == cursor + 1 do return .PName_NS, cursor + 1
			return .PName_LN, local_end
		}
		if text[cursor] == '.' {
			next, _, next_valid := rune_at(text, cursor + 1)
			if !next_valid || !is_pn_chars(next) do return .End, 0
			cursor += 1
			continue
		}
		value, next_width, next_valid := rune_at(text, cursor)
		if !next_valid || !is_pn_chars(value) do return .End, 0
		cursor += next_width
	}
	return .End, 0
}

@(private) try_read_pname :: proc(scanner: ^Scanner, text_start: int, start: Position) -> (Token, bool, Error) {
	kind, end := pname_end(scanner.source.text, scanner.pos)
	if end == 0 do return {}, false, {}
	if error := advance_to(scanner, end); error.code != .None do return {}, false, error
	return token_from(scanner, kind, text_start, start), true, {}
}

// next returns the next non-comment token. End is returned repeatedly after
// the input is exhausted. It never allocates and all token lexemes borrow the
// scanner source.
next :: proc(scanner: ^Scanner) -> (Token, Error) {
	if scanner.initial_error.code != .None do return {}, scanner.initial_error
	if error := skip_ignored(scanner); error.code != .None do return {}, error
	text_start := scanner.pos
	start := position(scanner)
	if scanner.pos == len(scanner.source.text) {
		return Token{kind = .End, span = {start = start, end = start}}, {}
	}

	value := scanner.source.text[scanner.pos]
	if value == '_' && scanner.pos + 1 < len(scanner.source.text) && scanner.source.text[scanner.pos + 1] == ':' {
		return read_blank_node_label(scanner, text_start, start)
	}
	if value == ':' || value >= 0x80 || (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z') {
		pname, matched, pname_error := try_read_pname(scanner, text_start, start)
		if pname_error.code != .None do return {}, pname_error
		if matched do return pname, {}
	}
	if is_name_start(value) do return read_name(scanner, text_start, start), {}
	if value == '?' {
		next_value, _, valid := rune_at(scanner.source.text, scanner.pos + 1)
		if valid && is_var_name_start(next_value) do return read_variable(scanner, text_start, start)
		return one(scanner, .Question, text_start, start), {}
	}
	if value == '$' do return read_variable(scanner, text_start, start)
	if value == '\'' || value == '"' do return read_string(scanner, text_start, start)
	if value == '@' do return read_langtag(scanner, text_start, start)
	if is_digit(value) || starts_unsigned_number(scanner.source.text, scanner.pos) do return read_number(scanner, text_start, start, false)
	if (value == '+' || value == '-') && starts_unsigned_number(scanner.source.text, scanner.pos + 1) do return read_number(scanner, text_start, start, true)

	switch value {
	case '{': return one(scanner, .Left_Brace, text_start, start), {}
	case '}': return one(scanner, .Right_Brace, text_start, start), {}
	case '(': return one(scanner, .Left_Paren, text_start, start), {}
	case ')': return one(scanner, .Right_Paren, text_start, start), {}
	case '[': return one(scanner, .Left_Bracket, text_start, start), {}
	case ']': return one(scanner, .Right_Bracket, text_start, start), {}
	case '.': return one(scanner, .Dot, text_start, start), {}
	case ';': return one(scanner, .Semicolon, text_start, start), {}
	case ',': return one(scanner, .Comma, text_start, start), {}
	case '*': return one(scanner, .Star, text_start, start), {}
	case '+': return one(scanner, .Plus, text_start, start), {}
	case '-': return one(scanner, .Minus, text_start, start), {}
	case '/': return one(scanner, .Slash, text_start, start), {}
	case '=': return one(scanner, .Equals, text_start, start), {}
	case '<':
		iri, matched, iri_error := try_read_iriref(scanner, text_start, start)
		if iri_error.code != .None do return {}, iri_error
		if matched do return iri, {}
		advance_ascii(scanner)
		if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '=' {
			advance_ascii(scanner)
			return token_from(scanner, .Less_Or_Equal, text_start, start), {}
		}
		return token_from(scanner, .Less, text_start, start), {}
	case '>':
		advance_ascii(scanner)
		if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '=' {
			advance_ascii(scanner)
			return token_from(scanner, .Greater_Or_Equal, text_start, start), {}
		}
		return token_from(scanner, .Greater, text_start, start), {}
	case '!':
		advance_ascii(scanner)
		if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '=' {
			advance_ascii(scanner)
			return token_from(scanner, .Not_Equals, text_start, start), {}
		}
		return token_from(scanner, .Bang, text_start, start), {}
	case '&':
		advance_ascii(scanner)
		if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '&' {
			advance_ascii(scanner)
			return token_from(scanner, .And, text_start, start), {}
		}
		return {}, error_from(start, .Unexpected_Character)
	case '|':
		advance_ascii(scanner)
		if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '|' {
			advance_ascii(scanner)
			return token_from(scanner, .Or, text_start, start), {}
		}
		return token_from(scanner, .Pipe, text_start, start), {}
	case '^':
		advance_ascii(scanner)
		if scanner.pos < len(scanner.source.text) && scanner.source.text[scanner.pos] == '^' {
			advance_ascii(scanner)
			return token_from(scanner, .Double_Caret, text_start, start), {}
		}
		return token_from(scanner, .Caret, text_start, start), {}
	}

	if value >= 0x80 {
		if error := advance_rune(scanner); error.code != .None do return {}, error
	}
	return {}, error_from(start, .Unexpected_Character)
}
