package public_engine_test

import "core:testing"
import "core:strings"
import rdf "odin-rdf:rdf"
import sparql "../../sparql"
import dataset "../../sparql/dataset"
import engine "../../sparql/engine"
import results "../../sparql/results"

@(private) cancel_immediately :: proc(_: rawptr) -> bool { return true }

@(private) Cancellation_State :: struct {
	polls:        int,
	cancel_after: int,
}

@(private) cancel_after_polls :: proc(data: rawptr) -> bool {
	state := cast(^Cancellation_State)data
	state.polls += 1
	return state.polls >= state.cancel_after
}

@(private) One_Shot_Cancellation_State :: struct {
	polls:     int,
	cancel_on: int,
}

@(private) cancel_once :: proc(data: rawptr) -> bool {
	state := cast(^One_Shot_Cancellation_State)data
	state.polls += 1
	return state.polls == state.cancel_on
}

@(private) service_view_callback :: proc(_: rdf.Term, data: rawptr) -> (dataset.View, bool) {
	return (cast(^dataset.View)data)^, true
}

@(test)
test_public_engine_exposes_callback_types_without_eval_imports :: proc(t: ^testing.T) {
	service_callback: engine.Service_Callback
	uuid_callback: engine.UUID_Callback
	rand_callback: engine.RAND_Callback
	testing.expect_value(t, service_callback == nil, true)
	testing.expect_value(t, uuid_callback == nil, true)
	testing.expect_value(t, rand_callback == nil, true)
}

@(test)
test_public_engine_execution_statistics_accumulate_without_eval_imports :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?friend { <urn:ada> <urn:knows> ?friend . <urn:ada> <urn:type> <urn:person> }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	source := External_Source{quads = []rdf.Quad{
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}),
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:type"), object = rdf.iri("urn:person")}),
	}}
	statistics := engine.Execution_Statistics{}
	view := dataset.custom_view(external_scan, &source)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8, Statistics = &statistics})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	testing.expect_value(t, engine.Row_Count(&result), 1)
	testing.expect_value(t, statistics.Dataset_Scans, u64(2))
	testing.expect_value(t, statistics.Dataset_Candidates >= u64(2), true)
	testing.expect_value(t, statistics.BGP_Matches >= u64(2), true)
	testing.expect_value(t, statistics.BGP_Solutions >= u64(1), true)
}

// External_Source deliberately owns no storage policy from odin-sparql. It is
// a minimal application-side adapter used to fix the public Scan_Proc contract.
@(private) External_Source :: struct {
	quads: []rdf.Quad,
	scans: int,
	stops: int,
}

@(private) external_term_equal :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value && strings.equal_fold(left.language, right.language) && left.datatype == right.datatype && left.scope == right.scope
}

@(private) external_matches :: proc(pattern: dataset.Quad_Pattern, quad: rdf.Quad) -> bool {
	#partial switch pattern.Graph_Mode {
	case .Default:
		if quad.has_graph do return false
	case .Named:
		if !quad.has_graph || !external_term_equal(pattern.Graph, quad.graph) do return false
	case .Any_Named:
		if !quad.has_graph do return false
	}
	return (!pattern.Has_Subject || external_term_equal(pattern.Subject, quad.subject)) &&
		(!pattern.Has_Predicate || external_term_equal(pattern.Predicate, quad.predicate)) &&
		(!pattern.Has_Object || external_term_equal(pattern.Object, quad.object))
}

@(private) external_scan :: proc(data: rawptr, pattern: dataset.Quad_Pattern, sink: dataset.Scan_Sink, sink_data: rawptr) -> dataset.Error_Code {
	source := cast(^External_Source)data
	source.scans += 1
	for quad in source.quads {
		if external_matches(pattern, quad) && !sink(quad, sink_data) {
			source.stops += 1
			break
		}
	}
	return .None
}

@(test)
test_public_engine_result_owns_selected_terms_after_query_and_dataset_destroy :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?name { <urn:ada> <urn:name> ?name }`)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:name"), object = rdf.literal("Ada")}
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8})
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	dataset.destroy(&store)
	sparql.Destroy(&query)
	defer engine.destroy(&result)

	testing.expect_value(t, engine.Kind(&result), engine.Result_Kind.Select)
	testing.expect_value(t, engine.Variable_Count(&result), 1)
	testing.expect_value(t, engine.Row_Count(&result), 1)
	name, name_ok := engine.Variable_Name(&result, 0)
	testing.expect_value(t, name_ok, true)
	testing.expect_value(t, name, "name")
	term, bound, cell_ok := engine.Cell(&result, 0, 0)
	testing.expect_value(t, cell_ok && bound, true)
	testing.expect_value(t, term.kind, rdf.Term_Kind.Literal)
	testing.expect_value(t, term.value, "Ada")
	_, _, missing_ok := engine.Cell(&result, 1, 0)
	testing.expect_value(t, missing_ok, false)
}

@(test)
test_public_result_serializers_remain_usable_after_query_and_dataset_destroy :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?name { <urn:ada> <urn:name> ?name }`)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:name"), object = rdf.literal("Ada")}
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8})
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	dataset.destroy(&store)
	sparql.Destroy(&query)
	defer engine.destroy(&result)

	json := strings.builder_make()
	defer strings.builder_destroy(&json)
	testing.expect_value(t, results.write_sparql_json(&json, &result), results.Error_Code.None)
	testing.expect_value(t, strings.to_string(json), `{"head":{"vars":["name"]},"results":{"bindings":[{"name":{"type":"literal","value":"Ada"}}]}}`)
	xml := strings.builder_make()
	defer strings.builder_destroy(&xml)
	testing.expect_value(t, results.write_sparql_xml(&xml, &result), results.Error_Code.None)
	testing.expect_value(t, strings.to_string(xml), `<?xml version="1.0"?><sparql xmlns="http://www.w3.org/2005/sparql-results#"><head><variable name="name"/></head><results><result><binding name="name"><literal>Ada</literal></binding></result></results></sparql>`)
	csv := strings.builder_make()
	defer strings.builder_destroy(&csv)
	testing.expect_value(t, results.write_sparql_csv(&csv, &result), results.Error_Code.None)
	testing.expect_value(t, strings.to_string(csv), "name\nAda\n")
	tsv := strings.builder_make()
	defer strings.builder_destroy(&tsv)
	testing.expect_value(t, results.write_sparql_tsv(&tsv, &result), results.Error_Code.None)
	testing.expect_value(t, strings.to_string(tsv), "?name\n\"Ada\"\n")
	not_graph := strings.builder_make()
	defer strings.builder_destroy(&not_graph)
	strings.write_string(&not_graph, "unchanged")
	testing.expect_value(t, results.write_ntriples(&not_graph, &result), results.Error_Code.Not_Graph_Result)
	testing.expect_value(t, strings.to_string(not_graph), "unchanged")
}

@(test)
test_public_result_serializers_leave_callers_output_unchanged_on_failure :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?value { <urn:source> <urn:value> ?value }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:source"), predicate = rdf.iri("urn:value"), object = rdf.literal("\x01")})
	testing.expect_value(t, dataset.add(&store, quad), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)

	output := strings.builder_make()
	defer strings.builder_destroy(&output)
	strings.write_string(&output, "unchanged")
	testing.expect_value(t, results.write_sparql_xml(&output, &result), results.Error_Code.Invalid_XML_Character)
	testing.expect_value(t, strings.to_string(output), "unchanged")
}

@(test)
test_public_graph_serializers_remain_usable_after_query_and_dataset_destroy :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`CONSTRUCT { ?person <urn:display-name> ?name } WHERE { ?person <urn:name> ?name }`)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:name"), object = rdf.literal("Ada")}
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8})
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	dataset.destroy(&store)
	sparql.Destroy(&query)
	defer engine.destroy(&result)

	ntriples := strings.builder_make()
	defer strings.builder_destroy(&ntriples)
	testing.expect_value(t, results.write_ntriples(&ntriples, &result), results.Error_Code.None)
	testing.expect_value(t, strings.to_string(ntriples), "<urn:ada> <urn:display-name> \"Ada\" .\n")
	turtle := strings.builder_make()
	defer strings.builder_destroy(&turtle)
	testing.expect_value(t, results.write_turtle(&turtle, &result), results.Error_Code.None)
	testing.expect_value(t, strings.to_string(turtle), "<urn:ada> <urn:display-name> \"Ada\" .\n")
	not_bindings := strings.builder_make()
	defer strings.builder_destroy(&not_bindings)
	strings.write_string(&not_bindings, "unchanged")
	testing.expect_value(t, results.write_sparql_json(&not_bindings, &result), results.Error_Code.Not_Bindings_Result)
	testing.expect_value(t, strings.to_string(not_bindings), "unchanged")
}

@(test)
test_public_engine_result_accessors_respect_query_form :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK {}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 1})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	testing.expect_value(t, engine.Kind(&result), engine.Result_Kind.Ask)
	value, ask_ok := engine.Ask_Value(&result)
	testing.expect_value(t, ask_ok, true)
	testing.expect_value(t, value, true)
	testing.expect_value(t, engine.Variable_Count(&result), 0)
	testing.expect_value(t, engine.Row_Count(&result), 0)
	_, _, cell_ok := engine.Cell(&result, 0, 0)
	testing.expect_value(t, cell_ok, false)
	_, triple_ok := engine.Triple(&result, 0)
	testing.expect_value(t, triple_ok, false)
}

@(test)
test_public_engine_rejects_invalid_options :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK {}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)

	zero_limit_result, zero_limit_error := engine.execute(&query, view, {})
	defer engine.destroy(&zero_limit_result)
	testing.expect_value(t, zero_limit_error, engine.Error_Code.Invalid_Options)
	testing.expect_value(t, engine.error_message(zero_limit_error), "execution options are invalid")
	invalid_clock_result, invalid_clock_error := engine.execute(&query, view, {Max_Solutions = 1, Now_Lexical = "not-a-date-time"})
	defer engine.destroy(&invalid_clock_result)
	testing.expect_value(t, invalid_clock_error, engine.Error_Code.Invalid_Options)

}

@(test)
test_public_engine_applies_describe_solution_modifiers_to_variable_targets :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`
		PREFIX : <urn:>
		DESCRIBE :ada ?target WHERE { ?target :rank ?rank }
		ORDER BY DESC(?rank) OFFSET 1 LIMIT 1
	`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	ada := rdf.iri("urn:ada")
	bert := rdf.iri("urn:bert")
	cora := rdf.iri("urn:cora")
	rank := rdf.iri("urn:rank")
	name := rdf.iri("urn:name")
	integer := "http://www.w3.org/2001/XMLSchema#integer"
	statements := []rdf.Triple{
		rdf.Triple{subject = ada, predicate = rank, object = rdf.typed_literal("1", integer)},
		rdf.Triple{subject = ada, predicate = name, object = rdf.literal("Ada")},
		rdf.Triple{subject = bert, predicate = rank, object = rdf.typed_literal("2", integer)},
		rdf.Triple{subject = bert, predicate = name, object = rdf.literal("Bert")},
		rdf.Triple{subject = cora, predicate = rank, object = rdf.typed_literal("3", integer)},
		rdf.Triple{subject = cora, predicate = name, object = rdf.literal("Cora")},
	}
	for statement in statements do testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	testing.expect_value(t, engine.Kind(&result), engine.Result_Kind.Graph)
	testing.expect_value(t, engine.Triple_Count(&result), 4)
	for index in 0..<engine.Triple_Count(&result) {
		triple, triple_ok := engine.Triple(&result, index)
		testing.expect_value(t, triple_ok, true)
		testing.expect_value(t, triple.subject.value == "urn:ada" || triple.subject.value == "urn:bert", true)
	}
}

@(test)
test_public_engine_reports_cancellation_as_a_distinct_error :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK {}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 1, Cancellation_Callback = cancel_immediately})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.Cancelled)
	testing.expect_value(t, engine.error_message(execute_error), "query execution was cancelled")
}

@(test)
test_public_engine_polls_cancellation_during_bgp_scan :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?name { <urn:ada> <urn:name> ?name }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:name"), object = rdf.literal("Ada")}
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	state := Cancellation_State{cancel_after = 6}
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8, Cancellation_Callback = cancel_after_polls, Cancellation_Data = &state})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.Cancelled)
	testing.expect_value(t, state.polls >= state.cancel_after, true)
}

@(test)
test_public_engine_cancellation_is_not_swallowed_by_service_silent :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?friend { SERVICE SILENT <urn:remote> { <urn:ada> <urn:knows> ?friend } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	local: dataset.Memory_Dataset
	dataset.init(&local)
	defer dataset.destroy(&local)
	dataset.seal(&local)
	local_view, local_view_error := dataset.view(&local)
	testing.expect_value(t, local_view_error, dataset.Error_Code.None)
	remote: dataset.Memory_Dataset
	dataset.init(&remote)
	defer dataset.destroy(&remote)
	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}
	testing.expect_value(t, dataset.add(&remote, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&remote)
	remote_view, remote_view_error := dataset.view(&remote)
	testing.expect_value(t, remote_view_error, dataset.Error_Code.None)
	state := Cancellation_State{cancel_after = 4}
	service_callback: engine.Service_Callback = service_view_callback
	result, execute_error := engine.execute(&query, local_view, {Max_Solutions = 8, Service_Callback = service_callback, Service_Data = &remote_view, Cancellation_Callback = cancel_after_polls, Cancellation_Data = &state})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.Cancelled)
	testing.expect_value(t, state.polls >= state.cancel_after, true)
}

@(test)
test_public_engine_latches_one_shot_cancellation_inside_exists :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person { ?person <urn:uses> ?endpoint FILTER EXISTS { ?person <urn:knows> ?friend } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:uses"), object = rdf.iri("urn:service")})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	state := One_Shot_Cancellation_State{cancel_on = 8}
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8, Cancellation_Callback = cancel_once, Cancellation_Data = &state})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.Cancelled)
	testing.expect_value(t, state.polls, state.cancel_on)
}

@(test)
test_public_engine_executes_against_application_scan_adapter :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { ?subject <urn:knows> ?friend }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	source := External_Source{quads = []rdf.Quad{
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}),
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:bert"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:cy")}),
	}}
	view := dataset.custom_view(external_scan, &source)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 1})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	value, ask_ok := engine.Ask_Value(&result)
	testing.expect_value(t, ask_ok && value, true)
	testing.expect_value(t, source.scans, 1)
	testing.expect_value(t, source.stops, 1)
}

@(test)
test_public_engine_application_scan_adapter_honors_named_graph_scope :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?friend { GRAPH <urn:people> { <urn:ada> <urn:knows> ?friend } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	source := External_Source{quads = []rdf.Quad{
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}),
		rdf.named_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:cy")}, rdf.iri("urn:people")),
	}}
	view := dataset.custom_view(external_scan, &source)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	testing.expect_value(t, engine.Row_Count(&result), 1)
	friend, bound, cell_ok := engine.Cell(&result, 0, 0)
	testing.expect_value(t, cell_ok && bound, true)
	testing.expect_value(t, friend.value, "urn:cy")
	testing.expect_value(t, source.scans, 2)
}

@(test)
test_public_engine_polls_cancellation_while_scanning_property_paths :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { <urn:ada> <urn:knows>+ ?friend }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	state := Cancellation_State{cancel_after = 5}
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 1, Cancellation_Callback = cancel_after_polls, Cancellation_Data = &state})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.Cancelled)
	testing.expect_value(t, state.polls, state.cancel_after)
}

@(test)
test_public_engine_cancels_aggregate_execution :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT (GROUP_CONCAT(?friend; separator=",") AS ?friends) { VALUES ?friend { "a" "b" "c" } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	state := Cancellation_State{cancel_after = 9}
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8, Cancellation_Callback = cancel_after_polls, Cancellation_Data = &state})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.Cancelled)
	testing.expect_value(t, state.polls >= state.cancel_after, true)
}
