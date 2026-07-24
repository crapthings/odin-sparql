package graph_dataset

import "core:testing"
import rdf "odin-rdf:rdf"
import sparql "odin-sparql:sparql"
import dataset "odin-sparql:sparql/dataset"
import engine "odin-sparql:sparql/engine"

@(private) Scan_State :: struct { count: int }

@(private) count_quad :: proc(_: rdf.Quad, user_data: rawptr) -> bool {
	(cast(^Scan_State)user_data).count += 1
	return true
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
	testing.expect_value(t, add(&store, rdf.named_graph_quad(rdf.Triple{rdf.iri("urn:graph-dataset:ada"), rdf.iri("urn:graph-dataset:knows"), rdf.iri("urn:graph-dataset:bea")}, rdf.iri("urn:graph-dataset:source"))), dataset.Error_Code.None)
	seal(&store)
	view, view_error := view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	query, parse_error := sparql.Parse(`SELECT ?friend { GRAPH <urn:graph-dataset:source> { <urn:graph-dataset:ada> <urn:graph-dataset:knows> ?friend } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 4})
	defer engine.destroy(&result)
	testing.expect_value(t, execute_error, engine.Error_Code.None)
	testing.expect_value(t, engine.Row_Count(&result), 1)
	friend, bound, valid := engine.Cell(&result, 0, 0)
	testing.expect(t, valid && bound)
	testing.expect_value(t, friend.value, "urn:graph-dataset:bea")
}
