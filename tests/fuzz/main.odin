package main

import "core:fmt"
import "core:os"
import sparql "../../sparql"

CASES     :: #config(FUZZ_CASES, 50_000)
MAX_BYTES :: #config(FUZZ_MAX_BYTES, 512)
SEED      :: u64(#config(FUZZ_SEED, 0x4f64696e53505131))
MAX_TRAVERSAL_DEPTH :: 128

SEEDS := [15]string{
	`SELECT ?s ?o { ?s <urn:p> ?o }`,
	`ASK { ?s <urn:p> "value"@en }`,
	`CONSTRUCT { ?s <urn:out> ?o } WHERE { ?s <urn:in> ?o }`,
	`DESCRIBE <urn:target> WHERE { ?s <urn:link> <urn:target> }`,
	`SELECT * { ?s !(<urn:p>|^<urn:q>) ?o }`,
	`SELECT (COUNT(*) AS ?count) { ?s <urn:p> ?o } GROUP BY ?s`,
	`SELECT ?s { ?s <urn:p> ?o FILTER EXISTS { ?s <urn:q> ?o } }`,
	`SELECT * { VALUES (?s ?o) { (<urn:s> "value") (UNDEF "other") } }`,
	`SELECT ?s { { SELECT ?s { ?s <urn:p> ?o } LIMIT 1 } }`,
	`CONSTRUCT { [ <urn:label> ?name ] <urn:knows> ?friend } WHERE { ?friend <urn:name> ?name }`,
	`SELECT ?s FROM <urn:default> FROM NAMED <urn:named> WHERE { GRAPH ?g { ?s <urn:p> ?o } }`,
	`SELECT ?s { SERVICE SILENT <urn:service> { ?s <urn:p> ?o } }`,
	`SELECT ?group (COUNT(*) AS ?count) { ?s <urn:p> ?o } GROUP BY (STR(?s) AS ?group) HAVING (COUNT(*) > 0) VALUES ?s { <urn:s> }`,
	`SELECT ?s { ?s <urn:p>{1,2} ?o }`,
	`DESCRIBE * WHERE { ?s <urn:p> ?o } ORDER BY ?s LIMIT 1`,
}

next_random :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}

generate_case :: proc(buffer: []byte, index: int, random: ^u64) -> string {
	length := int(next_random(random) % u64(len(buffer) + 1))
	if index % 6 == 0 {
		seed := SEEDS[int(next_random(random) % u64(len(SEEDS)))]
		length = min(len(seed), len(buffer))
		copy(buffer[:length], transmute([]byte)seed[:length])
	} else if index % 3 == 0 {
		seed := SEEDS[int(next_random(random) % u64(len(SEEDS)))]
		length = min(len(seed), len(buffer))
		copy(buffer[:length], transmute([]byte)seed[:length])
		mutations := 1 + int(next_random(random) % 8)
		for _ in 0..<mutations {
			if length == 0 do break
			at := int(next_random(random) % u64(length))
			buffer[at] = byte(next_random(random) >> 56)
		}
	} else {
		for byte_index in 0..<length do buffer[byte_index] = byte(next_random(random) >> 56)
	}
	return string(buffer[:length])
}

valid_range :: proc(range: sparql.Source_Range, input: string) -> bool {
	return range.Start.Byte_Offset >= 0 && range.End.Byte_Offset >= range.Start.Byte_Offset && range.End.Byte_Offset <= len(input)
}

check_term :: proc(query: ^sparql.Query, value: sparql.Term_View, input: string, depth: int) -> bool {
	if depth > MAX_TRAVERSAL_DEPTH || !valid_range(value.Range, input) do return false
	if value.Kind != .Blank_Property_List && value.Kind != .Collection do return true
	if value.Syntax_Node == sparql.Invalid_Term_Node_Ref do return false
	return check_term_node(query, value.Syntax_Node, input, depth + 1)
}

check_path :: proc(query: ^sparql.Query, reference: sparql.Path_Ref, input: string, depth: int) -> bool {
	if depth > MAX_TRAVERSAL_DEPTH do return false
	value, ok := sparql.Path(query, reference)
	if !ok || !valid_range(value.Range, input) || !check_term(query, value.Term, input, depth + 1) do return false
	for index in 0..<sparql.Path_Child_Count(query, reference) {
		child, child_ok := sparql.Path_Child(query, reference, index)
		if !child_ok || !check_path(query, child, input, depth + 1) do return false
	}
	for index in 0..<sparql.Path_Negated_Term_Count(query, reference) {
		term, _, term_ok := sparql.Path_Negated_Term(query, reference, index)
		if !term_ok || !check_term(query, term, input, depth + 1) do return false
	}
	return true
}

check_term_node :: proc(query: ^sparql.Query, reference: sparql.Term_Node_Ref, input: string, depth: int) -> bool {
	if depth > MAX_TRAVERSAL_DEPTH do return false
	value, ok := sparql.Query_Term_Node(query, reference)
	if !ok || !valid_range(value.Range, input) do return false
	for property_index in 0..<sparql.Term_Node_Property_Count(query, reference) {
		property, property_ok := sparql.Term_Node_Property(query, reference, property_index)
		if !property_ok || !valid_range(property.Range, input) || !check_term(query, property.Predicate, input, depth + 1) do return false
		if property.Path != sparql.Invalid_Path_Ref && !check_path(query, property.Path, input, depth + 1) do return false
		for object_index in 0..<sparql.Term_Node_Property_Object_Count(query, reference, property_index) {
			object, object_ok := sparql.Term_Node_Property_Object(query, reference, property_index, object_index)
			if !object_ok || !check_term(query, object, input, depth + 1) do return false
		}
	}
	for index in 0..<sparql.Term_Node_Item_Count(query, reference) {
		item, item_ok := sparql.Term_Node_Item(query, reference, index)
		if !item_ok || !check_term(query, item, input, depth + 1) do return false
	}
	return true
}

check_expression :: proc(query: ^sparql.Query, reference: sparql.Expression_Ref, input: string, depth: int) -> bool {
	if depth > MAX_TRAVERSAL_DEPTH do return false
	value, ok := sparql.Expression(query, reference)
	if !ok || !valid_range(value.Range, input) || !check_term(query, value.Term, input, depth + 1) || !check_term(query, value.Separator, input, depth + 1) do return false
	pattern, has_pattern := sparql.Expression_Pattern(query, reference)
	if has_pattern do return check_pattern(query, pattern, input, depth + 1)
	for index in 0..<sparql.Expression_Child_Count(query, reference) {
		child, child_ok := sparql.Expression_Child(query, reference, index)
		if !child_ok || !check_expression(query, child, input, depth + 1) do return false
	}
	return true
}

check_pattern :: proc(query: ^sparql.Query, reference: sparql.Pattern_Ref, input: string, depth: int) -> bool {
	if depth > MAX_TRAVERSAL_DEPTH do return false
	value, ok := sparql.Pattern(query, reference)
	if !ok || !valid_range(value.Range, input) || !check_term(query, value.Graph_Name, input, depth + 1) || !check_term(query, value.Variable, input, depth + 1) || !check_term(query, value.Service_Name, input, depth + 1) do return false
	if value.Expression != sparql.Invalid_Expression_Ref && !check_expression(query, value.Expression, input, depth + 1) do return false
	for index in 0..<sparql.Pattern_Child_Count(query, reference) {
		child, child_ok := sparql.Pattern_Child(query, reference, index)
		if !child_ok || !check_pattern(query, child, input, depth + 1) do return false
	}
	for index in 0..<sparql.Pattern_Triple_Count(query, reference) {
		triple, triple_ok := sparql.Pattern_Triple(query, reference, index)
		if !triple_ok || !valid_range(triple.Range, input) || !check_term(query, triple.Subject, input, depth + 1) || !check_term(query, triple.Predicate, input, depth + 1) || !check_term(query, triple.Object, input, depth + 1) do return false
		if triple.Path != sparql.Invalid_Path_Ref && !check_path(query, triple.Path, input, depth + 1) do return false
	}
	for index in 0..<sparql.Pattern_Standalone_Node_Count(query, reference) {
		term, term_ok := sparql.Pattern_Standalone_Node(query, reference, index)
		if !term_ok || !check_term(query, term, input, depth + 1) do return false
	}
	variable_count := sparql.Pattern_Values_Variable_Count(query, reference)
	for index in 0..<variable_count {
		variable, variable_ok := sparql.Pattern_Values_Variable(query, reference, index)
		if !variable_ok || !check_term(query, variable, input, depth + 1) do return false
	}
	for row_index in 0..<sparql.Pattern_Values_Row_Count(query, reference) {
		row, row_ok := sparql.Pattern_Values_Row(query, reference, row_index)
		if !row_ok || !valid_range(row.Range, input) do return false
		for column_index in 0..<variable_count {
			cell, _, cell_ok := sparql.Pattern_Values_Cell(query, reference, row_index, column_index)
			if !cell_ok || !check_term(query, cell, input, depth + 1) do return false
		}
	}
	subquery, has_subquery := sparql.Pattern_Subquery(query, reference)
	if has_subquery && !check_query(subquery, input, depth + 1) do return false
	return true
}

check_query :: proc(query: ^sparql.Query, input: string, depth: int) -> bool {
	if depth > MAX_TRAVERSAL_DEPTH || !valid_range(sparql.Query_Range(query), input) do return false
	form := sparql.Query_Form_Of(query)
	if form != .Select && form != .Ask && form != .Construct && form != .Describe do return false
	if sparql.Query_Has_Base(query) && !check_term(query, sparql.Query_Base(query), input, depth + 1) do return false
	for index in 0..<sparql.Query_Prefix_Count(query) {
		prefix, prefix_ok := sparql.Query_Prefix(query, index)
		if !prefix_ok || !valid_range(prefix.Range, input) || !check_term(query, prefix.Prefix, input, depth + 1) || !check_term(query, prefix.Namespace, input, depth + 1) do return false
	}
	for index in 0..<sparql.Query_Dataset_Clause_Count(query) {
		clause, clause_ok := sparql.Query_Dataset_Clause(query, index)
		if !clause_ok || !valid_range(clause.Range, input) || !check_term(query, clause.Source, input, depth + 1) do return false
	}
	where_pattern, has_where := sparql.Query_Where_Pattern(query)
	if has_where && !check_pattern(query, where_pattern, input, depth + 1) do return false
	if form != .Describe && !has_where do return false
	template, has_template := sparql.Query_Construct_Template(query)
	if has_template && !check_pattern(query, template, input, depth + 1) do return false
	for index in 0..<sparql.Query_Describe_Term_Count(query) {
		term, term_ok := sparql.Query_Describe_Term(query, index)
		if !term_ok || !check_term(query, term, input, depth + 1) do return false
	}
	for index in 0..<sparql.Query_Select_Projection_Count(query) {
		variable, expression, has_expression, projection_ok := sparql.Query_Select_Projection(query, index)
		if !projection_ok || !check_term(query, variable, input, depth + 1) do return false
		if has_expression && !check_expression(query, expression, input, depth + 1) do return false
	}
	for index in 0..<sparql.Query_Group_By_Count(query) {
		expression, alias, has_alias, group_ok := sparql.Query_Group_By(query, index)
		if !group_ok || !check_expression(query, expression, input, depth + 1) do return false
		if has_alias && !check_term(query, alias, input, depth + 1) do return false
	}
	for index in 0..<sparql.Query_Having_Count(query) {
		expression, having_ok := sparql.Query_Having(query, index)
		if !having_ok || !check_expression(query, expression, input, depth + 1) do return false
	}
	for index in 0..<sparql.Query_Order_Count(query) {
		condition, order_ok := sparql.Query_Order(query, index)
		if !order_ok || !valid_range(condition.Range, input) || !check_expression(query, condition.Expression, input, depth + 1) do return false
	}
	if limit, has_limit := sparql.Query_Limit(query); has_limit && !check_term(query, limit, input, depth + 1) do return false
	if offset, has_offset := sparql.Query_Offset(query); has_offset && !check_term(query, offset, input, depth + 1) do return false
	for index in 0..<sparql.Query_Tail_Values_Count(query) {
		values, values_ok := sparql.Query_Tail_Values(query, index)
		if !values_ok || !check_pattern(query, values, input, depth + 1) do return false
	}
	return true
}

check_input :: proc(input: string, case_index: int) -> bool {
	query, parse_error := sparql.Parse(input)
	defer sparql.Destroy(&query)
	if sparql.Parse_Error_Code(parse_error) != .None {
		if valid_range(sparql.Parse_Error_Range(parse_error), input) do return true
		fmt.eprintf("parser error range escaped input at case %d input=%q\n", case_index, input)
		return false
	}
	if check_query(&query, input, 0) do return true
	fmt.eprintf("public AST traversal invariant failed at case %d input=%q\n", case_index, input)
	return false
}

main :: proc() {
	if CASES <= 0 || MAX_BYTES <= 0 {
		fmt.eprintln("FUZZ_CASES and FUZZ_MAX_BYTES must be positive")
		os.exit(2)
	}
	buffer := make([]byte, MAX_BYTES)
	defer delete(buffer)
	for seed in SEEDS {
		// Do not rely on random corpus selection to validate a representative
		// syntax branch. Every intact seed must itself satisfy the public
		// traversal invariant before mutations are generated from it.
		if !check_input(seed, -1) do os.exit(1)
	}
	random := SEED
	for case_index in 0..<CASES {
		input := generate_case(buffer, case_index, &random)
		if !check_input(input, case_index) do os.exit(1)
	}
	fmt.printf("parser fuzz: %d cases, seed=0x%x, max_bytes=%d, 0 invariant failures\n", CASES, SEED, MAX_BYTES)
}
