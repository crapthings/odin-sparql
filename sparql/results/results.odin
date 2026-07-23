// Package results serializes owned graph query results without coupling the
// query engine to a concrete RDF syntax.
package results

import "core:strings"
import "core:unicode/utf8"
import rdf "odin-rdf:rdf"
import ntriples "odin-rdf:rdf/ntriples"
import turtle "odin-rdf:rdf/turtle"
import engine "../engine"

Error_Code :: enum { None, Not_Graph_Result, Not_Bindings_Result, Invalid_UTF8, Invalid_XML_Character, NTriples_Error, Turtle_Error }

error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:            return "no error"
	case .Not_Graph_Result:return "result is not an RDF graph"
	case .Not_Bindings_Result:return "result is not a SELECT or ASK result"
	case .Invalid_UTF8:    return "SPARQL result contains invalid UTF-8"
	case .Invalid_XML_Character:return "SPARQL result contains a character forbidden by XML 1.0"
	case .NTriples_Error:  return "RDF graph cannot be written as N-Triples"
	case .Turtle_Error:    return "RDF graph cannot be written as Turtle"
	}
	return "unknown graph-result serialization error"
}

@(private) csv_field :: proc(builder: ^strings.Builder, value: string) -> Error_Code {
	if !utf8.valid_string(value) do return .Invalid_UTF8
	quoted := false
	for character in value {
		if character == ',' || character == '"' || character == '\n' || character == '\r' { quoted = true; break }
	}
	if quoted do strings.write_byte(builder, '"')
	for character in value {
		if character == '"' {
			strings.write_string(builder, "\"\"")
		} else {
			strings.write_rune(builder, character)
		}
	}
	if quoted do strings.write_byte(builder, '"')
	return .None
}

@(private) write_blank_node_label :: proc(builder: ^strings.Builder, index: int) {
	// Spreadsheet-oriented CSV uses alphabetic labels, while TSV follows the
	// conventional b0, b1, ... form. This helper emits a stable base-26 label.
	letters: [32]u8
	count := 0
	value := index
	for {
		letters[count] = 'a' + u8(value % 26)
		count += 1
		value = value / 26 - 1
		if value < 0 do break
	}
	for position := count - 1; position >= 0; position -= 1 do strings.write_byte(builder, letters[position])
}

@(private) write_csv_term :: proc(builder: ^strings.Builder, term: rdf.Term, blanks: ^[dynamic]TSV_Blank_Node) -> Error_Code {
	switch term.kind {
	case .IRI:
		return csv_field(builder, term.value)
	case .Blank_Node:
		for entry in blanks^ {
			if !same_term(entry.term, term) do continue
			strings.write_string(builder, "_:")
			write_blank_node_label(builder, entry.index)
			return .None
		}
		if _, append_error := append(blanks, TSV_Blank_Node{term = term, index = len(blanks^)}); append_error != nil do return .NTriples_Error
		strings.write_string(builder, "_:")
		write_blank_node_label(builder, len(blanks^) - 1)
		return .None
	case .Literal:
		return csv_field(builder, term.value)
	}
	return .Not_Bindings_Result
}

@(private) TSV_Blank_Node :: struct {
	term:  rdf.Term,
	index: int,
}

@(private) same_term :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value && left.language == right.language && left.datatype == right.datatype && left.scope == right.scope
}

@(private) XSD_INTEGER :: "http://www.w3.org/2001/XMLSchema#integer"
@(private) XSD_DECIMAL :: "http://www.w3.org/2001/XMLSchema#decimal"
@(private) XSD_DOUBLE :: "http://www.w3.org/2001/XMLSchema#double"
@(private) XSD_FLOAT :: "http://www.w3.org/2001/XMLSchema#float"
@(private) XSD_BOOLEAN :: "http://www.w3.org/2001/XMLSchema#boolean"

@(private) digits_only :: proc(value: string) -> bool {
	if len(value) == 0 do return false
	for character in value do if character < '0' || character > '9' do return false
	return true
}

@(private) numeric_lexical_start :: proc(value: string) -> int {
	if len(value) > 0 && (value[0] == '+' || value[0] == '-') do return 1
	return 0
}

@(private) valid_integer_lexical :: proc(value: string) -> bool {
	start := numeric_lexical_start(value)
	return start < len(value) && digits_only(value[start:])
}

@(private) valid_decimal_lexical :: proc(value: string) -> bool {
	start := numeric_lexical_start(value)
	dot := strings.index_byte(value[start:], '.')
	if dot < 0 do return false
	dot += start
	return digits_only(value[start:dot]) && digits_only(value[dot + 1:])
}

@(private) valid_double_lexical :: proc(value: string) -> bool {
	if value == "INF" || value == "-INF" || value == "NaN" do return true
	start := numeric_lexical_start(value)
	exponent := -1
	for index in start..<len(value) {
		if value[index] == 'e' || value[index] == 'E' { exponent = index; break }
	}
	if exponent < 0 do return false
	mantissa := value[start:exponent]
	exponent_start := exponent + 1
	if exponent_start < len(value) && (value[exponent_start] == '+' || value[exponent_start] == '-') do exponent_start += 1
	if !digits_only(value[exponent_start:]) do return false
	if strings.index_byte(mantissa, '.') < 0 do return digits_only(mantissa)
	dot := strings.index_byte(mantissa, '.')
	return dot > 0 && dot + 1 < len(mantissa) && digits_only(mantissa[:dot]) && digits_only(mantissa[dot + 1:])
}

@(private) write_tsv_numeric :: proc(builder: ^strings.Builder, value: string) {
	for character in value do strings.write_rune(builder, character == 'E' ? 'e' : character)
}

@(private) write_tsv_term :: proc(builder: ^strings.Builder, term: rdf.Term, blanks: ^[dynamic]TSV_Blank_Node) -> Error_Code {
	if term.kind == .Blank_Node {
		for entry in blanks^ {
			if !same_term(entry.term, term) do continue
			strings.write_string(builder, "_:b")
			strings.write_int(builder, entry.index)
			return .None
		}
		index := len(blanks^)
		if _, append_error := append(blanks, TSV_Blank_Node{term = term, index = index}); append_error != nil do return .NTriples_Error
		strings.write_string(builder, "_:b")
		strings.write_int(builder, index)
		return .None
	}
	if term.kind == .Literal && len(term.language) == 0 {
		if term.datatype == XSD_BOOLEAN && (term.value == "true" || term.value == "false") {
			strings.write_string(builder, term.value)
			return .None
		}
		if term.datatype == XSD_INTEGER && valid_integer_lexical(term.value) {
			strings.write_string(builder, term.value)
			return .None
		}
		if term.datatype == XSD_DECIMAL && valid_decimal_lexical(term.value) {
			strings.write_string(builder, term.value)
			return .None
		}
		if (term.datatype == XSD_DOUBLE || term.datatype == XSD_FLOAT) && valid_double_lexical(term.value) {
			write_tsv_numeric(builder, term.value)
			return .None
		}
	}
	if ntriples.write_term(builder, term) != .None do return .NTriples_Error
	return .None
}

// write_sparql_csv writes the SPARQL 1.1 Results CSV representation for
// SELECT and ASK results. It is atomic; CSV intentionally serializes only a
// term's lexical value, except that blank nodes retain their `_:` marker.
write_sparql_csv :: proc(builder: ^strings.Builder, result: ^engine.Result) -> Error_Code {
	if engine.Kind(result) != .Select && engine.Kind(result) != .Ask do return .Not_Bindings_Result
	temporary := strings.builder_make()
	defer strings.builder_destroy(&temporary)
	if engine.Kind(result) == .Ask {
		value, ok := engine.Ask_Value(result)
		if !ok do return .Not_Bindings_Result
		strings.write_string(&temporary, "boolean\n")
		strings.write_string(&temporary, value ? "true\n" : "false\n")
	} else {
		blanks := make([dynamic]TSV_Blank_Node)
		defer delete(blanks)
		for column in 0..<engine.Variable_Count(result) {
			if column > 0 do strings.write_byte(&temporary, ',')
			name, ok := engine.Variable_Name(result, column)
			if !ok do return .Not_Bindings_Result
			if error := csv_field(&temporary, name); error != .None do return error
		}
		strings.write_byte(&temporary, '\n')
		for row in 0..<engine.Row_Count(result) {
			for column in 0..<engine.Variable_Count(result) {
				if column > 0 do strings.write_byte(&temporary, ',')
				term, bound, ok := engine.Cell(result, row, column)
				if !ok do return .Not_Bindings_Result
				if bound { if error := write_csv_term(&temporary, term, &blanks); error != .None do return error }
			}
			strings.write_byte(&temporary, '\n')
		}
	}
	strings.write_string(builder, strings.to_string(temporary))
	return .None
}

// write_sparql_tsv writes the SPARQL 1.1 Results TSV representation for
// SELECT and ASK results. Bound cells use N-Triples-compatible term syntax;
// blank-node labels are assigned deterministically within this document.
write_sparql_tsv :: proc(builder: ^strings.Builder, result: ^engine.Result) -> Error_Code {
	if engine.Kind(result) != .Select && engine.Kind(result) != .Ask do return .Not_Bindings_Result
	temporary := strings.builder_make()
	defer strings.builder_destroy(&temporary)
	if engine.Kind(result) == .Ask {
		value, ok := engine.Ask_Value(result)
		if !ok do return .Not_Bindings_Result
		strings.write_string(&temporary, "?boolean\n")
		strings.write_string(&temporary, value ? "true\n" : "false\n")
	} else {
		for column in 0..<engine.Variable_Count(result) {
			if column > 0 do strings.write_byte(&temporary, '\t')
			name, ok := engine.Variable_Name(result, column)
			if !ok || !utf8.valid_string(name) do return .Not_Bindings_Result
			strings.write_byte(&temporary, '?')
			strings.write_string(&temporary, name)
		}
		strings.write_byte(&temporary, '\n')
		blanks := make([dynamic]TSV_Blank_Node)
		defer delete(blanks)
		for row in 0..<engine.Row_Count(result) {
			for column in 0..<engine.Variable_Count(result) {
				if column > 0 do strings.write_byte(&temporary, '\t')
				term, bound, ok := engine.Cell(result, row, column)
				if !ok do return .Not_Bindings_Result
				if bound { if error := write_tsv_term(&temporary, term, &blanks); error != .None do return error }
			}
			strings.write_byte(&temporary, '\n')
		}
	}
	strings.write_string(builder, strings.to_string(temporary))
	return .None
}

@(private) write_json_string :: proc(builder: ^strings.Builder, value: string) -> Error_Code {
	if !utf8.valid_string(value) do return .Invalid_UTF8
	strings.write_byte(builder, '"')
	for character in value {
		switch character {
		case '"': strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\b': strings.write_string(builder, "\\b")
		case '\f': strings.write_string(builder, "\\f")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if character < 0x20 {
				hex := "0123456789abcdef"
				strings.write_string(builder, "\\u00")
				strings.write_byte(builder, hex[u8(character >> 4)])
				strings.write_byte(builder, hex[u8(character & 0x0f)])
			} else {
				strings.write_rune(builder, character)
			}
		}
	}
	strings.write_byte(builder, '"')
	return .None
}

@(private) write_json_term :: proc(builder: ^strings.Builder, term: rdf.Term) -> Error_Code {
	strings.write_string(builder, "{\"type\":")
	if term.kind == .IRI { if error := write_json_string(builder, "uri"); error != .None do return error
	} else if term.kind == .Blank_Node { if error := write_json_string(builder, "bnode"); error != .None do return error
	} else if term.kind == .Literal { if error := write_json_string(builder, "literal"); error != .None do return error
	} else { return .Not_Bindings_Result }
	strings.write_string(builder, ",\"value\":")
	if error := write_json_string(builder, term.value); error != .None do return error
	if term.kind == .Literal && len(term.language) != 0 {
		strings.write_string(builder, ",\"xml:lang\":")
		if error := write_json_string(builder, term.language); error != .None do return error
	} else if term.kind == .Literal && term.datatype != rdf.XSD_STRING {
		strings.write_string(builder, ",\"datatype\":")
		if error := write_json_string(builder, term.datatype); error != .None do return error
	}
	strings.write_byte(builder, '}')
	return .None
}

@(private) valid_xml_character :: proc(character: rune) -> bool {
	return character == '\t' || character == '\n' || character == '\r' ||
		(character >= 0x20 && character <= 0xd7ff) ||
		(character >= 0xe000 && character <= 0xfffd) ||
		(character >= 0x10000 && character <= 0x10ffff)
}

@(private) write_xml_text :: proc(builder: ^strings.Builder, value: string) -> Error_Code {
	if !utf8.valid_string(value) do return .Invalid_UTF8
	for character in value {
		if !valid_xml_character(character) do return .Invalid_XML_Character
		switch character {
		case '&': strings.write_string(builder, "&amp;")
		case '<': strings.write_string(builder, "&lt;")
		case '>': strings.write_string(builder, "&gt;")
		case '"': strings.write_string(builder, "&quot;")
		case '\'': strings.write_string(builder, "&apos;")
		case: strings.write_rune(builder, character)
		}
	}
	return .None
}

@(private) write_xml_binding :: proc(builder: ^strings.Builder, name: string, term: rdf.Term) -> Error_Code {
	strings.write_string(builder, "<binding name=\"")
	if error := write_xml_text(builder, name); error != .None do return error
	strings.write_string(builder, "\">")
	if term.kind == .IRI {
		strings.write_string(builder, "<uri>")
		if error := write_xml_text(builder, term.value); error != .None do return error
		strings.write_string(builder, "</uri>")
	} else if term.kind == .Blank_Node {
		strings.write_string(builder, "<bnode>")
		if error := write_xml_text(builder, term.value); error != .None do return error
		strings.write_string(builder, "</bnode>")
	} else if term.kind == .Literal {
		strings.write_string(builder, "<literal")
		if len(term.language) != 0 {
			strings.write_string(builder, " xml:lang=\"")
			if error := write_xml_text(builder, term.language); error != .None do return error
			strings.write_byte(builder, '"')
		} else if term.datatype != rdf.XSD_STRING {
			strings.write_string(builder, " datatype=\"")
			if error := write_xml_text(builder, term.datatype); error != .None do return error
			strings.write_byte(builder, '"')
		}
		strings.write_byte(builder, '>')
		if error := write_xml_text(builder, term.value); error != .None do return error
		strings.write_string(builder, "</literal>")
	} else { return .Not_Bindings_Result }
	strings.write_string(builder, "</binding>")
	return .None
}

// write_sparql_xml writes the SPARQL 1.1 Results XML document for SELECT/ASK.
write_sparql_xml :: proc(builder: ^strings.Builder, result: ^engine.Result) -> Error_Code {
	if engine.Kind(result) != .Select && engine.Kind(result) != .Ask do return .Not_Bindings_Result
	temporary := strings.builder_make()
	defer strings.builder_destroy(&temporary)
	strings.write_string(&temporary, "<?xml version=\"1.0\"?><sparql xmlns=\"http://www.w3.org/2005/sparql-results#\"><head>")
	if engine.Kind(result) == .Select {
		for index in 0..<engine.Variable_Count(result) {
			name, ok := engine.Variable_Name(result, index)
			if !ok { return .Not_Bindings_Result }
			strings.write_string(&temporary, "<variable name=\"")
			if error := write_xml_text(&temporary, name); error != .None do return error
			strings.write_string(&temporary, "\"/>")
		}
		strings.write_string(&temporary, "</head><results>")
		for row in 0..<engine.Row_Count(result) {
			strings.write_string(&temporary, "<result>")
			for column in 0..<engine.Variable_Count(result) {
				term, bound, ok := engine.Cell(result, row, column)
				if !ok { return .Not_Bindings_Result }
				if !bound do continue
				name, _ := engine.Variable_Name(result, column)
				if error := write_xml_binding(&temporary, name, term); error != .None do return error
			}
			strings.write_string(&temporary, "</result>")
		}
		strings.write_string(&temporary, "</results>")
	} else {
		value, ok := engine.Ask_Value(result)
		if !ok { return .Not_Bindings_Result }
		strings.write_string(&temporary, "</head><boolean>")
		strings.write_string(&temporary, value ? "true" : "false")
		strings.write_string(&temporary, "</boolean>")
	}
	strings.write_string(&temporary, "</sparql>")
	strings.write_string(builder, strings.to_string(temporary))
	return .None
}

// write_sparql_json writes the SPARQL 1.1 Query Results JSON representation
// for SELECT and ASK results. It is atomic and preserves row/binding order.
write_sparql_json :: proc(builder: ^strings.Builder, result: ^engine.Result) -> Error_Code {
	if engine.Kind(result) != .Select && engine.Kind(result) != .Ask do return .Not_Bindings_Result
	temporary := strings.builder_make()
	defer strings.builder_destroy(&temporary)
	strings.write_string(&temporary, "{\"head\":{")
	if engine.Kind(result) == .Select {
		strings.write_string(&temporary, "\"vars\":[")
		for index in 0..<engine.Variable_Count(result) {
			if index > 0 do strings.write_byte(&temporary, ',')
			name, ok := engine.Variable_Name(result, index)
			if !ok { return .Not_Bindings_Result }
			if error := write_json_string(&temporary, name); error != .None do return error
		}
		strings.write_string(&temporary, "]},\"results\":{\"bindings\":[")
		for row in 0..<engine.Row_Count(result) {
			if row > 0 do strings.write_byte(&temporary, ',')
			strings.write_byte(&temporary, '{')
			written := 0
			for column in 0..<engine.Variable_Count(result) {
				term, bound, ok := engine.Cell(result, row, column)
				if !ok { return .Not_Bindings_Result }
				if !bound do continue
				if written > 0 do strings.write_byte(&temporary, ',')
				name, _ := engine.Variable_Name(result, column)
				if error := write_json_string(&temporary, name); error != .None do return error
				strings.write_byte(&temporary, ':')
				if error := write_json_term(&temporary, term); error != .None do return error
				written += 1
			}
			strings.write_byte(&temporary, '}')
		}
		strings.write_string(&temporary, "]}}")
	} else {
		value, ok := engine.Ask_Value(result)
		if !ok { return .Not_Bindings_Result }
		strings.write_string(&temporary, "},\"boolean\":")
		strings.write_string(&temporary, value ? "true" : "false")
		strings.write_byte(&temporary, '}')
	}
	strings.write_string(builder, strings.to_string(temporary))
	return .None
}

// write_ntriples appends stable N-Triples records for a CONSTRUCT or DESCRIBE
// result. It is atomic: a serialization error leaves builder unchanged.
write_ntriples :: proc(builder: ^strings.Builder, result: ^engine.Result) -> Error_Code {
	if engine.Kind(result) != .Graph do return .Not_Graph_Result
	temporary := strings.builder_make()
	defer strings.builder_destroy(&temporary)
	for index in 0..<engine.Triple_Count(result) {
		triple, ok := engine.Triple(result, index)
		if !ok || ntriples.write_triple(&temporary, triple) != .None do return .NTriples_Error
	}
	strings.write_string(builder, strings.to_string(temporary))
	return .None
}

// write_turtle emits one stable triple statement per line. Prefix declarations
// are intentionally caller-controlled through writer options.
write_turtle :: proc(builder: ^strings.Builder, result: ^engine.Result, options: turtle.Writer_Options = {}) -> Error_Code {
	if engine.Kind(result) != .Graph do return .Not_Graph_Result
	temporary := strings.builder_make()
	defer strings.builder_destroy(&temporary)
	if turtle.write_prefixes(&temporary, options.prefixes) != .None do return .Turtle_Error
	for index in 0..<engine.Triple_Count(result) {
		triple, ok := engine.Triple(result, index)
		if !ok || turtle.write_triple(&temporary, triple, options) != .None do return .Turtle_Error
	}
	strings.write_string(builder, strings.to_string(temporary))
	return .None
}
