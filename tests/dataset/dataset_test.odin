package dataset_test

import "core:testing"
import rdf "odin-rdf:rdf"
import rdf_dataset "odin-rdf:rdf/dataset"
import dataset "../../sparql/dataset"

Scan_State :: struct {
	count: int,
	stop:  bool,
}

count_sink :: proc(_: rdf.Quad, data: rawptr) -> bool {
	state := cast(^Scan_State)data
	state.count += 1
	return !state.stop
}

@(test)
test_dataset_scan_rejects_invalid_view_and_sink_without_misreporting_sealed :: proc(t: ^testing.T) {
	state := Scan_State{}
	testing.expect_value(t, dataset.scan(dataset.View{}, {}, count_sink, &state), dataset.Error_Code.Invalid_View)

	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	testing.expect_value(t, dataset.scan(view, {}, nil), dataset.Error_Code.Invalid_Sink)
}

@(test)
test_memory_dataset_is_a_set_and_scans_default_graph :: proc(t: ^testing.T) {
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)

	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}
	default_quad := rdf.default_graph_quad(statement)
	named_quad := rdf.named_graph_quad(statement, rdf.iri("urn:graph"))
	testing.expect_value(t, dataset.add(&store, default_quad), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, default_quad), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, named_quad), dataset.Error_Code.None)
	testing.expect_value(t, dataset.quad_count(&store), 2)

	_, before_seal := dataset.view(&store)
	testing.expect_value(t, before_seal, dataset.Error_Code.Sealed)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:other"), predicate = rdf.iri("urn:p"), object = rdf.iri("urn:o")})), dataset.Error_Code.Sealed)

	all := Scan_State{}
	testing.expect_value(t, dataset.scan(view, {}, count_sink, &all), dataset.Error_Code.None)
	testing.expect_value(t, all.count, 1)

	matching := Scan_State{}
	pattern := dataset.Quad_Pattern{Has_Predicate = true, Predicate = rdf.iri("urn:knows")}
	testing.expect_value(t, dataset.scan(view, pattern, count_sink, &matching), dataset.Error_Code.None)
	testing.expect_value(t, matching.count, 1)
}

@(test)
test_memory_dataset_optional_quad_limit_preserves_set_and_lifecycle_semantics :: proc(t: ^testing.T) {
	store: dataset.Memory_Dataset
	testing.expect_value(t, dataset.init_with_options(&store, {Max_Quads = 1}), dataset.Error_Code.None)
	defer dataset.destroy(&store)

	first := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:first"), predicate = rdf.iri("urn:predicate"), object = rdf.iri("urn:object")})
	second := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:second"), predicate = rdf.iri("urn:predicate"), object = rdf.iri("urn:object")})
	testing.expect_value(t, dataset.add(&store, first), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, first), dataset.Error_Code.None)
	testing.expect_value(t, dataset.quad_count(&store), 1)
	testing.expect_value(t, dataset.add(&store, second), dataset.Error_Code.Quad_Limit)
	testing.expect_value(t, dataset.quad_count(&store), 1)

	dataset.seal(&store)
	testing.expect_value(t, dataset.add(&store, second), dataset.Error_Code.Sealed)
}

@(test)
test_memory_dataset_rejects_negative_quad_limit_without_initializing_storage :: proc(t: ^testing.T) {
	quad_store: dataset.Memory_Dataset
	testing.expect_value(t, dataset.init_with_options(&quad_store, {Max_Quads = -1}), dataset.Error_Code.Invalid_Options)
	defer dataset.destroy(&quad_store)
	lexical_store: dataset.Memory_Dataset
	testing.expect_value(t, dataset.init_with_options(&lexical_store, {Max_Lexical_Bytes = -1}), dataset.Error_Code.Invalid_Options)
	defer dataset.destroy(&lexical_store)
	testing.expect_value(t, dataset.error_message(.Invalid_Options), "dataset options are invalid")
	testing.expect_value(t, dataset.error_message(.Quad_Limit), "dataset quad limit reached")
	testing.expect_value(t, dataset.error_message(.Lexical_Limit), "dataset lexical byte limit reached")
}

@(test)
test_memory_dataset_optional_lexical_byte_limit_rejects_new_quad_without_mutation :: proc(t: ^testing.T) {
	store: dataset.Memory_Dataset
	testing.expect_value(t, dataset.init_with_options(&store, {Max_Lexical_Bytes = 80}), dataset.Error_Code.None)
	defer dataset.destroy(&store)

	first := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:a"), predicate = rdf.iri("urn:p"), object = rdf.literal("first")})
	second := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:b"), predicate = rdf.iri("urn:p"), object = rdf.literal("second")})
	testing.expect_value(t, dataset.add(&store, first), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, first), dataset.Error_Code.None)
	testing.expect_value(t, dataset.quad_count(&store), 1)
	testing.expect_value(t, dataset.add(&store, second), dataset.Error_Code.Lexical_Limit)
	testing.expect_value(t, dataset.quad_count(&store), 1)
}

@(test)
test_memory_dataset_scans_specific_and_any_named_graphs :: proc(t: ^testing.T) {
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)

	statement := rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}
	testing.expect_value(t, dataset.add(&store, rdf.named_graph_quad(statement, rdf.iri("urn:one"))), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.named_graph_quad(statement, rdf.iri("urn:two"))), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(statement)), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)

	specific := Scan_State{}
	specific_pattern := dataset.Quad_Pattern{Graph_Mode = .Named, Graph = rdf.iri("urn:one")}
	testing.expect_value(t, dataset.scan(view, specific_pattern, count_sink, &specific), dataset.Error_Code.None)
	testing.expect_value(t, specific.count, 1)

	any_named := Scan_State{}
	testing.expect_value(t, dataset.scan(view, dataset.Quad_Pattern{Graph_Mode = .Any_Named}, count_sink, &any_named), dataset.Error_Code.None)
	testing.expect_value(t, any_named.count, 2)
}

@(test)
test_memory_dataset_scan_honors_sink_cancellation :: proc(t: ^testing.T) {
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	objects := [2]string{"urn:one", "urn:two"}
	for object in objects {
		quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:subject"), predicate = rdf.iri("urn:predicate"), object = rdf.iri(object)})
		testing.expect_value(t, dataset.add(&store, quad), dataset.Error_Code.None)
	}
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	state := Scan_State{stop = true}
	testing.expect_value(t, dataset.scan(view, {}, count_sink, &state), dataset.Error_Code.None)
	testing.expect_value(t, state.count, 1)
}

@(test)
test_memory_dataset_triple_sink_copies_parser_callback_values :: proc(t: ^testing.T) {
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	statement := rdf.Triple{subject = rdf.iri("urn:subject"), predicate = rdf.iri("urn:predicate"), object = rdf.literal("value")}
	testing.expect_value(t, dataset.triple_sink(statement, &store), true)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	state := Scan_State{}
	testing.expect_value(t, dataset.scan(view, {}, count_sink, &state), dataset.Error_Code.None)
	testing.expect_value(t, state.count, 1)
}

@(test)
test_memory_dataset_add_collector_copies_and_deduplicates_quads :: proc(t: ^testing.T) {
	collector: rdf_dataset.Collector
	testing.expect_value(t, rdf_dataset.init(&collector), rdf_dataset.Error_Code.None)
	defer rdf_dataset.destroy(&collector)

	statement := rdf.Triple{subject = rdf.iri("urn:collector:subject"), predicate = rdf.iri("urn:collector:predicate"), object = rdf.literal("value")}
	default_quad := rdf.default_graph_quad(statement)
	named_quad := rdf.named_graph_quad(statement, rdf.iri("urn:collector:graph"))
	testing.expect_value(t, rdf_dataset.add(&collector, default_quad), rdf_dataset.Error_Code.None)
	testing.expect_value(t, rdf_dataset.add(&collector, default_quad), rdf_dataset.Error_Code.None)
	testing.expect_value(t, rdf_dataset.add(&collector, named_quad), rdf_dataset.Error_Code.None)

	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	testing.expect_value(t, dataset.add_collector(&store, &collector), dataset.Error_Code.None)
	testing.expect_value(t, dataset.quad_count(&store), 2)
	dataset.seal(&store)
	testing.expect_value(t, dataset.add_collector(&store, &collector), dataset.Error_Code.Sealed)

	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	all := Scan_State{}
	testing.expect_value(t, dataset.scan(view, {}, count_sink, &all), dataset.Error_Code.None)
	testing.expect_value(t, all.count, 1)
	named := Scan_State{}
	testing.expect_value(t, dataset.scan(view, dataset.Quad_Pattern{Graph_Mode = .Any_Named}, count_sink, &named), dataset.Error_Code.None)
	testing.expect_value(t, named.count, 1)
}
