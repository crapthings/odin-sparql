package eval

import "core:testing"
import rdf "odin-rdf:rdf"
import sparql ".."
import algebra "../algebra"
import dataset "../dataset"

@(private) add_default :: proc(t: ^testing.T, store: ^dataset.Memory_Dataset, subject, predicate, object: string) {
	quad := rdf.default_graph_quad(rdf.Triple{subject = rdf.iri(subject), predicate = rdf.iri(predicate), object = rdf.iri(object)})
	testing.expect_value(t, dataset.add(store, quad), dataset.Error_Code.None)
}

@(private) Recorded_Scans :: struct {
	source:     dataset.View,
	predicates: [dynamic]string,
}

@(private) record_scan :: proc(data: rawptr, pattern: dataset.Quad_Pattern, sink: dataset.Scan_Sink, sink_data: rawptr) -> dataset.Error_Code {
	recording := cast(^Recorded_Scans)data
	if pattern.Has_Predicate {
		_, append_error := append(&recording.predicates, pattern.Predicate.value)
		if append_error != nil do return .Out_Of_Memory
	}
	return dataset.scan(recording.source, pattern, sink, sink_data)
}

@(test)
test_evaluate_bgp_joins_and_owns_result_terms :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person ?friend {
		?person <urn:knows> ?friend . ?friend <urn:age> 42
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, plan_error := algebra.translate(&query)
	defer algebra.destroy(&plan)
	testing.expect_value(t, plan_error, algebra.Error_Code.None)

	store: dataset.Memory_Dataset
	dataset.init(&store)
	add_default(t, &store, "urn:ada", "urn:knows", "urn:bert")
	add_default(t, &store, "urn:ada", "urn:knows", "urn:cora")
	age := rdf.iri("urn:age")
	integer := "http://www.w3.org/2001/XMLSchema#integer"
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:bert"), predicate = age, object = rdf.typed_literal("42", integer)})), dataset.Error_Code.None)
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:cora"), predicate = age, object = rdf.typed_literal("42", integer)})), dataset.Error_Code.None)
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	result, eval_error := evaluate(&plan, view, Options{Max_Solutions = 8})
	defer destroy(&result)
	testing.expect_value(t, eval_error, Error_Code.None)
	testing.expect_value(t, Solution_Count(&result), 2)
	testing.expect_value(t, Variable_Count(&result), 2)
	person, person_ok := Variable_Name(&result, 0)
	friend, friend_ok := Variable_Name(&result, 1)
	testing.expect_value(t, person_ok, true)
	testing.expect_value(t, friend_ok, true)
	testing.expect_value(t, person, "person")
	testing.expect_value(t, friend, "friend")

	algebra.destroy(&plan)
	dataset.destroy(&store)
	term, bound, binding_ok := Solution_Binding(&result, 0, 0)
	testing.expect_value(t, binding_ok, true)
	testing.expect_value(t, bound, true)
	testing.expect_value(t, term.value, "urn:ada")
}

@(test)
test_statistics_and_opt_in_bgp_order_preserve_solutions :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person ?friend {
		?person <urn:knows> ?friend . ?friend <urn:age> 42 . ?person <urn:name> ?name
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, plan_error := algebra.translate(&query)
	defer algebra.destroy(&plan)
	testing.expect_value(t, plan_error, algebra.Error_Code.None)
	root, root_ok := algebra.Root_Operator(&plan)
	testing.expect_value(t, root_ok, true)
	root_operator, root_operator_ok := algebra.Operator_At(&plan, root)
	testing.expect_value(t, root_operator_ok, true)
	testing.expect_value(t, root_operator.Kind, algebra.Operator_Kind.BGP)
	testing.expect_value(t, root_operator.Triple_Count, 3)
	expected_predicates := [3]string{"urn:knows", "urn:age", "urn:name"}
	for expected_predicate, index in expected_predicates {
		triple, triple_ok := algebra.Triple(&plan, index)
		testing.expect_value(t, triple_ok, true)
		testing.expect_value(t, triple.Predicate.Term.value, expected_predicate)
	}
	planned_order, reordered, order_error := build_bgp_order(&plan, root_operator.First_Triple, root_operator.Triple_Count)
	defer delete(planned_order)
	testing.expect_value(t, order_error, Error_Code.None)
	testing.expect_value(t, reordered, true)
	if len(planned_order) == 3 {
		testing.expect_value(t, planned_order[0], 1)
		testing.expect_value(t, planned_order[1], 0)
		testing.expect_value(t, planned_order[2], 2)
	}
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_default(t, &store, "urn:ada", "urn:knows", "urn:bert")
	add_default(t, &store, "urn:ada", "urn:knows", "urn:cora")
	age := rdf.iri("urn:age")
	integer := "http://www.w3.org/2001/XMLSchema#integer"
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:bert"), predicate = age, object = rdf.typed_literal("42", integer)})), dataset.Error_Code.None)
	add_default(t, &store, "urn:ada", "urn:name", "ada")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	source_statistics := Execution_Statistics{}
	source, source_error := evaluate(&plan, view, Options{Max_Solutions = 8, Statistics = &source_statistics})
	defer destroy(&source)
	testing.expect_value(t, source_error, Error_Code.None)
	recording := Recorded_Scans{source = view, predicates = make([dynamic]string)}
	defer delete(recording.predicates)
	recorded_view := dataset.custom_view(record_scan, &recording)
	optimized_statistics := Execution_Statistics{}
	optimized, optimized_error := evaluate(&plan, recorded_view, Options{Max_Solutions = 8, Optimize_BGP = true, Statistics = &optimized_statistics})
	defer destroy(&optimized)
	testing.expect_value(t, optimized_error, Error_Code.None)
	testing.expect_value(t, Solution_Count(&source), 1)
	testing.expect_value(t, Solution_Count(&optimized), 1)
	testing.expect_value(t, source_statistics.BGP_Reorders, u64(0))
	testing.expect_value(t, optimized_statistics.BGP_Reorders, u64(1))
	testing.expect_value(t, optimized_statistics.Dataset_Scans, u64(3))
	testing.expect_value(t, optimized_statistics.Dataset_Candidates, u64(3))
	testing.expect_value(t, optimized_statistics.BGP_Matches, u64(3))
	testing.expect_value(t, optimized_statistics.BGP_Solutions, u64(1))
	testing.expect_value(t, len(recording.predicates), 3)
	if len(recording.predicates) == 3 {
		testing.expect_value(t, recording.predicates[0], "urn:age")
		testing.expect_value(t, recording.predicates[1], "urn:knows")
		testing.expect_value(t, recording.predicates[2], "urn:name")
	}
}

@(test)
test_optimize_bgp_accepts_an_already_preferred_source_order :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?person ?friend {
		?friend <urn:age> 42 . ?person <urn:knows> ?friend
	}`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, plan_error := algebra.translate(&query)
	defer algebra.destroy(&plan)
	testing.expect_value(t, plan_error, algebra.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	integer := "http://www.w3.org/2001/XMLSchema#integer"
	testing.expect_value(t, dataset.add(&store, rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:bert"), predicate = rdf.iri("urn:age"), object = rdf.typed_literal("42", integer)})), dataset.Error_Code.None)
	add_default(t, &store, "urn:ada", "urn:knows", "urn:bert")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)
	statistics := Execution_Statistics{}
	result, evaluate_error := evaluate(&plan, view, Options{Max_Solutions = 8, Optimize_BGP = true, Statistics = &statistics})
	defer destroy(&result)
	testing.expect_value(t, evaluate_error, Error_Code.None)
	testing.expect_value(t, statistics.BGP_Reorders, u64(0))
	testing.expect_value(t, Solution_Count(&result), 1)
}

@(test)
test_evaluate_requires_a_bound_and_reports_overflow :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?object { <urn:subject> <urn:predicate> ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, plan_error := algebra.translate(&query)
	defer algebra.destroy(&plan)
	testing.expect_value(t, plan_error, algebra.Error_Code.None)
	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	add_default(t, &store, "urn:subject", "urn:predicate", "urn:one")
	add_default(t, &store, "urn:subject", "urn:predicate", "urn:two")
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	testing.expect_value(t, view_error, dataset.Error_Code.None)

	_, invalid_options := evaluate(&plan, view, {})
	testing.expect_value(t, invalid_options, Error_Code.Invalid_Options)
	_, limit_error := evaluate(&plan, view, Options{Max_Solutions = 1})
	testing.expect_value(t, limit_error, Error_Code.Solution_Limit)
}

@(test)
test_exact_integer_and_decimal_value_equality :: proc(t: ^testing.T) {
	equal, equal_ok := decimal_equal("00000000000000000000000000000000000042", "+42", false, false)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, true)
	equal, equal_ok = decimal_equal("-00000000000000000000000000000000000042", "-42.000", false, true)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, true)
	equal, equal_ok = decimal_equal("-0", "+.000", false, true)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, true)
	equal, equal_ok = decimal_equal("00000000000000000000000000000000000042", "43.0", false, true)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, false)
	equal, equal_ok = decimal_equal("12", "1.2", false, true)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, false)
	equal, equal_ok = decimal_equal("100", "1", false, false)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, false)
	_, malformed_ok := decimal_equal("42", "4.2.0", false, true)
	testing.expect_value(t, malformed_ok, false)

	integer := rdf.typed_literal("00000000000000000000000000000000000042", XSD_INTEGER)
	decimal := rdf.typed_literal("42.000", XSD_DECIMAL)
	equal, equal_ok = sparql_value_equal(integer, decimal)
	testing.expect_value(t, equal_ok, true)
	testing.expect_value(t, equal, true)
}

@(test)
test_exact_integer_and_decimal_value_ordering :: proc(t: ^testing.T) {
	comparison, comparison_ok := decimal_compare("12", "1.2", false, true)
	testing.expect_value(t, comparison_ok, true)
	testing.expect_value(t, comparison, 1)
	comparison, comparison_ok = decimal_compare("-123.4500", "-123.449", true, true)
	testing.expect_value(t, comparison_ok, true)
	testing.expect_value(t, comparison, -1)
	comparison, comparison_ok = decimal_compare("0.00120", "+.0012", true, true)
	testing.expect_value(t, comparison_ok, true)
	testing.expect_value(t, comparison, 0)
	comparison, comparison_ok = decimal_compare("100000000000000000000", "99999999999999999999.9", false, true)
	testing.expect_value(t, comparison_ok, true)
	testing.expect_value(t, comparison, 1)
}
