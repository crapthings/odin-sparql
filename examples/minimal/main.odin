// A minimal external-consumer path: build RDF data, parse a query, execute it,
// and emit the standard SPARQL Results JSON representation.
package main

import "core:fmt"
import "core:strings"
import rdf "odin-rdf:rdf"
import sparql "../../sparql"
import dataset "../../sparql/dataset"
import engine "../../sparql/engine"
import results "../../sparql/results"

main :: proc() {
	query, parse_error := sparql.Parse(`SELECT ?name WHERE { <urn:ada> <urn:name> ?name }`)
	defer sparql.Destroy(&query)
	if sparql.Parse_Error_Code(parse_error) != .None {
		fmt.eprintln("parse error:", sparql.Parse_Error_Message(parse_error))
		return
	}

	store: dataset.Memory_Dataset
	dataset.init(&store)
	defer dataset.destroy(&store)
	statement := rdf.Triple{
		subject = rdf.iri("urn:ada"),
		predicate = rdf.iri("urn:name"),
		object = rdf.literal("Ada"),
	}
	if dataset.add(&store, rdf.default_graph_quad(statement)) != .None {
		fmt.eprintln("could not add the RDF statement")
		return
	}
	dataset.seal(&store)
	view, view_error := dataset.view(&store)
	if view_error != .None {
		fmt.eprintln("could not create dataset view")
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
