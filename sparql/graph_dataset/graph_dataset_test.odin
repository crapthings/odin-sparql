package graph_dataset

import "core:testing"
import rdf "odin-rdf:rdf"
import rdf_dataset "odin-rdf:rdf/dataset"
import sparql "odin-sparql:sparql"
import dataset "odin-sparql:sparql/dataset"
import engine "odin-sparql:sparql/engine"

@(private) Scan_State :: struct {
	count: int,
	stop:  bool,
}

@(private) count_quad :: proc(_: rdf.Quad, user_data: rawptr) -> bool {
	(cast(^Scan_State)user_data).count += 1
	return !(cast(^Scan_State)user_data).stop
}

@(private) scan_count :: proc(t: ^testing.T, view: dataset.View, pattern: dataset.Quad_Pattern, stop: bool = false) -> int {
	state := Scan_State{stop = stop}
	testing.expect_value(t, dataset.scan(view, pattern, count_quad, &state), dataset.Error_Code.None)
	return state.count
}

@(test)
test_graph_dataset_matches_memory_dataset_public_contract :: proc(t: ^testing.T) {
	first_scope := rdf.new_blank_node_scope()
	second_scope := rdf.new_blank_node_scope()
	predicate := rdf.iri("urn:graph-dataset:knows")
	first := rdf.default_graph_quad(rdf.Triple{rdf.blank_node("same", first_scope), predicate, rdf.language_literal("value", "EN")})
	same_identity := rdf.default_graph_quad(rdf.Triple{rdf.blank_node("same", first_scope), predicate, rdf.language_literal("value", "en")})
	second := rdf.named_graph_quad(rdf.Triple{rdf.blank_node("same", second_scope), predicate, rdf.iri("urn:graph-dataset:cy")}, rdf.iri("urn:graph-dataset:source"))
	third := rdf.default_graph_quad(rdf.Triple{rdf.iri("urn:graph-dataset:other"), predicate, rdf.iri("urn:graph-dataset:bea")})

	memory: dataset.Memory_Dataset
	graph_store: Dataset
	testing.expect_value(t, dataset.init_with_options(&memory, {Max_Quads = 2, Max_Lexical_Bytes = 256}), dataset.Error_Code.None)
	defer dataset.destroy(&memory)
	testing.expect_value(t, init(&graph_store, {Max_Quads = 2, Max_Lexical_Bytes = 256}), dataset.Error_Code.None)
	defer destroy(&graph_store)

	_, memory_before_seal := dataset.view(&memory)
	_, graph_before_seal := view(&graph_store)
	testing.expect_value(t, graph_before_seal, memory_before_seal)
	values := [4]rdf.Quad{first, same_identity, second, third}
	for value in values {
		memory_error := dataset.add(&memory, value)
		graph_error := add(&graph_store, value)
		testing.expect_value(t, graph_error, memory_error)
		testing.expect_value(t, quad_count(&graph_store), dataset.quad_count(&memory))
	}

	dataset.seal(&memory)
	seal(&graph_store)
	memory_view, memory_view_error := dataset.view(&memory)
	graph_view, graph_view_error := view(&graph_store)
	testing.expect_value(t, graph_view_error, memory_view_error)
	testing.expect_value(t, scan_count(t, graph_view, {}), scan_count(t, memory_view, {}))
	testing.expect_value(t, scan_count(t, graph_view, {Graph_Mode = .Any_Named}), scan_count(t, memory_view, {Graph_Mode = .Any_Named}))
	first_pattern := dataset.Quad_Pattern{Has_Subject = true, Subject = rdf.blank_node("same", first_scope)}
	testing.expect_value(t, scan_count(t, graph_view, first_pattern), scan_count(t, memory_view, first_pattern))
	testing.expect_value(t, scan_count(t, graph_view, {}, true), scan_count(t, memory_view, {}, true))
	testing.expect_value(t, add(&graph_store, third), dataset.add(&memory, third))
}

@(test)
test_graph_dataset_matches_memory_dataset_option_errors_and_lexical_limit :: proc(t: ^testing.T) {
	invalid_memory: dataset.Memory_Dataset
	invalid_graph: Dataset
	testing.expect_value(t, init(&invalid_graph, {Max_Quads = -1}), dataset.init_with_options(&invalid_memory, {Max_Quads = -1}))
	defer dataset.destroy(&invalid_memory)
	defer destroy(&invalid_graph)

	memory: dataset.Memory_Dataset
	graph_store: Dataset
	testing.expect_value(t, dataset.init_with_options(&memory, {Max_Lexical_Bytes = 80}), dataset.Error_Code.None)
	defer dataset.destroy(&memory)
	testing.expect_value(t, init(&graph_store, {Max_Lexical_Bytes = 80}), dataset.Error_Code.None)
	defer destroy(&graph_store)
	first := rdf.default_graph_quad(rdf.Triple{rdf.iri("urn:a"), rdf.iri("urn:p"), rdf.literal("first")})
	second := rdf.default_graph_quad(rdf.Triple{rdf.iri("urn:b"), rdf.iri("urn:p"), rdf.literal("second")})
	values := [3]rdf.Quad{first, first, second}
	for value in values {
		memory_error := dataset.add(&memory, value)
		graph_error := add(&graph_store, value)
		testing.expect_value(t, graph_error, memory_error)
		testing.expect_value(t, quad_count(&graph_store), dataset.quad_count(&memory))
	}
}

@(test)
test_graph_dataset_matches_memory_dataset_collector_ingestion :: proc(t: ^testing.T) {
	collector: rdf_dataset.Collector
	testing.expect_value(t, rdf_dataset.init(&collector), rdf_dataset.Error_Code.None)
	defer rdf_dataset.destroy(&collector)
	statement := rdf.Triple{rdf.iri("urn:graph-dataset:collector-subject"), rdf.iri("urn:graph-dataset:collector-predicate"), rdf.literal("value")}
	default_quad := rdf.default_graph_quad(statement)
	named_quad := rdf.named_graph_quad(statement, rdf.iri("urn:graph-dataset:collector-graph"))
	testing.expect_value(t, rdf_dataset.add(&collector, default_quad), rdf_dataset.Error_Code.None)
	testing.expect_value(t, rdf_dataset.add(&collector, default_quad), rdf_dataset.Error_Code.None)
	testing.expect_value(t, rdf_dataset.add(&collector, named_quad), rdf_dataset.Error_Code.None)

	memory: dataset.Memory_Dataset
	graph_store: Dataset
	dataset.init(&memory)
	defer dataset.destroy(&memory)
	testing.expect_value(t, init(&graph_store), dataset.Error_Code.None)
	defer destroy(&graph_store)
	testing.expect_value(t, add_collector(&graph_store, &collector), dataset.add_collector(&memory, &collector))
	testing.expect_value(t, quad_count(&graph_store), dataset.quad_count(&memory))
	dataset.seal(&memory)
	seal(&graph_store)
	memory_view, memory_view_error := dataset.view(&memory)
	graph_view, graph_view_error := view(&graph_store)
	testing.expect_value(t, graph_view_error, memory_view_error)
	testing.expect_value(t, scan_count(t, graph_view, {}), scan_count(t, memory_view, {}))
	testing.expect_value(t, scan_count(t, graph_view, {Graph_Mode = .Any_Named}), scan_count(t, memory_view, {Graph_Mode = .Any_Named}))
	testing.expect_value(t, add_collector(&graph_store, &collector), dataset.add_collector(&memory, &collector))
}

@(test)
test_graph_dataset_matches_memory_dataset_set_scope_and_limits :: proc(t: ^testing.T) {
	store: Dataset
	testing.expect_value(t, init(&store, {Max_Quads = 2}), dataset.Error_Code.None)
	defer destroy(&store)
	predicate := rdf.iri("urn:graph-dataset:knows")
	default_quad := rdf.default_graph_quad(rdf.Triple{rdf.iri("urn:graph-dataset:ada"), predicate, rdf.iri("urn:graph-dataset:bea")})
	named_quad := rdf.named_graph_quad(rdf.Triple{rdf.iri("urn:graph-dataset:ada"), predicate, rdf.iri("urn:graph-dataset:cy")}, rdf.iri("urn:graph-dataset:source"))
	third_quad := rdf.default_graph_quad(rdf.Triple{rdf.iri("urn:graph-dataset:bea"), predicate, rdf.iri("urn:graph-dataset:cy")})
	testing.expect_value(t, add(&store, default_quad), dataset.Error_Code.None)
	testing.expect_value(t, add(&store, named_quad), dataset.Error_Code.None)
	testing.expect_value(t, add(&store, default_quad), dataset.Error_Code.None)
	testing.expect_value(t, quad_count(&store), 2)
	testing.expect_value(t, add(&store, third_quad), dataset.Error_Code.Quad_Limit)
	testing.expect_value(t, quad_count(&store), 2)

	seal(&store)
	view, view_error := view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	default_matches: Scan_State
	testing.expect_value(t, dataset.scan(view, {}, count_quad, &default_matches), dataset.Error_Code.None)
	testing.expect_value(t, default_matches.count, 1)
	named_matches: Scan_State
	testing.expect_value(t, dataset.scan(view, {Graph_Mode = .Any_Named}, count_quad, &named_matches), dataset.Error_Code.None)
	testing.expect_value(t, named_matches.count, 1)
	testing.expect_value(t, add(&store, third_quad), dataset.Error_Code.Sealed)
}

@(test)
test_graph_dataset_executes_named_graph_query_through_public_engine :: proc(t: ^testing.T) {
	store: Dataset
	testing.expect_value(t, init(&store), dataset.Error_Code.None)
	defer destroy(&store)
	memory: dataset.Memory_Dataset
	dataset.init(&memory)
	defer dataset.destroy(&memory)
	quad := rdf.named_graph_quad(rdf.Triple{rdf.iri("urn:graph-dataset:ada"), rdf.iri("urn:graph-dataset:knows"), rdf.iri("urn:graph-dataset:bea")}, rdf.iri("urn:graph-dataset:source"))
	testing.expect_value(t, add(&store, quad), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&memory, quad), dataset.Error_Code.None)
	seal(&store)
	dataset.seal(&memory)
	graph_view, graph_view_error := view(&store)
	testing.expect_value(t, graph_view_error, dataset.Error_Code.None)
	memory_view, memory_view_error := dataset.view(&memory)
	testing.expect_value(t, memory_view_error, dataset.Error_Code.None)
	query, parse_error := sparql.Parse(`SELECT ?friend { GRAPH <urn:graph-dataset:source> { <urn:graph-dataset:ada> <urn:graph-dataset:knows> ?friend } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	graph_result, graph_execute_error := engine.execute(&query, graph_view, {Max_Solutions = 4})
	defer engine.destroy(&graph_result)
	memory_result, memory_execute_error := engine.execute(&query, memory_view, {Max_Solutions = 4})
	defer engine.destroy(&memory_result)
	testing.expect_value(t, graph_execute_error, memory_execute_error)
	testing.expect_value(t, engine.Row_Count(&graph_result), engine.Row_Count(&memory_result))
	testing.expect_value(t, engine.Row_Count(&graph_result), 1)
	graph_friend, graph_bound, graph_valid := engine.Cell(&graph_result, 0, 0)
	memory_friend, memory_bound, memory_valid := engine.Cell(&memory_result, 0, 0)
	testing.expect(t, graph_valid && graph_bound && memory_valid && memory_bound)
	testing.expect_value(t, graph_friend, memory_friend)
	testing.expect_value(t, graph_friend.value, "urn:graph-dataset:bea")
}
