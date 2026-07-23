package sparql

// Term_View is a borrowed source term. Lexical spellings retain SPARQL syntax
// such as `?name`, `<iri>`, and quoted literal delimiters.
Term_View :: struct {
	Kind:             Term_Kind,
	Lexical:          string,
	Has_Language:     bool,
	Language:         string,
	Has_Datatype:     bool,
	Datatype_Kind:    Term_Kind,
	Datatype_Lexical: string,
	Syntax_Node:      Term_Node_Ref,
	Range:            Source_Range,
}

Prefix_View :: struct {
	Prefix:    Term_View,
	Namespace: Term_View,
	Range:     Source_Range,
}

Dataset_Clause_View :: struct {
	Named:  bool,
	Source: Term_View,
	Range:  Source_Range,
}

Triple_Pattern_View :: struct {
	Subject:   Term_View,
	Predicate: Term_View,
	Path:      Path_Ref,
	Object:    Term_View,
	Range:     Source_Range,
}

Pattern_View :: struct {
	Kind:           Pattern_Kind,
	Range:          Source_Range,
	Graph_Name:     Term_View,
	Expression:     Expression_Ref,
	Variable:       Term_View,
	Service_Name:   Term_View,
	Service_Silent: bool,
}

Expression_View :: struct {
	Kind:           Expression_Kind,
	Operator:       Expression_Operator,
	Range:          Source_Range,
	Term:           Term_View,
	Name:           string,
	Uses_Distinct:  bool,
	Has_Separator:  bool,
	Separator:      Term_View,
}

Path_View :: struct {
	Kind:       Path_Kind,
	Range:      Source_Range,
	Term:       Term_View,
	Minimum:    int,
	Maximum:    int,
	Has_Maximum: bool,
}

Term_Node_View :: struct {
	Kind:  Term_Node_Kind,
	Range: Source_Range,
}

Property_List_View :: struct {
	Predicate: Term_View,
	Path:      Path_Ref,
	Range:     Source_Range,
}

Values_Row_View :: struct {
	Range: Source_Range,
}

Order_Condition_View :: struct {
	Direction:  Order_Direction,
	Expression: Expression_Ref,
	Range:      Source_Range,
}

@(private) public_location :: proc(value: Source_Position) -> Source_Location {
	return Source_Location{Byte_Offset = value.byte_offset, Line = value.line, Column = value.column}
}

@(private) public_range :: proc(value: Source_Span) -> Source_Range {
	return Source_Range{Start = public_location(value.start), End = public_location(value.end)}
}

@(private) public_term :: proc(value: Term) -> Term_View {
	return Term_View{
		Kind = value.kind,
		Lexical = value.lexical,
		Has_Language = value.has_language,
		Language = value.language,
		Has_Datatype = value.has_datatype,
		Datatype_Kind = value.datatype_kind,
		Datatype_Lexical = value.datatype_lexical,
		Syntax_Node = Term_Node_Ref(value.syntax_node),
		Range = public_range(value.span),
	}
}

// Query_Form_Of returns the top-level query form.
Query_Form_Of :: proc(query: ^Query) -> Query_Form { return query.form }

// Query_Range returns the half-open span covering the parsed query.
Query_Range :: proc(query: ^Query) -> Source_Range { return public_range(query.span) }

Query_Has_Base :: proc(query: ^Query) -> bool { return query.has_base }

Query_Base :: proc(query: ^Query) -> Term_View { return public_term(query.base) }

Query_Prefix_Count :: proc(query: ^Query) -> int { return len(query.prefixes) }

Query_Prefix :: proc(query: ^Query, index: int) -> (Prefix_View, bool) {
	if index < 0 || index >= len(query.prefixes) do return {}, false
	value := query.prefixes[index]
	return Prefix_View{Prefix = public_term(value.prefix), Namespace = public_term(value.namespace), Range = public_range(value.span)}, true
}

Query_Dataset_Clause_Count :: proc(query: ^Query) -> int { return len(query.dataset) }

Query_Dataset_Clause :: proc(query: ^Query, index: int) -> (Dataset_Clause_View, bool) {
	if index < 0 || index >= len(query.dataset) do return {}, false
	value := query.dataset[index]
	return Dataset_Clause_View{Named = value.named, Source = public_term(value.source), Range = public_range(value.span)}, true
}

// Query_Where_Pattern returns the root WHERE group for forms that have one.
Query_Where_Pattern :: proc(query: ^Query) -> (Pattern_Ref, bool) {
	#partial switch query.form {
	case .Select: return Pattern_Ref(query.select.where_pattern), query.select.where_pattern != Invalid_Pattern
	case .Ask: return Pattern_Ref(query.ask.where_pattern), query.ask.where_pattern != Invalid_Pattern
	case .Construct: return Pattern_Ref(query.construct.where_pattern), query.construct.where_pattern != Invalid_Pattern
	case .Describe: return Pattern_Ref(query.describe.where_pattern), query.describe.has_where
	}
	return Invalid_Pattern_Ref, false
}

Query_Construct_Template :: proc(query: ^Query) -> (Pattern_Ref, bool) {
	if query.form != .Construct || query.construct.template == Invalid_Pattern do return Invalid_Pattern_Ref, false
	return Pattern_Ref(query.construct.template), true
}

Query_Construct_Where_Shorthand :: proc(query: ^Query) -> bool {
	return query.form == .Construct && query.construct.where_shorthand
}

Query_Describe_All :: proc(query: ^Query) -> bool {
	return query.form == .Describe && query.describe.describe_all
}

Query_Describe_Term_Count :: proc(query: ^Query) -> int {
	if query.form != .Describe do return 0
	return len(query.describe.terms)
}

Query_Describe_Term :: proc(query: ^Query, index: int) -> (Term_View, bool) {
	if query.form != .Describe || index < 0 || index >= len(query.describe.terms) do return {}, false
	return public_term(query.describe.terms[index]), true
}

Query_Select_Modifier :: proc(query: ^Query) -> Select_Modifier { return query.select.modifier }
Query_Select_All :: proc(query: ^Query) -> bool { return query.select.select_all }
Query_Select_Projection_Count :: proc(query: ^Query) -> int { return len(query.select.projection) }

// Query_Select_Projection returns a variable and an optional expression.
// Has_Expression distinguishes `?name` from `(expression AS ?name)`.
Query_Select_Projection :: proc(query: ^Query, index: int) -> (variable: Term_View, expression: Expression_Ref, has_expression: bool, ok: bool) {
	if index < 0 || index >= len(query.select.projection) do return {}, Invalid_Expression_Ref, false, false
	expression_index := query.select.projection_expressions[index]
	return public_term(query.select.projection[index]), Expression_Ref(expression_index), expression_index != Invalid_Expression, true
}

Query_Group_By_Count :: proc(query: ^Query) -> int { return len(query.group_by) }

Query_Group_By :: proc(query: ^Query, index: int) -> (expression: Expression_Ref, alias: Term_View, has_alias: bool, ok: bool) {
	if index < 0 || index >= len(query.group_by) do return Invalid_Expression_Ref, {}, false, false
	alias_term := query.group_aliases[index]
	// A GROUP BY alias is an ordinary variable term, so its syntax_node is
	// deliberately Invalid_Term_Node just like every other ordinary Term.
	// Lexical content is the parser's presence marker for this optional field.
	return Expression_Ref(query.group_by[index]), public_term(alias_term), len(alias_term.lexical) != 0, true
}

Query_Having_Count :: proc(query: ^Query) -> int { return len(query.having) }

Query_Having :: proc(query: ^Query, index: int) -> (Expression_Ref, bool) {
	if index < 0 || index >= len(query.having) do return Invalid_Expression_Ref, false
	return Expression_Ref(query.having[index]), true
}

Query_Order_Count :: proc(query: ^Query) -> int { return len(query.order) }

Query_Order :: proc(query: ^Query, index: int) -> (Order_Condition_View, bool) {
	if index < 0 || index >= len(query.order) do return {}, false
	value := query.order[index]
	return Order_Condition_View{Direction = value.direction, Expression = Expression_Ref(value.expression), Range = public_range(value.span)}, true
}

Query_Limit :: proc(query: ^Query) -> (Term_View, bool) { return public_term(query.limit), query.has_limit }
Query_Offset :: proc(query: ^Query) -> (Term_View, bool) { return public_term(query.offset), query.has_offset }

Query_Tail_Values_Count :: proc(query: ^Query) -> int { return len(query.tail_values) }

Query_Tail_Values :: proc(query: ^Query, index: int) -> (Pattern_Ref, bool) {
	if index < 0 || index >= len(query.tail_values) do return Invalid_Pattern_Ref, false
	return Pattern_Ref(query.tail_values[index]), true
}

Pattern :: proc(query: ^Query, reference: Pattern_Ref) -> (Pattern_View, bool) {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return {}, false
	value := query.patterns[index]
	return Pattern_View{
		Kind = value.kind,
		Range = public_range(value.span),
		Graph_Name = public_term(value.graph_name),
		Expression = Expression_Ref(value.expression),
		Variable = public_term(value.variable),
		Service_Name = public_term(value.service_name),
		Service_Silent = value.service_silent,
	}, true
}

Pattern_Child_Count :: proc(query: ^Query, reference: Pattern_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return 0
	return len(query.patterns[index].children)
}

Pattern_Child :: proc(query: ^Query, reference: Pattern_Ref, index: int) -> (Pattern_Ref, bool) {
	pattern_index := int(reference)
	if pattern_index < 0 || pattern_index >= len(query.patterns) || index < 0 || index >= len(query.patterns[pattern_index].children) do return Invalid_Pattern_Ref, false
	return Pattern_Ref(query.patterns[pattern_index].children[index]), true
}

Pattern_Triple_Count :: proc(query: ^Query, reference: Pattern_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return 0
	return len(query.patterns[index].triples)
}

Pattern_Triple :: proc(query: ^Query, reference: Pattern_Ref, index: int) -> (Triple_Pattern_View, bool) {
	pattern_index := int(reference)
	if pattern_index < 0 || pattern_index >= len(query.patterns) || index < 0 || index >= len(query.patterns[pattern_index].triples) do return {}, false
	value := query.patterns[pattern_index].triples[index]
	return Triple_Pattern_View{Subject = public_term(value.subject), Predicate = public_term(value.predicate), Path = Path_Ref(value.path), Object = public_term(value.object), Range = public_range(value.span)}, true
}

Pattern_Standalone_Node_Count :: proc(query: ^Query, reference: Pattern_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return 0
	return len(query.patterns[index].standalone_nodes)
}

Pattern_Standalone_Node :: proc(query: ^Query, reference: Pattern_Ref, index: int) -> (Term_View, bool) {
	pattern_index := int(reference)
	if pattern_index < 0 || pattern_index >= len(query.patterns) || index < 0 || index >= len(query.patterns[pattern_index].standalone_nodes) do return {}, false
	return public_term(query.patterns[pattern_index].standalone_nodes[index]), true
}

Pattern_Values_Variable_Count :: proc(query: ^Query, reference: Pattern_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return 0
	return len(query.patterns[index].values_variables)
}

Pattern_Values_Variable :: proc(query: ^Query, reference: Pattern_Ref, index: int) -> (Term_View, bool) {
	pattern_index := int(reference)
	if pattern_index < 0 || pattern_index >= len(query.patterns) || index < 0 || index >= len(query.patterns[pattern_index].values_variables) do return {}, false
	return public_term(query.patterns[pattern_index].values_variables[index]), true
}

Pattern_Values_Row_Count :: proc(query: ^Query, reference: Pattern_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return 0
	return len(query.patterns[index].values_rows)
}

Pattern_Values_Row :: proc(query: ^Query, reference: Pattern_Ref, index: int) -> (Values_Row_View, bool) {
	pattern_index := int(reference)
	if pattern_index < 0 || pattern_index >= len(query.patterns) || index < 0 || index >= len(query.patterns[pattern_index].values_rows) do return {}, false
	return Values_Row_View{Range = public_range(query.patterns[pattern_index].values_rows[index].span)}, true
}

Pattern_Values_Cell :: proc(query: ^Query, reference: Pattern_Ref, row, column: int) -> (term: Term_View, unbound: bool, ok: bool) {
	pattern_index := int(reference)
	if pattern_index < 0 || pattern_index >= len(query.patterns) || row < 0 || row >= len(query.patterns[pattern_index].values_rows) do return {}, false, false
	value := query.patterns[pattern_index].values_rows[row]
	if column < 0 || column >= len(value.values) do return {}, false, false
	return public_term(value.values[column]), value.unbound[column], true
}

Pattern_Subquery :: proc(query: ^Query, reference: Pattern_Ref) -> (^Query, bool) {
	index := int(reference)
	if index < 0 || index >= len(query.patterns) do return nil, false
	subquery := query.patterns[index].subquery
	if subquery < 0 || subquery >= len(query.subqueries) do return nil, false
	return &query.subqueries[subquery], true
}

Expression :: proc(query: ^Query, reference: Expression_Ref) -> (Expression_View, bool) {
	index := int(reference)
	if index < 0 || index >= len(query.expressions) do return {}, false
	value := query.expressions[index]
	return Expression_View{Kind = value.kind, Operator = value.operator, Range = public_range(value.span), Term = public_term(value.term), Name = value.name, Uses_Distinct = value.uses_distinct, Has_Separator = value.has_separator, Separator = public_term(value.separator)}, true
}

Expression_Child_Count :: proc(query: ^Query, reference: Expression_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.expressions) do return 0
	return len(query.expressions[index].children)
}

Expression_Child :: proc(query: ^Query, reference: Expression_Ref, index: int) -> (Expression_Ref, bool) {
	expression_index := int(reference)
	if expression_index < 0 || expression_index >= len(query.expressions) || index < 0 || index >= len(query.expressions[expression_index].children) do return Invalid_Expression_Ref, false
	value := query.expressions[expression_index]
	if value.kind == .Exists || value.kind == .Not_Exists do return Invalid_Expression_Ref, false
	return Expression_Ref(value.children[index]), true
}

Expression_Pattern :: proc(query: ^Query, reference: Expression_Ref) -> (Pattern_Ref, bool) {
	index := int(reference)
	if index < 0 || index >= len(query.expressions) do return Invalid_Pattern_Ref, false
	value := query.expressions[index]
	if (value.kind != .Exists && value.kind != .Not_Exists) || len(value.children) != 1 do return Invalid_Pattern_Ref, false
	return Pattern_Ref(value.children[0]), true
}

Path :: proc(query: ^Query, reference: Path_Ref) -> (Path_View, bool) {
	index := int(reference)
	if index < 0 || index >= len(query.paths) do return {}, false
	value := query.paths[index]
	return Path_View{Kind = value.kind, Range = public_range(value.span), Term = public_term(value.term), Minimum = value.minimum, Maximum = value.maximum, Has_Maximum = value.has_maximum}, true
}

Path_Child_Count :: proc(query: ^Query, reference: Path_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.paths) do return 0
	return len(query.paths[index].children)
}

Path_Child :: proc(query: ^Query, reference: Path_Ref, index: int) -> (Path_Ref, bool) {
	path_index := int(reference)
	if path_index < 0 || path_index >= len(query.paths) || index < 0 || index >= len(query.paths[path_index].children) do return Invalid_Path_Ref, false
	return Path_Ref(query.paths[path_index].children[index]), true
}

Path_Negated_Term_Count :: proc(query: ^Query, reference: Path_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.paths) do return 0
	return len(query.paths[index].negated_terms)
}

Path_Negated_Term :: proc(query: ^Query, reference: Path_Ref, index: int) -> (term: Term_View, inverse: bool, ok: bool) {
	path_index := int(reference)
	if path_index < 0 || path_index >= len(query.paths) || index < 0 || index >= len(query.paths[path_index].negated_terms) do return {}, false, false
	value := query.paths[path_index]
	return public_term(value.negated_terms[index]), value.negated_inverse[index], true
}

Query_Term_Node :: proc(query: ^Query, reference: Term_Node_Ref) -> (Term_Node_View, bool) {
	index := int(reference)
	if index < 0 || index >= len(query.term_nodes) do return {}, false
	value := query.term_nodes[index]
	return Term_Node_View{Kind = value.kind, Range = public_range(value.span)}, true
}

Term_Node_Property_Count :: proc(query: ^Query, reference: Term_Node_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.term_nodes) do return 0
	return len(query.term_nodes[index].properties)
}

Term_Node_Property :: proc(query: ^Query, reference: Term_Node_Ref, index: int) -> (Property_List_View, bool) {
	node_index := int(reference)
	if node_index < 0 || node_index >= len(query.term_nodes) || index < 0 || index >= len(query.term_nodes[node_index].properties) do return {}, false
	value := query.term_nodes[node_index].properties[index]
	return Property_List_View{Predicate = public_term(value.predicate), Path = Path_Ref(value.path), Range = public_range(value.span)}, true
}

Term_Node_Property_Object_Count :: proc(query: ^Query, reference: Term_Node_Ref, property: int) -> int {
	node_index := int(reference)
	if node_index < 0 || node_index >= len(query.term_nodes) || property < 0 || property >= len(query.term_nodes[node_index].properties) do return 0
	return len(query.term_nodes[node_index].properties[property].objects)
}

Term_Node_Property_Object :: proc(query: ^Query, reference: Term_Node_Ref, property, index: int) -> (Term_View, bool) {
	node_index := int(reference)
	if node_index < 0 || node_index >= len(query.term_nodes) || property < 0 || property >= len(query.term_nodes[node_index].properties) || index < 0 || index >= len(query.term_nodes[node_index].properties[property].objects) do return {}, false
	return public_term(query.term_nodes[node_index].properties[property].objects[index]), true
}

Term_Node_Item_Count :: proc(query: ^Query, reference: Term_Node_Ref) -> int {
	index := int(reference)
	if index < 0 || index >= len(query.term_nodes) do return 0
	return len(query.term_nodes[index].items)
}

Term_Node_Item :: proc(query: ^Query, reference: Term_Node_Ref, index: int) -> (Term_View, bool) {
	node_index := int(reference)
	if node_index < 0 || node_index >= len(query.term_nodes) || index < 0 || index >= len(query.term_nodes[node_index].items) do return {}, false
	return public_term(query.term_nodes[node_index].items[index]), true
}
