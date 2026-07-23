package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import rdf "odin-rdf:rdf"
import sparql "../../sparql"
import dataset "../../sparql/dataset"
import engine "../../sparql/engine"

RECORDS :: #config(BENCH_RECORDS, 1_000)
ROUNDS  :: #config(BENCH_ROUNDS, 3)

KNOWS  :: "urn:odin-sparql:benchmark:knows"
KIND   :: "urn:odin-sparql:benchmark:kind"
NAME   :: "urn:odin-sparql:benchmark:name"
TARGET :: "urn:odin-sparql:benchmark:target"
FIXED_NOW :: "2000-01-01T00:00:00Z"

QUERY :: `SELECT ?entity {
	?entity <urn:odin-sparql:benchmark:knows> ?friend .
	?friend <urn:odin-sparql:benchmark:kind> <urn:odin-sparql:benchmark:target> .
	?entity <urn:odin-sparql:benchmark:name> ?name
}`

fatal :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

add_quad :: proc(store: ^dataset.Memory_Dataset, subject, predicate, object: rdf.Term) {
	if dataset.add(store, rdf.default_graph_quad(rdf.Triple{subject = subject, predicate = predicate, object = object})) != .None do fatal("benchmark dataset construction failed")
}

append_indexed_iri :: proc(builder: ^strings.Builder, prefix: string, index: int) -> rdf.Term {
	strings.write_string(builder, prefix)
	strings.write_int(builder, index)
	return rdf.iri(strings.to_string(builder^))
}

make_dataset :: proc() -> dataset.Memory_Dataset {
	store: dataset.Memory_Dataset
	dataset.init(&store)
	entity_builder := strings.builder_make()
	defer strings.builder_destroy(&entity_builder)
	friend_builder := strings.builder_make()
	defer strings.builder_destroy(&friend_builder)
	for index in 0..<RECORDS {
		entity := append_indexed_iri(&entity_builder, "urn:odin-sparql:benchmark:entity:", index)
		strings.builder_reset(&entity_builder)
		friend := append_indexed_iri(&friend_builder, "urn:odin-sparql:benchmark:friend:", index)
		strings.builder_reset(&friend_builder)
		add_quad(&store, entity, rdf.iri(KNOWS), friend)
		add_quad(&store, entity, rdf.iri(NAME), rdf.literal("candidate"))
	}
	add_quad(&store, rdf.iri("urn:odin-sparql:benchmark:friend:0"), rdf.iri(KIND), rdf.iri(TARGET))
	dataset.seal(&store)
	return store
}

run_case :: proc(query: ^sparql.Query, view: dataset.View, optimize: bool) -> (seconds: f64, statistics: engine.Execution_Statistics) {
	started := time.now()
	max_solutions := RECORDS + 1
	result, execute_error := engine.execute(query, view, {
		Max_Solutions      = max_solutions,
		Max_Numeric_Digits = 32,
		Now_Lexical        = FIXED_NOW,
		Optimize_BGP       = optimize,
		Statistics         = &statistics,
	})
	seconds = time.duration_seconds(time.since(started))
	defer engine.destroy(&result)
	if execute_error != .None {
		fmt.eprintln("benchmark query execution failed:", engine.error_message(execute_error), "(max solutions:", max_solutions, ")")
		os.exit(1)
	}
	if engine.Row_Count(&result) != 1 do fatal("benchmark query returned an unexpected row count")
	return seconds, statistics
}

main :: proc() {
	fmt.printf("configuration: records=%d rounds=%d max_solutions=%d max_numeric_digits=32 now=%s\n", RECORDS, ROUNDS, RECORDS + 1, FIXED_NOW)
	if RECORDS <= 0 || ROUNDS <= 0 {
		fmt.eprintln("BENCH_RECORDS and BENCH_ROUNDS must be positive")
		os.exit(2)
	}
	query, parse_error := sparql.Parse(QUERY)
	defer sparql.Destroy(&query)
	if sparql.Parse_Error_Code(parse_error) != .None do fatal("benchmark query parsing failed")
	store := make_dataset()
	defer dataset.destroy(&store)
	view, view_error := dataset.view(&store)
	if view_error != .None do fatal("benchmark dataset view failed")
	source_best := f64(1e30)
	optimized_best := f64(1e30)
	for round in 1..=ROUNDS {
		source_seconds, source_statistics := run_case(&query, view, false)
		optimized_seconds, optimized_statistics := run_case(&query, view, true)
		source_best = min(source_best, source_seconds)
		optimized_best = min(optimized_best, optimized_seconds)
		fmt.printf("round %d: source=%.3f ms (%d scans, %d candidates), optimized=%.3f ms (%d scans, %d candidates, %d reorders)\n", round, source_seconds * 1e3, source_statistics.Dataset_Scans, source_statistics.Dataset_Candidates, optimized_seconds * 1e3, optimized_statistics.Dataset_Scans, optimized_statistics.Dataset_Candidates, optimized_statistics.BGP_Reorders)
	}
	fmt.printf("best: source=%.3f ms, optimized=%.3f ms, speedup=%.2fx (%d records)\n", source_best * 1e3, optimized_best * 1e3, source_best / optimized_best, RECORDS)
}
