package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import xml "core:encoding/xml"
import json "core:encoding/json"
import rdf "odin-rdf:rdf"
import canon "odin-rdf:rdf/canon"
import rdf_dataset "odin-rdf:rdf/dataset"
import rdfxml "odin-rdf:rdf/rdfxml"
import turtle "odin-rdf:rdf/turtle"
import sparql "../../../sparql"
import dataset "../../../sparql/dataset"
import engine "../../../sparql/engine"
import results "../../../sparql/results"

Expected_Binding :: struct {
	name: string,
	term: rdf.Term,
}

Expected_Row :: struct {
	bindings: [dynamic]Expected_Binding,
}

Expected_Kind :: enum { Rows, Ask }

Expected_Result :: struct {
	kind:  Expected_Kind,
	rows:  [dynamic]Expected_Row,
	ask:   bool,
	owned: [dynamic]string,
}

@(private) compare_integral_decimal_lexical: bool

Service_Source :: struct {
	endpoint: string,
	view:     dataset.View,
}

Service_Fixture :: struct {
	stores:  []dataset.Memory_Dataset,
	sources: [dynamic]Service_Source,
}

@(private) Blank_Node_Mapping :: struct {
	actual:   rdf.Term,
	expected: rdf.Term,
}

@(private) JSON_Blank_Node_Mapping :: struct {
	actual:   string,
	expected: string,
}

// Normalized_Graph gives every blank node a serializer-safe label before it is
// passed to odin-rdf's RDFC canonicalizer. Turtle may create internal labels
// such as `.turtle-genid-0`; they are valid RDF identities but intentionally
// not valid N-Quads lexical labels. The normalization preserves node identity
// (including its source scope) while keeping graph comparison syntax-neutral.
@(private) Normalized_Graph :: struct {
	quads: [dynamic]rdf.Quad,
	owned: [dynamic]string,
}

@(private) Normalized_Blank_Node :: struct {
	original: rdf.Term,
	label:    string,
}

destroy_normalized_graph :: proc(graph: ^Normalized_Graph) {
	for value in graph.owned do delete(value)
	delete(graph.owned)
	delete(graph.quads)
	graph^ = {}
}

normalize_blank_node :: proc(term: rdf.Term, mappings: ^[dynamic]Normalized_Blank_Node, graph: ^Normalized_Graph) -> (rdf.Term, bool) {
	if term.kind != .Blank_Node do return term, true
	for entry in mappings^ do if term_equal(entry.original, term) do return rdf.blank_node(entry.label, term.scope), true
	label_builder := strings.builder_make()
	defer strings.builder_destroy(&label_builder)
	strings.write_string(&label_builder, "b")
	strings.write_int(&label_builder, len(mappings^))
	label, clone_error := strings.clone(strings.to_string(label_builder))
	if clone_error != nil do return {}, false
	if _, owned_error := append(&graph.owned, label); owned_error != nil { delete(label); return {}, false }
	if _, mapping_error := append(mappings, Normalized_Blank_Node{original = term, label = label}); mapping_error != nil do return {}, false
	return rdf.blank_node(label, term.scope), true
}

normalize_graph_for_canonicalization :: proc(source: []rdf.Quad) -> (Normalized_Graph, bool) {
	result := Normalized_Graph{quads = make([dynamic]rdf.Quad), owned = make([dynamic]string)}
	mappings := make([dynamic]Normalized_Blank_Node)
	defer delete(mappings)
	for source_quad in source {
		quad := source_quad
		ok: bool
		quad.subject, ok = normalize_blank_node(quad.subject, &mappings, &result)
		if !ok { destroy_normalized_graph(&result); return {}, false }
		quad.predicate, ok = normalize_blank_node(quad.predicate, &mappings, &result)
		if !ok { destroy_normalized_graph(&result); return {}, false }
		quad.object, ok = normalize_blank_node(quad.object, &mappings, &result)
		if !ok { destroy_normalized_graph(&result); return {}, false }
		if quad.has_graph {
			quad.graph, ok = normalize_blank_node(quad.graph, &mappings, &result)
			if !ok { destroy_normalized_graph(&result); return {}, false }
		}
		if _, append_error := append(&result.quads, quad); append_error != nil { destroy_normalized_graph(&result); return {}, false }
	}
	return result, true
}

destroy_expected :: proc(result: ^Expected_Result) {
	for value in result.owned do delete(value)
	delete(result.owned)
	for row in result.rows do delete(row.bindings)
	delete(result.rows)
	result^ = {}
}

expected_own :: proc(result: ^Expected_Result, value: string) -> (string, bool) {
	if len(value) == 0 do return "", true
	cloned, error := strings.clone(value)
	if error != nil do return "", false
	if _, append_error := append(&result.owned, cloned); append_error != nil { delete(cloned); return "", false }
	return cloned, true
}

copy_expected_term :: proc(result: ^Expected_Result, value: rdf.Term) -> (rdf.Term, bool) {
	copy := value
	ok: bool
	copy.value, ok = expected_own(result, value.value)
	if !ok do return {}, false
	copy.language, ok = expected_own(result, value.language)
	if !ok do return {}, false
	copy.datatype, ok = expected_own(result, value.datatype)
	if !ok do return {}, false
	return copy, true
}

element_children :: proc(doc: ^xml.Document, parent: xml.Element_ID) -> [dynamic]xml.Element_ID {
	result := make([dynamic]xml.Element_ID)
	for value in doc.elements[parent].value {
		switch child in value {
		case string:
		case xml.Element_ID:
			if doc.elements[child].kind == .Element do append(&result, child)
		}
	}
	return result
}

element_text :: proc(doc: ^xml.Document, element: xml.Element_ID) -> string {
	for value in doc.elements[element].value {
		switch text in value {
		case string: return text
		case xml.Element_ID:
		}
	}
	return ""
}

attribute :: proc(doc: ^xml.Document, element: xml.Element_ID, key: string) -> (string, bool) {
	for value in doc.elements[element].attribs do if value.key == key do return value.val, true
	return "", false
}

expected_term :: proc(doc: ^xml.Document, element: xml.Element_ID) -> (rdf.Term, bool) {
	value := doc.elements[element]
	text := element_text(doc, element)
	switch value.ident {
	case "uri": return rdf.iri(text), true
	case "literal":
		if language, found := attribute(doc, element, "xml:lang"); found do return rdf.language_literal(text, language), true
		if datatype, found := attribute(doc, element, "datatype"); found do return rdf.typed_literal(text, datatype), true
		return rdf.literal(text), true
	case "bnode":
		return rdf.blank_node(text), true
	}
	return {}, false
}

parse_expected_rows :: proc(path: string, base: string = "") -> (Expected_Result, bool) {
	if strings.has_suffix(path, ".ttl") do return parse_expected_turtle(path, base)
	if strings.has_suffix(path, ".rdf") do return parse_expected_rdfxml(path, base)
	result := Expected_Result{rows = make([dynamic]Expected_Row), owned = make([dynamic]string)}
	doc, parse_error := xml.load_from_file(path)
	if parse_error != .None { destroy_expected(&result); return {}, false }
	defer xml.destroy(doc)
	if len(doc.elements) == 0 || doc.elements[0].ident != "sparql" { destroy_expected(&result); return {}, false }
	head, head_found := xml.find_child_by_ident(doc, 0, "head")
	if !head_found { destroy_expected(&result); return {}, false }
	for child in element_children(doc, head) {
		if doc.elements[child].ident != "variable" do continue
		name, found := attribute(doc, child, "name")
		if !found { destroy_expected(&result); return {}, false }
		_, own_ok := expected_own(&result, name)
		if !own_ok { destroy_expected(&result); return {}, false }
	}
	boolean, boolean_found := xml.find_child_by_ident(doc, 0, "boolean")
	if boolean_found {
		value := element_text(doc, boolean)
		if value != "true" && value != "false" { destroy_expected(&result); return {}, false }
		result.kind = .Ask
		result.ask = value == "true"
		return result, true
	}
	results, results_found := xml.find_child_by_ident(doc, 0, "results")
	if !results_found { destroy_expected(&result); return {}, false }
	for result_element in element_children(doc, results) {
		if doc.elements[result_element].ident != "result" do continue
		row := Expected_Row{bindings = make([dynamic]Expected_Binding)}
		valid := true
		for binding_element in element_children(doc, result_element) {
			if doc.elements[binding_element].ident != "binding" do continue
			name, name_found := attribute(doc, binding_element, "name")
			children := element_children(doc, binding_element)
			if !name_found || len(children) > 1 { delete(children); valid = false; break }
			// SPARQL Results XML permits an empty binding element to represent an
			// explicitly listed but unbound variable. Expected_Row omits it, and
			// row_matches verifies that the corresponding actual cell is unbound.
			if len(children) == 0 { delete(children); continue }
			term, term_ok := expected_term(doc, children[0])
			delete(children)
			if !term_ok { valid = false; break }
			owned_name, name_ok := expected_own(&result, name)
			owned_term, term_copy_ok := copy_expected_term(&result, term)
			if !name_ok || !term_copy_ok { valid = false; break }
			if _, append_error := append(&row.bindings, Expected_Binding{name = owned_name, term = owned_term}); append_error != nil { valid = false; break }
		}
		if !valid { delete(row.bindings); destroy_expected(&result); return {}, false }
		if _, error := append(&result.rows, row); error != nil { delete(row.bindings); destroy_expected(&result); return {}, false }
	}
	return result, true
}

RS_TYPE :: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
RS_RESULT_SET :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#ResultSet"
RS_BOOLEAN :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#boolean"
RS_SOLUTION :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#solution"
RS_BINDING :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#binding"
RS_INDEX :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#index"
RS_VARIABLE :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#variable"
RS_VALUE :: "http://www.w3.org/2001/sw/DataAccess/tests/result-set#value"

term_equal :: proc(left, right: rdf.Term) -> bool {
	if left.kind != right.kind || !strings.equal_fold(left.language, right.language) || left.datatype != right.datatype || left.scope != right.scope do return false
	if left.value == right.value do return true
	if !compare_integral_decimal_lexical || left.kind != .Literal || left.datatype != "http://www.w3.org/2001/XMLSchema#decimal" do return false
	return integral_decimal_lexical(left.value) == integral_decimal_lexical(right.value)
}

// A few historic SPARQL 1.0 numeric-promotion fixtures represent integral
// xsd:decimal values without a fractional digit, while SPARQL 1.1 function
// vectors use the canonical .0 spelling. Keep this equivalence opt-in and
// limited to integral decimal spellings for those fixture comparisons.
@(private) integral_decimal_lexical :: proc(value: string) -> string {
	dot := strings.index_byte(value, '.')
	if dot < 0 do return value
	for character in value[dot + 1:] do if character != '0' do return value
	return value[:dot]
}

objects_for :: proc(collector: ^rdf_dataset.Collector, subject: rdf.Term, predicate: string) -> (result: [dynamic]rdf.Term, ok: bool) {
	result = make([dynamic]rdf.Term)
	for quad in collector.quads {
		if !term_equal(quad.subject, subject) || quad.predicate.kind != .IRI || quad.predicate.value != predicate do continue
		if _, error := append(&result, quad.object); error != nil { delete(result); return nil, false }
	}
	return result, true
}

first_object :: proc(collector: ^rdf_dataset.Collector, subject: rdf.Term, predicate: string) -> (rdf.Term, bool) {
	for quad in collector.quads do if term_equal(quad.subject, subject) && quad.predicate.kind == .IRI && quad.predicate.value == predicate do return quad.object, true
	return {}, false
}

parse_expected_turtle :: proc(path, base: string) -> (Expected_Result, bool) {
	result := Expected_Result{rows = make([dynamic]Expected_Row), owned = make([dynamic]string)}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil { destroy_expected(&result); return {}, false }
	defer delete(data)
	collector: rdf_dataset.Collector
	if rdf_dataset.init(&collector) != .None { destroy_expected(&result); return {}, false }
	defer rdf_dataset.destroy(&collector)
	if turtle.parse(string(data), rdf_dataset.triple_sink, turtle.Parse_Options{base_iri = base}, &collector).code != .None || collector.last_error != .None { destroy_expected(&result); return {}, false }
	result_set: rdf.Term
	found_result_set := false
	for quad in collector.quads {
		if quad.predicate.kind == .IRI && quad.predicate.value == RS_TYPE && quad.object.kind == .IRI && quad.object.value == RS_RESULT_SET {
			result_set = quad.subject
			found_result_set = true
			break
		}
	}
	if !found_result_set { destroy_expected(&result); return {}, false }
	if boolean, boolean_ok := first_object(&collector, result_set, RS_BOOLEAN); boolean_ok {
		if boolean.kind != .Literal || (boolean.value != "true" && boolean.value != "false") { destroy_expected(&result); return {}, false }
		result.kind = .Ask
		result.ask = boolean.value == "true"
		return result, true
	}
	solutions, solutions_ok := objects_for(&collector, result_set, RS_SOLUTION)
	defer delete(solutions)
	if !solutions_ok { destroy_expected(&result); return {}, false }
	row_indexes := make([dynamic]int)
	defer delete(row_indexes)
	for solution in solutions {
		row := Expected_Row{bindings = make([dynamic]Expected_Binding)}
		bindings, bindings_ok := objects_for(&collector, solution, RS_BINDING)
		if !bindings_ok { delete(row.bindings); destroy_expected(&result); return {}, false }
		valid := true
		for binding in bindings {
			variable, variable_ok := first_object(&collector, binding, RS_VARIABLE)
			value, value_ok := first_object(&collector, binding, RS_VALUE)
			if !variable_ok || !value_ok || variable.kind != .Literal { valid = false; break }
			name, name_ok := expected_own(&result, variable.value)
			copied_value, copied_ok := copy_expected_term(&result, value)
			if !name_ok || !copied_ok { valid = false; break }
			if _, append_error := append(&row.bindings, Expected_Binding{name = name, term = copied_value}); append_error != nil { valid = false; break }
		}
		delete(bindings)
		if !valid { delete(row.bindings); destroy_expected(&result); return {}, false }
		if _, append_error := append(&result.rows, row); append_error != nil { delete(row.bindings); destroy_expected(&result); return {}, false }
		sequence := len(result.rows)
		if index, index_ok := first_object(&collector, solution, RS_INDEX); index_ok && index.kind == .Literal {
			parsed, parsed_ok := strconv.parse_int(index.value, 10)
			if !parsed_ok || parsed <= 0 { destroy_expected(&result); return {}, false }
			sequence = parsed
		}
		if _, append_error := append(&row_indexes, sequence); append_error != nil { destroy_expected(&result); return {}, false }
	}
	for current in 1..<len(result.rows) {
		row := result.rows[current]
		sequence := row_indexes[current]
		position := current
		for position > 0 && sequence < row_indexes[position - 1] {
			result.rows[position] = result.rows[position - 1]
			row_indexes[position] = row_indexes[position - 1]
			position -= 1
		}
		result.rows[position] = row
		row_indexes[position] = sequence
	}
	return result, true
}

// parse_expected_rdfxml supports the historic W3C result-set RDF/XML files.
// They encode exactly the same rs:ResultSet graph handled by the Turtle path.
parse_expected_rdfxml :: proc(path, base: string) -> (Expected_Result, bool) {
	result := Expected_Result{rows = make([dynamic]Expected_Row), owned = make([dynamic]string)}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil { destroy_expected(&result); return {}, false }
	defer delete(data)
	collector: rdf_dataset.Collector
	if rdf_dataset.init(&collector) != .None { destroy_expected(&result); return {}, false }
	defer rdf_dataset.destroy(&collector)
	if rdfxml.parse(string(data), rdf_dataset.sink, rdfxml.Options{base_iri = base}, &collector).code != .None || collector.last_error != .None { destroy_expected(&result); return {}, false }
	result_set: rdf.Term
	found_result_set := false
	for quad in collector.quads {
		if quad.predicate.kind == .IRI && quad.predicate.value == RS_TYPE && quad.object.kind == .IRI && quad.object.value == RS_RESULT_SET {
			result_set = quad.subject
			found_result_set = true
			break
		}
	}
	if !found_result_set { destroy_expected(&result); return {}, false }
	if boolean, boolean_ok := first_object(&collector, result_set, RS_BOOLEAN); boolean_ok {
		if boolean.kind != .Literal || (boolean.value != "true" && boolean.value != "false") { destroy_expected(&result); return {}, false }
		result.kind = .Ask
		result.ask = boolean.value == "true"
		return result, true
	}
	solutions, solutions_ok := objects_for(&collector, result_set, RS_SOLUTION)
	defer delete(solutions)
	if !solutions_ok { destroy_expected(&result); return {}, false }
	for solution in solutions {
		row := Expected_Row{bindings = make([dynamic]Expected_Binding)}
		bindings, bindings_ok := objects_for(&collector, solution, RS_BINDING)
		if !bindings_ok { delete(row.bindings); destroy_expected(&result); return {}, false }
		valid := true
		for binding in bindings {
			variable, variable_ok := first_object(&collector, binding, RS_VARIABLE)
			value, value_ok := first_object(&collector, binding, RS_VALUE)
			if !variable_ok || !value_ok || variable.kind != .Literal { valid = false; break }
			name, name_ok := expected_own(&result, variable.value)
			copied_value, copied_ok := copy_expected_term(&result, value)
			if !name_ok || !copied_ok { valid = false; break }
			if _, append_error := append(&row.bindings, Expected_Binding{name = name, term = copied_value}); append_error != nil { valid = false; break }
		}
		delete(bindings)
		if !valid { delete(row.bindings); destroy_expected(&result); return {}, false }
		if _, append_error := append(&result.rows, row); append_error != nil { delete(row.bindings); destroy_expected(&result); return {}, false }
	}
	return result, true
}

actual_binding :: proc(result: ^engine.Result, row: int, name: string) -> (rdf.Term, bool, bool) {
	for index in 0..<engine.Variable_Count(result) {
		candidate, found := engine.Variable_Name(result, index)
		if found && candidate == name {
			term, bound, ok := engine.Cell(result, row, index)
			return term, bound, ok
		}
	}
	return {}, false, false
}

row_matches :: proc(result: ^engine.Result, row: int, expected: Expected_Row) -> bool {
	for binding in expected.bindings {
		actual, bound, ok := actual_binding(result, row, binding.name)
		if !ok || !bound || !term_equal(actual, binding.term) do return false
	}
	for index in 0..<engine.Variable_Count(result) {
		name, name_ok := engine.Variable_Name(result, index)
		if !name_ok do return false
		_, bound, cell_ok := engine.Cell(result, row, index)
		if !cell_ok do return false
		found := false
		for binding in expected.bindings do if binding.name == name do found = true
		if bound && !found do return false
	}
	return true
}

// term_matches_result preserves RDF blank-node identity across an unordered
// result set by maintaining a one-to-one mapping between actual and expected
// document-local node identifiers.
term_matches_result :: proc(actual, expected: rdf.Term, mapping: ^[dynamic]Blank_Node_Mapping) -> bool {
	if actual.kind != expected.kind do return false
	if actual.kind != .Blank_Node do return term_equal(actual, expected)
	for entry in mapping^ {
		if term_equal(actual, entry.actual) do return term_equal(expected, entry.expected)
		if term_equal(expected, entry.expected) do return false
	}
	_, append_error := append(mapping, Blank_Node_Mapping{actual = actual, expected = expected})
	return append_error == nil
}

row_matches_with_blank_nodes :: proc(result: ^engine.Result, row: int, expected: Expected_Row, mapping: ^[dynamic]Blank_Node_Mapping) -> bool {
	for binding in expected.bindings {
		actual, bound, ok := actual_binding(result, row, binding.name)
		if !ok || !bound || !term_matches_result(actual, binding.term, mapping) do return false
	}
	for index in 0..<engine.Variable_Count(result) {
		name, name_ok := engine.Variable_Name(result, index)
		if !name_ok do return false
		_, bound, cell_ok := engine.Cell(result, row, index)
		if !cell_ok do return false
		found := false
		for binding in expected.bindings do if binding.name == name do found = true
		if bound && !found do return false
	}
	return true
}

match_rows_with_blank_nodes :: proc(result: ^engine.Result, expected: [dynamic]Expected_Row, row: int, matched: ^[dynamic]bool, mapping: ^[dynamic]Blank_Node_Mapping) -> bool {
	if row == engine.Row_Count(result) do return true
	for index in 0..<len(expected) {
		if matched[index] do continue
		mapping_start := len(mapping^)
		if !row_matches_with_blank_nodes(result, row, expected[index], mapping) {
			resize(mapping, mapping_start)
			continue
		}
		matched[index] = true
		if match_rows_with_blank_nodes(result, expected, row + 1, matched, mapping) do return true
		matched[index] = false
		resize(mapping, mapping_start)
	}
	return false
}

has_blank_node :: proc(result: ^engine.Result, expected: [dynamic]Expected_Row) -> bool {
	for row in expected do for binding in row.bindings do if binding.term.kind == .Blank_Node do return true
	for row in 0..<engine.Row_Count(result) {
		for column in 0..<engine.Variable_Count(result) {
			term, bound, ok := engine.Cell(result, row, column)
			if ok && bound && term.kind == .Blank_Node do return true
		}
	}
	return false
}

compare_rows :: proc(result: ^engine.Result, expected: [dynamic]Expected_Row) -> bool {
	if engine.Row_Count(result) != len(expected) do return false
	matched := make([dynamic]bool)
	defer delete(matched)
	for _ in expected {
		if _, error := append(&matched, false); error != nil do return false
	}
	if has_blank_node(result, expected) {
		mapping := make([dynamic]Blank_Node_Mapping)
		defer delete(mapping)
		return match_rows_with_blank_nodes(result, expected, 0, &matched, &mapping)
	}
	for row in 0..<engine.Row_Count(result) {
		found := false
		for index in 0..<len(expected) {
			if !matched[index] && row_matches(result, row, expected[index]) {
				matched[index] = true
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

// compare_rows_lax_reduced implements mf:LaxCardinality for the SPARQL 1.0
// REDUCED manifest. An implementation may remove any number of duplicate
// solutions, but it may not invent a solution, exceed the source multiplicity,
// or remove every occurrence of a distinct solution mapping.
//
// The pinned REDUCED fixtures contain no blank nodes. Refusing them here keeps
// the one-to-one document-local blank-node policy explicit instead of silently
// weakening it for a cardinality mode that does not need it.
compare_rows_lax_reduced :: proc(result: ^engine.Result, expected: [dynamic]Expected_Row) -> bool {
	if has_blank_node(result, expected) do return false
	matched := make([dynamic]bool)
	defer delete(matched)
	for _ in expected {
		if _, error := append(&matched, false); error != nil do return false
	}
	// Every actual row must be an expected row, and cannot occur more often
	// than the expected multiset permits.
	for actual_row in 0..<engine.Row_Count(result) {
		found := false
		for expected_row in 0..<len(expected) {
			if !matched[expected_row] && row_matches(result, actual_row, expected[expected_row]) {
				matched[expected_row] = true
				found = true
				break
			}
		}
		if !found do return false
	}
	// Every distinct expected mapping must remain represented at least once.
	for expected_row in 0..<len(expected) {
		found := false
		for actual_row in 0..<engine.Row_Count(result) {
			if row_matches(result, actual_row, expected[expected_row]) {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

// compare_rows_in_order is used only for W3C ORDER BY fixtures. Unlike the
// regular result comparison it preserves sequence position while still mapping
// document-local blank-node identifiers one-to-one.
compare_rows_in_order :: proc(result: ^engine.Result, expected: [dynamic]Expected_Row) -> bool {
	if engine.Row_Count(result) != len(expected) do return false
	if !has_blank_node(result, expected) {
		for row in 0..<engine.Row_Count(result) do if !row_matches(result, row, expected[row]) do return false
		return true
	}
	mapping := make([dynamic]Blank_Node_Mapping)
	defer delete(mapping)
	for row in 0..<engine.Row_Count(result) do if !row_matches_with_blank_nodes(result, row, expected[row], &mapping) do return false
	return true
}

@(private) json_string :: proc(value: json.Value) -> (string, bool) {
	#partial switch item in value {
	case json.String: return string(item), true
	}
	return "", false
}

@(private) json_blank_node :: proc(value: json.Object) -> (string, bool) {
	type_value, type_ok := value["type"]
	identifier_value, identifier_found := value["value"]
	if !type_ok || !identifier_found || len(value) != 2 do return "", false
	kind, kind_ok := json_string(type_value)
	identifier, identifier_ok := json_string(identifier_value)
	if !kind_ok || !identifier_ok || kind != "bnode" do return "", false
	return identifier, true
}

// json_values_equal compares SPARQL Results JSON values structurally. Result
// blank-node labels are document-local, so serializations receive the same
// one-to-one mapping policy as SRX result-set comparison.
@(private) json_values_equal :: proc(actual, expected: json.Value, mapping: ^[dynamic]JSON_Blank_Node_Mapping) -> bool {
	#partial switch actual_value in actual {
	case json.Null:
		#partial switch _ in expected { case json.Null: return true }
	case json.Integer:
		#partial switch expected_value in expected { case json.Integer: return actual_value == expected_value }
	case json.Float:
		#partial switch expected_value in expected { case json.Float: return actual_value == expected_value }
	case json.Boolean:
		#partial switch expected_value in expected { case json.Boolean: return actual_value == expected_value }
	case json.String:
		#partial switch expected_value in expected { case json.String: return actual_value == expected_value }
	case json.Array:
		#partial switch expected_value in expected {
		case json.Array:
			if len(actual_value) != len(expected_value) do return false
			for index in 0..<len(actual_value) do if !json_values_equal(actual_value[index], expected_value[index], mapping) do return false
			return true
		}
	case json.Object:
		#partial switch expected_value in expected {
		case json.Object:
			actual_blank, actual_is_blank := json_blank_node(actual_value)
			expected_blank, expected_is_blank := json_blank_node(expected_value)
			if actual_is_blank || expected_is_blank {
				if !actual_is_blank || !expected_is_blank do return false
				for entry in mapping^ {
					if entry.actual == actual_blank do return entry.expected == expected_blank
					if entry.expected == expected_blank do return false
				}
				_, append_error := append(mapping, JSON_Blank_Node_Mapping{actual = actual_blank, expected = expected_blank})
				return append_error == nil
			}
			if len(actual_value) != len(expected_value) do return false
			for key, actual_child in actual_value {
				expected_child, found := expected_value[key]
				if !found || !json_values_equal(actual_child, expected_child, mapping) do return false
			}
			return true
		}
	}
	return false
}

load_default_data :: proc(store: ^dataset.Memory_Dataset, path: string, base: string = "") -> bool {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil do return false
	defer delete(data)
	if strings.has_suffix(path, ".rdf") {
		// RDF/XML has a quad callback and is therefore loaded directly into the
		// default graph. Its public parser currently owns document-base handling;
		// W3C fixtures used here carry absolute resources where it matters.
		parse_error := rdfxml.parse(string(data), dataset.sink, {}, store)
		if parse_error.code != .None {
			fmt.eprintf("RDF/XML data parse failed: %s (%v)\n", path, parse_error.code)
			return false
		}
		return true
	}
	parse_error := turtle.parse(string(data), dataset.triple_sink, turtle.Parse_Options{base_iri = base}, store)
	if parse_error.code != .None {
		fmt.eprintf("Turtle data parse failed: %s at %d:%d: %s\n", path, parse_error.line, parse_error.column, turtle.parse_error_message(parse_error.code))
		return false
	}
	return true
}

load_dataset :: proc(path: string, base: string = "") -> (dataset.Memory_Dataset, bool) {
	store: dataset.Memory_Dataset
	dataset.init(&store)
	if path == "-" {
		dataset.seal(&store)
		return store, true
	}
	if !load_default_data(&store, path, base) { dataset.destroy(&store); return {}, false }
	dataset.seal(&store)
	return store, true
}

destroy_service_fixture :: proc(fixture: ^Service_Fixture) {
	for index in 0..<len(fixture.stores) do dataset.destroy(&fixture.stores[index])
	delete(fixture.stores)
	delete(fixture.sources)
	fixture^ = {}
}

service_fixture_callback :: proc(endpoint: rdf.Term, user_data: rawptr) -> (dataset.View, bool) {
	fixture := cast(^Service_Fixture)user_data
	if endpoint.kind != .IRI do return {}, false
	for source in fixture.sources do if source.endpoint == endpoint.value do return source.view, true
	return {}, false
}

// load_service_fixture maps local W3C qt:serviceData documents to the
// evaluator's explicit SERVICE callback. The '-' default-data sentinel keeps
// endpoint-only fixture cases offline and does not represent a filesystem path.
load_service_fixture :: proc(fixture: ^Service_Fixture, args: []string, first: int) -> bool {
	if first < 0 || first > len(args) || (len(args) - first) % 2 != 0 do return false
	pair_count := (len(args) - first) / 2
	fixture^ = Service_Fixture{stores = make([]dataset.Memory_Dataset, pair_count), sources = make([dynamic]Service_Source)}
	for index in 0..<pair_count {
		endpoint := args[first + index * 2]
		path := args[first + index * 2 + 1]
		store := &fixture.stores[index]
		dataset.init(store)
		if !load_default_data(store, path) { destroy_service_fixture(fixture); return false }
		dataset.seal(store)
		view, view_error := dataset.view(store)
		if view_error != .None { destroy_service_fixture(fixture); return false }
		if _, append_error := append(&fixture.sources, Service_Source{endpoint = endpoint, view = view}); append_error != nil { destroy_service_fixture(fixture); return false }
	}
	return true
}

// load_expected_graph keeps the collector alive for the caller because its
// quads own the parsed Turtle strings. CONSTRUCT comparison is graph
// isomorphism, never a comparison of serializer labels or statement order.
load_expected_graph :: proc(path: string, base: string = "") -> (rdf_dataset.Collector, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil do return {}, false
	defer delete(data)
	collector: rdf_dataset.Collector
	if rdf_dataset.init(&collector) != .None do return {}, false
	parse_error := turtle.parse(string(data), rdf_dataset.triple_sink, turtle.Parse_Options{base_iri = base}, &collector)
	if parse_error.code != .None || collector.last_error != .None {
		rdf_dataset.destroy(&collector)
		return {}, false
	}
	return collector, true
}

Named_Load_State :: struct {
	store: ^dataset.Memory_Dataset,
	graph: rdf.Term,
}

named_triple_sink :: proc(triple: rdf.Triple, user_data: rawptr) -> bool {
	state := cast(^Named_Load_State)user_data
	return dataset.add(state.store, rdf.named_graph_quad(triple, state.graph)) == .None
}

named_quad_sink :: proc(quad: rdf.Quad, user_data: rawptr) -> bool {
	state := cast(^Named_Load_State)user_data
	triple := rdf.Triple{subject = quad.subject, predicate = quad.predicate, object = quad.object}
	return dataset.add(state.store, rdf.named_graph_quad(triple, state.graph)) == .None
}

load_named_data :: proc(store: ^dataset.Memory_Dataset, graph_iri, path: string) -> bool {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil do return false
	defer delete(data)
	state := Named_Load_State{store = store, graph = rdf.iri(graph_iri)}
	if strings.has_suffix(path, ".rdf") {
		return rdfxml.parse(string(data), named_quad_sink, {}, &state).code == .None
	}
	// qt:graphData names the graph by its document IRI, which is also the
	// base used for relative IRIs inside that RDF document.
	return turtle.parse(string(data), named_triple_sink, turtle.Parse_Options{base_iri = graph_iri}, &state).code == .None
}

// load_named_dataset consumes graph-IRI/Turtle-file pairs from args[first:].
load_named_dataset :: proc(args: []string, first: int) -> (dataset.Memory_Dataset, bool) {
	if first < 0 || first > len(args) || (len(args) - first) % 2 != 0 do return {}, false
	store: dataset.Memory_Dataset
	dataset.init(&store)
	for index := first; index < len(args); index += 2 {
		if !load_named_data(&store, args[index], args[index + 1]) { dataset.destroy(&store); return {}, false }
	}
	dataset.seal(&store)
	return store, true
}

// load_mixed_dataset loads one default graph and graph-IRI/Turtle-file pairs.
// The explicit default base is needed because qt:data and qt:graphData may use
// relative IRIs whose document bases are different.
load_mixed_dataset :: proc(args: []string, default_base, default_path: int, named_first: int) -> (dataset.Memory_Dataset, bool) {
	if default_base < 0 || default_path != default_base + 1 || named_first != default_path + 1 || named_first > len(args) || (len(args) - named_first) % 2 != 0 do return {}, false
	store: dataset.Memory_Dataset
	dataset.init(&store)
	if !load_default_data(&store, args[default_path], args[default_base]) { dataset.destroy(&store); return {}, false }
	for index := named_first; index < len(args); index += 2 {
		if !load_named_data(&store, args[index], args[index + 1]) { dataset.destroy(&store); return {}, false }
	}
	dataset.seal(&store)
	return store, true
}

main :: proc() {
	ordered := len(os.args) == 5 && os.args[1] == "--ordered"
	lax_reduced := len(os.args) == 5 && os.args[1] == "--lax-reduced"
	json_results := len(os.args) == 5 && os.args[1] == "--json"
	xml_results := len(os.args) == 5 && os.args[1] == "--xml"
	csv_results := len(os.args) == 5 && os.args[1] == "--csv"
	tsv_results := len(os.args) == 5 && os.args[1] == "--tsv"
	ntriples_graph := len(os.args) == 5 && os.args[1] == "--ntriples"
	turtle_graph := len(os.args) == 5 && os.args[1] == "--turtle"
	decimal_equivalent := len(os.args) == 5 && os.args[1] == "--decimal-equivalent"
	service := len(os.args) >= 5 && os.args[1] == "--service" && (len(os.args) - 5) % 2 == 0
	if !ordered && !lax_reduced && !json_results && !xml_results && !csv_results && !tsv_results && !ntriples_graph && !turtle_graph && !decimal_equivalent && !service && len(os.args) != 4 && (len(os.args) != 6 || os.args[1] != "--base") && (len(os.args) < 7 || os.args[1] != "--named" || (len(os.args) - 5) % 2 != 0) && (len(os.args) < 9 || os.args[1] != "--mixed" || (len(os.args) - 7) % 2 != 0) {
		fmt.eprintln("usage: basic_runner <query.rq> <data.ttl> <expected.{srx,ttl}> | basic_runner --ordered <query.rq> <data.ttl> <expected.{srx,ttl}> | basic_runner --lax-reduced <query.rq> <data.ttl> <expected.srx> | basic_runner --json|--xml|--csv|--tsv|--ntriples|--turtle|--decimal-equivalent <query.rq> <data.ttl> <expected-result> | basic_runner --base <base-iri> <query.rq> <data.ttl> <expected.{srx,ttl}> | basic_runner --named <query.rq> <expected.{srx,ttl}> <result-base> <graph-iri> <data.ttl> [...] | basic_runner --mixed <query.rq> <expected.{srx,ttl}> <result-base> <default-base> <default-data.ttl> <graph-iri> <data.ttl> [...] | basic_runner --service <query.rq> <data.ttl|-> <expected.srx> [<endpoint-iri> <data.ttl> ...]")
		os.exit(2)
	}
	query_path := os.args[1]
	expected_path := os.args[3]
	result_base := ""
	data_base := ""
	store: dataset.Memory_Dataset
	store_ok := false
	service_fixture: Service_Fixture
	service_ok := true
	if ordered || lax_reduced || json_results || xml_results || csv_results || tsv_results || ntriples_graph || turtle_graph || decimal_equivalent {
		query_path = os.args[2]
		expected_path = os.args[4]
		store, store_ok = load_dataset(os.args[3])
	} else if os.args[1] == "--named" {
		query_path = os.args[2]
		expected_path = os.args[3]
		result_base = os.args[4]
		store, store_ok = load_named_dataset(os.args[:], 5)
	} else if os.args[1] == "--mixed" {
		query_path = os.args[2]
		expected_path = os.args[3]
		result_base = os.args[4]
		store, store_ok = load_mixed_dataset(os.args[:], 5, 6, 7)
	} else if os.args[1] == "--base" {
		data_base = os.args[2]
		query_path = os.args[3]
		expected_path = os.args[5]
		store, store_ok = load_dataset(os.args[4], data_base)
	} else if service {
		query_path = os.args[2]
		expected_path = os.args[4]
		store, store_ok = load_dataset(os.args[3])
		service_ok = load_service_fixture(&service_fixture, os.args[:], 5)
	} else {
		store, store_ok = load_dataset(os.args[2])
	}
	compare_integral_decimal_lexical = decimal_equivalent
	if !store_ok || !service_ok { fmt.eprintln("cannot load Turtle data"); os.exit(2) }
	defer dataset.destroy(&store)
	defer if service do destroy_service_fixture(&service_fixture)
	query_data, query_read_error := os.read_entire_file(query_path, context.allocator)
	if query_read_error != nil { fmt.eprintln("cannot read query"); os.exit(2) }
	defer delete(query_data)
	query_source := string(query_data)
	owned_query_source := ""
	if len(result_base) != 0 {
		parts := [4]string{"BASE <", result_base, ">\n", query_source}
		prefixed, prefix_error := strings.concatenate(parts[:])
		if prefix_error != nil { fmt.eprintln("cannot construct query prologue"); os.exit(2) }
		owned_query_source = prefixed
		query_source = owned_query_source
	}
	query, parse_error := sparql.Parse(query_source)
	if len(owned_query_source) != 0 do delete(owned_query_source)
	if sparql.Parse_Error_Code(parse_error) != .None { fmt.eprintf("query parse failed: %v: %s\n", sparql.Parse_Error_Code(parse_error), query_source); os.exit(1) }
	defer sparql.Destroy(&query)
	view, view_error := dataset.view(&store)
	if view_error != .None { fmt.eprintln("cannot create dataset view"); os.exit(2) }
	// The fixture runner deliberately supplies a finite numeric budget so exact
	// arithmetic tests exercise the same resource contract as applications.
	// W3C fixtures must be reproducible. Supplying one fixed query clock also
	// verifies NOW() without coupling a conformance result to wall-clock time.
	options := engine.Options{Max_Solutions = 100_000, Max_Numeric_Digits = 100_000, Now_Lexical = "2000-01-01T00:00:00Z"}
	if service { options.Service_Callback = service_fixture_callback; options.Service_Data = &service_fixture }
	result, execute_error := engine.execute(&query, view, options)
	if execute_error != .None { fmt.eprintf("execution failed: %v\n", execute_error); os.exit(1) }
	defer engine.destroy(&result)
	if ntriples_graph || turtle_graph {
		output := strings.builder_make()
		defer strings.builder_destroy(&output)
		serialization_error := ntriples_graph ? results.write_ntriples(&output, &result) : results.write_turtle(&output, &result)
		if serialization_error != .None { fmt.eprintf("cannot serialize graph result: %v\n", serialization_error); os.exit(2) }
		expected_data, expected_read_error := os.read_entire_file(expected_path, context.allocator)
		if expected_read_error != nil { fmt.eprintln("cannot read expected graph result"); os.exit(2) }
		defer delete(expected_data)
		expected_output := string(expected_data)
		if strings.to_string(output) != expected_output { fmt.eprintf("serialized graph result differs: %s\n", strings.to_string(output)); os.exit(1) }
		return
	}
	if engine.Kind(&result) == .Graph {
		expected_graph, expected_graph_ok := load_expected_graph(expected_path, result_base)
		if !expected_graph_ok { fmt.eprintln("cannot parse expected RDF graph"); os.exit(2) }
		defer rdf_dataset.destroy(&expected_graph)
		actual := make([dynamic]rdf.Quad)
		defer delete(actual)
		for index in 0..<engine.Triple_Count(&result) {
			triple, triple_ok := engine.Triple(&result, index)
			if !triple_ok { fmt.eprintln("cannot read constructed triple"); os.exit(2) }
			if _, append_error := append(&actual, rdf.default_graph_quad(triple)); append_error != nil { fmt.eprintln("cannot allocate constructed graph"); os.exit(2) }
		}
		for quad, index in actual do if rdf.validate_quad_structure(quad) != .None { fmt.eprintf("invalid constructed quad %d\n", index); os.exit(2) }
		for quad, index in expected_graph.quads do if rdf.validate_quad_structure(quad) != .None { fmt.eprintf("invalid expected quad %d\n", index); os.exit(2) }
		normalized_actual, actual_normalized := normalize_graph_for_canonicalization(actual[:])
		if !actual_normalized { fmt.eprintln("cannot normalize constructed RDF graph"); os.exit(2) }
		defer destroy_normalized_graph(&normalized_actual)
		normalized_expected, expected_normalized := normalize_graph_for_canonicalization(expected_graph.quads[:])
		if !expected_normalized { fmt.eprintln("cannot normalize expected RDF graph"); os.exit(2) }
		defer destroy_normalized_graph(&normalized_expected)
		matches, match_error := canon.isomorphic(normalized_actual.quads[:], normalized_expected.quads[:])
		if match_error != .None { fmt.eprintf("cannot compare RDF graphs: %v\n", match_error); os.exit(2) }
		if !matches {
			fmt.eprintf("constructed RDF graph differs (actual=%d expected=%d)\n", len(actual), len(expected_graph.quads))
			for index in 0..<engine.Triple_Count(&result) {
				triple, _ := engine.Triple(&result, index)
				fmt.eprintf("actual[%d]=%s %s %s\n", index, triple.subject.value, triple.predicate.value, triple.object.value)
			}
			for quad, index in expected_graph.quads do fmt.eprintf("expected[%d]=%s %s %s\n", index, quad.subject.value, quad.predicate.value, quad.object.value)
			os.exit(1)
		}
		return
	}
	if json_results {
		output := strings.builder_make()
		defer strings.builder_destroy(&output)
		if results.write_sparql_json(&output, &result) != .None { fmt.eprintln("cannot serialize SPARQL JSON result"); os.exit(2) }
		expected_data, expected_read_error := os.read_entire_file(expected_path, context.allocator)
		if expected_read_error != nil { fmt.eprintln("cannot read expected JSON result"); os.exit(2) }
		defer delete(expected_data)
		actual_json, actual_parse_error := json.parse_string(strings.to_string(output), .JSON, true)
		defer json.destroy_value(actual_json)
		expected_json, expected_parse_error := json.parse_string(string(expected_data), .JSON, true)
		defer json.destroy_value(expected_json)
		if actual_parse_error != .None || expected_parse_error != .None { fmt.eprintln("cannot parse SPARQL JSON result"); os.exit(2) }
		mapping := make([dynamic]JSON_Blank_Node_Mapping)
		defer delete(mapping)
		if !json_values_equal(actual_json, expected_json, &mapping) { fmt.eprintf("SPARQL JSON result differs from expected SRJ: %s\n", strings.to_string(output)); os.exit(1) }
		return
	}
	if xml_results {
		output := strings.builder_make()
		defer strings.builder_destroy(&output)
		if results.write_sparql_xml(&output, &result) != .None { fmt.eprintln("cannot serialize SPARQL XML result"); os.exit(2) }
		expected_data, expected_read_error := os.read_entire_file(expected_path, context.allocator)
		if expected_read_error != nil { fmt.eprintln("cannot read expected XML result"); os.exit(2) }
		defer delete(expected_data)
		expected_xml := string(expected_data)
		for len(expected_xml) > 0 && (expected_xml[len(expected_xml) - 1] == '\n' || expected_xml[len(expected_xml) - 1] == '\r') do expected_xml = expected_xml[:len(expected_xml) - 1]
		if strings.to_string(output) != expected_xml {
			fmt.eprintf("SPARQL XML result differs from expected output:\n%s", strings.to_string(output))
			os.exit(1)
		}
		return
	}
	if csv_results || tsv_results {
		output := strings.builder_make()
		defer strings.builder_destroy(&output)
		write_error := csv_results ? results.write_sparql_csv(&output, &result) : results.write_sparql_tsv(&output, &result)
		if write_error != .None { fmt.eprintln("cannot serialize SPARQL CSV/TSV result"); os.exit(2) }
		expected_data, expected_read_error := os.read_entire_file(expected_path, context.allocator)
		if expected_read_error != nil { fmt.eprintln("cannot read expected CSV/TSV result"); os.exit(2) }
		defer delete(expected_data)
		if strings.to_string(output) != string(expected_data) {
			format := csv_results ? "CSV" : "TSV"
			fmt.eprintf("SPARQL %s result differs from expected output:\n%s", format, strings.to_string(output))
			os.exit(1)
		}
		return
	}
	expected, expected_ok := parse_expected_rows(expected_path, result_base)
	defer destroy_expected(&expected)
	if !expected_ok { fmt.eprintln("cannot parse SRX result"); os.exit(2) }
	if expected.kind == .Ask {
		if engine.Kind(&result) != .Ask { fmt.eprintln("SPARQL result kind differs from expected ASK result"); os.exit(1) }
		actual, actual_ok := engine.Ask_Value(&result)
		if !actual_ok || actual != expected.ask { fmt.eprintf("SPARQL ASK result differs (actual=%v expected=%v)\n", actual, expected.ask); os.exit(1) }
		return
	}
	if engine.Kind(&result) != .Select { fmt.eprintln("SPARQL result kind differs from expected SELECT result"); os.exit(1) }
	rows_match := compare_rows(&result, expected.rows)
	if ordered do rows_match = compare_rows_in_order(&result, expected.rows)
	if lax_reduced do rows_match = compare_rows_lax_reduced(&result, expected.rows)
	if !rows_match {
		fmt.eprintf("SPARQL result multiset differs from SRX (actual=%d expected=%d)\n", engine.Row_Count(&result), len(expected.rows))
		for row in 0..<engine.Row_Count(&result) {
			for column in 0..<engine.Variable_Count(&result) {
				name, _ := engine.Variable_Name(&result, column)
				term, bound, _ := engine.Cell(&result, row, column)
				if bound do fmt.eprintf("actual[%d].%s=%s kind=%v lang=%s datatype=%s\n", row, name, term.value, term.kind, term.language, term.datatype)
			}
		}
		for expected_row, row in expected.rows {
			for binding in expected_row.bindings do fmt.eprintf("expected[%d].%s=%s kind=%v lang=%s datatype=%s\n", row, binding.name, binding.term.value, binding.term.kind, binding.term.language, binding.term.datatype)
		}
		os.exit(1)
	}
}
