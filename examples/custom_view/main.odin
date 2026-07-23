// A minimal application-owned Dataset adapter. The source controls storage,
// matching, and lifetime; odin-sparql only consumes its streaming Scan_Proc.
package main

import "core:fmt"
import "core:strings"
import rdf "odin-rdf:rdf"
import sparql "../../sparql"
import dataset "../../sparql/dataset"
import engine "../../sparql/engine"
import results "../../sparql/results"

Source :: struct {
	quads: []rdf.Quad,
}

same_term :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value &&
		strings.equal_fold(left.language, right.language) &&
		left.datatype == right.datatype && left.scope == right.scope
}

matches :: proc(pattern: dataset.Quad_Pattern, quad: rdf.Quad) -> bool {
	#partial switch pattern.Graph_Mode {
	case .Default:
		if quad.has_graph do return false
	case .Named:
		if !quad.has_graph || !same_term(pattern.Graph, quad.graph) do return false
	case .Any_Named:
		if !quad.has_graph do return false
	}
	return (!pattern.Has_Subject || same_term(pattern.Subject, quad.subject)) &&
		(!pattern.Has_Predicate || same_term(pattern.Predicate, quad.predicate)) &&
		(!pattern.Has_Object || same_term(pattern.Object, quad.object))
}

scan :: proc(data: rawptr, pattern: dataset.Quad_Pattern, sink: dataset.Scan_Sink, sink_data: rawptr) -> dataset.Error_Code {
	source := cast(^Source)data
	for quad in source.quads {
		// false is a successful early-stop request from the engine, never an
		// adapter error. A real backend would stop its cursor here as well.
		if matches(pattern, quad) && !sink(quad, sink_data) do break
	}
	return .None
}

main :: proc() {
	source := Source{quads = []rdf.Quad{
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:bert")}),
		rdf.default_graph_quad(rdf.Triple{subject = rdf.iri("urn:ada"), predicate = rdf.iri("urn:knows"), object = rdf.iri("urn:cora")}),
	}}
	view := dataset.custom_view(scan, &source)

	query, parse_error := sparql.Parse(`SELECT ?friend WHERE { <urn:ada> <urn:knows> ?friend } ORDER BY ?friend`)
	defer sparql.Destroy(&query)
	if sparql.Parse_Error_Code(parse_error) != .None {
		fmt.eprintln("parse error:", sparql.Parse_Error_Message(parse_error))
		return
	}
	result, execute_error := engine.execute(&query, view, {Max_Solutions = 8, Max_Numeric_Digits = 32})
	defer engine.destroy(&result)
	if execute_error != .None {
		fmt.eprintln("execution error:", engine.error_message(execute_error))
		return
	}
	output := strings.builder_make()
	defer strings.builder_destroy(&output)
	if results.write_sparql_json(&output, &result) != .None {
		fmt.eprintln("could not serialize result as SPARQL Results JSON")
		return
	}
	fmt.println(strings.to_string(output))
}
