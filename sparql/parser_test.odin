package sparql

import "core:strings"
import "core:testing"

@(private) basic_pattern :: proc(query: ^Query, group_index: int) -> ^Pattern_Node {
	if group_index == Invalid_Pattern || group_index < 0 || group_index >= len(query.patterns) do return nil
	group := &query.patterns[group_index]
	if group.kind != .Group || len(group.children) != 1 do return nil
	child := group.children[0]
	if child < 0 || child >= len(query.patterns) do return nil
	basic := &query.patterns[child]
	if basic.kind != .Basic_Graph_Pattern do return nil
	return basic
}

@(test)
test_parse_select_basic_graph_pattern :: proc(t: ^testing.T) {
	query, error := parse(`PREFIX ex: <https://example.test/> SELECT DISTINCT ?name WHERE { ?person a ex:Person . ?person ex:name "Ada"@en }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, query.form, Query_Form.Select)
	testing.expect_value(t, query.select.modifier, Select_Modifier.Distinct)
	testing.expect_value(t, query.span.start.line, 1)
	testing.expect_value(t, query.span.end.line, 1)
	testing.expect_value(t, len(query.prefixes), 1)
	testing.expect_value(t, len(query.select.projection), 1)
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, len(basic.triples), 2)
		testing.expect_value(t, basic.triples[0].predicate.kind, Term_Kind.RDF_Type)
		testing.expect_value(t, basic.triples[1].predicate.lexical, "ex:name")
		testing.expect_value(t, basic.triples[1].object.language, "@en")
	}
}

@(test)
test_parse_query_owns_lexical_values :: proc(t: ^testing.T) {
	input, clone_error := strings.clone(`SELECT ?value { <urn:subject> <urn:predicate> "value" }`)
	testing.expect_value(t, clone_error, nil)
	query, error := parse(input)
	delete(input)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, query.select.projection[0].lexical, "?value")
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, basic.triples[0].object.lexical, `"value"`)
	}
}

@(test)
test_parse_reports_expected_term_and_unsupported_syntax :: proc(t: ^testing.T) {
	query, term_error := parse(`SELECT ?x { ?x <urn:p> }`)
	defer destroy(&query)
	testing.expect_value(t, term_error.code, Error_Code.Expected_Term)

	ask, ask_error := parse(`ASK { ?x ?p "value"^^<urn:datatype> }`)
	defer destroy(&ask)
	testing.expect_value(t, ask_error.code, Error_Code.None)
	testing.expect_value(t, ask.form, Query_Form.Ask)
	basic := basic_pattern(&ask, ask.ask.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, len(basic.triples), 1)
		testing.expect_value(t, basic.triples[0].object.datatype_lexical, "<urn:datatype>")
	}
}

@(test)
test_parse_ask_solution_modifiers :: proc(t: ^testing.T) {
	query, error := parse(`ASK { ?target <urn:tag> ?tag } GROUP BY ?target HAVING (COUNT(?tag) > 1) ORDER BY DESC(COUNT(?tag)) OFFSET 2 LIMIT 3`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, query.form, Query_Form.Ask)
	testing.expect_value(t, len(query.group_by), 1)
	testing.expect_value(t, len(query.having), 1)
	testing.expect_value(t, len(query.order), 1)
	testing.expect_value(t, query.offset.lexical, "2")
	testing.expect_value(t, query.limit.lexical, "3")
}

@(test)
test_parse_rejects_dataset_clauses_inside_subqueries :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * { SELECT ?value FROM <urn:dataset> WHERE { ?value <urn:p> ?object } }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.Invalid_Query)
}

@(test)
test_parse_subquery_accepts_final_values_clause :: proc(t: ^testing.T) {
	query, error := parse(`SELECT ?value { { SELECT ?value WHERE {} VALUES ?value { "Ada" } } }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 1)
	if len(outer.children) == 1 {
		subquery_pattern := &query.patterns[outer.children[0]]
		testing.expect_value(t, subquery_pattern.kind, Pattern_Kind.Subquery)
		subquery := &query.subqueries[subquery_pattern.subquery]
		testing.expect_value(t, len(subquery.tail_values), 1)
	}
}

@(test)
test_parse_final_values_after_solution_modifiers :: proc(t: ^testing.T) {
	query, error := parse(`SELECT (COUNT(?value) AS ?count) { ?value <urn:p> ?object } HAVING (COUNT(?value) > 1) ORDER BY DESC(COUNT(?value)) VALUES ?value { <urn:ada> }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, len(query.having), 1)
	testing.expect_value(t, len(query.order), 1)
	testing.expect_value(t, len(query.tail_values), 1)

	subquery, subquery_error := parse(`SELECT * { { SELECT (COUNT(?value) AS ?count) { ?value <urn:p> ?object } HAVING (COUNT(?value) > 1) VALUES ?value { <urn:ada> } } }`)
	defer destroy(&subquery)
	testing.expect_value(t, subquery_error.code, Error_Code.None)
	outer := &subquery.patterns[subquery.select.where_pattern]
	if len(outer.children) == 1 {
		nested := &subquery.subqueries[subquery.patterns[outer.children[0]].subquery]
		testing.expect_value(t, len(nested.having), 1)
		testing.expect_value(t, len(nested.tail_values), 1)
	}
}

@(test)
test_parse_rejects_repeated_final_values_clauses :: proc(t: ^testing.T) {
	top_level, top_level_error := parse(`SELECT * {} VALUES ?one { 1 } VALUES ?two { 2 }`)
	defer destroy(&top_level)
	testing.expect_value(t, top_level_error.code, Error_Code.Invalid_Query)
	subquery, subquery_error := parse(`SELECT * { { SELECT ?one WHERE {} VALUES ?one { 1 } VALUES ?two { 2 } } }`)
	defer destroy(&subquery)
	testing.expect_value(t, subquery_error.code, Error_Code.Invalid_Query)
}

@(test)
test_parse_error_messages_are_stable :: proc(t: ^testing.T) {
	messages := [Error_Code]string{
		.None                = "no error",
		.Lexical             = "invalid SPARQL token",
		.Expected_Query_Form = "expected SPARQL query form",
		.Expected_IRI        = "expected IRI reference",
		.Expected_Prefix     = "expected prefix name",
		.Expected_Variable   = "expected query variable",
		.Expected_Term       = "expected graph term",
		.Expected_Predicate  = "expected graph predicate",
		.Expected_Expression = "expected SPARQL expression",
		.Expected_Left_Paren = "expected opening parenthesis",
		.Expected_Right_Paren= "expected closing parenthesis",
		.Expected_As         = "expected AS",
		.Expected_By         = "expected BY",
		.Expected_Integer    = "expected integer",
		.Expected_Where      = "expected WHERE clause",
		.Expected_Left_Brace = "expected opening graph-pattern brace",
		.Expected_Right_Brace= "expected closing graph-pattern brace",
		.Expected_Dot        = "expected triple-pattern dot",
		.Invalid_Query       = "invalid SPARQL query form or scope",
		.Unsupported_Syntax  = "SPARQL syntax is not implemented yet",
		.Out_Of_Memory       = "memory allocation failed",
	}
	for code in Error_Code do testing.expect_value(t, error_message(code), messages[code])
}

@(test)
test_parse_construct_and_describe_forms :: proc(t: ^testing.T) {
	construct, construct_error := parse(`CONSTRUCT { ?person ex:name ?name } FROM <urn:data> WHERE { ?person ex:name ?name }`)
	defer destroy(&construct)
	testing.expect_value(t, construct_error.code, Error_Code.None)
	testing.expect_value(t, construct.form, Query_Form.Construct)
	template := basic_pattern(&construct, construct.construct.template)
	where_pattern := basic_pattern(&construct, construct.construct.where_pattern)
	if template == nil || where_pattern == nil {
		testing.expect_value(t, template == nil || where_pattern == nil, false)
	} else {
		testing.expect_value(t, len(template.triples), 1)
		testing.expect_value(t, len(where_pattern.triples), 1)
	}
	testing.expect_value(t, len(construct.dataset), 1)

	describe, describe_error := parse(`DESCRIBE ?person <urn:other> FROM NAMED <urn:named> WHERE { ?person ?predicate ?object }`)
	defer destroy(&describe)
	testing.expect_value(t, describe_error.code, Error_Code.None)
	testing.expect_value(t, describe.form, Query_Form.Describe)
	testing.expect_value(t, len(describe.describe.terms), 2)
	testing.expect_value(t, describe.describe.has_where, true)
	testing.expect_value(t, describe.dataset[0].named, true)
}

@(test)
test_parse_basic_graph_pattern_property_lists :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * { ?person a ex:Person, ex:Agent ; ex:name "Ada" ; ex:knows ?friend . }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, len(basic.triples), 4)
		testing.expect_value(t, basic.triples[0].predicate.kind, Term_Kind.RDF_Type)
		testing.expect_value(t, basic.triples[1].object.lexical, "ex:Agent")
		testing.expect_value(t, basic.triples[2].predicate.lexical, "ex:name")
		testing.expect_value(t, basic.triples[3].object.lexical, "?friend")
	}
}

@(test)
test_parse_recursive_optional_union_and_graph_patterns :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * {
		?person ex:name ?name
		OPTIONAL { ?person ex:email ?email }
		GRAPH ?graph { ?person ex:type ex:Person }
		{ ?person ex:role ex:Author } UNION { ?person ex:role ex:Editor }
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)

	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, outer.kind, Pattern_Kind.Group)
	testing.expect_value(t, len(outer.children), 4)
	if len(outer.children) == 4 {
		basic := &query.patterns[outer.children[0]]
		optional := &query.patterns[outer.children[1]]
		graph := &query.patterns[outer.children[2]]
		union_pattern := &query.patterns[outer.children[3]]
		testing.expect_value(t, basic.kind, Pattern_Kind.Basic_Graph_Pattern)
		testing.expect_value(t, len(basic.triples), 1)
		testing.expect_value(t, optional.kind, Pattern_Kind.Optional)
		testing.expect_value(t, len(optional.children), 1)
		testing.expect_value(t, graph.kind, Pattern_Kind.Graph)
		testing.expect_value(t, graph.graph_name.lexical, "?graph")
		testing.expect_value(t, len(graph.children), 1)
		testing.expect_value(t, union_pattern.kind, Pattern_Kind.Union)
		testing.expect_value(t, len(union_pattern.children), 2)
	}
}

@(test)
test_parse_filter_and_bind_expressions :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * {
		?person ex:age ?age
		FILTER(?age >= 18 && !BOUND(?retired))
		BIND(CONCAT(?person, "-id") AS ?identifier)
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)

	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 3)
	if len(outer.children) == 3 {
		filter := &query.patterns[outer.children[1]]
		bind := &query.patterns[outer.children[2]]
		testing.expect_value(t, filter.kind, Pattern_Kind.Filter)
		testing.expect_value(t, query.expressions[filter.expression].kind, Expression_Kind.Binary)
		testing.expect_value(t, query.expressions[filter.expression].operator, Expression_Operator.And)
		testing.expect_value(t, bind.kind, Pattern_Kind.Bind)
		testing.expect_value(t, bind.variable.lexical, "?identifier")
		testing.expect_value(t, query.expressions[bind.expression].kind, Expression_Kind.Function)
		testing.expect_value(t, query.expressions[bind.expression].name, "CONCAT")
	}
}

@(test)
test_parse_unparenthesized_filter_and_boolean_term :: proc(t: ^testing.T) {
	query, error := parse(`ASK { ?person ex:active true FILTER BOUND(?person) }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.ask.where_pattern]
	testing.expect_value(t, len(outer.children), 2)
	if len(outer.children) == 2 {
		basic := &query.patterns[outer.children[0]]
		filter := &query.patterns[outer.children[1]]
		testing.expect_value(t, basic.triples[0].object.kind, Term_Kind.Boolean)
		testing.expect_value(t, filter.kind, Pattern_Kind.Filter)
		testing.expect_value(t, query.expressions[filter.expression].name, "BOUND")
	}
}

@(test)
test_parse_minus_pattern :: proc(t: ^testing.T) {
	query, error := parse(`ASK { ?person ex:name ?name MINUS { ?person ex:blocked true } }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.ask.where_pattern]
	testing.expect_value(t, len(outer.children), 2)
	if len(outer.children) == 2 {
		minus := &query.patterns[outer.children[1]]
		testing.expect_value(t, minus.kind, Pattern_Kind.Minus)
		testing.expect_value(t, len(minus.children), 1)
	}
}

@(test)
test_parse_values_patterns :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * {
		VALUES ?person { <urn:ada> UNDEF }
		VALUES (?name ?age) { ("Ada" 42) ("Grace" UNDEF) }
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 2)
	if len(outer.children) == 2 {
		one := &query.patterns[outer.children[0]]
		many := &query.patterns[outer.children[1]]
		testing.expect_value(t, one.kind, Pattern_Kind.Values)
		testing.expect_value(t, len(one.values_variables), 1)
		testing.expect_value(t, len(one.values_rows), 2)
		testing.expect_value(t, one.values_rows[1].unbound[0], true)
		testing.expect_value(t, many.kind, Pattern_Kind.Values)
		testing.expect_value(t, len(many.values_variables), 2)
		testing.expect_value(t, len(many.values_rows), 2)
		testing.expect_value(t, many.values_rows[0].values[0].lexical, `"Ada"`)
		testing.expect_value(t, many.values_rows[1].unbound[1], true)
	}
}

@(test)
test_parse_order_limit_and_offset :: proc(t: ^testing.T) {
	query, error := parse(`SELECT ?person { ?person ex:score ?score } ORDER BY DESC(?score) ?person LIMIT 10 OFFSET 20`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, len(query.order), 2)
	if len(query.order) == 2 {
		testing.expect_value(t, query.order[0].direction, Order_Direction.Descending)
		testing.expect_value(t, query.order[1].direction, Order_Direction.Default)
		testing.expect_value(t, query.order[0].span.end.byte_offset, 64)
	}
	testing.expect_value(t, query.has_limit, true)
	testing.expect_value(t, query.limit.lexical, "10")
	testing.expect_value(t, query.has_offset, true)
	testing.expect_value(t, query.offset.lexical, "20")
}

@(test)
test_parse_select_expression_projection :: proc(t: ^testing.T) {
	query, error := parse(`SELECT ?x (?x + ?y AS ?sum) (datatype(?x) AS ?datatype) {}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, len(query.select.projection), 3)
	testing.expect_value(t, len(query.select.projection_expressions), 3)
	if len(query.select.projection) == 3 {
		testing.expect_value(t, query.select.projection[0].lexical, "?x")
		testing.expect_value(t, query.select.projection_expressions[0], Invalid_Expression)
		testing.expect_value(t, query.select.projection[1].lexical, "?sum")
		testing.expect_value(t, query.expressions[query.select.projection_expressions[1]].operator, Expression_Operator.Add)
		testing.expect_value(t, query.select.projection[2].lexical, "?datatype")
		testing.expect_value(t, query.expressions[query.select.projection_expressions[2]].name, "datatype")
	}
}

@(test)
test_parse_aggregate_wildcard_projection :: proc(t: ^testing.T) {
	query, error := parse(`SELECT (COUNT(DISTINCT *) AS ?count) {}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	expression := query.select.projection_expressions[0]
	testing.expect_value(t, query.expressions[expression].kind, Expression_Kind.Function)
	testing.expect_value(t, query.expressions[expression].name, "COUNT")
	testing.expect_value(t, query.expressions[expression].uses_distinct, true)
	testing.expect_value(t, len(query.expressions[expression].children), 1)
	testing.expect_value(t, query.expressions[query.expressions[expression].children[0]].kind, Expression_Kind.Wildcard)
}

@(test)
test_parse_in_and_not_in_expressions :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * { ?s ?p ?o FILTER(?o NOT IN(1, 2, ?s + 57)) FILTER(?s IN(?o)) }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	first_filter := &query.patterns[outer.children[1]]
	second_filter := &query.patterns[outer.children[2]]
	testing.expect_value(t, query.expressions[first_filter.expression].kind, Expression_Kind.Not_In)
	testing.expect_value(t, len(query.expressions[first_filter.expression].children), 4)
	testing.expect_value(t, query.expressions[second_filter.expression].kind, Expression_Kind.In)
}

@(test)
test_parse_construct_where_shorthand :: proc(t: ^testing.T) {
	query, error := parse(`CONSTRUCT WHERE { ?subject ?predicate 1816 }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, query.construct.where_shorthand, true)
	testing.expect_value(t, query.construct.template, query.construct.where_pattern)
	basic := basic_pattern(&query, query.construct.template)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, basic.triples[0].object.lexical, "1816")
	}
	with_dataset, dataset_error := parse(`CONSTRUCT FROM <urn:source> WHERE { ?subject ?predicate ?object }`)
	defer destroy(&with_dataset)
	testing.expect_value(t, dataset_error.code, Error_Code.None)
	testing.expect_value(t, with_dataset.construct.where_shorthand, true)
	testing.expect_value(t, with_dataset.construct.template, with_dataset.construct.where_pattern)
	testing.expect_value(t, len(with_dataset.dataset), 1)
}

@(test)
test_parse_blank_property_lists_and_collections_without_lowering :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * {
		?person ex:details [ ex:name "Ada" ; ex:knows (?friend ex:Grace) ] .
		(ex:one [ ex:kind ex:Thing ]) ex:tail ?tail
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, len(basic.triples), 2)
		details := basic.triples[0].object
		testing.expect_value(t, details.kind, Term_Kind.Blank_Property_List)
		details_node := &query.term_nodes[details.syntax_node]
		testing.expect_value(t, len(details_node.properties), 2)
		friends := details_node.properties[1].objects[0]
		testing.expect_value(t, friends.kind, Term_Kind.Collection)
		testing.expect_value(t, len(query.term_nodes[friends.syntax_node].items), 2)
		collection := basic.triples[1].subject
		testing.expect_value(t, collection.kind, Term_Kind.Collection)
		testing.expect_value(t, len(query.term_nodes[collection.syntax_node].items), 2)
		nested := query.term_nodes[collection.syntax_node].items[1]
		testing.expect_value(t, nested.kind, Term_Kind.Blank_Property_List)
	}
}

@(test)
test_parse_empty_blank_property_list_as_a_triple_subject :: proc(t: ^testing.T) {
	query, error := parse(`SELECT ?predicate ?object { [] ?predicate ?object }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
}

@(test)
test_parse_group_concat_subquery_with_empty_blank_property_list :: proc(t: ^testing.T) {
	where_query, where_error := parse(`SELECT ?predicate ?object WHERE { [] ?predicate ?object }`)
	defer destroy(&where_query)
	testing.expect_value(t, where_error.code, Error_Code.None)

	count, count_error := parse(`SELECT ?predicate (COUNT(?object) AS ?count) WHERE { [] ?predicate ?object } GROUP BY ?predicate`)
	defer destroy(&count)
	testing.expect_value(t, count_error.code, Error_Code.None)

	direct, direct_error := parse(`SELECT ?predicate (GROUP_CONCAT(?object) AS ?grouped) WHERE { [] ?predicate ?object } GROUP BY ?predicate`)
	defer destroy(&direct)
	testing.expect_value(t, direct_error.code, Error_Code.None)

	query, error := parse(`PREFIX : <http://www.example.org/>
	SELECT (COUNT(*) AS ?count) {
		{ SELECT ?predicate (GROUP_CONCAT(?object) AS ?grouped) WHERE {
			[] ?predicate ?object
		} GROUP BY ?predicate }
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
}

@(test)
test_parse_property_path_tree :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * {
		?subject ^ex:parent/(ex:knows|ex:worksWith)+ ?object .
		?left !(ex:blocked|^ex:blockedBy) ?right .
		?first ex:next? ?last
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		sequence := &query.paths[basic.triples[0].path]
		testing.expect_value(t, sequence.kind, Path_Kind.Sequence)
		testing.expect_value(t, query.paths[sequence.children[0]].kind, Path_Kind.Inverse)
		testing.expect_value(t, query.paths[sequence.children[1]].kind, Path_Kind.One_Or_More)
		negated := &query.paths[basic.triples[1].path]
		testing.expect_value(t, negated.kind, Path_Kind.Negated_Set)
		testing.expect_value(t, len(negated.negated_terms), 2)
		testing.expect_value(t, negated.negated_inverse[1], true)
		testing.expect_value(t, query.paths[basic.triples[2].path].kind, Path_Kind.Zero_Or_One)
	}
}

@(test)
test_parse_path_in_blank_property_list :: proc(t: ^testing.T) {
	query, error := parse(`PREFIX : <http://www.example.org/>
SELECT ?X WHERE { [ :p|:q|:r ?X ] }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect_value(t, basic == nil, false)
	} else {
		testing.expect_value(t, len(basic.standalone_nodes), 1)
	}
}

@(test)
test_parse_bounded_property_path_modifiers :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * WHERE { ?one <urn:p>{2} ?two . ?three <urn:q>{1,4} ?four . ?five <urn:r>{3,} ?six }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	basic := basic_pattern(&query, query.select.where_pattern)
	if basic == nil {
		testing.expect(t, basic != nil)
		return
	}
	exact := query.paths[basic.triples[0].path]
	finite := query.paths[basic.triples[1].path]
	unbounded := query.paths[basic.triples[2].path]
	testing.expect_value(t, exact.kind, Path_Kind.Bounded)
	testing.expect_value(t, exact.minimum, 2)
	testing.expect_value(t, exact.maximum, 2)
	testing.expect_value(t, exact.has_maximum, true)
	testing.expect_value(t, finite.minimum, 1)
	testing.expect_value(t, finite.maximum, 4)
	testing.expect_value(t, finite.has_maximum, true)
	testing.expect_value(t, unbounded.minimum, 3)
	testing.expect_value(t, unbounded.has_maximum, false)
	invalid_sources := [3]string{`SELECT * WHERE { ?s <urn:p>{,2} ?o }`, `SELECT * WHERE { ?s <urn:p>{4,2} ?o }`, `SELECT * WHERE { ?s <urn:p>{x} ?o }`}
	for source in invalid_sources {
		invalid, invalid_error := parse(source)
		defer destroy(&invalid)
		testing.expect(t, invalid_error.code != Error_Code.None)
	}
}

@(test)
test_parse_group_by_and_having :: proc(t: ^testing.T) {
	query, error := parse(`SELECT ?person (COUNT(*) AS ?count) { ?person ?predicate ?object }
		GROUP BY ?person (STR(?person) AS ?label)
		HAVING(COUNT(*) > 1)
		ORDER BY ?person`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, len(query.group_by), 2)
	testing.expect_value(t, query.group_aliases[0].syntax_node, Invalid_Term_Node)
	testing.expect_value(t, query.group_aliases[1].lexical, "?label")
	testing.expect_value(t, len(query.having), 1)
	testing.expect_value(t, query.expressions[query.having[0]].operator, Expression_Operator.Greater)
	testing.expect_value(t, len(query.order), 1)
}

@(test)
test_parse_subquery_with_independent_query_storage :: proc(t: ^testing.T) {
	query, error := parse(`SELECT ?person {
		?person ex:name ?name
		{ SELECT ?person { ?person ex:score ?score } ORDER BY DESC(?score) LIMIT 1 }
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 2)
	if len(outer.children) == 2 {
		subquery_pattern := &query.patterns[outer.children[1]]
		testing.expect_value(t, subquery_pattern.kind, Pattern_Kind.Subquery)
		subquery := &query.subqueries[subquery_pattern.subquery]
		testing.expect_value(t, subquery.form, Query_Form.Select)
		testing.expect_value(t, len(subquery.select.projection), 1)
		testing.expect_value(t, subquery.has_limit, true)
		testing.expect_value(t, len(subquery.order), 1)
	}
}

@(test)
test_parse_direct_subquery_syntax :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * { SELECT * { ?subject ?predicate ?object } }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 1)
	if len(outer.children) == 1 {
		pattern := &query.patterns[outer.children[0]]
		testing.expect_value(t, pattern.kind, Pattern_Kind.Subquery)
		testing.expect_value(t, query.subqueries[pattern.subquery].form, Query_Form.Select)
	}
}

@(test)
test_parse_query_final_values_clause :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * { } VALUES ?person { <urn:ada> }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	testing.expect_value(t, len(query.tail_values), 1)
	if len(query.tail_values) == 1 {
		values := &query.patterns[query.tail_values[0]]
		testing.expect_value(t, len(values.values_variables), 1)
		testing.expect_value(t, len(values.values_rows), 1)
	}
}

@(test)
test_parse_allows_optional_period_after_non_triple_patterns :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * {
		?subject <urn:p> ?object .
		OPTIONAL { ?subject <urn:name> ?name } .
		FILTER(?subject = <urn:subject>) .
		BIND(?object AS ?copy) .
		VALUES ?copy { <urn:object> } .
		{ ?subject <urn:q> ?other } .
	}`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 6)
}

@(test)
test_parse_service_without_network_behavior :: proc(t: ^testing.T) {
	query, error := parse(`SELECT * { SERVICE SILENT ?endpoint { ?subject ?predicate ?object } }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.None)
	outer := &query.patterns[query.select.where_pattern]
	testing.expect_value(t, len(outer.children), 1)
	if len(outer.children) == 1 {
		service := &query.patterns[outer.children[0]]
		testing.expect_value(t, service.kind, Pattern_Kind.Service)
		testing.expect_value(t, service.service_silent, true)
		testing.expect_value(t, service.service_name.lexical, "?endpoint")
		testing.expect_value(t, len(service.children), 1)
	}
}

@(test)
test_parse_rejects_non_predicate_term :: proc(t: ^testing.T) {
	query, error := parse(`ASK { ?subject "not-a-predicate" ?object }`)
	defer destroy(&query)
	testing.expect_value(t, error.code, Error_Code.Expected_Predicate)
}

@(test)
test_parse_validates_query_wide_scope_and_aggregate_constraints :: proc(t: ^testing.T) {
	select_all, select_all_error := parse(`SELECT * { ?subject ?predicate ?object } GROUP BY ?subject`)
	defer destroy(&select_all)
	testing.expect_value(t, select_all_error.code, Error_Code.Invalid_Query)

	aggregate, aggregate_error := parse(`SELECT (SUM(?left, ?right) AS ?total) {}`)
	defer destroy(&aggregate)
	testing.expect_value(t, aggregate_error.code, Error_Code.Invalid_Query)

	rebound, rebound_error := parse(`SELECT * { ?subject ?predicate ?value BIND(1 AS ?value) }`)
	defer destroy(&rebound)
	testing.expect_value(t, rebound_error.code, Error_Code.Invalid_Query)

	nested, nested_error := parse(`SELECT * { ?subject ?predicate ?value { BIND(1 AS ?value) } }`)
	defer destroy(&nested)
	testing.expect_value(t, nested_error.code, Error_Code.None)

	ungrouped_variable, ungrouped_variable_error := parse(`SELECT ?predicate (COUNT(*) AS ?count) { ?subject ?predicate ?object } GROUP BY ?subject`)
	defer destroy(&ungrouped_variable)
	testing.expect_value(t, ungrouped_variable_error.code, Error_Code.Invalid_Query)

	ungrouped_expression, ungrouped_expression_error := parse(`SELECT ((?left + ?right) AS ?sum) (COUNT(*) AS ?count) { ?subject ?predicate ?left ; ?other ?right } GROUP BY ?subject`)
	defer destroy(&ungrouped_expression)
	testing.expect_value(t, ungrouped_expression_error.code, Error_Code.Invalid_Query)

	ungrouped_group_key, ungrouped_group_key_error := parse(`SELECT ((?left + ?right) AS ?sum) (COUNT(*) AS ?count) { ?subject ?predicate ?left ; ?other ?right } GROUP BY (?left + ?right)`)
	defer destroy(&ungrouped_group_key)
	testing.expect_value(t, ungrouped_group_key_error.code, Error_Code.Invalid_Query)

	aliased_group_key, aliased_group_key_error := parse(`SELECT ?sum (COUNT(*) AS ?count) { ?subject ?predicate ?left ; ?other ?right } GROUP BY ((?left + ?right) AS ?sum)`)
	defer destroy(&aliased_group_key)
	testing.expect_value(t, aliased_group_key_error.code, Error_Code.None)
}
