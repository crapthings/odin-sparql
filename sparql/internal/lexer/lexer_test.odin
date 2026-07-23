package lexer

import "core:testing"

@(test)
test_skips_comments_whitespace_and_crlf :: proc(t: ^testing.T) {
	scanner := init("# header \u03b4\r\n  SeLeCt\t?name")
	defer destroy(&scanner)

	select, select_error := next(&scanner)
	testing.expect_value(t, select_error.code, Error_Code.None)
	testing.expect_value(t, select.kind, Token_Kind.Name)
	testing.expect_value(t, select.keyword, Keyword.Select)
	testing.expect_value(t, select.lexeme, "SeLeCt")
	testing.expect_value(t, select.span.start.line, 2)
	testing.expect_value(t, select.span.start.column, 3)

	variable, variable_error := next(&scanner)
	testing.expect_value(t, variable_error.code, Error_Code.None)
	testing.expect_value(t, variable.kind, Token_Kind.Variable)
	testing.expect_value(t, variable.lexeme, "?name")
	testing.expect_value(t, variable.span.start.line, 2)
	testing.expect_value(t, variable.span.start.column, 10)
}

@(test)
test_tokens_basic_pattern_punctuation :: proc(t: ^testing.T) {
	scanner := init("SELECT ?x { ?x ?p ?o . }")
	defer destroy(&scanner)
	expected := []Token_Kind{.Name, .Variable, .Left_Brace, .Variable, .Variable, .Variable, .Dot, .Right_Brace, .End}
	for kind in expected {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, kind)
	}
}

@(test)
test_recognizes_case_insensitive_keywords :: proc(t: ^testing.T) {
	scanner := init("prefix ASK construct describe where filter optional union graph values bind as a ordinary")
	defer destroy(&scanner)
	expected := []Keyword{.Prefix, .Ask, .Construct, .Describe, .Where, .Filter, .Optional, .Union, .Graph, .Values, .Bind, .As, .A, .None}
	for keyword in expected {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, Token_Kind.Name)
		testing.expect_value(t, token.keyword, keyword)
	}
}

@(test)
test_matches_case_insensitive_keyword_requests :: proc(t: ^testing.T) {
	scanner := init("TrUe FALSE select")
	defer destroy(&scanner)
	first, first_error := next(&scanner)
	testing.expect_value(t, first_error.code, Error_Code.None)
	testing.expect_value(t, is_keyword(first, "true"), true)
	second, second_error := next(&scanner)
	testing.expect_value(t, second_error.code, Error_Code.None)
	testing.expect_value(t, is_keyword(second, "false"), true)
	third, third_error := next(&scanner)
	testing.expect_value(t, third_error.code, Error_Code.None)
	testing.expect_value(t, is_keyword(third, "SELECT"), true)
}

@(test)
test_reports_invalid_dollar_variables_and_operator_errors_at_their_start :: proc(t: ^testing.T) {
	variable_scanner := init("$")
	defer destroy(&variable_scanner)
	_, variable_error := next(&variable_scanner)
	testing.expect_value(t, variable_error.code, Error_Code.Invalid_Variable)
	testing.expect_value(t, variable_error.span.start.line, 1)
	testing.expect_value(t, variable_error.span.start.column, 1)

	operator_scanner := init("&")
	defer destroy(&operator_scanner)
	_, operator_error := next(&operator_scanner)
	testing.expect_value(t, operator_error.code, Error_Code.Unexpected_Character)
	testing.expect_value(t, operator_error.span.start.byte_offset, 0)
}

@(test)
test_reads_path_and_unary_punctuation :: proc(t: ^testing.T) {
	scanner := init(`?p? !<urn:p>|^a`)
	defer destroy(&scanner)
	expected := []Token_Kind{.Variable, .Question, .Bang, .IRIREF, .Pipe, .Caret, .Name, .End}
	for kind in expected {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, kind)
	}
}

@(test)
test_rejects_invalid_utf8_in_a_comment :: proc(t: ^testing.T) {
	bytes := []byte{'#', 0xff}
	input := string(bytes)
	scanner := init(input)
	defer destroy(&scanner)
	_, error := next(&scanner)
	testing.expect_value(t, error.code, Error_Code.Invalid_UTF8)
	testing.expect_value(t, error.span.start.column, 2)
}

@(test)
test_processes_codepoint_escapes_before_lexing_and_preserves_raw_spans :: proc(t: ^testing.T) {
	scanner := init(`SEL\u0045CT ?x\u0020?y`)
	defer destroy(&scanner)

	select, select_error := next(&scanner)
	testing.expect_value(t, select_error.code, Error_Code.None)
	testing.expect_value(t, select.kind, Token_Kind.Name)
	testing.expect_value(t, select.keyword, Keyword.Select)
	testing.expect_value(t, select.lexeme, "SELECT")
	testing.expect_value(t, select.span.start.column, 1)
	testing.expect_value(t, select.span.end.column, 12)

	first_variable, first_error := next(&scanner)
	testing.expect_value(t, first_error.code, Error_Code.None)
	testing.expect_value(t, first_variable.lexeme, "?x")
	testing.expect_value(t, first_variable.span.start.column, 13)
	testing.expect_value(t, first_variable.span.end.column, 15)

	second_variable, second_error := next(&scanner)
	testing.expect_value(t, second_error.code, Error_Code.None)
	testing.expect_value(t, second_variable.lexeme, "?y")
	testing.expect_value(t, second_variable.span.start.column, 21)
	testing.expect_value(t, second_variable.span.end.column, 23)
}

@(test)
test_rejects_invalid_codepoint_escapes_before_tokenization :: proc(t: ^testing.T) {
	scanner := init(`SELECT \u00G0`)
	defer destroy(&scanner)
	_, error := next(&scanner)
	testing.expect_value(t, error.code, Error_Code.Invalid_Unicode_Escape)
	testing.expect_value(t, error.span.start.line, 1)
	testing.expect_value(t, error.span.start.column, 8)
}

@(test)
test_uses_longest_match_for_iri_references :: proc(t: ^testing.T) {
	scanner := init(`?a<?b&&?c>?d`)
	defer destroy(&scanner)

	first, first_error := next(&scanner)
	testing.expect_value(t, first_error.code, Error_Code.None)
	testing.expect_value(t, first.kind, Token_Kind.Variable)
	testing.expect_value(t, first.lexeme, "?a")

	iri, iri_error := next(&scanner)
	testing.expect_value(t, iri_error.code, Error_Code.None)
	testing.expect_value(t, iri.kind, Token_Kind.IRIREF)
	testing.expect_value(t, iri.lexeme, "<?b&&?c>")

	last, last_error := next(&scanner)
	testing.expect_value(t, last_error.code, Error_Code.None)
	testing.expect_value(t, last.kind, Token_Kind.Variable)
	testing.expect_value(t, last.lexeme, "?d")
}

@(test)
test_distinguishes_relational_less_than_and_decoded_iri_references :: proc(t: ^testing.T) {
	comparison := init(`?a < ?b`)
	defer destroy(&comparison)
	_, _ = next(&comparison)
	less, less_error := next(&comparison)
	testing.expect_value(t, less_error.code, Error_Code.None)
	testing.expect_value(t, less.kind, Token_Kind.Less)

	iri_scanner := init(`<urn:\u0065xample>`)
	defer destroy(&iri_scanner)
	iri, iri_error := next(&iri_scanner)
	testing.expect_value(t, iri_error.code, Error_Code.None)
	testing.expect_value(t, iri.kind, Token_Kind.IRIREF)
	testing.expect_value(t, iri.lexeme, "<urn:example>")
	testing.expect_value(t, iri.span.end.column, 19)
}

@(test)
test_reads_short_and_long_strings :: proc(t: ^testing.T) {
	short_scanner := init(`"line\nvalue"`)
	defer destroy(&short_scanner)
	short, short_error := next(&short_scanner)
	testing.expect_value(t, short_error.code, Error_Code.None)
	testing.expect_value(t, short.kind, Token_Kind.String)
	testing.expect_value(t, short.lexeme, `"line\nvalue"`)

	long_scanner := init(`'''first
second'''`)
	defer destroy(&long_scanner)
	long, long_error := next(&long_scanner)
	testing.expect_value(t, long_error.code, Error_Code.None)
	testing.expect_value(t, long.kind, Token_Kind.String)
	testing.expect_value(t, long.span.end.line, 2)
	testing.expect_value(t, long.span.end.column, 10)
}

@(test)
test_rejects_invalid_and_unterminated_string_literals :: proc(t: ^testing.T) {
	invalid_scanner := init(`"\q"`)
	defer destroy(&invalid_scanner)
	_, invalid_error := next(&invalid_scanner)
	testing.expect_value(t, invalid_error.code, Error_Code.Invalid_String_Escape)
	testing.expect_value(t, invalid_error.span.start.column, 3)

	unterminated_scanner := init(`"value`)
	defer destroy(&unterminated_scanner)
	_, unterminated_error := next(&unterminated_scanner)
	testing.expect_value(t, unterminated_error.code, Error_Code.Unterminated_String)
	testing.expect_value(t, unterminated_error.span.start.column, 7)
}

@(test)
test_reads_numeric_terminals_without_consuming_dot_or_operators :: proc(t: ^testing.T) {
	scanner := init(`0 42 .5 3.14 6e2 1.e-3 +8 -0.2 +.5 -1E+2 1.`)
	defer destroy(&scanner)
	expected := []Token_Kind{
		.Integer, .Integer, .Decimal, .Decimal, .Double, .Double,
		.Integer, .Decimal, .Decimal, .Double, .Integer, .Dot, .End,
	}
	for kind in expected {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, kind)
	}
}

@(test)
test_reads_unicode_variables_language_tags_and_blank_node_labels :: proc(t: ^testing.T) {
	scanner := init(`?Δ $9 "name"@en-GB _:café _:a.b.`)
	defer destroy(&scanner)
	expected := []Token_Kind{.Variable, .Variable, .String, .LangTag, .Blank_Node_Label, .Blank_Node_Label, .Dot, .End}
	for kind in expected {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, kind)
	}
}

@(test)
test_rejects_invalid_variable_language_tag_and_blank_node_label :: proc(t: ^testing.T) {
	invalid_variable := init(`$-`)
	defer destroy(&invalid_variable)
	_, variable_error := next(&invalid_variable)
	testing.expect_value(t, variable_error.code, Error_Code.Invalid_Variable)

	invalid_language := init(`@1`)
	defer destroy(&invalid_language)
	_, language_error := next(&invalid_language)
	testing.expect_value(t, language_error.code, Error_Code.Invalid_Language_Tag)

	invalid_blank := init(`_:-bad`)
	defer destroy(&invalid_blank)
	_, blank_error := next(&invalid_blank)
	testing.expect_value(t, blank_error.code, Error_Code.Invalid_Blank_Node)
}

@(test)
test_reads_prefixed_name_terminals_and_leaves_trailing_dots :: proc(t: ^testing.T) {
	scanner := init(`:local ex:café ex:percent%20 ex:escaped\~name ex:final.`)
	defer destroy(&scanner)
	expected := []Token_Kind{.PName_LN, .PName_LN, .PName_LN, .PName_LN, .PName_LN, .Dot, .End}
	for kind in expected {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, kind)
	}
}

@(test)
test_reads_prefix_only_prefixed_names :: proc(t: ^testing.T) {
	scanner := init(`: ex: rdf:`)
	defer destroy(&scanner)
	for _ in 0..<3 {
		token, error := next(&scanner)
		testing.expect_value(t, error.code, Error_Code.None)
		testing.expect_value(t, token.kind, Token_Kind.PName_NS)
	}
}

@(test)
test_lexical_error_messages_are_stable :: proc(t: ^testing.T) {
	messages := [Error_Code]string{
		.None                   = "no error",
		.Invalid_UTF8           = "invalid UTF-8",
		.Invalid_Unicode_Escape = "invalid Unicode escape",
		.Invalid_Variable       = "expected variable name",
		.Invalid_Language_Tag   = "invalid language tag",
		.Invalid_Blank_Node     = "invalid blank-node label",
		.Invalid_String_Escape  = "invalid string escape",
		.Unterminated_String    = "unterminated string literal",
		.Out_Of_Memory          = "memory allocation failed",
		.Unexpected_Character   = "unexpected character",
	}
	for code in Error_Code do testing.expect_value(t, error_message(code), messages[code])
}
