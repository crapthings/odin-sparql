package property

import "core:testing"
import rdf "odin-rdf:rdf"
import sparql "../../sparql"
import dataset "../../sparql/dataset"
import engine "../../sparql/engine"

PROPERTY_SEEDS :: 32
PROPERTY_EDGES :: 30

QUERY :: `SELECT ?a ?b ?c {
	?a <urn:property:p0> ?b .
	?b <urn:property:p1> <urn:property:node:0> .
	?a <urn:property:p2> ?c
}`

@(private) next_random :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407
	return state^
}

@(private) equal_term :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value && left.language == right.language && left.datatype == right.datatype && left.scope == right.scope
}

@(private) equal_row :: proc(left, right: ^engine.Result, left_row, right_row: int) -> bool {
	if engine.Variable_Count(left) != engine.Variable_Count(right) do return false
	for column in 0..<engine.Variable_Count(left) {
		left_term, left_bound, left_ok := engine.Cell(left, left_row, column)
		right_term, right_bound, right_ok := engine.Cell(right, right_row, column)
		if !left_ok || !right_ok || left_bound != right_bound do return false
		if left_bound && !equal_term(left_term, right_term) do return false
	}
	return true
}

@(private) equal_result_multiset :: proc(left, right: ^engine.Result) -> bool {
	if engine.Variable_Count(left) != engine.Variable_Count(right) || engine.Row_Count(left) != engine.Row_Count(right) do return false
	matched := make([dynamic]bool)
	defer delete(matched)
	for _ in 0..<engine.Row_Count(right) {
		if _, append_error := append(&matched, false); append_error != nil do return false
	}
	for left_row in 0..<engine.Row_Count(left) {
		found := false
		for right_row in 0..<engine.Row_Count(right) {
			if !matched[right_row] && equal_row(left, right, left_row, right_row) {
				matched[right_row] = true
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

@(private) add_quad :: proc(t: ^testing.T, store: ^dataset.Memory_Dataset, subject, predicate, object: string) {
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri(subject), predicate = rdf.iri(predicate), object = rdf.iri(object)})
	testing.expect_value(t, dataset.add(store, quad), dataset.Error_Code.None)
}

@(test)
test_opt_in_bgp_order_preserves_deterministic_generated_multisets :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(QUERY)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	nodes := [5]string{
		"urn:property:node:0",
		"urn:property:node:1",
		"urn:property:node:2",
		"urn:property:node:3",
		"urn:property:node:4",
	}
	predicates := [3]string{"urn:property:p0", "urn:property:p1", "urn:property:p2"}
	for seed in 1..=PROPERTY_SEEDS {
		state := u64(seed)
		store: dataset.Memory_Dataset
		dataset.init(&store)
		for _ in 0..<PROPERTY_EDGES {
			subject := nodes[int(next_random(&state) % u64(len(nodes)))]
			predicate := predicates[int(next_random(&state) % u64(len(predicates)))]
			object := nodes[int(next_random(&state) % u64(len(nodes)))]
			add_quad(t, &store, subject, predicate, object)
		}
		dataset.seal(&store)
		view, view_error := dataset.view(&store)
		testing.expect_value(t, view_error, dataset.Error_Code.None)
		source, source_error := engine.execute(&query, view, {Max_Solutions = 256})
		testing.expect_value(t, source_error, engine.Error_Code.None)
		optimized, optimized_error := engine.execute(&query, view, {Max_Solutions = 256, Optimize_BGP = true})
		testing.expect_value(t, optimized_error, engine.Error_Code.None)
		testing.expect_value(t, equal_result_multiset(&source, &optimized), true)
		engine.destroy(&optimized)
		engine.destroy(&source)
		dataset.destroy(&store)
	}
}
