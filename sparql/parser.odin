package sparql

import lexer "./internal/lexer"
import "core:strings"
import "core:strconv"

// Parse_Error_Code identifies lexical, grammar, and allocation outcomes.
Error_Code :: enum {
	None,
	Lexical,
	Expected_Query_Form,
	Expected_IRI,
	Expected_Prefix,
	Expected_Variable,
	Expected_Term,
	Expected_Predicate,
	Expected_Expression,
	Expected_Left_Paren,
	Expected_Right_Paren,
	Expected_As,
	Expected_By,
	Expected_Integer,
	Expected_Where,
	Expected_Left_Brace,
	Expected_Right_Brace,
	Expected_Dot,
	Invalid_Query,
	Unsupported_Syntax,
	Out_Of_Memory,
}

// Parse_Error contains a stable code and original-query source span. For a
// lexical failure, lexical_code preserves the internal lexer diagnosis.
Parse_Error :: struct {
	code:         Error_Code,
	lexical_code: lexer.Error_Code,
	span:         Source_Span,
}

// error_message returns a stable allocation-free diagnostic for a parse code.
error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:                return "no error"
	case .Lexical:             return "invalid SPARQL token"
	case .Expected_Query_Form: return "expected SPARQL query form"
	case .Expected_IRI:        return "expected IRI reference"
	case .Expected_Prefix:     return "expected prefix name"
	case .Expected_Variable:   return "expected query variable"
	case .Expected_Term:       return "expected graph term"
	case .Expected_Predicate:  return "expected graph predicate"
	case .Expected_Expression: return "expected SPARQL expression"
	case .Expected_Left_Paren: return "expected opening parenthesis"
	case .Expected_Right_Paren:return "expected closing parenthesis"
	case .Expected_As:         return "expected AS"
	case .Expected_By:         return "expected BY"
	case .Expected_Integer:    return "expected integer"
	case .Expected_Where:      return "expected WHERE clause"
	case .Expected_Left_Brace: return "expected opening graph-pattern brace"
	case .Expected_Right_Brace:return "expected closing graph-pattern brace"
	case .Expected_Dot:        return "expected triple-pattern dot"
	case .Invalid_Query:       return "invalid SPARQL query form or scope"
	case .Unsupported_Syntax:  return "SPARQL syntax is not implemented yet"
	case .Out_Of_Memory:       return "memory allocation failed"
	}
	return "unknown parse error"
}

@(private) Parser :: struct {
	scanner: lexer.Scanner,
	current: lexer.Token,
}

@(private) source_position :: proc(value: lexer.Position) -> Source_Position {
	return Source_Position{byte_offset = value.byte_offset, line = value.line, column = value.column}
}

@(private) source_span :: proc(value: lexer.Span) -> Source_Span {
	return Source_Span{start = source_position(value.start), end = source_position(value.end)}
}

@(private) error_at :: proc(parser: ^Parser, code: Error_Code) -> Parse_Error {
	return Parse_Error{code = code, span = source_span(parser.current.span)}
}

@(private) advance :: proc(parser: ^Parser) -> Parse_Error {
	token, lexical_error := lexer.next(&parser.scanner)
	if lexical_error.code != .None {
		return Parse_Error{code = .Lexical, lexical_code = lexical_error.code, span = source_span(lexical_error.span)}
	}
	parser.current = token
	return {}
}

@(private) append_prefix :: proc(query: ^Query, value: Prefix_Decl) -> bool {
	_, error := append(&query.prefixes, value)
	return error == nil
}

// A subquery is parsed as its own Query for ownership and scope validation,
// but it inherits the enclosing prologue. Prefix declarations are immutable
// AST values whose strings remain owned by the enclosing query.
@(private) inherit_subquery_prologue :: proc(parent, child: ^Query) -> bool {
	child.has_base = parent.has_base
	child.base = parent.base
	for declaration in parent.prefixes {
		if !append_prefix(child, declaration) do return false
	}
	return true
}

@(private) append_projection :: proc(query: ^Query, value: Term) -> bool {
	_, error := append(&query.select.projection, value)
	if error != nil do return false
	_, expression_error := append(&query.select.projection_expressions, Invalid_Expression)
	return expression_error == nil
}

@(private) append_expression_projection :: proc(query: ^Query, variable: Term, expression: int) -> bool {
	_, variable_error := append(&query.select.projection, variable)
	if variable_error != nil do return false
	_, expression_error := append(&query.select.projection_expressions, expression)
	return expression_error == nil
}

@(private) append_dataset :: proc(query: ^Query, value: Dataset_Clause) -> bool {
	_, error := append(&query.dataset, value)
	return error == nil
}

@(private) append_describe_term :: proc(query: ^Query, value: Term) -> bool {
	_, error := append(&query.describe.terms, value)
	return error == nil
}

@(private) append_order_condition :: proc(query: ^Query, value: Order_Condition) -> bool {
	_, error := append(&query.order, value)
	return error == nil
}

@(private) append_group_condition :: proc(query: ^Query, expression: int, alias: Term) -> bool {
	_, expression_error := append(&query.group_by, expression)
	if expression_error != nil do return false
	_, alias_error := append(&query.group_aliases, alias)
	return alias_error == nil
}

@(private) append_having_condition :: proc(query: ^Query, expression: int) -> bool {
	_, error := append(&query.having, expression)
	return error == nil
}

@(private) append_pattern_to :: proc(patterns: ^[dynamic]Triple_Pattern, value: Triple_Pattern) -> bool {
	_, error := append(patterns, value)
	return error == nil
}

@(private) append_standalone_node :: proc(query: ^Query, basic: int, value: Term) -> bool {
	_, error := append(&query.patterns[basic].standalone_nodes, value)
	return error == nil
}

@(private) append_pattern_child :: proc(query: ^Query, parent, child: int) -> bool {
	_, error := append(&query.patterns[parent].children, child)
	return error == nil
}

@(private) add_pattern :: proc(query: ^Query, kind: Pattern_Kind, span: Source_Span) -> (int, bool) {
	pattern := Pattern_Node{
		kind = kind,
		span = span,
		triples = make([dynamic]Triple_Pattern),
		standalone_nodes = make([dynamic]Term),
		children = make([dynamic]int),
		expression = Invalid_Expression,
		values_variables = make([dynamic]Term),
		values_rows = make([dynamic]Values_Row),
		subquery = -1,
	}
	_, error := append(&query.patterns, pattern)
	if error != nil {
		delete(pattern.triples)
		delete(pattern.standalone_nodes)
		delete(pattern.children)
		delete(pattern.values_variables)
		delete(pattern.values_rows)
		return Invalid_Pattern, false
	}
	return len(query.patterns) - 1, true
}

@(private) append_subquery :: proc(query: ^Query, subquery: Query) -> (int, bool) {
	_, error := append(&query.subqueries, subquery)
	if error != nil do return -1, false
	return len(query.subqueries) - 1, true
}

@(private) add_term_node :: proc(query: ^Query, kind: Term_Node_Kind, span: Source_Span) -> (int, bool) {
	node := Term_Node{kind = kind, span = span, properties = make([dynamic]Property_List), items = make([dynamic]Term)}
	_, error := append(&query.term_nodes, node)
	if error != nil {
		delete(node.properties)
		delete(node.items)
		return Invalid_Term_Node, false
	}
	return len(query.term_nodes) - 1, true
}

@(private) add_node_property :: proc(query: ^Query, node: int, predicate: Term, path: int, span: Source_Span) -> (int, bool) {
	property := Property_List{predicate = predicate, path = path, objects = make([dynamic]Term), span = span}
	_, error := append(&query.term_nodes[node].properties, property)
	if error != nil {
		delete(property.objects)
		return -1, false
	}
	return len(query.term_nodes[node].properties) - 1, true
}

@(private) append_node_property_object :: proc(query: ^Query, node, property: int, object: Term) -> bool {
	_, error := append(&query.term_nodes[node].properties[property].objects, object)
	return error == nil
}

@(private) append_node_item :: proc(query: ^Query, node: int, item: Term) -> bool {
	_, error := append(&query.term_nodes[node].items, item)
	return error == nil
}

@(private) add_path :: proc(query: ^Query, kind: Path_Kind, span: Source_Span, term: Term = {}) -> (int, bool) {
	path := Path_Node{
		kind = kind,
		span = span,
		term = term,
		children = make([dynamic]int),
		negated_terms = make([dynamic]Term),
		negated_inverse = make([dynamic]bool),
	}
	_, error := append(&query.paths, path)
	if error != nil {
		delete(path.children)
		delete(path.negated_terms)
		delete(path.negated_inverse)
		return Invalid_Path, false
	}
	return len(query.paths) - 1, true
}

@(private) append_path_child :: proc(query: ^Query, path, child: int) -> bool {
	_, error := append(&query.paths[path].children, child)
	return error == nil
}

@(private) append_negated_path_term :: proc(query: ^Query, path: int, term: Term, inverse: bool) -> bool {
	_, term_error := append(&query.paths[path].negated_terms, term)
	if term_error != nil do return false
	_, inverse_error := append(&query.paths[path].negated_inverse, inverse)
	return inverse_error == nil
}

@(private) append_expression_child :: proc(query: ^Query, parent, child: int) -> bool {
	_, error := append(&query.expressions[parent].children, child)
	return error == nil
}

@(private) append_values_variable :: proc(query: ^Query, pattern: int, variable: Term) -> bool {
	_, error := append(&query.patterns[pattern].values_variables, variable)
	return error == nil
}

@(private) append_values_row :: proc(query: ^Query, pattern: int, span: Source_Span) -> (int, bool) {
	row := Values_Row{values = make([dynamic]Term), unbound = make([dynamic]bool), span = span}
	_, error := append(&query.patterns[pattern].values_rows, row)
	if error != nil {
		delete(row.values)
		delete(row.unbound)
		return -1, false
	}
	return len(query.patterns[pattern].values_rows) - 1, true
}

@(private) append_values_cell :: proc(query: ^Query, pattern, row: int, value: Term, unbound: bool) -> bool {
	_, value_error := append(&query.patterns[pattern].values_rows[row].values, value)
	if value_error != nil do return false
	_, unbound_error := append(&query.patterns[pattern].values_rows[row].unbound, unbound)
	return unbound_error == nil
}

@(private) add_expression :: proc(query: ^Query, value: Expression_Node) -> (int, bool) {
	expression := value
	expression.children = make([dynamic]int)
	_, error := append(&query.expressions, expression)
	if error != nil {
		delete(expression.children)
		return Invalid_Expression, false
	}
	return len(query.expressions) - 1, true
}

@(private) parse_verb :: proc(parser: ^Parser, query: ^Query) -> (Term, Parse_Error) {
	term, error := parse_term(parser, query)
	if error.code != .None do return {}, error
	#partial switch term.kind {
	case .Variable, .IRIREF, .Prefixed_Name, .RDF_Type:
		return term, {}
	case:
		return {}, Parse_Error{code = .Expected_Predicate, span = term.span}
	}
}

@(private) parse_path_primary :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	if parser.current.kind == .Left_Paren {
		start := source_span(parser.current.span).start
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		path, path_error := parse_path_alternative(parser, query)
		if path_error.code != .None do return Invalid_Path, path_error
		if parser.current.kind != .Right_Paren do return Invalid_Path, error_at(parser, .Expected_Right_Paren)
		query.paths[path].span.start = start
		query.paths[path].span.end = source_span(parser.current.span).end
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		return path, {}
	}
	if parser.current.kind == .Bang {
		start := source_span(parser.current.span).start
		negated, ok := add_path(query, .Negated_Set, {start = start, end = start})
		if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = start}}
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		parenthesized := parser.current.kind == .Left_Paren
		if parenthesized {
			if error := advance(parser); error.code != .None do return Invalid_Path, error
		}
		for {
			inverse := false
			if parser.current.kind == .Caret {
				inverse = true
				if error := advance(parser); error.code != .None do return Invalid_Path, error
			}
			term, term_error := parse_verb(parser, query)
			if term_error.code != .None do return Invalid_Path, term_error
			if !append_negated_path_term(query, negated, term, inverse) do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = term.span}
			query.paths[negated].span.end = term.span.end
			if !parenthesized || parser.current.kind != .Pipe do break
			if error := advance(parser); error.code != .None do return Invalid_Path, error
		}
		if parenthesized {
			if parser.current.kind != .Right_Paren do return Invalid_Path, error_at(parser, .Expected_Right_Paren)
			query.paths[negated].span.end = source_span(parser.current.span).end
			if error := advance(parser); error.code != .None do return Invalid_Path, error
		}
		return negated, {}
	}
	term, term_error := parse_verb(parser, query)
	if term_error.code != .None do return Invalid_Path, term_error
	path, ok := add_path(query, .Term, term.span, term)
	if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = term.span}
	return path, {}
}

@(private) parse_path_elt :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	start := source_span(parser.current.span).start
	inverse := parser.current.kind == .Caret
	if inverse {
		if error := advance(parser); error.code != .None do return Invalid_Path, error
	}
	path, path_error := parse_path_primary(parser, query)
	if path_error.code != .None do return Invalid_Path, path_error
	if inverse {
		inverse_path, ok := add_path(query, .Inverse, {start = start, end = query.paths[path].span.end})
		if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.paths[path].span.end}}
		if !append_path_child(query, inverse_path, path) do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = query.paths[inverse_path].span}
		path = inverse_path
	}
	modifier: Path_Kind
	#partial switch parser.current.kind {
	case .Star: modifier = .Zero_Or_More
	case .Plus: modifier = .One_Or_More
	case .Question: modifier = .Zero_Or_One
	case .Left_Brace:
		bounded_start := query.paths[path].span.start
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		if parser.current.kind != .Integer do return Invalid_Path, error_at(parser, .Expected_Integer)
		minimum, minimum_ok := strconv.parse_int(parser.current.lexeme, 10)
		if !minimum_ok || minimum < 0 do return Invalid_Path, error_at(parser, .Invalid_Query)
		maximum := minimum
		has_maximum := true
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		if parser.current.kind == .Comma {
			if error := advance(parser); error.code != .None do return Invalid_Path, error
			if parser.current.kind == .Right_Brace {
				has_maximum = false
			} else {
				if parser.current.kind != .Integer do return Invalid_Path, error_at(parser, .Expected_Integer)
				maximum_value, maximum_ok := strconv.parse_int(parser.current.lexeme, 10)
				if !maximum_ok || maximum_value < minimum do return Invalid_Path, error_at(parser, .Invalid_Query)
				maximum = maximum_value
				if error := advance(parser); error.code != .None do return Invalid_Path, error
			}
		}
		if parser.current.kind != .Right_Brace do return Invalid_Path, error_at(parser, .Expected_Right_Brace)
		end := source_span(parser.current.span).end
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		bounded, ok := add_path(query, .Bounded, {start = bounded_start, end = end})
		if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = {start = bounded_start, end = end}}
		query.paths[bounded].minimum = minimum
		query.paths[bounded].maximum = maximum
		query.paths[bounded].has_maximum = has_maximum
		if !append_path_child(query, bounded, path) do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = query.paths[bounded].span}
		return bounded, {}
	case: return path, {}
	}
	end := source_span(parser.current.span).end
	if error := advance(parser); error.code != .None do return Invalid_Path, error
	modified, ok := add_path(query, modifier, {start = query.paths[path].span.start, end = end})
	if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = {start = query.paths[path].span.start, end = end}}
	if !append_path_child(query, modified, path) do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = query.paths[modified].span}
	return modified, {}
}

@(private) parse_path_sequence :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_path_elt(parser, query)
	if left_error.code != .None do return Invalid_Path, left_error
	for parser.current.kind == .Slash {
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		right, right_error := parse_path_elt(parser, query)
		if right_error.code != .None do return Invalid_Path, right_error
		sequence, ok := add_path(query, .Sequence, {start = query.paths[left].span.start, end = query.paths[right].span.end})
		if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = {start = query.paths[left].span.start, end = query.paths[right].span.end}}
		if !append_path_child(query, sequence, left) || !append_path_child(query, sequence, right) do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = query.paths[sequence].span}
		left = sequence
	}
	return left, {}
}

@(private) parse_path_alternative :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_path_sequence(parser, query)
	if left_error.code != .None do return Invalid_Path, left_error
	for parser.current.kind == .Pipe {
		if error := advance(parser); error.code != .None do return Invalid_Path, error
		right, right_error := parse_path_sequence(parser, query)
		if right_error.code != .None do return Invalid_Path, right_error
		alternative, ok := add_path(query, .Alternative, {start = query.paths[left].span.start, end = query.paths[right].span.end})
		if !ok do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = {start = query.paths[left].span.start, end = query.paths[right].span.end}}
		if !append_path_child(query, alternative, left) || !append_path_child(query, alternative, right) do return Invalid_Path, Parse_Error{code = .Out_Of_Memory, span = query.paths[alternative].span}
		left = alternative
	}
	return left, {}
}

@(private) parse_property_path :: proc(parser: ^Parser, query: ^Query) -> (Term, int, Parse_Error) {
	path, path_error := parse_path_alternative(parser, query)
	if path_error.code != .None do return {}, Invalid_Path, path_error
	return query.paths[path].term, path, {}
}

@(private) parse_describe_target :: proc(parser: ^Parser, query: ^Query) -> (Term, Parse_Error) {
	term, error := parse_term(parser, query)
	if error.code != .None do return {}, error
	#partial switch term.kind {
	case .Variable, .IRIREF, .Prefixed_Name:
		return term, {}
	case:
		return {}, Parse_Error{code = .Expected_Term, span = term.span}
	}
}

@(private) clone_term :: proc(query: ^Query, token: lexer.Token, kind: Term_Kind) -> (Term, Parse_Error) {
	lexical, ok := own_string(query, token.lexeme)
	if !ok do return {}, Parse_Error{code = .Out_Of_Memory, span = source_span(token.span)}
	return Term{kind = kind, lexical = lexical, syntax_node = Invalid_Term_Node, span = source_span(token.span)}, {}
}

@(private) parse_term :: proc(parser: ^Parser, query: ^Query) -> (Term, Parse_Error) {
	kind: Term_Kind
	#partial switch parser.current.kind {
	case .Variable:         kind = .Variable
	case .IRIREF:           kind = .IRIREF
	case .PName_NS, .PName_LN: kind = .Prefixed_Name
	case .Blank_Node_Label: kind = .Blank_Node_Label
	case .String:           kind = .String_Literal
	case .Integer:          kind = .Integer
	case .Decimal:          kind = .Decimal
	case .Double:           kind = .Double
	case .Name:
		if lexer.is_keyword(parser.current, "true") || lexer.is_keyword(parser.current, "false") {
			kind = .Boolean
		} else if lexer.is_keyword(parser.current, "a") {
			kind = .RDF_Type
		} else {
			return {}, error_at(parser, .Expected_Term)
		}
	case:
		return {}, error_at(parser, .Expected_Term)
	}
	term, error := clone_term(query, parser.current, kind)
	if error.code != .None do return {}, error
	if error = advance(parser); error.code != .None do return {}, error
	if kind == .String_Literal {
		if parser.current.kind == .LangTag {
			language, owned := own_string(query, parser.current.lexeme)
			if !owned do return {}, Parse_Error{code = .Out_Of_Memory, span = source_span(parser.current.span)}
			term.has_language = true
			term.language = language
			term.span.end = source_span(parser.current.span).end
			if error = advance(parser); error.code != .None do return {}, error
		} else if parser.current.kind == .Double_Caret {
			if error = advance(parser); error.code != .None do return {}, error
			if parser.current.kind != .IRIREF && parser.current.kind != .PName_NS && parser.current.kind != .PName_LN {
				return {}, error_at(parser, .Expected_IRI)
			}
			datatype, owned := own_string(query, parser.current.lexeme)
			if !owned do return {}, Parse_Error{code = .Out_Of_Memory, span = source_span(parser.current.span)}
			term.has_datatype = true
			term.datatype_kind = .IRIREF
			if parser.current.kind != .IRIREF do term.datatype_kind = .Prefixed_Name
			term.datatype_lexical = datatype
			term.span.end = source_span(parser.current.span).end
			if error = advance(parser); error.code != .None do return {}, error
		}
	}
	return term, {}
}

// parse_graph_node retains source-level [] and () structures for algebra
// lowering. It is used only where SPARQL permits TriplesNode syntax.
@(private) parse_graph_node :: proc(parser: ^Parser, query: ^Query) -> (Term, Parse_Error) {
	if parser.current.kind == .Left_Bracket {
		start := source_span(parser.current.span).start
		node, ok := add_term_node(query, .Blank_Property_List, {start = start, end = start})
		if !ok do return {}, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = start}}
		term := Term{kind = .Blank_Property_List, syntax_node = node, span = {start = start, end = start}}
		if error := advance(parser); error.code != .None do return {}, error
		for parser.current.kind != .Right_Bracket {
			if parser.current.kind == .End do return {}, error_at(parser, .Expected_Term)
			predicate, path, predicate_error := parse_property_path(parser, query)
			if predicate_error.code != .None do return {}, predicate_error
			property, property_ok := add_node_property(query, node, predicate, path, {start = predicate.span.start, end = predicate.span.end})
			if !property_ok do return {}, Parse_Error{code = .Out_Of_Memory, span = predicate.span}
			for {
				object, object_error := parse_graph_node(parser, query)
				if object_error.code != .None do return {}, object_error
				if !append_node_property_object(query, node, property, object) do return {}, Parse_Error{code = .Out_Of_Memory, span = object.span}
				query.term_nodes[node].properties[property].span.end = object.span.end
				if parser.current.kind != .Comma do break
				if error := advance(parser); error.code != .None do return {}, error
			}
			if parser.current.kind != .Semicolon do break
			if error := advance(parser); error.code != .None do return {}, error
		}
		if parser.current.kind != .Right_Bracket do return {}, error_at(parser, .Expected_Term)
		term.span.end = source_span(parser.current.span).end
		query.term_nodes[node].span = term.span
		if error := advance(parser); error.code != .None do return {}, error
		return term, {}
	}
	if parser.current.kind == .Left_Paren {
		start := source_span(parser.current.span).start
		node, ok := add_term_node(query, .Collection, {start = start, end = start})
		if !ok do return {}, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = start}}
		term := Term{kind = .Collection, syntax_node = node, span = {start = start, end = start}}
		if error := advance(parser); error.code != .None do return {}, error
		for parser.current.kind != .Right_Paren {
			if parser.current.kind == .End do return {}, error_at(parser, .Expected_Right_Paren)
			item, item_error := parse_graph_node(parser, query)
			if item_error.code != .None do return {}, item_error
			if !append_node_item(query, node, item) do return {}, Parse_Error{code = .Out_Of_Memory, span = item.span}
		}
		term.span.end = source_span(parser.current.span).end
		query.term_nodes[node].span = term.span
		if error := advance(parser); error.code != .None do return {}, error
		return term, {}
	}
	return parse_term(parser, query)
}

@(private) parse_prologue :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	for parser.current.kind == .Name && (lexer.is_keyword(parser.current, "BASE") || lexer.is_keyword(parser.current, "PREFIX")) {
		base_declaration := lexer.is_keyword(parser.current, "BASE")
		if error := advance(parser); error.code != .None do return error
		if base_declaration {
			if parser.current.kind != .IRIREF do return error_at(parser, .Expected_IRI)
			term, error := clone_term(query, parser.current, .IRIREF)
			if error.code != .None do return error
			query.base = term
			query.has_base = true
			if error = advance(parser); error.code != .None do return error
			continue
		}
		if parser.current.kind != .PName_NS do return error_at(parser, .Expected_Prefix)
		prefix, error := clone_term(query, parser.current, .Prefixed_Name)
		if error.code != .None do return error
		if error = advance(parser); error.code != .None do return error
		if parser.current.kind != .IRIREF do return error_at(parser, .Expected_IRI)
		namespace, namespace_error := clone_term(query, parser.current, .IRIREF)
		if namespace_error.code != .None do return namespace_error
		if !append_prefix(query, Prefix_Decl{prefix = prefix, namespace = namespace, span = {start = prefix.span.start, end = namespace.span.end}}) {
			return Parse_Error{code = .Out_Of_Memory, span = namespace.span}
		}
		if error = advance(parser); error.code != .None do return error
	}
	return {}
}

@(private) parse_dataset_clauses :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	for lexer.is_keyword(parser.current, "FROM") {
		start := source_span(parser.current.span).start
		if error := advance(parser); error.code != .None do return error
		named := false
		if lexer.is_keyword(parser.current, "NAMED") {
			named = true
			if error := advance(parser); error.code != .None do return error
		}
		if parser.current.kind != .IRIREF do return error_at(parser, .Expected_IRI)
		source, error := clone_term(query, parser.current, .IRIREF)
		if error.code != .None do return error
		clause := Dataset_Clause{named = named, source = source, span = {start = start, end = source.span.end}}
		if !append_dataset(query, clause) do return Parse_Error{code = .Out_Of_Memory, span = clause.span}
		if error = advance(parser); error.code != .None do return error
	}
	return {}
}

@(private) starts_non_triple_group_item :: proc(token: lexer.Token) -> bool {
	return token.kind == .Left_Brace || lexer.is_keyword(token, "OPTIONAL") || lexer.is_keyword(token, "GRAPH") ||
		lexer.is_keyword(token, "FILTER") || lexer.is_keyword(token, "BIND") || lexer.is_keyword(token, "MINUS") ||
		lexer.is_keyword(token, "VALUES") || lexer.is_keyword(token, "SERVICE")
}

@(private) parse_triples_block :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	start := source_span(parser.current.span).start
	basic, basic_ok := add_pattern(query, .Basic_Graph_Pattern, {start = start, end = start})
	if !basic_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = start}}

	for {
		if parser.current.kind == .End || parser.current.kind == .Right_Brace || starts_non_triple_group_item(parser.current) do break
		subject, error := parse_graph_node(parser, query)
		if error.code != .None do return Invalid_Pattern, error
		if (subject.kind == .Blank_Property_List || subject.kind == .Collection) &&
			(parser.current.kind == .Dot || parser.current.kind == .Right_Brace || starts_non_triple_group_item(parser.current)) {
			if !append_standalone_node(query, basic, subject) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = subject.span}
			if parser.current.kind == .Dot {
				if error = advance(parser); error.code != .None do return Invalid_Pattern, error
				continue
			}
			break
		}
		need_predicate := true
		for need_predicate || parser.current.kind == .Semicolon {
			if !need_predicate {
				if error = advance(parser); error.code != .None do return Invalid_Pattern, error
				if parser.current.kind == .Dot || parser.current.kind == .Right_Brace || starts_non_triple_group_item(parser.current) do break
			}
			predicate, path, predicate_error := parse_property_path(parser, query)
			if predicate_error.code != .None do return Invalid_Pattern, predicate_error
			for {
				object, object_error := parse_graph_node(parser, query)
				if object_error.code != .None do return Invalid_Pattern, object_error
				triple := Triple_Pattern{subject = subject, predicate = predicate, path = path, object = object, span = {start = subject.span.start, end = object.span.end}}
				if !append_pattern_to(&query.patterns[basic].triples, triple) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = triple.span}
				if parser.current.kind != .Comma do break
				if error = advance(parser); error.code != .None do return Invalid_Pattern, error
			}
			need_predicate = false
		}
		if parser.current.kind == .Dot {
			if error = advance(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if parser.current.kind == .Right_Brace || starts_non_triple_group_item(parser.current) do break
		return Invalid_Pattern, error_at(parser, .Expected_Dot)
	}
	if len(query.patterns[basic].triples) == 0 && len(query.patterns[basic].standalone_nodes) == 0 do return Invalid_Pattern, error_at(parser, .Expected_Term)
	if len(query.patterns[basic].triples) > 0 {
		query.patterns[basic].span.end = query.patterns[basic].triples[len(query.patterns[basic].triples) - 1].span.end
	} else {
		query.patterns[basic].span.end = query.patterns[basic].standalone_nodes[len(query.patterns[basic].standalone_nodes) - 1].span.end
	}
	return basic, {}
}

@(private) parse_graph_name :: proc(parser: ^Parser, query: ^Query) -> (Term, Parse_Error) {
	term, error := parse_term(parser, query)
	if error.code != .None do return {}, error
	#partial switch term.kind {
	case .Variable, .IRIREF, .Prefixed_Name:
		return term, {}
	case:
		return {}, Parse_Error{code = .Expected_Term, span = term.span}
	}
}

@(private) add_unary_expression :: proc(query: ^Query, operator: Expression_Operator, start: Source_Position, child: int) -> (int, Parse_Error) {
	expression, ok := add_expression(query, Expression_Node{kind = .Unary, operator = operator, span = {start = start, end = query.expressions[child].span.end}})
	if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.expressions[child].span.end}}
	if !append_expression_child(query, expression, child) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
	return expression, {}
}

@(private) add_binary_expression :: proc(query: ^Query, operator: Expression_Operator, left, right: int) -> (int, Parse_Error) {
	expression, ok := add_expression(query, Expression_Node{kind = .Binary, operator = operator, span = {start = query.expressions[left].span.start, end = query.expressions[right].span.end}})
	if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = {start = query.expressions[left].span.start, end = query.expressions[right].span.end}}
	if !append_expression_child(query, expression, left) || !append_expression_child(query, expression, right) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
	return expression, {}
}

@(private) parse_function_call :: proc(parser: ^Parser, query: ^Query, start: Source_Position, name: string, term: Term) -> (int, Parse_Error) {
	if parser.current.kind != .Left_Paren do return Invalid_Expression, error_at(parser, .Expected_Left_Paren)
	expression, ok := add_expression(query, Expression_Node{kind = .Function, name = name, term = term, span = {start = start, end = source_span(parser.current.span).end}})
	if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = source_span(parser.current.span).end}}
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	if lexer.is_keyword(parser.current, "DISTINCT") {
		query.expressions[expression].uses_distinct = true
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
	}
	if parser.current.kind == .Star {
		star_span := source_span(parser.current.span)
		wildcard, wildcard_ok := add_expression(query, Expression_Node{kind = .Wildcard, span = star_span})
		if !wildcard_ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = star_span}
		if !append_expression_child(query, expression, wildcard) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
	}
	if parser.current.kind != .Right_Paren {
		for {
			argument, argument_error := parse_expression(parser, query)
			if argument_error.code != .None do return Invalid_Expression, argument_error
			if !append_expression_child(query, expression, argument) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
			if parser.current.kind != .Comma do break
			if error := advance(parser); error.code != .None do return Invalid_Expression, error
		}
	}
	if parser.current.kind == .Semicolon {
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		if !lexer.is_keyword(parser.current, "SEPARATOR") do return Invalid_Expression, error_at(parser, .Expected_Expression)
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		if parser.current.kind != .Equals do return Invalid_Expression, error_at(parser, .Expected_Expression)
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		separator, separator_error := parse_term(parser, query)
		if separator_error.code != .None do return Invalid_Expression, separator_error
		if separator.kind != .String_Literal do return Invalid_Expression, Parse_Error{code = .Expected_Term, span = separator.span}
		query.expressions[expression].has_separator = true
		query.expressions[expression].separator = separator
	}
	if parser.current.kind != .Right_Paren do return Invalid_Expression, error_at(parser, .Expected_Right_Paren)
	query.expressions[expression].span.end = source_span(parser.current.span).end
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	return expression, {}
}

@(private) parse_primary_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	if parser.current.kind == .Left_Paren {
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		expression, expression_error := parse_expression(parser, query)
		if expression_error.code != .None do return Invalid_Expression, expression_error
		if parser.current.kind != .Right_Paren do return Invalid_Expression, error_at(parser, .Expected_Right_Paren)
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		return expression, {}
	}
	if lexer.is_keyword(parser.current, "EXISTS") || lexer.is_keyword(parser.current, "NOT") {
		start := source_span(parser.current.span).start
		not_exists := lexer.is_keyword(parser.current, "NOT")
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		if not_exists && !lexer.is_keyword(parser.current, "EXISTS") do return Invalid_Expression, error_at(parser, .Expected_Expression)
		if not_exists {
			if error := advance(parser); error.code != .None do return Invalid_Expression, error
		}
		group, group_error := parse_group_graph_pattern(parser, query)
		if group_error.code != .None do return Invalid_Expression, group_error
		kind := Expression_Kind.Exists
		if not_exists do kind = .Not_Exists
		expression, ok := add_expression(query, Expression_Node{kind = kind, span = {start = start, end = query.patterns[group].span.end}})
		if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.patterns[group].span.end}}
		if !append_expression_child(query, expression, group) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
		return expression, {}
	}
	if parser.current.kind == .Name && !lexer.is_keyword(parser.current, "true") && !lexer.is_keyword(parser.current, "false") {
		start := source_span(parser.current.span).start
		name, ok := own_string(query, parser.current.lexeme)
		if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = source_span(parser.current.span)}
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		return parse_function_call(parser, query, start, name, {})
	}
	term, term_error := parse_term(parser, query)
	if term_error.code != .None do return Invalid_Expression, term_error
	if parser.current.kind == .Left_Paren && (term.kind == .IRIREF || term.kind == .Prefixed_Name) {
		return parse_function_call(parser, query, term.span.start, term.lexical, term)
	}
	expression, ok := add_expression(query, Expression_Node{kind = .Term, term = term, span = term.span})
	if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = term.span}
	return expression, {}
}

@(private) parse_unary_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	operator: Expression_Operator
	start := source_span(parser.current.span).start
	#partial switch parser.current.kind {
	case .Bang: operator = .Not
	case .Plus: operator = .Unary_Plus
	case .Minus: operator = .Unary_Minus
	case: return parse_primary_expression(parser, query)
	}
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	child, child_error := parse_unary_expression(parser, query)
	if child_error.code != .None do return Invalid_Expression, child_error
	return add_unary_expression(query, operator, start, child)
}

@(private) parse_multiplicative_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_unary_expression(parser, query)
	if left_error.code != .None do return Invalid_Expression, left_error
	for parser.current.kind == .Star || parser.current.kind == .Slash {
		operator := Expression_Operator.Multiply
		if parser.current.kind == .Slash do operator = .Divide
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		right, right_error := parse_unary_expression(parser, query)
		if right_error.code != .None do return Invalid_Expression, right_error
		left, left_error = add_binary_expression(query, operator, left, right)
		if left_error.code != .None do return Invalid_Expression, left_error
	}
	return left, {}
}

@(private) is_signed_numeric_token :: proc(token: lexer.Token) -> bool {
	if token.kind != .Integer && token.kind != .Decimal && token.kind != .Double do return false
	return len(token.lexeme) > 1 && (token.lexeme[0] == '+' || token.lexeme[0] == '-')
}

@(private) parse_unsigned_numeric_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	token := parser.current
	if !is_signed_numeric_token(token) do return Invalid_Expression, error_at(parser, .Expected_Expression)
	token.lexeme = token.lexeme[1:]
	token.span.start.byte_offset += 1
	token.span.start.column += 1
	kind: Term_Kind
	#partial switch token.kind {
	case .Integer: kind = .Integer
	case .Decimal: kind = .Decimal
	case .Double: kind = .Double
	}
	term, term_error := clone_term(query, token, kind)
	if term_error.code != .None do return Invalid_Expression, term_error
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	expression, ok := add_expression(query, Expression_Node{kind = .Term, term = term, span = term.span})
	if !ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = term.span}
	return expression, {}
}

@(private) parse_additive_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_multiplicative_expression(parser, query)
	if left_error.code != .None do return Invalid_Expression, left_error
	for parser.current.kind == .Plus || parser.current.kind == .Minus || is_signed_numeric_token(parser.current) {
		operator := Expression_Operator.Add
		right: int
		right_error: Parse_Error
		if is_signed_numeric_token(parser.current) {
			if parser.current.lexeme[0] == '-' do operator = .Subtract
			right, right_error = parse_unsigned_numeric_expression(parser, query)
		} else {
			if parser.current.kind == .Minus do operator = .Subtract
			if error := advance(parser); error.code != .None do return Invalid_Expression, error
			right, right_error = parse_multiplicative_expression(parser, query)
		}
		if right_error.code != .None do return Invalid_Expression, right_error
		left, left_error = add_binary_expression(query, operator, left, right)
		if left_error.code != .None do return Invalid_Expression, left_error
	}
	return left, {}
}

@(private) relational_operator :: proc(kind: lexer.Token_Kind) -> (Expression_Operator, bool) {
	#partial switch kind {
	case .Equals: return .Equal, true
	case .Not_Equals: return .Not_Equal, true
	case .Less: return .Less, true
	case .Less_Or_Equal: return .Less_Or_Equal, true
	case .Greater: return .Greater, true
	case .Greater_Or_Equal: return .Greater_Or_Equal, true
	}
	return .None, false
}

@(private) parse_relational_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_additive_expression(parser, query)
	if left_error.code != .None do return Invalid_Expression, left_error
	operator, found := relational_operator(parser.current.kind)
	if found {
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		right, right_error := parse_additive_expression(parser, query)
		if right_error.code != .None do return Invalid_Expression, right_error
		return add_binary_expression(query, operator, left, right)
	}
	negated := false
	if lexer.is_keyword(parser.current, "NOT") {
		negated = true
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
	}
	if !lexer.is_keyword(parser.current, "IN") {
		if negated do return Invalid_Expression, error_at(parser, .Expected_Expression)
		return left, {}
	}
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	if parser.current.kind != .Left_Paren do return Invalid_Expression, error_at(parser, .Expected_Left_Paren)
	membership_kind := Expression_Kind.In
	if negated do membership_kind = .Not_In
	membership, membership_ok := add_expression(query, Expression_Node{kind = membership_kind, span = {start = query.expressions[left].span.start, end = source_span(parser.current.span).end}})
	if !membership_ok do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[left].span}
	if !append_expression_child(query, membership, left) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[membership].span}
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	if parser.current.kind != .Right_Paren {
		for {
			member, member_error := parse_expression(parser, query)
			if member_error.code != .None do return Invalid_Expression, member_error
			if !append_expression_child(query, membership, member) do return Invalid_Expression, Parse_Error{code = .Out_Of_Memory, span = query.expressions[membership].span}
			if parser.current.kind != .Comma do break
			if error := advance(parser); error.code != .None do return Invalid_Expression, error
		}
	}
	if parser.current.kind != .Right_Paren do return Invalid_Expression, error_at(parser, .Expected_Right_Paren)
	query.expressions[membership].span.end = source_span(parser.current.span).end
	if error := advance(parser); error.code != .None do return Invalid_Expression, error
	return membership, {}
}

@(private) parse_and_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_relational_expression(parser, query)
	if left_error.code != .None do return Invalid_Expression, left_error
	for parser.current.kind == .And {
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		right, right_error := parse_relational_expression(parser, query)
		if right_error.code != .None do return Invalid_Expression, right_error
		left, left_error = add_binary_expression(query, .And, left, right)
		if left_error.code != .None do return Invalid_Expression, left_error
	}
	return left, {}
}

// parse_expression parses the SPARQL operator-precedence ladder currently
// needed by FILTER and BIND. Aggregate and IN forms extend this AST later.
@(private) parse_expression :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	left, left_error := parse_and_expression(parser, query)
	if left_error.code != .None do return Invalid_Expression, left_error
	for parser.current.kind == .Or {
		if error := advance(parser); error.code != .None do return Invalid_Expression, error
		right, right_error := parse_and_expression(parser, query)
		if right_error.code != .None do return Invalid_Expression, right_error
		left, left_error = add_binary_expression(query, .Or, left, right)
		if left_error.code != .None do return Invalid_Expression, left_error
	}
	return left, {}
}

@(private) parse_values_cell :: proc(parser: ^Parser, query: ^Query, pattern, row: int) -> (Source_Span, Parse_Error) {
	if lexer.is_keyword(parser.current, "UNDEF") {
		span := source_span(parser.current.span)
		if !append_values_cell(query, pattern, row, {}, true) do return {}, Parse_Error{code = .Out_Of_Memory, span = span}
		error := advance(parser)
		if error.code != .None do return {}, error
		return span, {}
	}
	value, value_error := parse_term(parser, query)
	if value_error.code != .None do return {}, value_error
	if !append_values_cell(query, pattern, row, value, false) do return {}, Parse_Error{code = .Out_Of_Memory, span = value.span}
	return value.span, {}
}

@(private) parse_values_clause :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	start := source_span(parser.current.span).start
	if error := advance(parser); error.code != .None do return Invalid_Pattern, error
	pattern, ok := add_pattern(query, .Values, {start = start, end = start})
	if !ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = start}}

	if parser.current.kind == .Variable {
		variable, variable_error := parse_term(parser, query)
		if variable_error.code != .None do return Invalid_Pattern, variable_error
		if !append_values_variable(query, pattern, variable) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = variable.span}
		if parser.current.kind != .Left_Brace do return Invalid_Pattern, error_at(parser, .Expected_Left_Brace)
		if error := advance(parser); error.code != .None do return Invalid_Pattern, error
		for parser.current.kind != .Right_Brace {
			if parser.current.kind == .End do return Invalid_Pattern, error_at(parser, .Expected_Right_Brace)
			row_start := source_span(parser.current.span).start
			row, row_ok := append_values_row(query, pattern, {start = row_start, end = row_start})
			if !row_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = row_start, end = row_start}}
			cell_span, cell_error := parse_values_cell(parser, query, pattern, row)
			if cell_error.code != .None do return Invalid_Pattern, cell_error
			query.patterns[pattern].values_rows[row].span.end = cell_span.end
		}
	} else if parser.current.kind == .Left_Paren {
		if error := advance(parser); error.code != .None do return Invalid_Pattern, error
		for parser.current.kind == .Variable {
			variable, variable_error := parse_term(parser, query)
			if variable_error.code != .None do return Invalid_Pattern, variable_error
			if !append_values_variable(query, pattern, variable) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = variable.span}
		}
		if parser.current.kind != .Right_Paren do return Invalid_Pattern, error_at(parser, .Expected_Right_Paren)
		if error := advance(parser); error.code != .None do return Invalid_Pattern, error
		if parser.current.kind != .Left_Brace do return Invalid_Pattern, error_at(parser, .Expected_Left_Brace)
		if error := advance(parser); error.code != .None do return Invalid_Pattern, error
		for parser.current.kind != .Right_Brace {
			if parser.current.kind == .End do return Invalid_Pattern, error_at(parser, .Expected_Right_Brace)
			if parser.current.kind != .Left_Paren do return Invalid_Pattern, error_at(parser, .Expected_Left_Paren)
			row_start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			row, row_ok := append_values_row(query, pattern, {start = row_start, end = row_start})
			if !row_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = row_start, end = row_start}}
			for _ in 0..<len(query.patterns[pattern].values_variables) {
				_, cell_error := parse_values_cell(parser, query, pattern, row)
				if cell_error.code != .None do return Invalid_Pattern, cell_error
			}
			if parser.current.kind != .Right_Paren do return Invalid_Pattern, error_at(parser, .Expected_Right_Paren)
			query.patterns[pattern].values_rows[row].span.end = source_span(parser.current.span).end
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
		}
	} else {
		return Invalid_Pattern, error_at(parser, .Expected_Variable)
	}
	if parser.current.kind != .Right_Brace do return Invalid_Pattern, error_at(parser, .Expected_Right_Brace)
	query.patterns[pattern].span.end = source_span(parser.current.span).end
	if error := advance(parser); error.code != .None do return Invalid_Pattern, error
	return pattern, {}
}

@(private) is_solution_modifier_start :: proc(token: lexer.Token) -> bool {
	return lexer.is_keyword(token, "GROUP") || lexer.is_keyword(token, "HAVING") || lexer.is_keyword(token, "ORDER") ||
		lexer.is_keyword(token, "LIMIT") || lexer.is_keyword(token, "OFFSET")
}

@(private) is_solution_modifier_end :: proc(token: lexer.Token) -> bool {
	// ValuesClause occurs after SolutionModifier at query and SubSelect scope.
	// Treat it as a modifier terminator so GROUP, HAVING, and ORDER expression
	// loops leave it for parse_tail_values.
	return token.kind == .End || token.kind == .Right_Brace || lexer.is_keyword(token, "VALUES")
}

@(private) parse_group_condition :: proc(parser: ^Parser, query: ^Query) -> (int, Term, Parse_Error) {
	alias := Term{syntax_node = Invalid_Term_Node}
	if parser.current.kind != .Left_Paren {
		expression, expression_error := parse_expression(parser, query)
		if expression_error.code != .None do return Invalid_Expression, {}, expression_error
		return expression, alias, {}
	}
	if error := advance(parser); error.code != .None do return Invalid_Expression, {}, error
	expression, expression_error := parse_expression(parser, query)
	if expression_error.code != .None do return Invalid_Expression, {}, expression_error
	if lexer.is_keyword(parser.current, "AS") {
		if error := advance(parser); error.code != .None do return Invalid_Expression, {}, error
		if parser.current.kind != .Variable do return Invalid_Expression, {}, error_at(parser, .Expected_Variable)
		value, value_error := parse_term(parser, query)
		if value_error.code != .None do return Invalid_Expression, {}, value_error
		alias = value
	}
	if parser.current.kind != .Right_Paren do return Invalid_Expression, {}, error_at(parser, .Expected_Right_Paren)
	if error := advance(parser); error.code != .None do return Invalid_Expression, {}, error
	return expression, alias, {}
}

@(private) parse_limit_or_offset :: proc(parser: ^Parser, query: ^Query, is_limit: bool) -> Parse_Error {
	if error := advance(parser); error.code != .None do return error
	if parser.current.kind != .Integer do return error_at(parser, .Expected_Integer)
	value, value_error := clone_term(query, parser.current, .Integer)
	if value_error.code != .None do return value_error
	if is_limit {
		query.has_limit = true
		query.limit = value
	} else {
		query.has_offset = true
		query.offset = value
	}
	return advance(parser)
}

@(private) parse_solution_modifiers :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	for is_solution_modifier_start(parser.current) {
		if lexer.is_keyword(parser.current, "GROUP") {
			if error := advance(parser); error.code != .None do return error
			if !lexer.is_keyword(parser.current, "BY") do return error_at(parser, .Expected_By)
			if error := advance(parser); error.code != .None do return error
			if is_solution_modifier_start(parser.current) || is_solution_modifier_end(parser.current) do return error_at(parser, .Expected_Expression)
			for !is_solution_modifier_start(parser.current) && !is_solution_modifier_end(parser.current) {
				expression, alias, condition_error := parse_group_condition(parser, query)
				if condition_error.code != .None do return condition_error
				if !append_group_condition(query, expression, alias) do return Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
			}
			continue
		}
		if lexer.is_keyword(parser.current, "HAVING") {
			if error := advance(parser); error.code != .None do return error
			if is_solution_modifier_start(parser.current) || is_solution_modifier_end(parser.current) do return error_at(parser, .Expected_Expression)
			for !is_solution_modifier_start(parser.current) && !is_solution_modifier_end(parser.current) {
				expression, expression_error := parse_expression(parser, query)
				if expression_error.code != .None do return expression_error
				if !append_having_condition(query, expression) do return Parse_Error{code = .Out_Of_Memory, span = query.expressions[expression].span}
			}
			continue
		}
		if lexer.is_keyword(parser.current, "LIMIT") {
			if error := parse_limit_or_offset(parser, query, true); error.code != .None do return error
			continue
		}
		if lexer.is_keyword(parser.current, "OFFSET") {
			if error := parse_limit_or_offset(parser, query, false); error.code != .None do return error
			continue
		}
		if error := advance(parser); error.code != .None do return error
		if !lexer.is_keyword(parser.current, "BY") do return error_at(parser, .Expected_By)
		if error := advance(parser); error.code != .None do return error
		if is_solution_modifier_start(parser.current) || is_solution_modifier_end(parser.current) do return error_at(parser, .Expected_Expression)
		for !is_solution_modifier_start(parser.current) && !is_solution_modifier_end(parser.current) {
			direction := Order_Direction.Default
			start := source_span(parser.current.span).start
			expression: int
			end: Source_Position
			if lexer.is_keyword(parser.current, "ASC") || lexer.is_keyword(parser.current, "DESC") {
				if lexer.is_keyword(parser.current, "ASC") {
					direction = .Ascending
				} else {
					direction = .Descending
				}
				if error := advance(parser); error.code != .None do return error
				if parser.current.kind != .Left_Paren do return error_at(parser, .Expected_Left_Paren)
				if error := advance(parser); error.code != .None do return error
				value, value_error := parse_expression(parser, query)
				if value_error.code != .None do return value_error
				expression = value
				if parser.current.kind != .Right_Paren do return error_at(parser, .Expected_Right_Paren)
				end = source_span(parser.current.span).end
				if error := advance(parser); error.code != .None do return error
			} else {
				value, value_error := parse_expression(parser, query)
				if value_error.code != .None do return value_error
				expression = value
				end = query.expressions[expression].span.end
			}
			condition := Order_Condition{direction = direction, expression = expression, span = {start = start, end = end}}
			if !append_order_condition(query, condition) do return Parse_Error{code = .Out_Of_Memory, span = condition.span}
		}
	}
	return {}
}

@(private) parse_subquery_pattern :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	if parser.current.kind != .Left_Brace do return Invalid_Pattern, error_at(parser, .Expected_Left_Brace)
	if error := advance(parser); error.code != .None do return Invalid_Pattern, error
	if !lexer.is_keyword(parser.current, "SELECT") do return Invalid_Pattern, error_at(parser, .Expected_Query_Form)
	subquery: Query
	init_query(&subquery)
	if !inherit_subquery_prologue(query, &subquery) {
		destroy(&subquery)
		return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = source_span(parser.current.span)}
	}
	subquery.span.start = source_span(parser.current.span).start
	if error := parse_select(parser, &subquery, false); error.code != .None {
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	if error := parse_tail_values(parser, &subquery); error.code != .None {
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	if parser.current.kind != .Right_Brace {
		error := error_at(parser, .Expected_Right_Brace)
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	subquery.span.end = source_span(parser.current.span).end
	end := source_span(parser.current.span).end
	if error := advance(parser); error.code != .None {
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	index, appended := append_subquery(query, subquery)
	if !appended {
		destroy(&subquery)
		return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = subquery.span}
	}
	pattern, pattern_ok := add_pattern(query, .Subquery, {start = subquery.span.start, end = end})
	if !pattern_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = subquery.span.start, end = end}}
	query.patterns[pattern].subquery = index
	return pattern, {}
}

@(private) parse_direct_subquery :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	if !lexer.is_keyword(parser.current, "SELECT") do return Invalid_Pattern, error_at(parser, .Expected_Query_Form)
	subquery: Query
	init_query(&subquery)
	if !inherit_subquery_prologue(query, &subquery) {
		destroy(&subquery)
		return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = source_span(parser.current.span)}
	}
	subquery.span.start = source_span(parser.current.span).start
	if error := parse_select(parser, &subquery, false); error.code != .None {
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	if error := parse_tail_values(parser, &subquery); error.code != .None {
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	if parser.current.kind != .Right_Brace {
		error := error_at(parser, .Expected_Right_Brace)
		destroy(&subquery)
		return Invalid_Pattern, error
	}
	subquery.span.end = source_span(parser.current.span).start
	index, appended := append_subquery(query, subquery)
	if !appended {
		destroy(&subquery)
		return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = subquery.span}
	}
	pattern, pattern_ok := add_pattern(query, .Subquery, subquery.span)
	if !pattern_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = subquery.span}
	query.patterns[pattern].subquery = index
	return pattern, {}
}

// A GraphPatternNotTriples item may be followed by one optional period. Triple
// blocks consume their own separators, so this helper is only called after a
// non-triple group-pattern item has been parsed.
@(private) consume_optional_group_period :: proc(parser: ^Parser) -> Parse_Error {
	if parser.current.kind == .Dot do return advance(parser)
	return {}
}

@(private) parse_group_graph_pattern :: proc(parser: ^Parser, query: ^Query) -> (int, Parse_Error) {
	if parser.current.kind != .Left_Brace do return Invalid_Pattern, error_at(parser, .Expected_Left_Brace)
	group_start := source_span(parser.current.span).start
	group, group_ok := add_pattern(query, .Group, {start = group_start, end = group_start})
	if !group_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = group_start, end = group_start}}
	if error := advance(parser); error.code != .None do return Invalid_Pattern, error

	for parser.current.kind != .Right_Brace {
		if parser.current.kind == .End do return Invalid_Pattern, error_at(parser, .Expected_Right_Brace)
		if lexer.is_keyword(parser.current, "SELECT") {
			if len(query.patterns[group].children) != 0 do return Invalid_Pattern, error_at(parser, .Expected_Right_Brace)
			subquery, subquery_error := parse_direct_subquery(parser, query)
			if subquery_error.code != .None do return Invalid_Pattern, subquery_error
			if !append_pattern_child(query, group, subquery) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[subquery].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "SERVICE") {
			start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			silent := false
			if lexer.is_keyword(parser.current, "SILENT") {
				silent = true
				if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			}
			service_name, name_error := parse_graph_name(parser, query)
			if name_error.code != .None do return Invalid_Pattern, name_error
			child, child_error := parse_group_graph_pattern(parser, query)
			if child_error.code != .None do return Invalid_Pattern, child_error
			service, service_ok := add_pattern(query, .Service, {start = start, end = query.patterns[child].span.end})
			if !service_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.patterns[child].span.end}}
			query.patterns[service].service_name = service_name
			query.patterns[service].service_silent = silent
			if !append_pattern_child(query, service, child) || !append_pattern_child(query, group, service) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[service].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "VALUES") {
			values, values_error := parse_values_clause(parser, query)
			if values_error.code != .None do return Invalid_Pattern, values_error
			if !append_pattern_child(query, group, values) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[values].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "MINUS") {
			start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			child, child_error := parse_group_graph_pattern(parser, query)
			if child_error.code != .None do return Invalid_Pattern, child_error
			minus, minus_ok := add_pattern(query, .Minus, {start = start, end = query.patterns[child].span.end})
			if !minus_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.patterns[child].span.end}}
			if !append_pattern_child(query, minus, child) || !append_pattern_child(query, group, minus) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[minus].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "FILTER") {
			start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			has_parentheses := parser.current.kind == .Left_Paren
			if has_parentheses {
				if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			}
			expression, expression_error := parse_expression(parser, query)
			if expression_error.code != .None do return Invalid_Pattern, expression_error
			end := query.expressions[expression].span.end
			if has_parentheses {
				if parser.current.kind != .Right_Paren do return Invalid_Pattern, error_at(parser, .Expected_Right_Paren)
				end = source_span(parser.current.span).end
				if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			}
			filter, filter_ok := add_pattern(query, .Filter, {start = start, end = end})
			if !filter_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = end}}
			query.patterns[filter].expression = expression
			if !append_pattern_child(query, group, filter) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[filter].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "BIND") {
			start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			if parser.current.kind != .Left_Paren do return Invalid_Pattern, error_at(parser, .Expected_Left_Paren)
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			expression, expression_error := parse_expression(parser, query)
			if expression_error.code != .None do return Invalid_Pattern, expression_error
			if !lexer.is_keyword(parser.current, "AS") do return Invalid_Pattern, error_at(parser, .Expected_As)
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			if parser.current.kind != .Variable do return Invalid_Pattern, error_at(parser, .Expected_Variable)
			variable, variable_error := parse_term(parser, query)
			if variable_error.code != .None do return Invalid_Pattern, variable_error
			if parser.current.kind != .Right_Paren do return Invalid_Pattern, error_at(parser, .Expected_Right_Paren)
			end := source_span(parser.current.span).end
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			bind, bind_ok := add_pattern(query, .Bind, {start = start, end = end})
			if !bind_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = end}}
			query.patterns[bind].expression = expression
			query.patterns[bind].variable = variable
			if !append_pattern_child(query, group, bind) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[bind].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "OPTIONAL") {
			start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			child, child_error := parse_group_graph_pattern(parser, query)
			if child_error.code != .None do return Invalid_Pattern, child_error
			optional, optional_ok := add_pattern(query, .Optional, {start = start, end = query.patterns[child].span.end})
			if !optional_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.patterns[child].span.end}}
			if !append_pattern_child(query, optional, child) || !append_pattern_child(query, group, optional) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[optional].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if lexer.is_keyword(parser.current, "GRAPH") {
			start := source_span(parser.current.span).start
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			graph_name, name_error := parse_graph_name(parser, query)
			if name_error.code != .None do return Invalid_Pattern, name_error
			child, child_error := parse_group_graph_pattern(parser, query)
			if child_error.code != .None do return Invalid_Pattern, child_error
			graph, graph_ok := add_pattern(query, .Graph, {start = start, end = query.patterns[child].span.end})
			if !graph_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = {start = start, end = query.patterns[child].span.end}}
			query.patterns[graph].graph_name = graph_name
			if !append_pattern_child(query, graph, child) || !append_pattern_child(query, group, graph) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[graph].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		if parser.current.kind == .Left_Brace {
			checkpoint := parser^
			if error := advance(parser); error.code != .None do return Invalid_Pattern, error
			is_subquery := lexer.is_keyword(parser.current, "SELECT")
			parser^ = checkpoint
			if is_subquery {
				subquery, subquery_error := parse_subquery_pattern(parser, query)
				if subquery_error.code != .None do return Invalid_Pattern, subquery_error
				if !lexer.is_keyword(parser.current, "UNION") {
					if !append_pattern_child(query, group, subquery) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[subquery].span}
					if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
					continue
				}
				union_pattern, union_ok := add_pattern(query, .Union, {start = query.patterns[subquery].span.start, end = query.patterns[subquery].span.end})
				if !union_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[subquery].span}
				if !append_pattern_child(query, union_pattern, subquery) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[subquery].span}
				for lexer.is_keyword(parser.current, "UNION") {
					if error := advance(parser); error.code != .None do return Invalid_Pattern, error
					right, right_error := parse_group_graph_pattern(parser, query)
					if right_error.code != .None do return Invalid_Pattern, right_error
					if !append_pattern_child(query, union_pattern, right) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[right].span}
					query.patterns[union_pattern].span.end = query.patterns[right].span.end
				}
				if !append_pattern_child(query, group, union_pattern) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[union_pattern].span}
				if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
				continue
			}
			first, first_error := parse_group_graph_pattern(parser, query)
			if first_error.code != .None do return Invalid_Pattern, first_error
			if !lexer.is_keyword(parser.current, "UNION") {
				if !append_pattern_child(query, group, first) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[first].span}
				if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
				continue
			}
			union_pattern, union_ok := add_pattern(query, .Union, {start = query.patterns[first].span.start, end = query.patterns[first].span.end})
			if !union_ok do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[first].span}
			if !append_pattern_child(query, union_pattern, first) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[first].span}
			for lexer.is_keyword(parser.current, "UNION") {
				if error := advance(parser); error.code != .None do return Invalid_Pattern, error
				right, right_error := parse_group_graph_pattern(parser, query)
				if right_error.code != .None do return Invalid_Pattern, right_error
				if !append_pattern_child(query, union_pattern, right) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[right].span}
				query.patterns[union_pattern].span.end = query.patterns[right].span.end
			}
			if !append_pattern_child(query, group, union_pattern) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[union_pattern].span}
			if error := consume_optional_group_period(parser); error.code != .None do return Invalid_Pattern, error
			continue
		}
		basic, basic_error := parse_triples_block(parser, query)
		if basic_error.code != .None do return Invalid_Pattern, basic_error
		if !append_pattern_child(query, group, basic) do return Invalid_Pattern, Parse_Error{code = .Out_Of_Memory, span = query.patterns[basic].span}
	}
	query.patterns[group].span.end = source_span(parser.current.span).end
	error := advance(parser)
	if error.code != .None do return Invalid_Pattern, error
	return group, {}
}

@(private) parse_select :: proc(parser: ^Parser, query: ^Query, allow_dataset_clauses: bool = true) -> Parse_Error {
	query.form = .Select
	if error := advance(parser); error.code != .None do return error
	if lexer.is_keyword(parser.current, "DISTINCT") {
		query.select.modifier = .Distinct
		if error := advance(parser); error.code != .None do return error
	} else if lexer.is_keyword(parser.current, "REDUCED") {
		query.select.modifier = .Reduced
		if error := advance(parser); error.code != .None do return error
	}
	if parser.current.kind == .Star {
		query.select.select_all = true
		if error := advance(parser); error.code != .None do return error
	} else {
		for parser.current.kind == .Variable || parser.current.kind == .Left_Paren {
			if parser.current.kind == .Variable {
				variable, error := parse_term(parser, query)
				if error.code != .None do return error
				if !append_projection(query, variable) do return Parse_Error{code = .Out_Of_Memory, span = variable.span}
				continue
			}
			if error := advance(parser); error.code != .None do return error
			expression, expression_error := parse_expression(parser, query)
			if expression_error.code != .None do return expression_error
			if !lexer.is_keyword(parser.current, "AS") do return error_at(parser, .Expected_As)
			if error := advance(parser); error.code != .None do return error
			if parser.current.kind != .Variable do return error_at(parser, .Expected_Variable)
			variable, variable_error := parse_term(parser, query)
			if variable_error.code != .None do return variable_error
			if parser.current.kind != .Right_Paren do return error_at(parser, .Expected_Right_Paren)
			if !append_expression_projection(query, variable, expression) do return Parse_Error{code = .Out_Of_Memory, span = variable.span}
			if error := advance(parser); error.code != .None do return error
		}
		if len(query.select.projection) == 0 do return error_at(parser, .Expected_Variable)
	}
	// SubSelect grammar intentionally omits DatasetClause. Reject it while the
	// offending FROM token is current instead of accepting a query the algebra
	// must reject later.
	if !allow_dataset_clauses && lexer.is_keyword(parser.current, "FROM") do return error_at(parser, .Invalid_Query)
	if lexer.is_keyword(parser.current, "WHERE") {
		if error := parse_dataset_clauses(parser, query); error.code != .None do return error
		if error := advance(parser); error.code != .None do return error
	} else if error := parse_dataset_clauses(parser, query); error.code != .None {
		return error
	}
	where_pattern, error := parse_group_graph_pattern(parser, query)
	if error.code != .None do return error
	query.select.where_pattern = where_pattern
	return parse_solution_modifiers(parser, query)
}

@(private) parse_ask :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	query.form = .Ask
	if error := advance(parser); error.code != .None do return error
	if error := parse_dataset_clauses(parser, query); error.code != .None do return error
	if lexer.is_keyword(parser.current, "WHERE") {
		if error := advance(parser); error.code != .None do return error
	}
	where_pattern, error := parse_group_graph_pattern(parser, query)
	if error.code != .None do return error
	query.ask.where_pattern = where_pattern
	return parse_solution_modifiers(parser, query)
}

// CONSTRUCT WHERE is shorthand for a construct template and therefore admits
// only ConstructTriples—not FILTER, GRAPH, OPTIONAL, or other graph-pattern
// operators. The general group parser is reused for token handling, then this
// shape check restores the narrower grammar production.
@(private) construct_where_template :: proc(query: ^Query, pattern: int) -> bool {
	if pattern < 0 || pattern >= len(query.patterns) do return false
	node := query.patterns[pattern]
	if node.kind == .Basic_Graph_Pattern do return len(node.standalone_nodes) == 0
	if node.kind != .Group do return false
	for child in node.children do if !construct_where_template(query, child) do return false
	return true
}

@(private) parse_construct :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	query.form = .Construct
	if error := advance(parser); error.code != .None do return error
	if lexer.is_keyword(parser.current, "WHERE") {
		query.construct.where_shorthand = true
		if error := advance(parser); error.code != .None do return error
		where_pattern, where_error := parse_group_graph_pattern(parser, query)
		if where_error.code != .None do return where_error
		if !construct_where_template(query, where_pattern) do return Parse_Error{code = .Invalid_Query, span = query.patterns[where_pattern].span}
		query.construct.template = where_pattern
		query.construct.where_pattern = where_pattern
		return parse_solution_modifiers(parser, query)
	}
	where_shorthand_with_dataset := lexer.is_keyword(parser.current, "FROM")
	if !where_shorthand_with_dataset {
		template, template_error := parse_group_graph_pattern(parser, query)
		if template_error.code != .None do return template_error
		query.construct.template = template
	}
	if error := parse_dataset_clauses(parser, query); error.code != .None do return error
	if !lexer.is_keyword(parser.current, "WHERE") do return error_at(parser, .Expected_Where)
	if error := advance(parser); error.code != .None do return error
	where_pattern, where_error := parse_group_graph_pattern(parser, query)
	if where_error.code != .None do return where_error
	if where_shorthand_with_dataset {
		if !construct_where_template(query, where_pattern) do return Parse_Error{code = .Invalid_Query, span = query.patterns[where_pattern].span}
		query.construct.where_shorthand = true
		query.construct.template = where_pattern
	}
	query.construct.where_pattern = where_pattern
	return parse_solution_modifiers(parser, query)
}

@(private) parse_describe :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	query.form = .Describe
	if error := advance(parser); error.code != .None do return error
	if parser.current.kind == .Star {
		query.describe.describe_all = true
		if error := advance(parser); error.code != .None do return error
	} else {
		for parser.current.kind == .Variable || parser.current.kind == .IRIREF || parser.current.kind == .PName_NS || parser.current.kind == .PName_LN {
			term, error := parse_describe_target(parser, query)
			if error.code != .None do return error
			if !append_describe_term(query, term) do return Parse_Error{code = .Out_Of_Memory, span = term.span}
		}
		if len(query.describe.terms) == 0 do return error_at(parser, .Expected_Term)
	}
	if error := parse_dataset_clauses(parser, query); error.code != .None do return error
	if !lexer.is_keyword(parser.current, "WHERE") do return parse_solution_modifiers(parser, query)
	query.describe.has_where = true
	if error := advance(parser); error.code != .None do return error
	where_pattern, error := parse_group_graph_pattern(parser, query)
	if error.code != .None do return error
	query.describe.where_pattern = where_pattern
	return parse_solution_modifiers(parser, query)
}

// scope_contains uses lexical variable spelling because ?name and $name are
// distinct source spellings until algebra translation normalizes them.
@(private) scope_contains :: proc(scope: [dynamic]string, variable: string) -> bool {
	for known in scope do if known == variable do return true
	return false
}

@(private) scope_contains_from :: proc(scope: [dynamic]string, start: int, variable: string) -> bool {
	for index in start..<len(scope) do if scope[index] == variable do return true
	return false
}

@(private) scope_add :: proc(scope: ^[dynamic]string, variable: string) -> bool {
	if scope_contains(scope^, variable) do return true
	_, error := append(scope, variable)
	return error == nil
}

@(private) scope_add_term :: proc(query: ^Query, scope: ^[dynamic]string, term: Term) -> bool {
	if term.kind == .Variable && !scope_add(scope, term.lexical) do return false
	if term.kind != .Blank_Property_List && term.kind != .Collection do return true
	if term.syntax_node == Invalid_Term_Node do return true
	if term.syntax_node < 0 || term.syntax_node >= len(query.term_nodes) do return true
	node := &query.term_nodes[term.syntax_node]
	for property in node.properties {
		if !scope_add_term(query, scope, property.predicate) do return false
		for object in property.objects do if !scope_add_term(query, scope, object) do return false
	}
	for item in node.items do if !scope_add_term(query, scope, item) do return false
	return true
}

@(private) scope_add_pattern_variables :: proc(query: ^Query, pattern: int, scope: ^[dynamic]string) -> bool {
	if pattern < 0 || pattern >= len(query.patterns) do return true
	value := &query.patterns[pattern]
	#partial switch value.kind {
	case .Basic_Graph_Pattern:
		for triple in value.triples {
			if !scope_add_term(query, scope, triple.subject) || !scope_add_term(query, scope, triple.predicate) || !scope_add_term(query, scope, triple.object) do return false
		}
		for node in value.standalone_nodes do if !scope_add_term(query, scope, node) do return false
	case .Values:
		for variable in value.values_variables do if !scope_add_term(query, scope, variable) do return false
	}
	return true
}

@(private) expression_is_variable :: proc(query: ^Query, expression: int, variable: string) -> bool {
	if expression < 0 || expression >= len(query.expressions) do return false
	value := query.expressions[expression]
	return value.kind == .Term && value.term.kind == .Variable && value.term.lexical == variable
}

@(private) group_alias_is_variable :: proc(query: ^Query, variable: string) -> bool {
	for alias in query.group_aliases do if alias.kind == .Variable && alias.lexical == variable do return true
	return false
}

@(private) validate_aggregate_calls :: proc(query: ^Query) -> Parse_Error {
	for expression in query.expressions {
		if expression.kind != .Function do continue
		if (strings.equal_fold(expression.name, "COUNT") || strings.equal_fold(expression.name, "SUM") || strings.equal_fold(expression.name, "AVG") || strings.equal_fold(expression.name, "GROUP_CONCAT") || strings.equal_fold(expression.name, "MIN") || strings.equal_fold(expression.name, "MAX") || strings.equal_fold(expression.name, "SAMPLE")) && len(expression.children) != 1 {
			return Parse_Error{code = .Invalid_Query, span = expression.span}
		}
		if expression.has_separator && !strings.equal_fold(expression.name, "GROUP_CONCAT") do return Parse_Error{code = .Invalid_Query, span = expression.span}
	}
	return {}
}

@(private) query_has_aggregate :: proc(query: ^Query) -> bool {
	for expression in query.expressions {
		if expression.kind != .Function do continue
		if strings.equal_fold(expression.name, "COUNT") || strings.equal_fold(expression.name, "SUM") || strings.equal_fold(expression.name, "AVG") || strings.equal_fold(expression.name, "MIN") || strings.equal_fold(expression.name, "MAX") || strings.equal_fold(expression.name, "SAMPLE") || strings.equal_fold(expression.name, "GROUP_CONCAT") do return true
	}
	return false
}

@(private) expression_is_aggregate :: proc(query: ^Query, expression: int) -> bool {
	if expression < 0 || expression >= len(query.expressions) do return false
	value := query.expressions[expression]
	return value.kind == .Function && (strings.equal_fold(value.name, "COUNT") || strings.equal_fold(value.name, "SUM") || strings.equal_fold(value.name, "AVG") || strings.equal_fold(value.name, "MIN") || strings.equal_fold(value.name, "MAX") || strings.equal_fold(value.name, "SAMPLE") || strings.equal_fold(value.name, "GROUP_CONCAT"))
}

@(private) expression_has_ungrouped_variable :: proc(query: ^Query, expression: int) -> bool {
	if expression < 0 || expression >= len(query.expressions) do return true
	value := query.expressions[expression]
	if expression_is_aggregate(query, expression) do return false
	if value.kind == .Term && value.term.kind == .Variable {
		for group_expression in query.group_by do if expression_is_variable(query, group_expression, value.term.lexical) do return false
		return true
	}
	for child in value.children do if expression_has_ungrouped_variable(query, child) do return true
	return false
}

// validate_group_scope enforces the syntactic scope constraints that require
// a complete group pattern (not merely token-local grammar), notably BIND's
// prohibition on rebinding an in-scope variable.
@(private) validate_group_scope :: proc(query: ^Query, group: int, scope: ^[dynamic]string) -> Parse_Error {
	if group < 0 || group >= len(query.patterns) do return {}
	pattern := &query.patterns[group]
	if pattern.kind != .Group {
		if !scope_add_pattern_variables(query, group, scope) do return Parse_Error{code = .Out_Of_Memory, span = pattern.span}
		return {}
	}
	// A nested group may use BIND to shadow a variable inherited from its
	// parent. Only bindings introduced by this group itself prohibit another
	// BIND with the same target.
	local_scope_start := len(scope^)
	for child in pattern.children {
		if child < 0 || child >= len(query.patterns) do continue
		item := &query.patterns[child]
		#partial switch item.kind {
		case .Basic_Graph_Pattern, .Values:
			if !scope_add_pattern_variables(query, child, scope) do return Parse_Error{code = .Out_Of_Memory, span = item.span}
		case .Bind:
			if scope_contains_from(scope^, local_scope_start, item.variable.lexical) do return Parse_Error{code = .Invalid_Query, span = item.variable.span}
			if !scope_add(scope, item.variable.lexical) do return Parse_Error{code = .Out_Of_Memory, span = item.variable.span}
		case .Group:
			if error := validate_group_scope(query, child, scope); error.code != .None do return error
		case .Optional, .Graph, .Service:
			if len(item.children) > 0 {
				if error := validate_group_scope(query, item.children[0], scope); error.code != .None do return error
			}
		case .Minus:
			// MINUS does not introduce bindings into its enclosing group.
		case .Union:
			merged_scope := make([dynamic]string)
			defer delete(merged_scope)
			for branch in item.children {
				branch_scope := make([dynamic]string)
				defer delete(branch_scope)
				for known in scope^ {
					if !scope_add(&branch_scope, known) do return Parse_Error{code = .Out_Of_Memory, span = item.span}
				}
				if error := validate_group_scope(query, branch, &branch_scope); error.code != .None do return error
				for variable in branch_scope {
					if !scope_add(&merged_scope, variable) do return Parse_Error{code = .Out_Of_Memory, span = item.span}
				}
			}
			for variable in merged_scope {
				if !scope_add(scope, variable) do return Parse_Error{code = .Out_Of_Memory, span = item.span}
			}
		case .Subquery:
			if item.subquery >= 0 && item.subquery < len(query.subqueries) {
				subquery := &query.subqueries[item.subquery]
				if error := validate_query(subquery); error.code != .None do return error
				if subquery.form == .Select {
					for variable in subquery.select.projection do if !scope_add(scope, variable.lexical) do return Parse_Error{code = .Out_Of_Memory, span = variable.span}
				}
			}
		case .Filter:
		}
	}
	return {}
}

@(private) validate_query :: proc(query: ^Query) -> Parse_Error {
	if error := validate_aggregate_calls(query); error.code != .None do return error
	if query.form != .Select do return {}

	scope := make([dynamic]string)
	defer delete(scope)
	if error := validate_group_scope(query, query.select.where_pattern, &scope); error.code != .None do return error
	for values in query.tail_values {
		if !scope_add_pattern_variables(query, values, &scope) do return Parse_Error{code = .Out_Of_Memory, span = query.patterns[values].span}
	}

	if query.select.select_all && len(query.group_by) > 0 {
		return Parse_Error{code = .Invalid_Query, span = query.span}
	}
	// GROUP BY alone establishes the same projection scope boundary as an
	// aggregate query: an ungrouped variable cannot be selected merely because
	// it occurred in the WHERE pattern.
	has_aggregate := query_has_aggregate(query) || len(query.group_by) != 0
	for variable, index in query.select.projection {
		for previous in 0..<index do if query.select.projection[previous].lexical == variable.lexical do return Parse_Error{code = .Invalid_Query, span = variable.span}
		expression := query.select.projection_expressions[index]
		if expression != Invalid_Expression && scope_contains(scope, variable.lexical) {
			return Parse_Error{code = .Invalid_Query, span = variable.span}
		}
		if has_aggregate && expression == Invalid_Expression {
			grouped := false
			for group_expression in query.group_by do if expression_is_variable(query, group_expression, variable.lexical) do grouped = true
			if group_alias_is_variable(query, variable.lexical) do grouped = true
			if !grouped do return Parse_Error{code = .Invalid_Query, span = variable.span}
		}
		if has_aggregate && expression != Invalid_Expression {
			// A non-variable GROUP BY expression does not itself make its source
			// variables projectable. SPARQL exposes that group key only through an
			// explicit `AS ?alias`, which must then be selected as the variable.
			if expression_has_ungrouped_variable(query, expression) do return Parse_Error{code = .Invalid_Query, span = query.expressions[expression].span}
		}
	}
	return {}
}

@(private) parse_tail_values :: proc(parser: ^Parser, query: ^Query) -> Parse_Error {
	if !lexer.is_keyword(parser.current, "VALUES") do return {}
	values, values_error := parse_values_clause(parser, query)
	if values_error.code != .None do return values_error
	if _, append_error := append(&query.tail_values, values); append_error != nil {
		return Parse_Error{code = .Out_Of_Memory, span = query.patterns[values].span}
	}
	// ValuesClause is optional, not repeatable, at Query and SubSelect scope.
	if lexer.is_keyword(parser.current, "VALUES") do return error_at(parser, .Invalid_Query)
	return {}
}

// parse produces an owned SPARQL Query AST. The returned query remains valid
// after input is released; call destroy on every successful result. This first
// implementation accepts BASE/PREFIX plus SELECT basic graph patterns.
parse :: proc(input: string) -> (Query, Parse_Error) {
	query: Query
	init_query(&query)
	parser := Parser{scanner = lexer.init(input)}
	defer lexer.destroy(&parser.scanner)
	if error := advance(&parser); error.code != .None {
		destroy(&query)
		return {}, error
	}
	query.span.start = source_span(parser.current.span).start
	if error := parse_prologue(&parser, &query); error.code != .None {
		destroy(&query)
		return {}, error
	}
	if lexer.is_keyword(parser.current, "SELECT") {
		if error := parse_select(&parser, &query); error.code != .None {
			destroy(&query)
			return {}, error
		}
	} else if lexer.is_keyword(parser.current, "ASK") {
		if error := parse_ask(&parser, &query); error.code != .None {
			destroy(&query)
			return {}, error
		}
	} else if lexer.is_keyword(parser.current, "CONSTRUCT") {
		if error := parse_construct(&parser, &query); error.code != .None {
			destroy(&query)
			return {}, error
		}
	} else if lexer.is_keyword(parser.current, "DESCRIBE") {
		if error := parse_describe(&parser, &query); error.code != .None {
			destroy(&query)
			return {}, error
		}
	} else {
		destroy(&query)
		return {}, error_at(&parser, .Expected_Query_Form)
	}
	if error := parse_tail_values(&parser, &query); error.code != .None {
		destroy(&query)
		return {}, error
	}
	if parser.current.kind != .End {
		error := error_at(&parser, .Unsupported_Syntax)
		destroy(&query)
		return {}, error
	}
	query.span.end = source_span(parser.current.span).end
	if error := validate_query(&query); error.code != .None {
		destroy(&query)
		return {}, error
	}
	return query, {}
}

// Parse is the experimental owned-query entry point. It is published so the
// pinned conformance runner can exercise the same parser as applications;
// fields and broader AST traversal remain pre-1.0 API surface.
Parse :: proc(input: string) -> (Query, Parse_Error) {
	return parse(input)
}

// Destroy releases a Query returned by Parse. It is safe for a zero Query.
Destroy :: proc(query: ^Query) {
	destroy(query)
}

// Parse_Error_Code returns the stable code associated with a parse failure.
Parse_Error_Code :: proc(error: Parse_Error) -> Error_Code {
	return error.code
}

// Parse_Error_Range returns the original-query range associated with a parse
// failure. It is meaningful only when Parse_Error_Code is not None.
Parse_Error_Range :: proc(error: Parse_Error) -> Source_Range {
	return public_range(error.span)
}

// Parse_Error_Message returns the stable, allocation-free diagnostic for a
// parse failure code.
Parse_Error_Message :: proc(error: Parse_Error) -> string {
	return error_message(error.code)
}
