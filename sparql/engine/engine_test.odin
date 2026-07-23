package engine

import "core:testing"
import uuid "core:encoding/uuid"
import rdf "odin-rdf:rdf"
import turtle "odin-rdf:rdf/turtle"
import sparql ".."
import algebra "../algebra"
import dataset "../dataset"

@(private) add_iri_quad :: proc(t: ^testing.T, store: ^dataset.Memory_Dataset, subject, predicate, object: string) {
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri(subject), predicate = rdf.iri(predicate), object = rdf.iri(object)})
	testing.expect_value(t, dataset.add(store, quad), dataset.Error_Code.None)
}

@(private) add_integer_quad :: proc(t: ^testing.T, store: ^dataset.Memory_Dataset, subject, predicate, object: string) {
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri(subject), predicate = rdf.iri(predicate), object = rdf.typed_literal(object, "http://www.w3.org/2001/XMLSchema#integer")})
	testing.expect_value(t, dataset.add(store, quad), dataset.Error_Code.None)
}

@(private) add_typed_quad :: proc(t: ^testing.T, store: ^dataset.Memory_Dataset, subject, predicate, object, datatype: string) {
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri(subject), predicate = rdf.iri(predicate), object = rdf.typed_literal(object, datatype)})
	testing.expect_value(t, dataset.add(store, quad), dataset.Error_Code.None)
}

@(private) add_named_iri_quad :: proc(t: ^testing.T, store: ^dataset.Memory_Dataset, graph, subject, predicate, object: string) {
	quad := rdf.named_graph_quad(rdf.Triple{subject = rdf.iri(subject), predicate = rdf.iri(predicate), object = rdf.iri(object)}, rdf.iri(graph))
	testing.expect_value(t, dataset.add(store, quad), dataset.Error_Code.None)
}

@(private) Service_Fixture :: struct {
	endpoint:  string,
	view:      dataset.View,
	available: bool,
	calls:     int,
}

@(private) UUID_Fixture :: struct {
	next:   u8,
	repeat: bool,
}

@(private) RAND_Fixture :: struct {
	value: f64,
	ok:    bool,
}

@(private) rand_fixture_callback :: proc(data: rawptr) -> (f64, bool) {
	fixture := cast(^RAND_Fixture)data
	return fixture.value, fixture.ok
}

@(private) uuid_fixture_callback :: proc(data: rawptr) -> (uuid.Identifier, bool) {
	fixture := cast(^UUID_Fixture)data
	identifier: uuid.Identifier
	if fixture.repeat {
		identifier[15] = 1
	} else {
		fixture.next += 1
		identifier[15] = fixture.next
	}
	return identifier, true
}

@(private) service_fixture_callback :: proc(endpoint: rdf.Term, data: rawptr) -> (dataset.View, bool) {
	fixture := cast(^Service_Fixture)data
	fixture.calls += 1
	if !fixture.available || endpoint.kind != .IRI || endpoint.value != fixture.endpoint do return {}, false
	return fixture.view, true
}

@(test)
test_execute_select_projects_bgp_multiset :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person { ?person <urn:knows> ?friend }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:bert")
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:cora")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Kind(&result), Result_Kind.Select)
	testing.expect_value(t, Variable_Count(&result), 1)
	testing.expect_value(t, Row_Count(&result), 2)
	name, name_ok := Variable_Name(&result, 0)
	testing.expect_value(t, name_ok, true)
	testing.expect_value(t, name, "person")
	for row in 0..<Row_Count(&result) {
		term, bound, ok := Cell(&result, row, 0)
		testing.expect_value(t, ok, true)
		testing.expect_value(t, bound, true)
		testing.expect_value(t, term.value, "urn:ada")
	}
}

@(test)
test_execute_default_now_survives_a_multi_pattern_bgp :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?entity {
		?entity <urn:knows> ?friend .
		?friend <urn:kind> <urn:target> .
		?entity <urn:name> ?name
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:bert")
	add_iri_quad(t, &store, "urn:bert", "urn:kind", "urn:target")
	add_iri_quad(t, &store, "urn:ada", "urn:name", "urn:ada-name")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	// No Now_Lexical is supplied: the evaluator must safely capture one query
	// clock even when optimized builds reuse temporary allocator storage.
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
}

@(test)
test_execute_select_star_preserves_source_variable_order :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * WHERE { ?subject ?predicate ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:bert")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected_names := [3]string{"subject", "predicate", "object"}
	testing.expect_value(t, Variable_Count(&result), len(expected_names))
	for expected, column in expected_names {
		name, name_ok := Variable_Name(&result, column)
		testing.expect_value(t, name_ok, true)
		testing.expect_value(t, name, expected)
	}
}

@(test)
test_execute_canonicalizes_case_insensitive_boolean_keywords :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT (TRUE AS ?true_value) (False AS ?false_value) WHERE { }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	true_value, true_bound, true_ok := Cell(&result, 0, 0)
	false_value, false_bound, false_ok := Cell(&result, 0, 1)
	testing.expect_value(t, true_ok && true_bound && false_ok && false_bound, true)
	testing.expect_value(t, true_value.value, "true")
	testing.expect_value(t, false_value.value, "false")
	testing.expect_value(t, true_value.datatype, "http://www.w3.org/2001/XMLSchema#boolean")
	testing.expect_value(t, false_value.datatype, "http://www.w3.org/2001/XMLSchema#boolean")
}

@(test)
test_execute_service_callback_correlates_bindings_and_honors_silent :: proc(t: ^testing.T) {
	variable_endpoint, variable_endpoint_parse_error := sparql.Parse(`SELECT * { ?person <urn:uses> ?endpoint SERVICE ?endpoint { ?person <urn:knows> ?friend } }`)
	defer sparql.Destroy(&variable_endpoint)
	ordinary_failure, ordinary_failure_parse_error := sparql.Parse(`SELECT ?person { ?person <urn:uses> <urn:remote> SERVICE <urn:missing> { ?person <urn:knows> ?friend } }`)
	defer sparql.Destroy(&ordinary_failure)
	silent_failure, silent_failure_parse_error := sparql.Parse(`SELECT ?person { ?person <urn:uses> <urn:remote> SERVICE SILENT <urn:missing> { ?person <urn:knows> ?friend } }`)
	defer sparql.Destroy(&silent_failure)
	testing.expect_value(t, sparql.Parse_Error_Code(variable_endpoint_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(ordinary_failure_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(silent_failure_parse_error), sparql.Error_Code.None)
	local: dataset.Memory_Dataset
	dataset.init(&local)
	defer dataset.destroy(&local)
	add_iri_quad(t, &local, "urn:ada", "urn:uses", "urn:remote")
	dataset.seal(&local)
	local_view, local_view_error := dataset.view(&local)
	testing.expect_value(t, local_view_error, dataset.Error_Code.None)
	remote: dataset.Memory_Dataset
	dataset.init(&remote)
	defer dataset.destroy(&remote)
	add_iri_quad(t, &remote, "urn:ada", "urn:knows", "urn:bert")
	dataset.seal(&remote)
	remote_view, remote_view_error := dataset.view(&remote)
	testing.expect_value(t, remote_view_error, dataset.Error_Code.None)
	fixture := Service_Fixture{endpoint = "urn:remote", view = remote_view, available = true}
	statistics := Execution_Statistics{}
	options := Options{Max_Solutions = 8, Service_Callback = service_fixture_callback, Service_Data = &fixture, Statistics = &statistics}
	result, execute_error := execute(&variable_endpoint, local_view, options)
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, fixture.calls, 1)
	testing.expect_value(t, Variable_Count(&result), 3)
	expected_names := [3]string{"person", "endpoint", "friend"}
	for expected, column in expected_names {
		name, name_ok := Variable_Name(&result, column)
		testing.expect_value(t, name_ok, true)
		testing.expect_value(t, name, expected)
	}
	testing.expect_value(t, Row_Count(&result), 1)
	person, person_bound, person_ok := Cell(&result, 0, 0)
	endpoint, endpoint_bound, endpoint_ok := Cell(&result, 0, 1)
	friend, friend_bound, friend_ok := Cell(&result, 0, 2)
	testing.expect_value(t, person_ok && person_bound && endpoint_ok && endpoint_bound && friend_ok && friend_bound, true)
	testing.expect_value(t, person.value, "urn:ada")
	testing.expect_value(t, endpoint.value, "urn:remote")
	testing.expect_value(t, friend.value, "urn:bert")
	failed, failed_error := execute(&ordinary_failure, local_view, options)
	defer destroy(&failed)
	testing.expect_value(t, failed_error, Error_Code.Service_Error)
	silent, silent_error := execute(&silent_failure, local_view, options)
	defer destroy(&silent)
	testing.expect_value(t, silent_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&silent), 1)
	silent_person, silent_person_bound, silent_person_ok := Cell(&silent, 0, 0)
	testing.expect_value(t, silent_person_ok && silent_person_bound, true)
	testing.expect_value(t, silent_person.value, "urn:ada")
	testing.expect_value(t, statistics.Service_Calls, u64(3))
}

@(test)
test_execute_select_star_hides_blank_property_list_subject :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * { ?subject <urn:details> [ <urn:property> ?value ] }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	blank_scope := rdf.new_blank_node_scope()
	details := rdf.blank_node("details", blank_scope)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:details"), object = details})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = details, predicate = rdf.iri("urn:property"), object = rdf.literal("engineer")})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Variable_Count(&result), 2)
	testing.expect_value(t, Row_Count(&result), 1)
	subject_name, subject_name_ok := Variable_Name(&result, 0)
	value_name, value_name_ok := Variable_Name(&result, 1)
	testing.expect_value(t, subject_name_ok, true)
	testing.expect_value(t, value_name_ok, true)
	testing.expect_value(t, subject_name, "subject")
	testing.expect_value(t, value_name, "value")
	subject, subject_bound, subject_ok := Cell(&result, 0, 0)
	value, value_bound, value_ok := Cell(&result, 0, 1)
	testing.expect_value(t, subject_ok && subject_bound, true)
	testing.expect_value(t, value_ok && value_bound, true)
	testing.expect_value(t, subject.value, "urn:ada")
	testing.expect_value(t, value.value, "engineer")
}

@(test)
test_execute_select_star_lowers_collection_to_rdf_list_patterns :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * { ?subject <urn:items> (?first [ <urn:value> ?second ]) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	blank_scope := rdf.new_blank_node_scope()
	head := rdf.blank_node("head", blank_scope)
	tail := rdf.blank_node("tail", blank_scope)
	details := rdf.blank_node("details", blank_scope)
	first := rdf.iri("urn:first")
	rdf_first := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
	rdf_rest := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
	rdf_nil := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:items"), object = head})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = head, predicate = rdf_first, object = first})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = head, predicate = rdf_rest, object = tail})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = tail, predicate = rdf_first, object = details})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = tail, predicate = rdf_rest, object = rdf_nil})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = details, predicate = rdf.iri("urn:value"), object = rdf.literal("second")})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Variable_Count(&result), 3)
	testing.expect_value(t, Row_Count(&result), 1)
	expected_names := [3]string{"subject", "first", "second"}
	for name, column in expected_names {
		actual_name, name_ok := Variable_Name(&result, column)
		testing.expect_value(t, name_ok, true)
		testing.expect_value(t, actual_name, name)
	}
	subject, subject_bound, subject_ok := Cell(&result, 0, 0)
	first_value, first_bound, first_ok := Cell(&result, 0, 1)
	second, second_bound, second_ok := Cell(&result, 0, 2)
	testing.expect_value(t, subject_ok && subject_bound && first_ok && first_bound && second_ok && second_bound, true)
	testing.expect_value(t, subject.value, "urn:ada")
	testing.expect_value(t, first_value.value, "urn:first")
	testing.expect_value(t, second.value, "second")

	standalone, standalone_parse_error := sparql.Parse(`ASK { (<urn:first> [ <urn:value> "second" ]) }`)
	defer sparql.Destroy(&standalone)
	testing.expect_value(t, sparql.Parse_Error_Code(standalone_parse_error), sparql.Error_Code.None)
	standalone_result, standalone_error := execute(&standalone, view, {Max_Solutions = 8})
	defer destroy(&standalone_result)
	testing.expect_value(t, standalone_error, Error_Code.None)
	standalone_value, standalone_ok := Ask_Value(&standalone_result)
	testing.expect_value(t, standalone_ok && standalone_value, true)
}

@(test)
test_execute_empty_collection_matches_rdf_nil :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { <urn:ada> <urn:items> () }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	rdf_nil := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:items"), object = rdf_nil})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	value, value_ok := Ask_Value(&result)
	testing.expect_value(t, value_ok && value, true)
}

@(test)
test_execute_construct_instantiates_fresh_template_blank_nodes_and_graph_set :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`CONSTRUCT {
		_:result <urn:for> ?friend .
		_:result <urn:kind> <urn:generated>
	} WHERE { <urn:ada> <urn:knows> ?friend }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:bert")
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:cora")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Kind(&result), Result_Kind.Graph)
	testing.expect_value(t, Triple_Count(&result), 4)
	first, first_ok := Triple(&result, 0)
	second, second_ok := Triple(&result, 1)
	third, third_ok := Triple(&result, 2)
	fourth, fourth_ok := Triple(&result, 3)
	testing.expect_value(t, first_ok && second_ok && third_ok && fourth_ok, true)
	testing.expect_value(t, first.subject.kind, rdf.Term_Kind.Blank_Node)
	testing.expect_value(t, equal_term(first.subject, second.subject), true)
	testing.expect_value(t, equal_term(third.subject, fourth.subject), true)
	testing.expect_value(t, equal_term(first.subject, third.subject), false)
	testing.expect_value(t, first.object.value, "urn:bert")
	testing.expect_value(t, third.object.value, "urn:cora")

	deduplicated, deduplicated_parse_error := sparql.Parse(`CONSTRUCT { <urn:a> <urn:derived> <urn:b> } WHERE { <urn:ada> <urn:knows> ?friend }`)
	defer sparql.Destroy(&deduplicated)
	testing.expect_value(t, sparql.Parse_Error_Code(deduplicated_parse_error), sparql.Error_Code.None)
	deduplicated_result, deduplicated_error := execute(&deduplicated, view, {Max_Solutions = 8})
	defer destroy(&deduplicated_result)
	testing.expect_value(t, deduplicated_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&deduplicated_result), 1)

	sliced, sliced_parse_error := sparql.Parse(`CONSTRUCT { <urn:output> <urn:for> ?friend } WHERE { <urn:ada> <urn:knows> ?friend } ORDER BY DESC(?friend) OFFSET 1 LIMIT 1`)
	defer sparql.Destroy(&sliced)
	testing.expect_value(t, sparql.Parse_Error_Code(sliced_parse_error), sparql.Error_Code.None)
	sliced_result, sliced_error := execute(&sliced, view, {Max_Solutions = 8})
	defer destroy(&sliced_result)
	testing.expect_value(t, sliced_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&sliced_result), 1)
	sliced_triple, sliced_ok := Triple(&sliced_result, 0)
	testing.expect_value(t, sliced_ok, true)
	testing.expect_value(t, sliced_triple.object.value, "urn:bert")
}

@(test)
test_execute_describe_returns_concise_default_graph_descriptions :: proc(t: ^testing.T) {
	direct, direct_parse_error := sparql.Parse(`DESCRIBE <urn:ada>`)
	defer sparql.Destroy(&direct)
	testing.expect_value(t, sparql.Parse_Error_Code(direct_parse_error), sparql.Error_Code.None)
	explicit_with_empty_where, explicit_with_empty_where_parse_error := sparql.Parse(`DESCRIBE <urn:ada> ?target WHERE { ?target <urn:p> <urn:missing> }`)
	defer sparql.Destroy(&explicit_with_empty_where)
	testing.expect_value(t, sparql.Parse_Error_Code(explicit_with_empty_where_parse_error), sparql.Error_Code.None)
	variable, variable_parse_error := sparql.Parse(`DESCRIBE ?target WHERE { ?target <urn:p> <urn:cora> }`)
	defer sparql.Destroy(&variable)
	testing.expect_value(t, sparql.Parse_Error_Code(variable_parse_error), sparql.Error_Code.None)
	all, all_parse_error := sparql.Parse(`DESCRIBE * WHERE { <urn:ada> <urn:p> ?target }`)
	defer sparql.Destroy(&all)
	testing.expect_value(t, sparql.Parse_Error_Code(all_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:p", "urn:bert")
	add_iri_quad(t, &store, "urn:ada", "urn:q", "urn:cora")
	add_iri_quad(t, &store, "urn:bert", "urn:p", "urn:cora")
	add_named_iri_quad(t, &store, "urn:named", "urn:ada", "urn:p", "urn:outside")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	direct_result, direct_error := execute(&direct, view, {Max_Solutions = 8})
	defer destroy(&direct_result)
	testing.expect_value(t, direct_error, Error_Code.None)
	testing.expect_value(t, Kind(&direct_result), Result_Kind.Graph)
	testing.expect_value(t, Triple_Count(&direct_result), 2)
	first, first_ok := Triple(&direct_result, 0)
	second, second_ok := Triple(&direct_result, 1)
	testing.expect_value(t, first_ok && second_ok, true)
	testing.expect_value(t, first.subject.value, "urn:ada")
	testing.expect_value(t, second.subject.value, "urn:ada")
	explicit_with_empty_where_result, explicit_with_empty_where_error := execute(&explicit_with_empty_where, view, {Max_Solutions = 8})
	defer destroy(&explicit_with_empty_where_result)
	testing.expect_value(t, explicit_with_empty_where_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&explicit_with_empty_where_result), 2)
	variable_result, variable_error := execute(&variable, view, {Max_Solutions = 8})
	defer destroy(&variable_result)
	testing.expect_value(t, variable_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&variable_result), 1)
	variable_triple, variable_ok := Triple(&variable_result, 0)
	testing.expect_value(t, variable_ok, true)
	testing.expect_value(t, variable_triple.subject.value, "urn:bert")
	testing.expect_value(t, variable_triple.object.value, "urn:cora")
	all_result, all_error := execute(&all, view, {Max_Solutions = 8})
	defer destroy(&all_result)
	testing.expect_value(t, all_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&all_result), 1)
	all_triple, all_ok := Triple(&all_result, 0)
	testing.expect_value(t, all_ok, true)
	testing.expect_value(t, all_triple.subject.value, "urn:bert")
}

@(test)
test_execute_describe_variable_after_turtle_ingestion :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse("DESCRIBE ?target WHERE { ?target <urn:p> <urn:cora> }\n")
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	parsed := turtle.parse(`<urn:ada> <urn:p> <urn:bert> .
<urn:ada> <urn:q> <urn:cora> .
<urn:bert> <urn:p> <urn:cora> .
`, dataset.triple_sink, {}, &store)
	testing.expect_value(t, parsed.code, turtle.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&result), 1)
	triple, triple_ok := Triple(&result, 0)
	testing.expect_value(t, triple_ok, true)
	testing.expect_value(t, triple.subject.value, "urn:bert")
}

@(test)
test_execute_describe_variable_blank_node_from_declared_dataset :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`DESCRIBE ?target FROM <urn:source> WHERE { <urn:seed> <urn:selects> ?target }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	blank_scope := rdf.new_blank_node_scope()
	details := rdf.blank_node("details", blank_scope)
	testing.expect_value(t, dataset.add(&store, rdf.named_graph_quad(rdf.Triple{subject = rdf.iri("urn:seed"), predicate = rdf.iri("urn:selects"), object = details}, rdf.iri("urn:source"))), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.named_graph_quad(rdf.Triple{subject = details, predicate = rdf.iri("urn:label"), object = rdf.literal("selected")}, rdf.iri("urn:source"))), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = details, predicate = rdf.iri("urn:label"), object = rdf.literal("outside")})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&result), 1)
	triple, triple_ok := Triple(&result, 0)
	testing.expect_value(t, triple_ok, true)
	testing.expect_value(t, triple.subject.kind, rdf.Term_Kind.Blank_Node)
	testing.expect_value(t, triple.subject.value, "details")
	testing.expect_value(t, triple.predicate.value, "urn:label")
	testing.expect_value(t, triple.object.value, "selected")
}

@(test)
test_execute_construct_from_uses_declared_query_dataset :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`CONSTRUCT FROM <urn:source> WHERE { ?subject <urn:p> ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:source", "urn:ada", "urn:p", "urn:bert")
	add_iri_quad(t, &store, "urn:default", "urn:p", "urn:outside")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&result), 1)
	triple, triple_ok := Triple(&result, 0)
	testing.expect_value(t, triple_ok, true)
	testing.expect_value(t, triple.subject.value, "urn:ada")
	testing.expect_value(t, triple.object.value, "urn:bert")
}

@(test)
test_execute_construct_from_named_restricts_graph_template_bindings :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`CONSTRUCT { ?subject <urn:derived> ?object } FROM NAMED <urn:source> WHERE { GRAPH <urn:source> { ?subject <urn:p> ?object } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:source", "urn:ada", "urn:p", "urn:bert")
	add_named_iri_quad(t, &store, "urn:other", "urn:cora", "urn:p", "urn:dana")
	add_iri_quad(t, &store, "urn:default", "urn:p", "urn:outside")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Triple_Count(&result), 1)
	triple, triple_ok := Triple(&result, 0)
	testing.expect_value(t, triple_ok, true)
	testing.expect_value(t, triple.subject.value, "urn:ada")
	testing.expect_value(t, triple.predicate.value, "urn:derived")
	testing.expect_value(t, triple.object.value, "urn:bert")
}

@(test)
test_execute_sequence_and_inverse_property_paths :: proc(t: ^testing.T) {
	sequence, sequence_parse_error := sparql.Parse(`SELECT ?start ?end { ?start <urn:first> / <urn:second> ?end }`)
	defer sparql.Destroy(&sequence)
	testing.expect_value(t, sparql.Parse_Error_Code(sequence_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:a", "urn:first", "urn:b")
	add_iri_quad(t, &store, "urn:b", "urn:second", "urn:c")
	add_iri_quad(t, &store, "urn:parent", "urn:parentOf", "urn:child")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	sequence_result, sequence_error := execute(&sequence, view, {Max_Solutions = 8})
	defer destroy(&sequence_result)
	testing.expect_value(t, sequence_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&sequence_result), 1)
	start, start_bound, start_ok := Cell(&sequence_result, 0, 0)
	end, end_bound, end_ok := Cell(&sequence_result, 0, 1)
	testing.expect_value(t, start_ok && start_bound && end_ok && end_bound, true)
	testing.expect_value(t, start.value, "urn:a")
	testing.expect_value(t, end.value, "urn:c")

	inverse, inverse_parse_error := sparql.Parse(`SELECT ?parent { <urn:child> ^<urn:parentOf> ?parent }`)
	defer sparql.Destroy(&inverse)
	testing.expect_value(t, sparql.Parse_Error_Code(inverse_parse_error), sparql.Error_Code.None)
	inverse_result, inverse_error := execute(&inverse, view, {Max_Solutions = 8})
	defer destroy(&inverse_result)
	testing.expect_value(t, inverse_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&inverse_result), 1)
	parent, parent_bound, parent_ok := Cell(&inverse_result, 0, 0)
	testing.expect_value(t, parent_ok && parent_bound, true)
	testing.expect_value(t, parent.value, "urn:parent")
}

@(test)
test_execute_alternative_and_closure_paths_deduplicate_cycles :: proc(t: ^testing.T) {
	plus, plus_parse_error := sparql.Parse(`SELECT ?end { <urn:a> (<urn:p>|<urn:q>)+ ?end }`)
	defer sparql.Destroy(&plus)
	testing.expect_value(t, sparql.Parse_Error_Code(plus_parse_error), sparql.Error_Code.None)
	star, star_parse_error := sparql.Parse(`SELECT ?end { <urn:a> <urn:p>* ?end }`)
	defer sparql.Destroy(&star)
	testing.expect_value(t, sparql.Parse_Error_Code(star_parse_error), sparql.Error_Code.None)
	alternative_sequence, alternative_sequence_parse_error := sparql.Parse(`SELECT ?end { <urn:a> (<urn:left>|<urn:right>)/(<urn:up>|<urn:down>) ?end }`)
	defer sparql.Destroy(&alternative_sequence)
	testing.expect_value(t, sparql.Parse_Error_Code(alternative_sequence_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:a", "urn:p", "urn:b")
	add_iri_quad(t, &store, "urn:b", "urn:p", "urn:a")
	add_iri_quad(t, &store, "urn:b", "urn:q", "urn:c")
	add_iri_quad(t, &store, "urn:a", "urn:left", "urn:left-node")
	add_iri_quad(t, &store, "urn:left-node", "urn:down", "urn:target")
	add_iri_quad(t, &store, "urn:a", "urn:right", "urn:right-node")
	add_iri_quad(t, &store, "urn:right-node", "urn:up", "urn:target")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	plus_result, plus_error := execute(&plus, view, {Max_Solutions = 8})
	defer destroy(&plus_result)
	testing.expect_value(t, plus_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&plus_result), 3)
	plus_expected := [3]string{"urn:b", "urn:a", "urn:c"}
	for expected, row in plus_expected {
		term, bound, ok := Cell(&plus_result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected)
	}
	star_result, star_error := execute(&star, view, {Max_Solutions = 8})
	defer destroy(&star_result)
	testing.expect_value(t, star_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&star_result), 2)
	star_expected := [2]string{"urn:a", "urn:b"}
	for expected, row in star_expected {
		term, bound, ok := Cell(&star_result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected)
	}
	alternative_sequence_result, alternative_sequence_error := execute(&alternative_sequence, view, {Max_Solutions = 8})
	defer destroy(&alternative_sequence_result)
	testing.expect_value(t, alternative_sequence_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&alternative_sequence_result), 2)
	for row in 0..<Row_Count(&alternative_sequence_result) {
		term, bound, ok := Cell(&alternative_sequence_result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, "urn:target")
	}
}

@(test)
test_execute_bounded_property_paths :: proc(t: ^testing.T) {
	exact, exact_parse_error := sparql.Parse(`SELECT ?end { <urn:a> <urn:p>{2} ?end }`)
	defer sparql.Destroy(&exact)
	testing.expect_value(t, sparql.Parse_Error_Code(exact_parse_error), sparql.Error_Code.None)
	finite, finite_parse_error := sparql.Parse(`SELECT ?end { <urn:a> <urn:p>{1,2} ?end }`)
	defer sparql.Destroy(&finite)
	testing.expect_value(t, sparql.Parse_Error_Code(finite_parse_error), sparql.Error_Code.None)
	unbounded, unbounded_parse_error := sparql.Parse(`SELECT ?end { <urn:a> <urn:p>{2,} ?end }`)
	defer sparql.Destroy(&unbounded)
	testing.expect_value(t, sparql.Parse_Error_Code(unbounded_parse_error), sparql.Error_Code.None)
	zero, zero_parse_error := sparql.Parse(`SELECT ?end { <urn:a> <urn:p>{0} ?end }`)
	defer sparql.Destroy(&zero)
	testing.expect_value(t, sparql.Parse_Error_Code(zero_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:a", "urn:p", "urn:b")
	add_iri_quad(t, &store, "urn:b", "urn:p", "urn:c")
	add_iri_quad(t, &store, "urn:c", "urn:p", "urn:d")
	add_iri_quad(t, &store, "urn:d", "urn:p", "urn:c")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	exact_result, exact_error := execute(&exact, view, {Max_Solutions = 8})
	defer destroy(&exact_result)
	testing.expect_value(t, exact_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&exact_result), 1)
	exact_end, exact_bound, exact_ok := Cell(&exact_result, 0, 0)
	testing.expect_value(t, exact_ok && exact_bound, true)
	testing.expect_value(t, exact_end.value, "urn:c")
	finite_result, finite_error := execute(&finite, view, {Max_Solutions = 8})
	defer destroy(&finite_result)
	testing.expect_value(t, finite_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&finite_result), 2)
	finite_first, finite_first_bound, finite_first_ok := Cell(&finite_result, 0, 0)
	finite_second, finite_second_bound, finite_second_ok := Cell(&finite_result, 1, 0)
	testing.expect_value(t, finite_first_ok && finite_first_bound && finite_second_ok && finite_second_bound, true)
	testing.expect_value(t, finite_first.value, "urn:b")
	testing.expect_value(t, finite_second.value, "urn:c")
	unbounded_result, unbounded_error := execute(&unbounded, view, {Max_Solutions = 8})
	defer destroy(&unbounded_result)
	testing.expect_value(t, unbounded_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&unbounded_result), 2)
	unbounded_first, unbounded_first_bound, unbounded_first_ok := Cell(&unbounded_result, 0, 0)
	unbounded_second, unbounded_second_bound, unbounded_second_ok := Cell(&unbounded_result, 1, 0)
	testing.expect_value(t, unbounded_first_ok && unbounded_first_bound && unbounded_second_ok && unbounded_second_bound, true)
	testing.expect_value(t, unbounded_first.value, "urn:c")
	testing.expect_value(t, unbounded_second.value, "urn:d")
	zero_result, zero_error := execute(&zero, view, {Max_Solutions = 8})
	defer destroy(&zero_result)
	testing.expect_value(t, zero_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&zero_result), 1)
	zero_end, zero_bound, zero_ok := Cell(&zero_result, 0, 0)
	testing.expect_value(t, zero_ok && zero_bound, true)
	testing.expect_value(t, zero_end.value, "urn:a")
}

@(test)
test_execute_property_paths_inside_blank_property_lists_and_collections :: proc(t: ^testing.T) {
	blank_list, blank_list_parse_error := sparql.Parse(`SELECT * { ?root <urn:details> [ <urn:p>{2} ?end ] }`)
	defer sparql.Destroy(&blank_list)
	testing.expect_value(t, sparql.Parse_Error_Code(blank_list_parse_error), sparql.Error_Code.None)
	collection, collection_parse_error := sparql.Parse(`SELECT ?end { <urn:root> <urn:items> ([ <urn:p>{1,} ?end ]) }`)
	defer sparql.Destroy(&collection)
	testing.expect_value(t, sparql.Parse_Error_Code(collection_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	blank_scope := rdf.new_blank_node_scope()
	details := rdf.blank_node("details", blank_scope)
	head := rdf.blank_node("head", blank_scope)
	rdf_first := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#first")
	rdf_rest := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#rest")
	rdf_nil := rdf.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#nil")
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:root"), predicate = rdf.iri("urn:details"), object = details})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:root"), predicate = rdf.iri("urn:items"), object = head})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = head, predicate = rdf_first, object = details})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = head, predicate = rdf_rest, object = rdf_nil})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = details, predicate = rdf.iri("urn:p"), object = rdf.iri("urn:mid")})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:mid"), predicate = rdf.iri("urn:p"), object = rdf.iri("urn:end")})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	blank_result, blank_error := execute(&blank_list, view, {Max_Solutions = 8})
	defer destroy(&blank_result)
	testing.expect_value(t, blank_error, Error_Code.None)
	testing.expect_value(t, Variable_Count(&blank_result), 2)
	testing.expect_value(t, Row_Count(&blank_result), 1)
	root_name, root_name_ok := Variable_Name(&blank_result, 0)
	end_name, end_name_ok := Variable_Name(&blank_result, 1)
	testing.expect_value(t, root_name_ok && end_name_ok, true)
	testing.expect_value(t, root_name, "root")
	testing.expect_value(t, end_name, "end")
	end, end_bound, end_ok := Cell(&blank_result, 0, 1)
	testing.expect_value(t, end_ok && end_bound, true)
	testing.expect_value(t, end.value, "urn:end")
	collection_result, collection_error := execute(&collection, view, {Max_Solutions = 8})
	defer destroy(&collection_result)
	testing.expect_value(t, collection_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&collection_result), 2)
	collection_first, collection_first_bound, collection_first_ok := Cell(&collection_result, 0, 0)
	collection_second, collection_second_bound, collection_second_ok := Cell(&collection_result, 1, 0)
	testing.expect_value(t, collection_first_ok && collection_first_bound && collection_second_ok && collection_second_bound, true)
	testing.expect_value(t, collection_first.value, "urn:mid")
	testing.expect_value(t, collection_second.value, "urn:end")
}

@(test)
test_execute_negated_property_set_and_named_path_scopes :: proc(t: ^testing.T) {
	negated, negated_parse_error := sparql.Parse(`SELECT ?target { <urn:a> !(<urn:blocked>|^<urn:blockedBy>) ?target }`)
	defer sparql.Destroy(&negated)
	testing.expect_value(t, sparql.Parse_Error_Code(negated_parse_error), sparql.Error_Code.None)
	named, named_parse_error := sparql.Parse(`SELECT ?graph ?end { GRAPH ?graph { <urn:a> <urn:p>+ ?end } }`)
	defer sparql.Destroy(&named)
	testing.expect_value(t, sparql.Parse_Error_Code(named_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:a", "urn:allowed", "urn:b")
	add_iri_quad(t, &store, "urn:a", "urn:blocked", "urn:c")
	add_iri_quad(t, &store, "urn:d", "urn:blockedBy", "urn:a")
	add_named_iri_quad(t, &store, "urn:one", "urn:a", "urn:p", "urn:b")
	add_named_iri_quad(t, &store, "urn:one", "urn:b", "urn:p", "urn:c")
	add_named_iri_quad(t, &store, "urn:two", "urn:a", "urn:p", "urn:d")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	negated_result, negated_error := execute(&negated, view, {Max_Solutions = 8})
	defer destroy(&negated_result)
	testing.expect_value(t, negated_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&negated_result), 1)
	target, target_bound, target_ok := Cell(&negated_result, 0, 0)
	testing.expect_value(t, target_ok && target_bound, true)
	testing.expect_value(t, target.value, "urn:b")
	named_result, named_error := execute(&named, view, {Max_Solutions = 8})
	defer destroy(&named_result)
	testing.expect_value(t, named_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&named_result), 3)
	expected_graphs := [3]string{"urn:one", "urn:one", "urn:two"}
	expected_ends := [3]string{"urn:b", "urn:c", "urn:d"}
	for expected_graph, row in expected_graphs {
		graph, graph_bound, graph_ok := Cell(&named_result, row, 0)
		end, end_bound, end_ok := Cell(&named_result, row, 1)
		testing.expect_value(t, graph_ok && graph_bound && end_ok && end_bound, true)
		testing.expect_value(t, graph.value, expected_graph)
		testing.expect_value(t, end.value, expected_ends[row])
	}
}

@(test)
test_execute_subquery_select_star_exposes_its_pattern_variables :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?x ?p WHERE {
		GRAPH ?g { { SELECT * WHERE { ?x ?p ?y } } }
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:graph", "urn:ada", "urn:knows", "urn:bert")
	add_named_iri_quad(t, &store, "urn:graph", "urn:bert", "urn:knows", "urn:cora")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	for row in 0..<Row_Count(&result) {
		x, x_bound, x_ok := Cell(&result, row, 0)
		predicate, predicate_bound, predicate_ok := Cell(&result, row, 1)
		testing.expect_value(t, x_ok && x_bound, true)
		testing.expect_value(t, predicate_ok && predicate_bound, true)
		testing.expect_value(t, predicate.value, "urn:knows")
		if row == 0 do testing.expect_value(t, x.value, "urn:ada")
		if row == 1 do testing.expect_value(t, x.value, "urn:bert")
	}
}

@(test)
test_execute_subquery_does_not_inherit_or_leak_outer_bindings :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?outer ?selected WHERE {
		?outer <urn:outer> ?private .
		{ SELECT ?selected WHERE { ?selected <urn:inner> ?private } }
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:outer-a", "urn:outer", "urn:one")
	add_iri_quad(t, &store, "urn:outer-b", "urn:outer", "urn:two")
	add_iri_quad(t, &store, "urn:selected-c", "urn:inner", "urn:three")
	add_iri_quad(t, &store, "urn:selected-d", "urn:inner", "urn:four")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 4)
	expected_outer := [4]string{"urn:outer-a", "urn:outer-a", "urn:outer-b", "urn:outer-b"}
	expected_selected := [4]string{"urn:selected-c", "urn:selected-d", "urn:selected-c", "urn:selected-d"}
	for row in 0..<Row_Count(&result) {
		outer, outer_bound, outer_ok := Cell(&result, row, 0)
		selected, selected_bound, selected_ok := Cell(&result, row, 1)
		testing.expect_value(t, outer_ok && outer_bound, true)
		testing.expect_value(t, selected_ok && selected_bound, true)
		testing.expect_value(t, outer.value, expected_outer[row])
		testing.expect_value(t, selected.value, expected_selected[row])
	}
}

@(test)
test_execute_subquery_applies_order_distinct_and_slice_after_projection :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?x WHERE {
		{ SELECT DISTINCT ?x WHERE { ?x <urn:score> ?score }
		  ORDER BY DESC(?score) OFFSET 1 LIMIT 1 }
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:ada", "urn:score", "3")
	add_integer_quad(t, &store, "urn:ada", "urn:score", "2")
	add_integer_quad(t, &store, "urn:bert", "urn:score", "1")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	x, x_bound, x_ok := Cell(&result, 0, 0)
	testing.expect_value(t, x_ok && x_bound, true)
	testing.expect_value(t, x.value, "urn:bert")
}

@(test)
test_execute_group_by_count_and_having :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person (COUNT(*) AS ?count) WHERE {
		?person <urn:knows> ?friend
	} GROUP BY ?person HAVING(COUNT(*) > 1) ORDER BY ?person`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:bert")
	add_iri_quad(t, &store, "urn:ada", "urn:knows", "urn:cora")
	add_iri_quad(t, &store, "urn:bert", "urn:knows", "urn:ada")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	person, person_bound, person_ok := Cell(&result, 0, 0)
	count, count_bound, count_ok := Cell(&result, 0, 1)
	testing.expect_value(t, person_ok && person_bound, true)
	testing.expect_value(t, count_ok && count_bound, true)
	testing.expect_value(t, person.value, "urn:ada")
	testing.expect_value(t, count.value, "2")
}

@(test)
test_execute_group_by_expression_alias_projects_the_group_key :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?key (COUNT(*) AS ?count) WHERE {
		?subject ?group ?object
	} GROUP BY (?group AS ?key) ORDER BY ?key`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:one", "urn:alpha", "urn:first")
	add_iri_quad(t, &store, "urn:two", "urn:alpha", "urn:second")
	add_iri_quad(t, &store, "urn:three", "urn:beta", "urn:third")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	first_key, first_key_bound, first_key_ok := Cell(&result, 0, 0)
	first_count, first_count_bound, first_count_ok := Cell(&result, 0, 1)
	second_key, second_key_bound, second_key_ok := Cell(&result, 1, 0)
	second_count, second_count_bound, second_count_ok := Cell(&result, 1, 1)
	testing.expect_value(t, first_key_ok && first_key_bound && first_count_ok && first_count_bound, true)
	testing.expect_value(t, second_key_ok && second_key_bound && second_count_ok && second_count_bound, true)
	testing.expect_value(t, first_key.value, "urn:alpha")
	testing.expect_value(t, first_count.value, "2")
	testing.expect_value(t, second_key.value, "urn:beta")
	testing.expect_value(t, second_count.value, "1")
}

@(test)
test_execute_exists_retains_the_enclosing_named_graph_scope :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject WHERE {
		GRAPH <urn:graph> {
			?subject <urn:p> <urn:first>
			FILTER EXISTS { ?subject <urn:p> <urn:second> }
		}
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:graph", "urn:only-first", "urn:p", "urn:first")
	add_named_iri_quad(t, &store, "urn:graph", "urn:both", "urn:p", "urn:first")
	add_named_iri_quad(t, &store, "urn:graph", "urn:both", "urn:p", "urn:second")
	add_iri_quad(t, &store, "urn:only-first", "urn:p", "urn:second")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	subject, subject_bound, subject_ok := Cell(&result, 0, 0)
	testing.expect_value(t, subject_ok && subject_bound, true)
	testing.expect_value(t, subject.value, "urn:both")
}

@(test)
test_execute_unicode_case_mapping_preserves_language_tags :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT (LCASE(?value) AS ?lower) (UCASE(?value) AS ?upper) WHERE {
		VALUES ?value { "ÄRGER"@de }
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	lower, lower_bound, lower_ok := Cell(&result, 0, 0)
	upper, upper_bound, upper_ok := Cell(&result, 0, 1)
	testing.expect_value(t, lower_ok && lower_bound && upper_ok && upper_bound, true)
	testing.expect_value(t, lower.value, "ärger")
	testing.expect_value(t, lower.language, "de")
	testing.expect_value(t, upper.value, "ÄRGER")
	testing.expect_value(t, upper.language, "de")
}

@(test)
test_execute_string_search_rejects_incompatible_language_tags :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT
		(STRBEFORE("abc"@en, "b"@cy) AS ?before_mismatch)
		(STRAFTER("abc", ""@en) AS ?after_mismatch)
		(STRAFTER("abc"@en, ""@en) AS ?after_matching)
		(STRSTARTS("abc", "a"@en) AS ?starts_mismatch)
		(STRENDS("abc"@en, "c"@cy) AS ?ends_mismatch)
		(CONTAINS("abc"@en, "b"@en) AS ?contains_matching)
		WHERE {}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	_, before_bound, before_ok := Cell(&result, 0, 0)
	_, after_bound, after_ok := Cell(&result, 0, 1)
	after, matching_bound, matching_ok := Cell(&result, 0, 2)
	_, starts_bound, starts_ok := Cell(&result, 0, 3)
	_, ends_bound, ends_ok := Cell(&result, 0, 4)
	contains, contains_bound, contains_ok := Cell(&result, 0, 5)
	testing.expect_value(t, before_ok && !before_bound, true)
	testing.expect_value(t, after_ok && !after_bound, true)
	testing.expect_value(t, matching_ok && matching_bound, true)
	testing.expect_value(t, after.value, "abc")
	testing.expect_value(t, after.language, "en")
	testing.expect_value(t, starts_ok && !starts_bound, true)
	testing.expect_value(t, ends_ok && !ends_bound, true)
	testing.expect_value(t, contains_ok && contains_bound, true)
	testing.expect_value(t, contains.value, "true")
}

@(test)
test_execute_count_on_an_empty_multiset_returns_zero :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT (COUNT(?item) AS ?count) WHERE { ?item <urn:missing> ?value }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	count, count_bound, count_ok := Cell(&result, 0, 0)
	testing.expect_value(t, count_ok && count_bound, true)
	testing.expect_value(t, count.value, "0")
}

@(test)
test_execute_grouped_sum_and_average_share_numeric_promotion :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?kind (SUM(?value) AS ?sum) (AVG(?value) AS ?average) WHERE {
		?subject ?kind ?value
	} GROUP BY ?kind ORDER BY ?kind`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:a", "urn:integer", "1")
	add_integer_quad(t, &store, "urn:b", "urn:integer", "2")
	add_typed_quad(t, &store, "urn:c", "urn:decimal", "1.0", "http://www.w3.org/2001/XMLSchema#decimal")
	add_typed_quad(t, &store, "urn:d", "urn:decimal", "2.2", "http://www.w3.org/2001/XMLSchema#decimal")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	for row in 0..<Row_Count(&result) {
		kind, kind_bound, kind_ok := Cell(&result, row, 0)
		sum, sum_bound, sum_ok := Cell(&result, row, 1)
		average, average_bound, average_ok := Cell(&result, row, 2)
		testing.expect_value(t, kind_ok && kind_bound && sum_ok && sum_bound && average_ok && average_bound, true)
		if kind.value == "urn:decimal" {
			testing.expect_value(t, sum.value, "3.2")
			testing.expect_value(t, sum.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
			testing.expect_value(t, average.value, "1.6")
			testing.expect_value(t, average.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
		} else {
			testing.expect_value(t, kind.value, "urn:integer")
			testing.expect_value(t, sum.value, "3")
			testing.expect_value(t, sum.datatype, "http://www.w3.org/2001/XMLSchema#integer")
			testing.expect_value(t, average.value, "1.5")
			testing.expect_value(t, average.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
		}
	}
}

@(test)
test_execute_average_on_an_empty_multiset_returns_zero :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT (AVG(?item) AS ?average) WHERE { ?item <urn:missing> ?value }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	average, average_bound, average_ok := Cell(&result, 0, 0)
	testing.expect_value(t, average_ok && average_bound, true)
	testing.expect_value(t, average.value, "0")
	testing.expect_value(t, average.datatype, "http://www.w3.org/2001/XMLSchema#integer")
}

@(test)
test_execute_aggregate_errors_leave_aliases_unbound_without_dropping_group :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?group (AVG(?value) AS ?average) ((MIN(?value) + MAX(?value)) / 2 AS ?middle) WHERE {
		?group <urn:value> ?value
	} GROUP BY ?group`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:good", "urn:value", "1")
	add_integer_quad(t, &store, "urn:good", "urn:value", "3")
	add_integer_quad(t, &store, "urn:broken", "urn:value", "1")
	blank_scope := rdf.new_blank_node_scope()
	broken := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:broken"), predicate = rdf.iri("urn:value"), object = rdf.blank_node("not-a-number", blank_scope)})
	testing.expect_value(t, dataset.add(&store, broken), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	for row in 0..<Row_Count(&result) {
		group, group_bound, group_ok := Cell(&result, row, 0)
		average, average_bound, average_ok := Cell(&result, row, 1)
		middle, middle_bound, middle_ok := Cell(&result, row, 2)
		testing.expect_value(t, group_ok && group_bound && average_ok && middle_ok, true)
		if group.value == "urn:good" {
			testing.expect_value(t, average_bound, true)
			testing.expect_value(t, middle_bound, true)
			testing.expect_value(t, average.value, "2.0")
		testing.expect_value(t, middle.value, "2.0")
		} else {
			testing.expect_value(t, group.value, "urn:broken")
			testing.expect_value(t, average_bound, false)
			testing.expect_value(t, middle_bound, false)
		}
	}
}

@(test)
test_execute_max_on_an_empty_multiset_returns_one_unbound_result :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT (MAX(?value) AS ?maximum) WHERE { ?subject <urn:missing> ?value }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	_, bound, cell_ok := Cell(&result, 0, 0)
	testing.expect_value(t, cell_ok, true)
	testing.expect_value(t, bound, false)
}

@(test)
test_execute_ask_preserves_complete_input_for_group_concat :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK {
		{ SELECT (GROUP_CONCAT(?item;SEPARATOR=":") AS ?joined) WHERE {
			VALUES ?item { "one" "two" }
		} }
		FILTER(?joined = "one:two" || ?joined = "two:one")
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	value, value_ok := Ask_Value(&result)
	testing.expect_value(t, value_ok && value, true)
}

@(test)
test_execute_ask_stops_after_first_solution :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { <urn:subject> <urn:predicate> ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:subject", "urn:predicate", "urn:one")
	add_iri_quad(t, &store, "urn:subject", "urn:predicate", "urn:two")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 1})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Kind(&result), Result_Kind.Ask)
	value, ask_ok := Ask_Value(&result)
	testing.expect_value(t, ask_ok, true)
	testing.expect_value(t, value, true)
}

@(test)
test_execute_select_reports_its_explicit_solution_limit :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?object { <urn:subject> <urn:predicate> ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:subject", "urn:predicate", "urn:one")
	add_iri_quad(t, &store, "urn:subject", "urn:predicate", "urn:two")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	_, execute_error := execute(&query, view, {Max_Solutions = 1})
	testing.expect_value(t, execute_error, Error_Code.Solution_Limit)
}

@(test)
test_execute_union_preserves_branch_solutions :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { { ?subject <urn:kind> <urn:one> } UNION { ?subject <urn:kind> <urn:two> } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:kind", "urn:one")
	add_iri_quad(t, &store, "urn:bert", "urn:kind", "urn:two")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	first, first_bound, first_ok := Cell(&result, 0, 0)
	second, second_bound, second_ok := Cell(&result, 1, 0)
	testing.expect_value(t, first_ok && first_bound, true)
	testing.expect_value(t, second_ok && second_bound, true)
	testing.expect_value(t, first.value, "urn:ada")
	testing.expect_value(t, second.value, "urn:bert")
}

@(test)
test_execute_optional_retains_unmatched_left_solution :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person ?age { ?person <urn:name> ?name OPTIONAL { ?person <urn:age> ?age } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:name", "urn:ada-name")
	add_iri_quad(t, &store, "urn:bert", "urn:name", "urn:bert-name")
	add_iri_quad(t, &store, "urn:ada", "urn:age", "urn:forty-two")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	age, age_bound, age_ok := Cell(&result, 0, 1)
	testing.expect_value(t, age_ok && age_bound, true)
	testing.expect_value(t, age.value, "urn:forty-two")
	_, missing_age_bound, missing_age_ok := Cell(&result, 1, 1)
	testing.expect_value(t, missing_age_ok, true)
	testing.expect_value(t, missing_age_bound, false)
}

@(test)
test_execute_minus_requires_a_shared_compatible_binding :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person { ?person <urn:name> ?name MINUS { ?person <urn:blocked> <urn:true> } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:name", "urn:ada-name")
	add_iri_quad(t, &store, "urn:bert", "urn:name", "urn:bert-name")
	add_iri_quad(t, &store, "urn:ada", "urn:blocked", "urn:true")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	person, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, person.value, "urn:bert")
}

@(test)
test_execute_graph_variable_scans_named_graphs_only :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?graph ?subject { GRAPH ?graph { ?subject <urn:kind> ?kind } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:one", "urn:ada", "urn:kind", "urn:first")
	add_named_iri_quad(t, &store, "urn:two", "urn:bert", "urn:kind", "urn:second")
	add_iri_quad(t, &store, "urn:default", "urn:kind", "urn:ignored")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	first_graph, first_bound, first_ok := Cell(&result, 0, 0)
	second_graph, second_bound, second_ok := Cell(&result, 1, 0)
	testing.expect_value(t, first_ok && first_bound, true)
	testing.expect_value(t, second_ok && second_bound, true)
	testing.expect_value(t, first_graph.value, "urn:one")
	testing.expect_value(t, second_graph.value, "urn:two")
}

@(test)
test_execute_values_preserves_unbound_cells :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person ?age { VALUES (?person ?age) { (<urn:ada> 42) (<urn:bert> UNDEF) } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	age, age_bound, age_ok := Cell(&result, 0, 1)
	testing.expect_value(t, age_ok && age_bound, true)
	testing.expect_value(t, age.value, "42")
	_, missing_age_bound, missing_age_ok := Cell(&result, 1, 1)
	testing.expect_value(t, missing_age_ok, true)
	testing.expect_value(t, missing_age_bound, false)
}

@(test)
test_execute_tail_values_joins_after_where :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person { ?person <urn:kind> <urn:included> } VALUES ?person { <urn:bert> }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:kind", "urn:included")
	add_iri_quad(t, &store, "urn:bert", "urn:kind", "urn:included")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	person, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, person.value, "urn:bert")
}

@(test)
test_execute_filter_equality_and_bind_variable_extension :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person ?copy { ?person <urn:kind> ?value FILTER(?person = <urn:ada>) BIND(?value AS ?copy) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:ada", "urn:kind", "urn:chosen")
	add_iri_quad(t, &store, "urn:bert", "urn:kind", "urn:ignored")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	person, person_bound, person_ok := Cell(&result, 0, 0)
	copy, copy_bound, copy_ok := Cell(&result, 0, 1)
	testing.expect_value(t, person_ok && person_bound, true)
	testing.expect_value(t, copy_ok && copy_bound, true)
	testing.expect_value(t, person.value, "urn:ada")
	testing.expect_value(t, copy.value, "urn:chosen")
}

@(test)
test_execute_filter_can_read_a_later_group_bind :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject ?copy { ?subject <urn:value> ?value FILTER(?copy = 3) BIND(?value + 1 AS ?copy) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:first", "urn:value", "1")
	add_integer_quad(t, &store, "urn:second", "urn:value", "2")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	subject, subject_bound, subject_ok := Cell(&result, 0, 0)
	copy, copy_bound, copy_ok := Cell(&result, 0, 1)
	testing.expect_value(t, subject_ok && subject_bound, true)
	testing.expect_value(t, subject.value, "urn:second")
	testing.expect_value(t, copy_ok && copy_bound, true)
	testing.expect_value(t, copy.value, "3")
}

@(test)
test_execute_graph_variable_is_not_bound_inside_nested_optional :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?graph ?subject { GRAPH ?graph { ?subject <urn:p> ?object OPTIONAL { ?subject <urn:p> ?graph } } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:graph", "urn:first", "urn:p", "urn:other")
	add_named_iri_quad(t, &store, "urn:graph", "urn:second", "urn:p", "urn:graph")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	graph, graph_bound, graph_ok := Cell(&result, 0, 0)
	subject, subject_bound, subject_ok := Cell(&result, 0, 1)
	testing.expect_value(t, graph_ok && graph_bound, true)
	testing.expect_value(t, graph.value, "urn:graph")
	testing.expect_value(t, subject_ok && subject_bound, true)
	testing.expect_value(t, subject.value, "urn:second")
}

@(test)
test_execute_empty_graph_pattern_requires_an_existing_named_graph :: proc(t: ^testing.T) {
	known_query, known_parse_error := sparql.Parse(`ASK { GRAPH <urn:known> {} }`)
	defer sparql.Destroy(&known_query)
	unknown_query, unknown_parse_error := sparql.Parse(`ASK { GRAPH <urn:unknown> {} }`)
	defer sparql.Destroy(&unknown_query)
	testing.expect_value(t, sparql.Parse_Error_Code(known_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(unknown_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:known", "urn:subject", "urn:p", "urn:object")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	known_result, known_execute_error := execute(&known_query, view, {Max_Solutions = 8})
	defer destroy(&known_result)
	unknown_result, unknown_execute_error := execute(&unknown_query, view, {Max_Solutions = 8})
	defer destroy(&unknown_result)
	testing.expect_value(t, known_execute_error, Error_Code.None)
	testing.expect_value(t, unknown_execute_error, Error_Code.None)
	known, known_ok := Ask_Value(&known_result)
	unknown, unknown_ok := Ask_Value(&unknown_result)
	testing.expect_value(t, known_ok && known, true)
	testing.expect_value(t, unknown_ok && unknown, false)
}

@(test)
test_execute_filter_compares_xsd_strings_lexically :: proc(t: ^testing.T) {
	less_query, less_parse_error := sparql.Parse(`ASK { FILTER("alpha" < "beta") }`)
	defer sparql.Destroy(&less_query)
	greater_query, greater_parse_error := sparql.Parse(`ASK { FILTER("beta" < "alpha") }`)
	defer sparql.Destroy(&greater_query)
	str_query, str_parse_error := sparql.Parse(`ASK { BIND(<urn:alpha> AS ?left) BIND(<urn:beta> AS ?right) FILTER(STR(?left) < STR(?right)) }`)
	defer sparql.Destroy(&str_query)
	testing.expect_value(t, sparql.Parse_Error_Code(less_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(greater_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(str_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	less_result, less_execute_error := execute(&less_query, view, {Max_Solutions = 8})
	defer destroy(&less_result)
	greater_result, greater_execute_error := execute(&greater_query, view, {Max_Solutions = 8})
	defer destroy(&greater_result)
	str_result, str_execute_error := execute(&str_query, view, {Max_Solutions = 8})
	defer destroy(&str_result)
	testing.expect_value(t, less_execute_error, Error_Code.None)
	testing.expect_value(t, greater_execute_error, Error_Code.None)
	testing.expect_value(t, str_execute_error, Error_Code.None)
	less, less_ok := Ask_Value(&less_result)
	greater, greater_ok := Ask_Value(&greater_result)
	str, str_ok := Ask_Value(&str_result)
	testing.expect_value(t, less_ok && less, true)
	testing.expect_value(t, greater_ok && greater, false)
	testing.expect_value(t, str_ok && str, true)
}

@(test)
test_execute_promotes_derived_xsd_integer_datatypes :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?sum { <urn:left> <urn:value> ?left . <urn:right> <urn:value> ?right . BIND(?left + ?right AS ?sum) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:left", "urn:value", "2", "http://www.w3.org/2001/XMLSchema#short")
	add_typed_quad(t, &store, "urn:right", "urn:value", "3", "http://www.w3.org/2001/XMLSchema#byte")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	sum, sum_bound, sum_ok := Cell(&result, 0, 0)
	testing.expect_value(t, sum_ok && sum_bound, true)
	testing.expect_value(t, sum.value, "5")
	testing.expect_value(t, sum.datatype, "http://www.w3.org/2001/XMLSchema#integer")
}

@(test)
test_execute_bind_and_filter_use_boolean_expression_kernel :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?flag { BIND(!false AS ?flag) FILTER(?flag = true) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	flag, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, flag.value, "true")
	testing.expect_value(t, flag.datatype, "http://www.w3.org/2001/XMLSchema#boolean")
}

@(test)
test_execute_filter_numeric_relations_preserve_exact_decimal_order :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:value> ?value FILTER(?value < 100.0) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	integer := "http://www.w3.org/2001/XMLSchema#integer"
	decimal := "http://www.w3.org/2001/XMLSchema#decimal"
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:below"), predicate = rdf.iri("urn:value"), object = rdf.typed_literal("99.999", decimal)})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:equal"), predicate = rdf.iri("urn:value"), object = rdf.typed_literal("100", integer)})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:above"), predicate = rdf.iri("urn:value"), object = rdf.typed_literal("100.001", decimal)})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	subject, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, subject.value, "urn:below")
}

@(test)
test_execute_boolean_operators_short_circuit_expression_errors :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?or ?and { BIND(true || !<urn:not-a-boolean> AS ?or) BIND(false && !<urn:not-a-boolean> AS ?and) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	or_value, or_bound, or_ok := Cell(&result, 0, 0)
	and_value, and_bound, and_ok := Cell(&result, 0, 1)
	testing.expect_value(t, or_ok && or_bound, true)
	testing.expect_value(t, and_ok && and_bound, true)
	testing.expect_value(t, or_value.value, "true")
	testing.expect_value(t, and_value.value, "false")
}

@(test)
test_execute_unary_numeric_expressions_own_generated_lexical_forms :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?positive ?negative { BIND(+42 AS ?positive) BIND(-42 AS ?negative) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	positive, positive_bound, positive_ok := Cell(&result, 0, 0)
	negative, negative_bound, negative_ok := Cell(&result, 0, 1)
	testing.expect_value(t, positive_ok && positive_bound, true)
	testing.expect_value(t, negative_ok && negative_bound, true)
	testing.expect_value(t, positive.value, "+42")
	testing.expect_value(t, negative.value, "-42")
	testing.expect_value(t, negative.datatype, "http://www.w3.org/2001/XMLSchema#integer")
}

@(test)
test_execute_exact_binary_integer_and_decimal_arithmetic :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?sum ?product ?difference { BIND(999999999999999999999999 + 1 AS ?sum) BIND(1.25 * 4 AS ?product) BIND(10.5 - 1.25 AS ?difference) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 64})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	sum, sum_bound, sum_ok := Cell(&result, 0, 0)
	product, product_bound, product_ok := Cell(&result, 0, 1)
	difference, difference_bound, difference_ok := Cell(&result, 0, 2)
	testing.expect_value(t, sum_ok && sum_bound, true)
	testing.expect_value(t, product_ok && product_bound, true)
	testing.expect_value(t, difference_ok && difference_bound, true)
	testing.expect_value(t, sum.value, "1000000000000000000000000")
	testing.expect_value(t, sum.datatype, "http://www.w3.org/2001/XMLSchema#integer")
	testing.expect_value(t, product.value, "5.00")
	testing.expect_value(t, product.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
	testing.expect_value(t, difference.value, "9.25")
}

@(test)
test_execute_exact_arithmetic_reports_configured_numeric_limit :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { BIND(999999999999999999 + 1 AS ?value) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	_, execute_error := execute(&query, view, {Max_Solutions = 1, Max_Numeric_Digits = 18})
	testing.expect_value(t, execute_error, Error_Code.Numeric_Limit)
}

@(test)
test_execute_exact_division_preserves_terminating_values_and_rounds_recurring_values :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?half ?decimal ?recurring ?negative { BIND(1 / 2 AS ?half) BIND(1.5 / 0.5 AS ?decimal) BIND(1 / 7 AS ?recurring) BIND(-1 / 8 AS ?negative) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32, Decimal_Division_Precision = 4})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	half, half_bound, half_ok := Cell(&result, 0, 0)
	decimal, decimal_bound, decimal_ok := Cell(&result, 0, 1)
	recurring, recurring_bound, recurring_ok := Cell(&result, 0, 2)
	negative, negative_bound, negative_ok := Cell(&result, 0, 3)
	testing.expect_value(t, half_ok && half_bound, true)
	testing.expect_value(t, decimal_ok && decimal_bound, true)
	testing.expect_value(t, recurring_ok && recurring_bound, true)
	testing.expect_value(t, negative_ok && negative_bound, true)
	testing.expect_value(t, half.value, "0.5")
	testing.expect_value(t, decimal.value, "3.0")
	testing.expect_value(t, recurring.value, "0.1429")
	testing.expect_value(t, negative.value, "-0.125")
	testing.expect_value(t, half.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
	testing.expect_value(t, decimal.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
}

@(test)
test_execute_division_uses_bind_filter_and_numeric_limit_error_rules :: proc(t: ^testing.T) {
	bind_query, bind_parse_error := sparql.Parse(`SELECT ?bound { BIND(1 / 0 AS ?invalid) BIND(BOUND(?invalid) AS ?bound) }`)
	defer sparql.Destroy(&bind_query)
	testing.expect_value(t, sparql.Parse_Error_Code(bind_parse_error), sparql.Error_Code.None)
	filter_query, filter_parse_error := sparql.Parse(`ASK { FILTER(1 / 0 = 1) }`)
	defer sparql.Destroy(&filter_query)
	testing.expect_value(t, sparql.Parse_Error_Code(filter_parse_error), sparql.Error_Code.None)
	limit_query, limit_parse_error := sparql.Parse(`ASK { BIND(1 / 3 AS ?value) }`)
	defer sparql.Destroy(&limit_query)
	testing.expect_value(t, sparql.Parse_Error_Code(limit_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	bound_result, bound_error := execute(&bind_query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&bound_result)
	testing.expect_value(t, bound_error, Error_Code.None)
	bound, bound_bound, bound_ok := Cell(&bound_result, 0, 0)
	testing.expect_value(t, bound_ok && bound_bound, true)
	testing.expect_value(t, bound.value, "false")
	filter_result, filter_error := execute(&filter_query, view, {Max_Solutions = 1, Max_Numeric_Digits = 32})
	defer destroy(&filter_result)
	testing.expect_value(t, filter_error, Error_Code.None)
	filter_value, filter_ok := Ask_Value(&filter_result)
	testing.expect_value(t, filter_ok, true)
	testing.expect_value(t, filter_value, false)
	_, limit_error := execute(&limit_query, view, {Max_Solutions = 1, Max_Numeric_Digits = 3, Decimal_Division_Precision = 4})
	testing.expect_value(t, limit_error, Error_Code.Numeric_Limit)
}

@(test)
test_execute_division_promotes_float_and_double_operands :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX x: <http://www.w3.org/2001/XMLSchema#> SELECT ?float ?double ?infinity { BIND("3"^^x:float / 3 AS ?float) BIND("3"^^x:float / "3"^^x:double AS ?double) BIND("1"^^x:double / "0"^^x:double AS ?infinity) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	float_value, float_bound, float_ok := Cell(&result, 0, 0)
	double_value, double_bound, double_ok := Cell(&result, 0, 1)
	infinity, infinity_bound, infinity_ok := Cell(&result, 0, 2)
	testing.expect_value(t, float_ok && float_bound, true)
	testing.expect_value(t, double_ok && double_bound, true)
	testing.expect_value(t, infinity_ok && infinity_bound, true)
	testing.expect_value(t, float_value.value, "1")
	testing.expect_value(t, float_value.datatype, "http://www.w3.org/2001/XMLSchema#float")
	testing.expect_value(t, double_value.value, "1")
	testing.expect_value(t, double_value.datatype, "http://www.w3.org/2001/XMLSchema#double")
	testing.expect_value(t, infinity.value, "INF")
	testing.expect_value(t, infinity.datatype, "http://www.w3.org/2001/XMLSchema#double")
}

@(test)
test_execute_add_subtract_and_multiply_promote_floating_operands :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX x: <http://www.w3.org/2001/XMLSchema#> SELECT ?sum ?difference ?product { BIND("1.5"^^x:float + 2 AS ?sum) BIND("5"^^x:double - "2"^^x:float AS ?difference) BIND("1.5"^^x:float * 2 AS ?product) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected := [3]struct{ lexical, datatype: string }{
		{"3.5", "http://www.w3.org/2001/XMLSchema#float"},
		{"3", "http://www.w3.org/2001/XMLSchema#double"},
		{"3", "http://www.w3.org/2001/XMLSchema#float"},
	}
	for column in 0..<len(expected) {
		value, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[column].lexical)
		testing.expect_value(t, value.datatype, expected[column].datatype)
	}
}

@(test)
test_execute_bound_distinguishes_unbound_variables_without_an_expression_error :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?missing ?is_bound { BIND(BOUND(?missing) AS ?is_bound) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	_, missing_bound, missing_ok := Cell(&result, 0, 0)
	is_bound, is_bound_bound, is_bound_ok := Cell(&result, 0, 1)
	testing.expect_value(t, missing_ok, true)
	testing.expect_value(t, missing_bound, false)
	testing.expect_value(t, is_bound_ok && is_bound_bound, true)
	testing.expect_value(t, is_bound.value, "false")
}

@(test)
test_execute_same_term_preserves_the_distinction_from_value_equality :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?same ?equal { BIND(sameTerm(1, 01) AS ?same) BIND(1 = 01 AS ?equal) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	same, same_bound, same_ok := Cell(&result, 0, 0)
	equal, equal_bound, equal_ok := Cell(&result, 0, 1)
	testing.expect_value(t, same_ok && same_bound, true)
	testing.expect_value(t, equal_ok && equal_bound, true)
	testing.expect_value(t, same.value, "false")
	testing.expect_value(t, equal.value, "true")
}

@(test)
test_execute_string_language_and_datatype_builtins :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?text ?lang ?datatype { BIND(STR("value"@en) AS ?text) BIND(LANG("value"@en) AS ?lang) BIND(DATATYPE("value"@en) AS ?datatype) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	text, text_bound, text_ok := Cell(&result, 0, 0)
	language, language_bound, language_ok := Cell(&result, 0, 1)
	datatype, datatype_bound, datatype_ok := Cell(&result, 0, 2)
	testing.expect_value(t, text_ok && text_bound, true)
	testing.expect_value(t, language_ok && language_bound, true)
	testing.expect_value(t, datatype_ok && datatype_bound, true)
	testing.expect_value(t, text.value, "value")
	testing.expect_value(t, text.datatype, "http://www.w3.org/2001/XMLSchema#string")
	testing.expect_value(t, language.value, "en")
	testing.expect_value(t, datatype.kind, rdf.Term_Kind.IRI)
	testing.expect_value(t, datatype.value, "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
}

@(test)
test_execute_rdf_term_kind_builtins :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?iri ?uri ?blank ?literal { <urn:subject> <urn:predicate> ?value BIND(isIRI(<urn:value>) AS ?iri) BIND(isURI(<urn:value>) AS ?uri) BIND(isBlank(?value) AS ?blank) BIND(isLiteral("value") AS ?literal) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	blank_scope := rdf.new_blank_node_scope()
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:subject"), predicate = rdf.iri("urn:predicate"), object = rdf.blank_node("value", blank_scope)})
	testing.expect_value(t, dataset.add(&store, quad), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	for column in 0..<4 {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, "true")
		testing.expect_value(t, term.datatype, "http://www.w3.org/2001/XMLSchema#boolean")
	}
}

@(test)
test_execute_lang_matches_uses_case_insensitive_subtag_boundaries :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?prefix ?exact ?miss ?wildcard { BIND(langMatches(lang("value"@en-GB), "en") AS ?prefix) BIND(langMatches(lang("value"@en-GB), "EN-gb") AS ?exact) BIND(langMatches(lang("value"@en-GB), "eng") AS ?miss) BIND(langMatches(lang("value"@en-GB), "*") AS ?wildcard) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	for column in 0..<4 {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		expected := "true"
		if column == 2 do expected = "false"
		testing.expect_value(t, term.value, expected)
	}
}

@(test)
test_execute_in_and_not_in_preserve_match_and_error_semantics :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?found ?missing ?empty ?suppressed_error { BIND(2 IN (1, 2, 3) AS ?found) BIND(2 IN (1, 3) AS ?missing) BIND(2 NOT IN () AS ?empty) BIND(2 NOT IN (?unbound, 2) AS ?suppressed_error) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [4]string{"true", "false", "true", "false"}
	for column in 0..<4 {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
	}
}

@(test)
test_execute_is_numeric_identifies_only_numeric_literal_datatypes :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?integer ?decimal ?double ?string { BIND(isNumeric(1) AS ?integer) BIND(isNumeric(1.0) AS ?decimal) BIND(isNumeric(1e0) AS ?double) BIND(isNumeric("1") AS ?string) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [4]string{"true", "true", "true", "false"}
	for column in 0..<4 {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
	}
}

@(test)
test_execute_if_and_coalesce_evaluate_only_the_selected_or_first_valid_branch :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?if_true ?if_false ?coalesced { BIND(IF(true, "chosen", ?unbound) AS ?if_true) BIND(IF(false, ?unbound, "fallback") AS ?if_false) BIND(COALESCE(?unbound, "first", "later") AS ?coalesced) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [3]string{"chosen", "fallback", "first"}
	for column in 0..<3 {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
	}
}

@(test)
test_execute_select_projection_expression_extends_then_projects_its_alias :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?source (IF(?source = <urn:one>, "selected", "other") AS ?label) { ?source <urn:kind> <urn:value> }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:one", "urn:kind", "urn:value")
	add_iri_quad(t, &store, "urn:two", "urn:kind", "urn:value")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Variable_Count(&result), 2)
	testing.expect_value(t, Row_Count(&result), 2)
	first_label, first_bound, first_ok := Cell(&result, 0, 1)
	second_label, second_bound, second_ok := Cell(&result, 1, 1)
	testing.expect_value(t, first_ok && first_bound, true)
	testing.expect_value(t, second_ok && second_bound, true)
	testing.expect_value(t, first_label.value, "selected")
	testing.expect_value(t, second_label.value, "other")
}

@(test)
test_execute_select_applies_offset_and_limit_after_projection :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:kind> <urn:value> } OFFSET 1 LIMIT 1`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:one", "urn:kind", "urn:value")
	add_iri_quad(t, &store, "urn:two", "urn:kind", "urn:value")
	add_iri_quad(t, &store, "urn:three", "urn:kind", "urn:value")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	value, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, value.value, "urn:two")
}

@(test)
test_execute_select_rejects_negative_or_overflowing_slice_bounds :: proc(t: ^testing.T) {
	negative, negative_parse_error := sparql.Parse(`SELECT * { } LIMIT -1`)
	defer sparql.Destroy(&negative)
	testing.expect_value(t, sparql.Parse_Error_Code(negative_parse_error), sparql.Error_Code.None)
	overflow, overflow_parse_error := sparql.Parse(`SELECT * { } OFFSET 999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999`)
	defer sparql.Destroy(&overflow)
	testing.expect_value(t, sparql.Parse_Error_Code(overflow_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	_, negative_error := execute(&negative, view, {Max_Solutions = 8})
	_, overflow_error := execute(&overflow, view, {Max_Solutions = 8})
	testing.expect_value(t, negative_error, Error_Code.Invalid_Slice)
	testing.expect_value(t, overflow_error, Error_Code.Invalid_Slice)
}

@(test)
test_execute_distinct_and_reduced_deduplicate_projected_rows_before_slicing :: proc(t: ^testing.T) {
	distinct_query, distinct_parse_error := sparql.Parse(`SELECT DISTINCT ?subject { ?subject <urn:kind> ?object } OFFSET 1`)
	defer sparql.Destroy(&distinct_query)
	reduced, reduced_parse_error := sparql.Parse(`SELECT REDUCED ?subject { ?subject <urn:kind> ?object }`)
	defer sparql.Destroy(&reduced)
	testing.expect_value(t, sparql.Parse_Error_Code(distinct_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(reduced_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:one", "urn:kind", "urn:first")
	add_iri_quad(t, &store, "urn:one", "urn:kind", "urn:second")
	add_iri_quad(t, &store, "urn:two", "urn:kind", "urn:third")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	distinct_result, distinct_error := execute(&distinct_query, view, {Max_Solutions = 8})
	defer destroy(&distinct_result)
	reduced_result, reduced_error := execute(&reduced, view, {Max_Solutions = 8})
	defer destroy(&reduced_result)
	testing.expect_value(t, distinct_error, Error_Code.None)
	testing.expect_value(t, reduced_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&distinct_result), 1)
	distinct_value, distinct_bound, distinct_ok := Cell(&distinct_result, 0, 0)
	testing.expect_value(t, distinct_ok && distinct_bound, true)
	testing.expect_value(t, distinct_value.value, "urn:two")
	testing.expect_value(t, Row_Count(&reduced_result), 2)
}

@(test)
test_execute_order_by_reads_non_projected_bindings_and_honors_descending_direction :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:rank> ?rank } ORDER BY DESC(?rank)`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:one", "urn:rank", "urn:a")
	add_iri_quad(t, &store, "urn:two", "urn:rank", "urn:c")
	add_iri_quad(t, &store, "urn:three", "urn:rank", "urn:b")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected := [3]string{"urn:two", "urn:three", "urn:one"}
	for row in 0..<len(expected) {
		value, bound, ok := Cell(&result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[row])
	}
}

@(test)
test_execute_order_by_precedes_distinct_offset_and_limit :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT DISTINCT ?subject { ?subject <urn:rank> ?rank } ORDER BY DESC(?rank) OFFSET 1 LIMIT 1`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_iri_quad(t, &store, "urn:one", "urn:rank", "urn:c")
	add_iri_quad(t, &store, "urn:one", "urn:rank", "urn:a")
	add_iri_quad(t, &store, "urn:two", "urn:rank", "urn:b")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	value, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, value.value, "urn:two")
}

@(test)
test_execute_order_by_evaluates_numeric_expressions_once_per_solution :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:first> ?first ; <urn:second> ?second } ORDER BY (?first + ?second)`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:one", "urn:first", "1")
	add_integer_quad(t, &store, "urn:one", "urn:second", "2")
	add_integer_quad(t, &store, "urn:two", "urn:first", "10")
	add_integer_quad(t, &store, "urn:two", "urn:second", "20")
	add_integer_quad(t, &store, "urn:three", "urn:first", "100")
	add_integer_quad(t, &store, "urn:three", "urn:second", "200")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected := [3]string{"urn:one", "urn:two", "urn:three"}
	for row in 0..<len(expected) {
		value, bound, ok := Cell(&result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[row])
	}
}

@(test)
test_execute_exact_xsd_casts_preserve_value_space_and_bind_errors :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX x: <http://www.w3.org/2001/XMLSchema#>
SELECT ?integer ?decimal ?boolean ?string ?missing {
  BIND(x:integer(-1.9) AS ?integer)
  BIND(x:decimal("42") AS ?decimal)
  BIND(x:boolean("0") AS ?boolean)
  BIND(x:string(<urn:value>) AS ?string)
  BIND(x:integer("not-a-number") AS ?missing)
}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected := [4]struct{ lexical, datatype: string }{
		{"-1", "http://www.w3.org/2001/XMLSchema#integer"},
		{"42", "http://www.w3.org/2001/XMLSchema#decimal"},
		{"false", "http://www.w3.org/2001/XMLSchema#boolean"},
		{"urn:value", "http://www.w3.org/2001/XMLSchema#string"},
	}
	for column in 0..<len(expected) {
		value, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[column].lexical)
		testing.expect_value(t, value.datatype, expected[column].datatype)
	}
	_, missing_bound, missing_ok := Cell(&result, 0, 4)
	testing.expect_value(t, missing_ok, true)
	testing.expect_value(t, missing_bound, false)
}

@(test)
test_execute_group_by_cast_materializes_the_alias_value :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?integer { ?subject <urn:value> ?object } GROUP BY (xsd:integer(?object) AS ?integer)`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:one", "urn:value", "1")
	add_integer_quad(t, &store, "urn:two", "urn:value", "2")
	add_typed_quad(t, &store, "urn:three", "urn:value", "2E-1", "http://www.w3.org/2001/XMLSchema#double")
	add_typed_quad(t, &store, "urn:four", "urn:value", "2.2", "http://www.w3.org/2001/XMLSchema#double")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 3)
	expected_values := [3]string{"1", "2", "0"}
	for expected, row in expected_values {
		value, bound, ok := Cell(&result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected)
		testing.expect_value(t, value.datatype, "http://www.w3.org/2001/XMLSchema#integer")
	}
}

@(test)
test_execute_distinct_aggregates_retain_computed_expression_keys :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT
		(COUNT(DISTINCT CONCAT(STR(?value), "!")) AS ?count)
		(SUM(DISTINCT (?value + 0)) AS ?sum)
		(GROUP_CONCAT(DISTINCT CONCAT(STR(?value), "!"); SEPARATOR=",") AS ?joined)
		WHERE { ?subject <urn:value> ?value }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_integer_quad(t, &store, "urn:one", "urn:value", "1")
	add_integer_quad(t, &store, "urn:two", "urn:value", "1")
	add_integer_quad(t, &store, "urn:three", "urn:value", "2")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	count_column := -1
	sum_column := -1
	joined_column := -1
	for column in 0..<Variable_Count(&result) {
		name, name_ok := Variable_Name(&result, column)
		if !name_ok do continue
		if name == "count" do count_column = column
		if name == "sum" do sum_column = column
		if name == "joined" do joined_column = column
	}
	testing.expect_value(t, count_column >= 0 && sum_column >= 0 && joined_column >= 0, true)
	count, count_bound, count_ok := Cell(&result, 0, count_column)
	sum, sum_bound, sum_ok := Cell(&result, 0, sum_column)
	joined, joined_bound, joined_ok := Cell(&result, 0, joined_column)
	testing.expect_value(t, count_ok && count_bound && sum_ok && sum_bound && joined_ok && joined_bound, true)
	testing.expect_value(t, count.value, "2")
	testing.expect_value(t, sum.value, "3")
	testing.expect_value(t, joined.value, "1!,2!")
}

@(test)
test_execute_computed_group_key_survives_order_materialization :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?key (COUNT(*) AS ?count)
		WHERE { VALUES ?value { "b" "a" "b" } }
		GROUP BY (CONCAT(?value, "!") AS ?key)
		ORDER BY ?key`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	key_column := -1
	count_column := -1
	for column in 0..<Variable_Count(&result) {
		name, name_ok := Variable_Name(&result, column)
		if !name_ok do continue
		if name == "key" do key_column = column
		if name == "count" do count_column = column
	}
	testing.expect_value(t, key_column >= 0 && count_column >= 0, true)
	expected_keys := [2]string{"a!", "b!"}
	expected_counts := [2]string{"1", "2"}
	for row in 0..<len(expected_keys) {
		key, key_bound, key_ok := Cell(&result, row, key_column)
		count, count_bound, count_ok := Cell(&result, row, count_column)
		testing.expect_value(t, key_ok && key_bound && count_ok && count_bound, true)
		testing.expect_value(t, key.value, expected_keys[row])
		testing.expect_value(t, count.value, expected_counts[row])
	}
}

@(test)
test_execute_float_and_double_casts_validate_lexical_forms_and_special_values :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX x: <http://www.w3.org/2001/XMLSchema#>
SELECT ?float ?double ?infinity ?missing {
  BIND(x:float("1.25") AS ?float)
  BIND(x:double(true) AS ?double)
  BIND(x:double("INF") AS ?infinity)
  BIND(x:float("not-a-number") AS ?missing)
}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected := [3]struct{ lexical, datatype: string }{
		{"1.25", "http://www.w3.org/2001/XMLSchema#float"},
		{"1", "http://www.w3.org/2001/XMLSchema#double"},
		{"INF", "http://www.w3.org/2001/XMLSchema#double"},
	}
	for column in 0..<len(expected) {
		value, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[column].lexical)
		testing.expect_value(t, value.datatype, expected[column].datatype)
	}
	_, missing_bound, missing_ok := Cell(&result, 0, 3)
	testing.expect_value(t, missing_ok, true)
	testing.expect_value(t, missing_bound, false)
}

@(test)
test_execute_iri_function_resolves_runtime_string_against_query_base :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`BASE <http://example.org/root/>
SELECT ?iri ?uri { BIND("child" AS ?path) BIND(IRI(?path) AS ?iri) BIND(URI(<sibling>) AS ?uri) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	expected := [2]string{"http://example.org/root/child", "http://example.org/root/sibling"}
	for column in 0..<len(expected) {
		value, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.kind, rdf.Term_Kind.IRI)
		testing.expect_value(t, value.value, expected[column])
	}
}

@(test)
test_execute_exact_numeric_rounding_functions_preserve_datatype_and_half_rule :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?absolute ?floor ?ceiling ?negativeHalf ?negativeMore { BIND(ABS(-2.50) AS ?absolute) BIND(FLOOR(-1.6) AS ?floor) BIND(CEIL(1.1) AS ?ceiling) BIND(ROUND(-1.5) AS ?negativeHalf) BIND(ROUND(-1.5001) AS ?negativeMore) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [5]string{"2.50", "-2", "2", "-1", "-2"}
	for column in 0..<len(expected) {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
		testing.expect_value(t, term.datatype, "http://www.w3.org/2001/XMLSchema#decimal")
	}
}

@(test)
test_execute_floating_rounding_functions_preserve_type_special_values_and_half_rule :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?floatAbs ?doubleCeil ?floatFloor ?doubleHalf ?floatHalf ?nan ?negativeInfinity {
			BIND(ABS("-1.25"^^xsd:float) AS ?floatAbs)
			BIND(CEIL("-1.25"^^xsd:double) AS ?doubleCeil)
			BIND(FLOOR("-1.25"^^xsd:float) AS ?floatFloor)
			BIND(ROUND("-1.5"^^xsd:double) AS ?doubleHalf)
			BIND(ROUND("-1.5"^^xsd:float) AS ?floatHalf)
			BIND(ROUND("NaN"^^xsd:double) AS ?nan)
			BIND(FLOOR("-INF"^^xsd:float) AS ?negativeInfinity)
		}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [7]struct{ lexical, datatype: string }{
		{"1.25", "http://www.w3.org/2001/XMLSchema#float"},
		{"-1", "http://www.w3.org/2001/XMLSchema#double"},
		{"-2", "http://www.w3.org/2001/XMLSchema#float"},
		{"-1", "http://www.w3.org/2001/XMLSchema#double"},
		{"-1", "http://www.w3.org/2001/XMLSchema#float"},
		{"NaN", "http://www.w3.org/2001/XMLSchema#double"},
		{"-INF", "http://www.w3.org/2001/XMLSchema#float"},
	}
	for column in 0..<len(expected) {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column].lexical)
		testing.expect_value(t, term.datatype, expected[column].datatype)
	}
}

@(test)
test_execute_substr_accepts_floating_numeric_indices :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?doubleStart ?floatLength ?negativeHalf ?nan ?infinity {
			BIND(SUBSTR("abcd", "1.6"^^xsd:double) AS ?doubleStart)
			BIND(SUBSTR("abcd", 2, "1.6"^^xsd:float) AS ?floatLength)
			BIND(SUBSTR("abcd", "-1.5"^^xsd:double, 4) AS ?negativeHalf)
			BIND(SUBSTR("abcd", "NaN"^^xsd:double) AS ?nan)
			BIND(SUBSTR("abcd", "INF"^^xsd:float) AS ?infinity)
		}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [3]string{"bcd", "bc", "ab"}
	for column in 0..<len(expected) {
		value, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[column])
	}
	for column in 3..<5 {
		_, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok, true)
		testing.expect_value(t, bound, false)
	}
}

@(test)
test_execute_encode_for_uri_uses_utf8_bytes_and_drops_language :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?encoded { BIND(ENCODE_FOR_URI("食べ物 100%"@ja) AS ?encoded) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	encoded, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, encoded.value, "%E9%A3%9F%E3%81%B9%E7%89%A9%20100%25")
	testing.expect_value(t, encoded.language, "")
	testing.expect_value(t, encoded.datatype, "http://www.w3.org/2001/XMLSchema#string")
}

@(test)
test_execute_regex_implements_sparql_flags_and_expression_errors :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?plain ?dotall ?multiline ?quoted ?invalid {
		BIND(REGEX("""a
c""", "a.c") AS ?plain)
		BIND(REGEX("""a
c""", "a.c", "s") AS ?dotall)
		BIND(REGEX("""a
b
c""", "^b$", "m") AS ?multiline)
		BIND(REGEX("a?+*.{}()[]c", "a?+*.{}()[]c", "q") AS ?quoted)
		BIND(REGEX("text", "text", "z") AS ?invalid)
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [4]string{"false", "true", "true", "true"}
	for column in 0..<len(expected) {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
		testing.expect_value(t, term.datatype, "http://www.w3.org/2001/XMLSchema#boolean")
	}
	_, invalid_bound, invalid_ok := Cell(&result, 0, 4)
	testing.expect_value(t, invalid_ok, true)
	testing.expect_value(t, invalid_bound, false)
}

@(test)
test_execute_strlang_constructs_owned_language_literals_and_rejects_invalid_arguments :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?constructed ?nested ?invalid {
		BIND(STRLANG("food", "en-US") AS ?constructed)
		BIND(STRLANG(STR("食べ物"@ja), CONCAT("ja", "-JP")) AS ?nested)
		BIND(STRLANG("food"@en, "en-US") AS ?invalid)
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected_values := [2]string{"food", "食べ物"}
	expected_languages := [2]string{"en-US", "ja-JP"}
	for column in 0..<len(expected_values) {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected_values[column])
		testing.expect_value(t, term.language, expected_languages[column])
		testing.expect_value(t, term.datatype, "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString")
	}
	_, invalid_bound, invalid_ok := Cell(&result, 0, 2)
	testing.expect_value(t, invalid_ok, true)
	testing.expect_value(t, invalid_bound, false)
}

@(test)
test_execute_language_tags_are_case_insensitive_for_matching_and_same_term :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:label> "food"@en-us FILTER(SAMETERM("food"@EN-us, "food"@en-US)) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:subject"), predicate = rdf.iri("urn:label"), object = rdf.language_literal("food", "EN-US")})
	testing.expect_value(t, dataset.add(&store, quad), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	subject, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, subject.value, "urn:subject")
}

@(test)
test_execute_bnode_is_solution_local_for_string_arguments_and_fresh_without_one :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?one ?two ?fresh ?same { BIND(BNODE("label") AS ?one) BIND(BNODE("label") AS ?two) BIND(BNODE() AS ?fresh) BIND(SAMETERM(?one, ?two) AS ?same) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	one, one_bound, one_ok := Cell(&result, 0, 0)
	two, two_bound, two_ok := Cell(&result, 0, 1)
	fresh, fresh_bound, fresh_ok := Cell(&result, 0, 2)
	same, same_bound, same_ok := Cell(&result, 0, 3)
	testing.expect_value(t, one_ok && one_bound && two_ok && two_bound && fresh_ok && fresh_bound && same_ok && same_bound, true)
	testing.expect_value(t, one.kind, rdf.Term_Kind.Blank_Node)
	testing.expect_value(t, two.kind, rdf.Term_Kind.Blank_Node)
	testing.expect_value(t, fresh.kind, rdf.Term_Kind.Blank_Node)
	testing.expect_value(t, one.value, two.value)
	testing.expect_value(t, one.scope, two.scope)
	testing.expect_value(t, one.value == fresh.value && one.scope == fresh.scope, false)
	testing.expect_value(t, same.value, "true")
}

@(test)
test_execute_substr_uses_code_points_and_exact_numeric_rounding :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?zero ?rounded ?large ?language { BIND(SUBSTR("abcd", 0, 2) AS ?zero) BIND(SUBSTR("abcd", 1.5, 2) AS ?rounded) BIND(SUBSTR("abcd", 999999999999999999999999999999999999999999999999) AS ?large) BIND(SUBSTR("食べ物"@ja, 2) AS ?language) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [4]string{"a", "bc", "", "べ物"}
	for column in 0..<len(expected) {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
	}
	language, language_bound, language_ok := Cell(&result, 0, 3)
	testing.expect_value(t, language_ok && language_bound, true)
	testing.expect_value(t, language.language, "ja")
}

@(test)
test_execute_hash_functions_return_lowercase_simple_literals :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?md5 ?sha256 { BIND(MD5("foo"@en) AS ?md5) BIND(SHA256("foo") AS ?sha256) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	expected := [2]string{"acbd18db4cc2f85cedef654fccc4a4d8", "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"}
	for column in 0..<len(expected) {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, expected[column])
		testing.expect_value(t, term.language, "")
		testing.expect_value(t, term.datatype, "http://www.w3.org/2001/XMLSchema#string")
	}
}

@(test)
test_execute_concat_preserves_a_shared_language_tag_and_owns_its_result :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?language ?mixed { BIND(CONCAT("first"@en, "second"@en) AS ?language) BIND(CONCAT("first"@en, "second") AS ?mixed) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	language, language_bound, language_ok := Cell(&result, 0, 0)
	mixed, mixed_bound, mixed_ok := Cell(&result, 0, 1)
	testing.expect_value(t, language_ok && language_bound, true)
	testing.expect_value(t, mixed_ok && mixed_bound, true)
	testing.expect_value(t, language.value, "firstsecond")
	testing.expect_value(t, language.language, "en")
	testing.expect_value(t, mixed.value, "firstsecond")
	testing.expect_value(t, mixed.language, "")
}

@(test)
test_execute_string_predicates_require_compatible_language_tags :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?starts ?ends ?contains ?mismatch { BIND(STRSTARTS("alphabet"@en, "alpha") AS ?starts) BIND(STRENDS("alphabet"@en, "bet"@en) AS ?ends) BIND(CONTAINS("alphabet"@en, "pha") AS ?contains) BIND(CONTAINS("alphabet"@en, "pha"@fr) AS ?mismatch) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	for column in 0..<3 {
		term, bound, ok := Cell(&result, 0, column)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, term.value, "true")
	}
	_, mismatch_bound, mismatch_ok := Cell(&result, 0, 3)
	testing.expect_value(t, mismatch_ok, true)
	testing.expect_value(t, mismatch_bound, false)
}

@(test)
test_execute_strlen_counts_unicode_code_points_not_utf8_bytes :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?length { BIND(STRLEN("👨‍👩‍👧‍👦") AS ?length) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	length, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, length.value, "7")
	testing.expect_value(t, length.datatype, "http://www.w3.org/2001/XMLSchema#integer")
}

@(test)
test_execute_strbefore_and_strafter_preserve_the_source_language_tag :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?before ?after ?missing { BIND(STRBEFORE("alphabet"@en, "pha") AS ?before) BIND(STRAFTER("alphabet"@en, "pha") AS ?after) BIND(STRBEFORE("alphabet"@en, "none") AS ?missing) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	before, before_bound, before_ok := Cell(&result, 0, 0)
	after, after_bound, after_ok := Cell(&result, 0, 1)
	missing, missing_bound, missing_ok := Cell(&result, 0, 2)
	testing.expect_value(t, before_ok && before_bound, true)
	testing.expect_value(t, after_ok && after_bound, true)
	testing.expect_value(t, missing_ok && missing_bound, true)
	testing.expect_value(t, before.value, "al")
	testing.expect_value(t, after.value, "bet")
	testing.expect_value(t, before.language, "en")
	testing.expect_value(t, after.language, "en")
	testing.expect_value(t, missing.value, "")
	testing.expect_value(t, missing.language, "")
	testing.expect_value(t, missing.datatype, "http://www.w3.org/2001/XMLSchema#string")
}

@(test)
test_execute_strdt_requires_an_unlanguage_tagged_string_and_an_iri_datatype :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?typed ?generated ?invalid { BIND(STRDT("42", <urn:datatype>) AS ?typed) BIND(STRDT(CONCAT("4", "2"), <urn:datatype>) AS ?generated) BIND(STRDT("42"@en, <urn:datatype>) AS ?invalid) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	typed, typed_bound, typed_ok := Cell(&result, 0, 0)
	generated, generated_bound, generated_ok := Cell(&result, 0, 1)
	_, invalid_bound, invalid_ok := Cell(&result, 0, 2)
	testing.expect_value(t, typed_ok && typed_bound, true)
	testing.expect_value(t, generated_ok && generated_bound, true)
	testing.expect_value(t, typed.value, "42")
	testing.expect_value(t, typed.datatype, "urn:datatype")
	testing.expect_value(t, generated.value, "42")
	testing.expect_value(t, generated.datatype, "urn:datatype")
	testing.expect_value(t, invalid_ok, true)
	testing.expect_value(t, invalid_bound, false)
}

@(test)
test_execute_from_merges_declared_named_graphs_into_default_graph :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject FROM <urn:one> FROM <urn:two> { ?subject <urn:kind> <urn:included> }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:one", "urn:ada", "urn:kind", "urn:included")
	add_named_iri_quad(t, &store, "urn:two", "urn:ada", "urn:kind", "urn:included")
	add_iri_quad(t, &store, "urn:default", "urn:kind", "urn:included")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	subject, bound, ok := Cell(&result, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, subject.value, "urn:ada")
}

@(test)
test_execute_from_named_limits_graph_patterns_and_empties_default_graph :: proc(t: ^testing.T) {
	graph_query, graph_parse_error := sparql.Parse(`SELECT ?graph ?subject FROM NAMED <urn:one> { GRAPH ?graph { ?subject <urn:kind> <urn:included> } }`)
	defer sparql.Destroy(&graph_query)
	testing.expect_value(t, sparql.Parse_Error_Code(graph_parse_error), sparql.Error_Code.None)
	default_query, default_parse_error := sparql.Parse(`ASK FROM NAMED <urn:one> { ?subject <urn:kind> <urn:included> }`)
	defer sparql.Destroy(&default_query)
	testing.expect_value(t, sparql.Parse_Error_Code(default_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_named_iri_quad(t, &store, "urn:one", "urn:ada", "urn:kind", "urn:included")
	add_named_iri_quad(t, &store, "urn:two", "urn:bert", "urn:kind", "urn:included")
	add_iri_quad(t, &store, "urn:default", "urn:kind", "urn:included")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&graph_query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	graph, graph_bound, graph_ok := Cell(&result, 0, 0)
	testing.expect_value(t, graph_ok && graph_bound, true)
	testing.expect_value(t, graph.value, "urn:one")
	ask, ask_error := execute(&default_query, view, {Max_Solutions = 1})
	defer destroy(&ask)
	testing.expect_value(t, ask_error, Error_Code.None)
	value, value_ok := Ask_Value(&ask)
	testing.expect_value(t, value_ok, true)
	testing.expect_value(t, value, false)
}

@(test)
test_execute_value_equality_keeps_unknown_datatypes_open_and_identical_terms_equal :: proc(t: ^testing.T) {
	unknown_query, unknown_parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:p> ?value FILTER(?value != "a"^^<urn:unknown>) }`)
	defer sparql.Destroy(&unknown_query)
	language_query, language_parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:p> ?value FILTER(?value != "lang"^^<urn:unknown>) }`)
	defer sparql.Destroy(&language_query)
	identical_query, identical_parse_error := sparql.Parse(`ASK { ?subject <urn:invalid> ?value FILTER(?value = ?value) }`)
	defer sparql.Destroy(&identical_query)
	testing.expect_value(t, sparql.Parse_Error_Code(unknown_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(language_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(identical_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:one", "urn:p", "a", "urn:unknown")
	add_typed_quad(t, &store, "urn:two", "urn:p", "b", "urn:unknown")
	language_quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:language"), predicate = rdf.iri("urn:p"), object = rdf.language_literal("lang", "en")})
	testing.expect_value(t, dataset.add(&store, language_quad), dataset.Error_Code.None)
	add_integer_quad(t, &store, "urn:three", "urn:invalid", "not-an-integer")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	unknown_result, unknown_execute_error := execute(&unknown_query, view, {Max_Solutions = 8})
	defer destroy(&unknown_result)
	testing.expect_value(t, unknown_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&unknown_result), 1)
	unknown_subject, unknown_bound, unknown_ok := Cell(&unknown_result, 0, 0)
	testing.expect_value(t, unknown_ok && unknown_bound, true)
	testing.expect_value(t, unknown_subject.value, "urn:language")
	language_result, language_execute_error := execute(&language_query, view, {Max_Solutions = 8})
	defer destroy(&language_result)
	testing.expect_value(t, language_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&language_result), 1)
	language_subject, language_bound, language_ok := Cell(&language_result, 0, 0)
	testing.expect_value(t, language_ok && language_bound, true)
	testing.expect_value(t, language_subject.value, "urn:language")
	identical_result, identical_execute_error := execute(&identical_query, view, {Max_Solutions = 8})
	defer destroy(&identical_result)
	testing.expect_value(t, identical_execute_error, Error_Code.None)
	value, value_ok := Ask_Value(&identical_result)
	testing.expect_value(t, value_ok && value, true)
}

@(test)
test_execute_optional_filter_sees_outer_bindings_and_extends_matching_rows :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?left ?right ?inside {
		?left <urn:p> ?outer .
		?right <urn:p> ?right_value .
		OPTIONAL { ?right <urn:p> ?inside . FILTER(?outer != ?inside || ?outer = ?inside) }
		FILTER(BOUND(?inside))
	}`)
	defer sparql.Destroy(&query)
	correlated_query, correlated_parse_error := sparql.Parse(`SELECT ?left ?right ?inside {
		?left <urn:p> ?outer .
		?right <urn:p> ?right_value .
		OPTIONAL { ?right <urn:p> ?inside . FILTER(?outer = ?outer) }
		FILTER(BOUND(?inside))
	}`)
	defer sparql.Destroy(&correlated_query)
	unfiltered_query, unfiltered_parse_error := sparql.Parse(`SELECT ?left ?outer ?right ?inside {
		?left <urn:p> ?outer .
		?right <urn:p> ?right_value .
		OPTIONAL { ?right <urn:p> ?inside . FILTER(?outer = ?outer) }
	}`)
	defer sparql.Destroy(&unfiltered_query)
	bound_query, bound_parse_error := sparql.Parse(`SELECT ?left ?right ?inside {
		?left <urn:p> ?outer .
		?right <urn:p> ?right_value .
		OPTIONAL { ?right <urn:p> ?inside . FILTER(BOUND(?outer)) }
		FILTER(BOUND(?inside))
	}`)
	defer sparql.Destroy(&bound_query)
	plain_optional_query, plain_optional_parse_error := sparql.Parse(`SELECT ?left ?right ?inside {
		?left <urn:p> ?outer .
		?right <urn:p> ?right_value .
		OPTIONAL { ?right <urn:p> ?inside }
	}`)
	defer sparql.Destroy(&plain_optional_query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(correlated_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(unfiltered_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(bound_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(plain_optional_parse_error), sparql.Error_Code.None)
	bound_plan, bound_translation_error := algebra.translate(&bound_query)
	defer algebra.destroy(&bound_plan)
	testing.expect_value(t, bound_translation_error, algebra.Error_Code.None)
	outer_variable := -1
	for index in 0..<algebra.Variable_Count(&bound_plan) {
		name, name_ok := algebra.Variable_Name(&bound_plan, index)
		if name_ok && name == "outer" do outer_variable = index
	}
	testing.expect(t, outer_variable >= 0)
	outer_triple_found := false
	for index in 0..<algebra.Triple_Count(&bound_plan) {
		triple, triple_ok := algebra.Triple(&bound_plan, index)
		if triple_ok && triple.Object.Kind == .Variable && triple.Object.Variable == outer_variable do outer_triple_found = true
	}
	testing.expect_value(t, outer_triple_found, true)
	bound_expression_count := 0
	for operator in 0..<algebra.Operator_Count(&bound_plan) {
		operator_node, operator_ok := algebra.Operator_At(&bound_plan, operator)
		if !operator_ok || operator_node.Kind != .Filter do continue
		node, node_ok := algebra.Expression_At(&bound_plan, operator_node.Expression)
		if !node_ok || node.Kind != .Bound do continue
		child, child_ok := algebra.Expression_Child(&bound_plan, operator_node.Expression, 0)
		argument, argument_ok := algebra.Expression_At(&bound_plan, child)
		testing.expect_value(t, child_ok && argument_ok, true)
		if argument_ok && argument.Term.Kind == .Variable {
			name, name_ok := algebra.Variable_Name(&bound_plan, argument.Term.Variable)
			testing.expect_value(t, name_ok, true)
			testing.expect_value(t, name == "outer" || name == "inside", true)
			if name == "outer" do testing.expect_value(t, argument.Term.Variable, outer_variable)
		}
		bound_expression_count += 1
	}
	testing.expect_value(t, bound_expression_count, 2)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:one", "urn:p", "one", "http://www.w3.org/2001/XMLSchema#string")
	add_typed_quad(t, &store, "urn:two", "urn:p", "two", "http://www.w3.org/2001/XMLSchema#string")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 16})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 4)
	for row in 0..<Row_Count(&result) {
		_, inside_bound, inside_ok := Cell(&result, row, 2)
		testing.expect_value(t, inside_ok && inside_bound, true)
	}
	correlated_result, correlated_execute_error := execute(&correlated_query, view, {Max_Solutions = 16})
	defer destroy(&correlated_result)
	testing.expect_value(t, correlated_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&correlated_result), 4)
	unfiltered_result, unfiltered_execute_error := execute(&unfiltered_query, view, {Max_Solutions = 16})
	defer destroy(&unfiltered_result)
	testing.expect_value(t, unfiltered_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&unfiltered_result), 4)
	for row in 0..<Row_Count(&unfiltered_result) {
		_, outer_bound, outer_ok := Cell(&unfiltered_result, row, 1)
		_, right_bound, right_ok := Cell(&unfiltered_result, row, 2)
		_, inside_bound, inside_ok := Cell(&unfiltered_result, row, 3)
		testing.expect_value(t, outer_ok && outer_bound, true)
		testing.expect_value(t, right_ok && right_bound, true)
		testing.expect_value(t, inside_ok && inside_bound, true)
	}
	bound_result, bound_execute_error := execute(&bound_query, view, {Max_Solutions = 16})
	defer destroy(&bound_result)
	testing.expect_value(t, bound_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&bound_result), 4)
	plain_optional_result, plain_optional_execute_error := execute(&plain_optional_query, view, {Max_Solutions = 16})
	defer destroy(&plain_optional_result)
	testing.expect_value(t, plain_optional_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&plain_optional_result), 4)
	for row in 0..<Row_Count(&plain_optional_result) {
		_, inside_bound, inside_ok := Cell(&plain_optional_result, row, 2)
		testing.expect_value(t, inside_ok && inside_bound, true)
	}
}

@(test)
test_execute_xsd_date_comparison_validates_lexical_forms_and_preserves_timezone_absence :: proc(t: ^testing.T) {
	greater_query, greater_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?subject { ?subject <urn:date> ?value FILTER(?value > "2006-08-22"^^xsd:date) }`)
	defer sparql.Destroy(&greater_query)
	equal_query, equal_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?subject { ?subject <urn:date> ?value FILTER(?value = "2006-08-23"^^xsd:date) }`)
	defer sparql.Destroy(&equal_query)
	not_equal_query, not_equal_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?subject { ?subject <urn:date> ?value FILTER(?value != "2006-08-23"^^xsd:date) }`)
	defer sparql.Destroy(&not_equal_query)
	timezone_query, timezone_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		ASK { <urn:early> <urn:date> ?early . <urn:utc> <urn:date> ?utc . FILTER(?early < ?utc) }`)
	defer sparql.Destroy(&timezone_query)
	testing.expect_value(t, sparql.Parse_Error_Code(greater_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(equal_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(not_equal_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(timezone_parse_error), sparql.Error_Code.None)
	date_datatype := "http://www.w3.org/2001/XMLSchema#date"
	date_time_datatype := "http://www.w3.org/2001/XMLSchema#dateTime"
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:plain", "urn:date", "2006-08-23", date_datatype)
	add_typed_quad(t, &store, "urn:z", "urn:date", "2006-08-23Z", date_datatype)
	add_typed_quad(t, &store, "urn:zero", "urn:date", "2006-08-23+00:00", date_datatype)
	add_typed_quad(t, &store, "urn:old", "urn:date", "2001-01-01Z", date_datatype)
	add_typed_quad(t, &store, "urn:datetime", "urn:date", "2006-08-23T09:00:00+01:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:invalid", "urn:date", "2006-02-30", date_datatype)
	add_typed_quad(t, &store, "urn:early", "urn:date", "2006-08-23+14:00", date_datatype)
	add_typed_quad(t, &store, "urn:utc", "urn:date", "2006-08-23Z", date_datatype)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	greater, greater_execute_error := execute(&greater_query, view, {Max_Solutions = 16})
	defer destroy(&greater)
	testing.expect_value(t, greater_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&greater), 5)
	for row in 0..<Row_Count(&greater) {
		subject, bound, ok := Cell(&greater, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, subject.value == "urn:plain" || subject.value == "urn:z" || subject.value == "urn:zero" || subject.value == "urn:early" || subject.value == "urn:utc", true)
	}
	equal, equal_execute_error := execute(&equal_query, view, {Max_Solutions = 16})
	defer destroy(&equal)
	testing.expect_value(t, equal_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&equal), 1)
	equal_subject, equal_bound, equal_ok := Cell(&equal, 0, 0)
	testing.expect_value(t, equal_ok && equal_bound, true)
	testing.expect_value(t, equal_subject.value, "urn:plain")
	not_equal, not_equal_execute_error := execute(&not_equal_query, view, {Max_Solutions = 16})
	defer destroy(&not_equal)
	testing.expect_value(t, not_equal_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&not_equal), 2)
	for row in 0..<Row_Count(&not_equal) {
		subject, bound, ok := Cell(&not_equal, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, subject.value == "urn:old" || subject.value == "urn:datetime", true)
	}
	timezone, timezone_execute_error := execute(&timezone_query, view, {Max_Solutions = 1})
	defer destroy(&timezone)
	testing.expect_value(t, timezone_execute_error, Error_Code.None)
	timezone_value, timezone_ok := Ask_Value(&timezone)
	testing.expect_value(t, timezone_ok && timezone_value, true)
}

@(test)
test_execute_xsd_date_time_relations_normalize_explicit_timezones_and_reject_invalid_lexical_forms :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?subject { ?subject <urn:time> ?value FILTER(?value < "2006-08-23T01:00:00Z"^^xsd:dateTime) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	date_time_datatype := "http://www.w3.org/2001/XMLSchema#dateTime"
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	// 01:30+01:00 is 00:30Z, and the two fraction spellings represent the
	// same instant. Only 24:00:00 is legal; 24:00:01 is an expression error.
	add_typed_quad(t, &store, "urn:offset", "urn:time", "2006-08-23T01:30:00+01:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:fraction", "urn:time", "2006-08-23T00:59:59.900Z", date_time_datatype)
	add_typed_quad(t, &store, "urn:invalid", "urn:time", "2006-08-23T24:00:01Z", date_time_datatype)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 2)
	for row in 0..<Row_Count(&result) {
		subject, bound, ok := Cell(&result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, subject.value == "urn:offset" || subject.value == "urn:fraction", true)
	}
}

@(test)
test_execute_xsd_date_time_equality_normalizes_instants_and_24_hour_midnight :: proc(t: ^testing.T) {
	equal_query, equal_parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:left> ?left ; <urn:right> ?right FILTER(?left = ?right) }`)
	defer sparql.Destroy(&equal_query)
	not_equal_query, not_equal_parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:left> ?left ; <urn:right> ?right FILTER(?left != ?right) }`)
	defer sparql.Destroy(&not_equal_query)
	testing.expect_value(t, sparql.Parse_Error_Code(equal_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(not_equal_parse_error), sparql.Error_Code.None)
	date_time_datatype := "http://www.w3.org/2001/XMLSchema#dateTime"
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:offset", "urn:left", "2002-04-02T23:00:00-04:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:offset", "urn:right", "2002-04-03T02:00:00-01:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:midnight", "urn:left", "1999-12-31T24:00:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:midnight", "urn:right", "2000-01-01T00:00:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:fraction", "urn:left", "2008-04-01T00:00:00.00Z", date_time_datatype)
	add_typed_quad(t, &store, "urn:fraction", "urn:right", "2008-04-01T00:00:00Z", date_time_datatype)
	add_typed_quad(t, &store, "urn:mixed", "urn:left", "2002-04-02T23:00:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:mixed", "urn:right", "2002-04-02T23:00:00+06:00", date_time_datatype)
	add_typed_quad(t, &store, "urn:invalid", "urn:left", "2002-04-02T24:00:01", date_time_datatype)
	add_typed_quad(t, &store, "urn:invalid", "urn:right", "2002-04-03T00:00:01", date_time_datatype)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	equal, equal_execute_error := execute(&equal_query, view, {Max_Solutions = 8})
	defer destroy(&equal)
	testing.expect_value(t, equal_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&equal), 3)
	for row in 0..<Row_Count(&equal) {
		subject, bound, ok := Cell(&equal, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, subject.value == "urn:offset" || subject.value == "urn:midnight" || subject.value == "urn:fraction", true)
	}
	not_equal, not_equal_execute_error := execute(&not_equal_query, view, {Max_Solutions = 8})
	defer destroy(&not_equal)
	testing.expect_value(t, not_equal_execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&not_equal), 1)
	subject, bound, ok := Cell(&not_equal, 0, 0)
	testing.expect_value(t, ok && bound, true)
	testing.expect_value(t, subject.value, "urn:mixed")
}

@(test)
test_execute_xsd_date_time_cast_validates_lexical_input_and_preserves_spelling :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?cast ?repeat ?invalid ?language ?number {
			BIND(xsd:dateTime("2002-10-10T17:00:00Z") AS ?cast)
			BIND(xsd:dateTime("1999-12-31T24:00:00") AS ?repeat)
			BIND(xsd:dateTime("2002-02-30T17:00:00Z") AS ?invalid)
			BIND(xsd:dateTime("2002-10-10T17:00:00Z"@en) AS ?language)
			BIND(xsd:dateTime(1) AS ?number)
		}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	cast_term, cast_bound, cast_ok := Cell(&result, 0, 0)
	repeat, repeat_bound, repeat_ok := Cell(&result, 0, 1)
	_, invalid_bound, invalid_ok := Cell(&result, 0, 2)
	_, language_bound, language_ok := Cell(&result, 0, 3)
	_, number_bound, number_ok := Cell(&result, 0, 4)
	testing.expect_value(t, cast_ok && cast_bound, true)
	testing.expect_value(t, repeat_ok && repeat_bound, true)
	testing.expect_value(t, cast_term.value, "2002-10-10T17:00:00Z")
	testing.expect_value(t, repeat.value, "1999-12-31T24:00:00")
	testing.expect_value(t, cast_term.datatype, "http://www.w3.org/2001/XMLSchema#dateTime")
	testing.expect_value(t, repeat.datatype, "http://www.w3.org/2001/XMLSchema#dateTime")
	testing.expect_value(t, invalid_ok && !invalid_bound, true)
	testing.expect_value(t, language_ok && !language_bound, true)
	testing.expect_value(t, number_ok && !number_bound, true)
}

@(test)
test_execute_xsd_date_and_time_cast_validate_lexical_input_and_language_rules :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?date ?time ?date_repeat ?time_repeat ?bad_date ?bad_time ?language ?cross_type {
			BIND(xsd:date("-0005-01-02+05:30") AS ?date)
			BIND(xsd:time("24:00:00.000Z") AS ?time)
			BIND(xsd:date("2002-10-10"^^xsd:date) AS ?date_repeat)
			BIND(xsd:time("10:20:30.250-08:00"^^xsd:time) AS ?time_repeat)
			BIND(xsd:date("2002-02-30") AS ?bad_date)
			BIND(xsd:time("24:00:01") AS ?bad_time)
			BIND(xsd:date("2002-10-10"@en) AS ?language)
			BIND(xsd:date("2002-10-10T00:00:00Z"^^xsd:dateTime) AS ?cross_type)
		}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	date, date_bound, date_ok := Cell(&result, 0, 0)
	time, time_bound, time_ok := Cell(&result, 0, 1)
	date_repeat, date_repeat_bound, date_repeat_ok := Cell(&result, 0, 2)
	time_repeat, time_repeat_bound, time_repeat_ok := Cell(&result, 0, 3)
	_, bad_date_bound, bad_date_ok := Cell(&result, 0, 4)
	_, bad_time_bound, bad_time_ok := Cell(&result, 0, 5)
	_, language_bound, language_ok := Cell(&result, 0, 6)
	_, cross_type_bound, cross_type_ok := Cell(&result, 0, 7)
	testing.expect_value(t, date_ok && date_bound, true)
	testing.expect_value(t, time_ok && time_bound, true)
	testing.expect_value(t, date_repeat_ok && date_repeat_bound, true)
	testing.expect_value(t, time_repeat_ok && time_repeat_bound, true)
	testing.expect_value(t, date.value, "-0005-01-02+05:30")
	testing.expect_value(t, date.datatype, "http://www.w3.org/2001/XMLSchema#date")
	testing.expect_value(t, time.value, "24:00:00.000Z")
	testing.expect_value(t, time.datatype, "http://www.w3.org/2001/XMLSchema#time")
	testing.expect_value(t, date_repeat.value, "2002-10-10")
	testing.expect_value(t, time_repeat.value, "10:20:30.250-08:00")
	testing.expect_value(t, bad_date_ok && !bad_date_bound, true)
	testing.expect_value(t, bad_time_ok && !bad_time_bound, true)
	testing.expect_value(t, language_ok && !language_bound, true)
	testing.expect_value(t, cross_type_ok && !cross_type_bound, true)
}

@(test)
test_execute_now_uses_one_injected_query_clock_and_rejects_invalid_clock_input :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?first ?second { BIND(NOW() AS ?first) BIND(NOW() AS ?second) }`)
	defer sparql.Destroy(&query)
	ask_query, ask_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#> ASK { BIND(NOW() AS ?n) FILTER(DATATYPE(?n) = xsd:dateTime) }`)
	defer sparql.Destroy(&ask_query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(ask_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8, Now_Lexical = "2002-10-10T17:00:00.250Z"})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	first, first_bound, first_ok := Cell(&result, 0, 0)
	second, second_bound, second_ok := Cell(&result, 0, 1)
	testing.expect_value(t, first_ok && first_bound, true)
	testing.expect_value(t, second_ok && second_bound, true)
	testing.expect_value(t, first.value, "2002-10-10T17:00:00.250Z")
	testing.expect_value(t, second.value, first.value)
	testing.expect_value(t, first.datatype, "http://www.w3.org/2001/XMLSchema#dateTime")
	default_clock, default_clock_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&default_clock)
	testing.expect_value(t, default_clock_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&default_clock), 1)
	default_first, default_first_bound, default_first_ok := Cell(&default_clock, 0, 0)
	testing.expect_value(t, default_first_ok && default_first_bound, true)
	testing.expect_value(t, default_first.datatype, "http://www.w3.org/2001/XMLSchema#dateTime")
	fixed_ask, fixed_ask_error := execute(&ask_query, view, {Max_Solutions = 8, Now_Lexical = "2002-10-10T17:00:00Z"})
	defer destroy(&fixed_ask)
	testing.expect_value(t, fixed_ask_error, Error_Code.None)
	fixed_ask_value, fixed_ask_ok := Ask_Value(&fixed_ask)
	testing.expect_value(t, fixed_ask_ok && fixed_ask_value, true)
	default_ask, default_ask_error := execute(&ask_query, view, {Max_Solutions = 100_000, Max_Numeric_Digits = 100_000})
	defer destroy(&default_ask)
	testing.expect_value(t, default_ask_error, Error_Code.None)
	default_ask_value, default_ask_ok := Ask_Value(&default_ask)
	testing.expect_value(t, default_ask_ok && default_ask_value, true)
	invalid, invalid_error := execute(&query, view, {Max_Solutions = 8, Now_Lexical = "not-a-date-time"})
	defer destroy(&invalid)
	testing.expect_value(t, invalid_error, Error_Code.Invalid_Options)
}

@(test)
test_execute_uuid_and_struuid_have_correct_forms_and_require_fresh_values :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?iri ?text { BIND(UUID() AS ?iri) BIND(STRUUID() AS ?text) }`)
	defer sparql.Destroy(&query)
	ask_query, ask_parse_error := sparql.Parse(`ASK { BIND(UUID() AS ?left) BIND(UUID() AS ?right) FILTER(?left != ?right) }`)
	defer sparql.Destroy(&ask_query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(ask_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	fixture: UUID_Fixture
	result, execute_error := execute(&query, view, {Max_Solutions = 8, UUID_Callback = uuid_fixture_callback, UUID_Data = &fixture})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	iri, iri_bound, iri_ok := Cell(&result, 0, 0)
	text, text_bound, text_ok := Cell(&result, 0, 1)
	testing.expect_value(t, iri_ok && iri_bound, true)
	testing.expect_value(t, text_ok && text_bound, true)
	testing.expect_value(t, iri.kind, rdf.Term_Kind.IRI)
	testing.expect_value(t, iri.value, "urn:uuid:00000000-0000-0000-0000-000000000001")
	testing.expect_value(t, text.kind, rdf.Term_Kind.Literal)
	testing.expect_value(t, text.value, "00000000-0000-0000-0000-000000000002")
	testing.expect_value(t, text.datatype, "http://www.w3.org/2001/XMLSchema#string")
	fresh_fixture: UUID_Fixture
	fresh_result, fresh_error := execute(&ask_query, view, {Max_Solutions = 8, UUID_Callback = uuid_fixture_callback, UUID_Data = &fresh_fixture})
	defer destroy(&fresh_result)
	testing.expect_value(t, fresh_error, Error_Code.None)
	fresh_value, fresh_ok := Ask_Value(&fresh_result)
	testing.expect_value(t, fresh_ok && fresh_value, true)
	repeated_fixture := UUID_Fixture{repeat = true}
	repeated_result, repeated_error := execute(&ask_query, view, {Max_Solutions = 8, UUID_Callback = uuid_fixture_callback, UUID_Data = &repeated_fixture})
	defer destroy(&repeated_result)
	testing.expect_value(t, repeated_error, Error_Code.None)
	repeated_value, repeated_ok := Ask_Value(&repeated_result)
	testing.expect_value(t, repeated_ok && !repeated_value, true)
}

@(test)
test_execute_rand_uses_injected_unit_interval_values_and_rejects_invalid_values :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?r { BIND(RAND() AS ?r) }`)
	defer sparql.Destroy(&query)
	ask_query, ask_parse_error := sparql.Parse(`ASK { BIND(RAND() AS ?r) FILTER(BOUND(?r)) }`)
	defer sparql.Destroy(&ask_query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(ask_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	fixture := RAND_Fixture{value = 0.125, ok = true}
	result, execute_error := execute(&query, view, {Max_Solutions = 8, RAND_Callback = rand_fixture_callback, RAND_Data = &fixture})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	value, bound, value_ok := Cell(&result, 0, 0)
	testing.expect_value(t, value_ok && bound, true)
	testing.expect_value(t, value.value, "0.125")
	testing.expect_value(t, value.datatype, "http://www.w3.org/2001/XMLSchema#double")
	invalid_fixture := RAND_Fixture{value = 1, ok = true}
	invalid, invalid_error := execute(&ask_query, view, {Max_Solutions = 8, RAND_Callback = rand_fixture_callback, RAND_Data = &invalid_fixture})
	defer destroy(&invalid)
	testing.expect_value(t, invalid_error, Error_Code.None)
	invalid_value, invalid_ok := Ask_Value(&invalid)
	testing.expect_value(t, invalid_ok && !invalid_value, true)
}

@(test)
test_execute_temporal_components_preserve_fraction_and_timezone_boundaries :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
SELECT ?year ?seconds ?zone ?tz {
  BIND("-0005-01-02T03:04:05.250+05:30"^^xsd:dateTime AS ?date)
  BIND(YEAR(?date) AS ?year) BIND(SECONDS(?date) AS ?seconds)
  BIND(TIMEZONE(?date) AS ?zone) BIND(TZ(?date) AS ?tz)
}`)
	defer sparql.Destroy(&query)
	missing_timezone_query, missing_timezone_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#> ASK { BIND("2011-02-01T01:02:03"^^xsd:dateTime AS ?date) BIND(TIMEZONE(?date) AS ?zone) FILTER(BOUND(?zone)) }`)
	defer sparql.Destroy(&missing_timezone_query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(missing_timezone_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	year, year_bound, year_ok := Cell(&result, 0, 0)
	seconds, seconds_bound, seconds_ok := Cell(&result, 0, 1)
	zone, zone_bound, zone_ok := Cell(&result, 0, 2)
	tz, tz_bound, tz_ok := Cell(&result, 0, 3)
	testing.expect_value(t, year_ok && year_bound && year.value == "-5", true)
	testing.expect_value(t, seconds_ok && seconds_bound && seconds.value == "5.250", true)
	testing.expect_value(t, zone_ok && zone_bound && zone.value == "PT5H30M", true)
	testing.expect_value(t, tz_ok && tz_bound && tz.value == "+05:30", true)
	missing_timezone, missing_timezone_error := execute(&missing_timezone_query, view, {Max_Solutions = 8})
	defer destroy(&missing_timezone)
	testing.expect_value(t, missing_timezone_error, Error_Code.None)
	missing_timezone_value, missing_timezone_ok := Ask_Value(&missing_timezone)
	testing.expect_value(t, missing_timezone_ok && !missing_timezone_value, true)
}

@(test)
test_execute_temporal_components_accept_xsd_time_values :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
SELECT ?hours ?minutes ?seconds ?zone ?tz {
  BIND("23:59:05.250-08:00"^^xsd:time AS ?time)
  BIND(HOURS(?time) AS ?hours) BIND(MINUTES(?time) AS ?minutes)
  BIND(SECONDS(?time) AS ?seconds) BIND(TIMEZONE(?time) AS ?zone)
  BIND(TZ(?time) AS ?tz)
}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 1)
	hours, hours_bound, hours_ok := Cell(&result, 0, 0)
	minutes, minutes_bound, minutes_ok := Cell(&result, 0, 1)
	seconds, seconds_bound, seconds_ok := Cell(&result, 0, 2)
	zone, zone_bound, zone_ok := Cell(&result, 0, 3)
	tz, tz_bound, tz_ok := Cell(&result, 0, 4)
	testing.expect_value(t, hours_ok && hours_bound && hours.value == "23", true)
	testing.expect_value(t, minutes_ok && minutes_bound && minutes.value == "59", true)
	testing.expect_value(t, seconds_ok && seconds_bound && seconds.value == "5.250", true)
	testing.expect_value(t, zone_ok && zone_bound && zone.value == "-PT8H", true)
	testing.expect_value(t, tz_ok && tz_bound && tz.value == "-08:00", true)
}

@(test)
test_execute_replace_preserves_unmatched_capture_positions_and_errors_on_empty_pattern :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?value { BIND(REPLACE("ab", "(a)|(b)", "[$1][$2]") AS ?value) }`)
	defer sparql.Destroy(&query)
	empty_pattern_query, empty_pattern_parse_error := sparql.Parse(`ASK { BIND(REPLACE("abc", "a*", "x") AS ?value) FILTER(BOUND(?value)) }`)
	defer sparql.Destroy(&empty_pattern_query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(empty_pattern_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	value, value_bound, value_ok := Cell(&result, 0, 0)
	testing.expect_value(t, value_ok && value_bound, true)
	testing.expect_value(t, value.value, "[a][][][b]")
	empty_pattern, empty_pattern_error := execute(&empty_pattern_query, view, {Max_Solutions = 8})
	defer destroy(&empty_pattern)
	testing.expect_value(t, empty_pattern_error, Error_Code.None)
	empty_pattern_value, empty_pattern_ok := Ask_Value(&empty_pattern)
	testing.expect_value(t, empty_pattern_ok && !empty_pattern_value, true)
}

@(test)
test_execute_order_by_uses_temporal_value_ordering :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:date> ?date } ORDER BY ?date`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:later", "urn:date", "2010-01-01T01:00:00Z", "http://www.w3.org/2001/XMLSchema#dateTime")
	add_typed_quad(t, &store, "urn:first-equivalent", "urn:date", "2010-01-01T00:30:00Z", "http://www.w3.org/2001/XMLSchema#dateTime")
	add_typed_quad(t, &store, "urn:second-equivalent", "urn:date", "2010-01-01T01:30:00+01:00", "http://www.w3.org/2001/XMLSchema#dateTime")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := execute(&query, view, {Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, execute_error, Error_Code.None)
	testing.expect_value(t, Row_Count(&result), 3)
	expected := [3]string{"urn:first-equivalent", "urn:second-equivalent", "urn:later"}
	for row in 0..<Row_Count(&result) {
		value, bound, ok := Cell(&result, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[row])
	}
}

@(test)
test_execute_xsd_time_equality_relations_and_order_normalize_explicit_offsets :: proc(t: ^testing.T) {
	equality_query, equality_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#> ASK { BIND("00:30:00Z"^^xsd:time AS ?left) BIND("01:30:00+01:00"^^xsd:time AS ?right) FILTER(?left = ?right) }`)
	defer sparql.Destroy(&equality_query)
	relation_query, relation_parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#> ASK { BIND("23:30:00-01:00"^^xsd:time AS ?left) BIND("00:15:00Z"^^xsd:time AS ?right) FILTER(?left > ?right) }`)
	defer sparql.Destroy(&relation_query)
	order_query, order_parse_error := sparql.Parse(`SELECT ?subject { ?subject <urn:time> ?time } ORDER BY ?time`)
	defer sparql.Destroy(&order_query)
	testing.expect_value(t, sparql.Parse_Error_Code(equality_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(relation_parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Parse_Error_Code(order_parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_typed_quad(t, &store, "urn:late", "urn:time", "03:00:00Z", "http://www.w3.org/2001/XMLSchema#time")
	add_typed_quad(t, &store, "urn:first-equivalent", "urn:time", "00:30:00Z", "http://www.w3.org/2001/XMLSchema#time")
	add_typed_quad(t, &store, "urn:second-equivalent", "urn:time", "01:30:00+01:00", "http://www.w3.org/2001/XMLSchema#time")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	equality, equality_error := execute(&equality_query, view, {Max_Solutions = 8})
	defer destroy(&equality)
	testing.expect_value(t, equality_error, Error_Code.None)
	equality_value, equality_ok := Ask_Value(&equality)
	testing.expect_value(t, equality_ok && equality_value, true)
	relation, relation_error := execute(&relation_query, view, {Max_Solutions = 8})
	defer destroy(&relation)
	testing.expect_value(t, relation_error, Error_Code.None)
	relation_value, relation_ok := Ask_Value(&relation)
	testing.expect_value(t, relation_ok && relation_value, true)
	ordered, order_error := execute(&order_query, view, {Max_Solutions = 8})
	defer destroy(&ordered)
	testing.expect_value(t, order_error, Error_Code.None)
	expected := [3]string{"urn:first-equivalent", "urn:second-equivalent", "urn:late"}
	for row in 0..<Row_Count(&ordered) {
		value, bound, ok := Cell(&ordered, row, 0)
		testing.expect_value(t, ok && bound, true)
		testing.expect_value(t, value.value, expected[row])
	}
}
