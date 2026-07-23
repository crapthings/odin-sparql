package algebra

import "core:testing"
import sparql ".."

@(test)
test_translate_resolves_prefixes_literals_and_variable_identity :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`BASE <https://example.test/base/>
		PREFIX ex: <vocab/>
		SELECT ?subject { ?subject a "Ada\n"@en . $subject ex:age 42 }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	testing.expect_value(t, len(plan.triples), 2)
	testing.expect_value(t, len(plan.variables), 1)
	root, root_ok := Root_Operator(&plan)
	testing.expect_value(t, root_ok, true)
	operator, operator_ok := Operator_At(&plan, root)
	testing.expect_value(t, operator_ok, true)
	testing.expect_value(t, operator.Kind, Operator_Kind.BGP)
	testing.expect_value(t, operator.First_Triple, 0)
	testing.expect_value(t, operator.Triple_Count, 2)
	if len(plan.triples) == 2 {
		first := plan.triples[0]
		second := plan.triples[1]
		testing.expect_value(t, first.subject.kind, Slot_Kind.Variable)
		testing.expect_value(t, first.subject.variable, second.subject.variable)
		testing.expect_value(t, first.predicate.term.value, "http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
		testing.expect_value(t, first.object.term.value, "Ada\n")
		testing.expect_value(t, first.object.term.language, "en")
		testing.expect_value(t, second.predicate.term.value, "https://example.test/base/vocab/age")
		testing.expect_value(t, second.object.term.value, "42")
		testing.expect_value(t, second.object.term.datatype, "http://www.w3.org/2001/XMLSchema#integer")
	}
}

@(test)
test_translate_treats_query_blank_labels_as_variables :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * { _:node <urn:parent> ?child . _:node <urn:name> "Ada" }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	testing.expect_value(t, len(plan.variables), 2)
	if len(plan.triples) == 2 {
		testing.expect_value(t, plan.triples[0].subject.kind, Slot_Kind.Variable)
		testing.expect_value(t, plan.triples[0].subject.variable, plan.triples[1].subject.variable)
	}
}

@(test)
test_translate_records_top_level_select_star_columns_in_source_order :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * WHERE { ?subject ?predicate ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	expected_names := [3]string{"subject", "predicate", "object"}
	testing.expect_value(t, Result_Variable_Count(&plan), len(expected_names))
	for expected, index in expected_names {
		variable, variable_ok := Result_Variable(&plan, index)
		name, name_ok := Variable_Name(&plan, variable)
		testing.expect_value(t, variable_ok && name_ok, true)
		testing.expect_value(t, name, expected)
	}
}

@(test)
test_translate_lowers_blank_property_lists_without_exposing_internal_subject :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { { SELECT * { ?subject <urn:details> [ <urn:property> ?value ] } } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	testing.expect_value(t, len(plan.triples), 2)
	testing.expect_value(t, len(plan.projection_variables), 2)
	if len(plan.triples) == 2 {
		property := plan.triples[0]
		outer := plan.triples[1]
		testing.expect_value(t, outer.subject.kind, Slot_Kind.Variable)
		testing.expect_value(t, outer.object.kind, Slot_Kind.Variable)
		testing.expect_value(t, property.subject.variable, outer.object.variable)
		testing.expect_value(t, property.predicate.term.value, "urn:property")
		testing.expect_value(t, property.object.kind, Slot_Kind.Variable)
		if len(plan.projection_variables) == 2 {
			testing.expect_value(t, plan.projection_variables[0], outer.subject.variable)
			testing.expect_value(t, plan.projection_variables[1], property.object.variable)
		}
	}
}

@(test)
test_translate_lowers_collections_and_hides_generated_cells_from_select_star :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { { SELECT * { ?subject <urn:items> (?first [ <urn:value> ?second ]) } } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	testing.expect_value(t, len(plan.triples), 6)
	testing.expect_value(t, len(plan.projection_variables), 3)
	first_count := 0
	rest_count := 0
	for triple in plan.triples {
		if triple.predicate.kind != Slot_Kind.Term do continue
		if triple.predicate.term.value == RDF_FIRST do first_count += 1
		if triple.predicate.term.value == RDF_REST do rest_count += 1
	}
	testing.expect_value(t, first_count, 2)
	testing.expect_value(t, rest_count, 2)
	for variable in plan.projection_variables {
		name, name_ok := Variable_Name(&plan, variable)
		testing.expect_value(t, name_ok, true)
		testing.expect_value(t, name == "subject" || name == "first" || name == "second", true)
	}
}

@(test)
test_translate_preserves_cast_group_expression_and_alias :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
		SELECT ?integer { ?subject ?predicate ?object } GROUP BY (xsd:integer(?object) AS ?integer)`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	for index in 0..<Operator_Count(&plan) {
		operator, operator_ok := Operator_At(&plan, index)
		if !operator_ok || operator.Kind != .Group do continue
		expression, variable, expression_ok := Group_Expression(&plan, index, 0)
		view, view_ok := Expression_At(&plan, expression)
		name, name_ok := Variable_Name(&plan, variable)
		testing.expect_value(t, expression_ok && view_ok && name_ok, true)
		testing.expect_value(t, view.Kind, Expression_Kind.Cast_Integer)
		testing.expect_value(t, name, "integer")
		return
	}
	testing.expect_value(t, false, true)
}

@(test)
test_translate_preserves_bounded_property_path_cardinality :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * WHERE { ?subject <urn:p>{2,4} ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	found := false
	for index in 0..<len(plan.paths) {
		path := plan.paths[index]
		if path.kind != .Bounded do continue
		found = true
		testing.expect_value(t, path.minimum, 2)
		testing.expect_value(t, path.maximum, 4)
		testing.expect_value(t, path.has_maximum, true)
	}
	testing.expect_value(t, found, true)
}

@(test)
test_translate_joins_nested_property_paths_without_exposing_private_nodes :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { { SELECT * { ?root <urn:items> ([ <urn:p>{1,} ?end ]) } } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	path_found := false
	for index in 0..<Operator_Count(&plan) {
		operator, operator_ok := Operator_At(&plan, index)
		if operator_ok && operator.Kind == Operator_Kind.Path do path_found = true
	}
	testing.expect_value(t, path_found, true)
	testing.expect_value(t, len(plan.projection_variables), 2)
	for variable in plan.projection_variables {
		name, name_ok := Variable_Name(&plan, variable)
		testing.expect_value(t, name_ok, true)
		testing.expect_value(t, name == "root" || name == "end", true)
	}
}

@(test)
test_translate_lowers_empty_and_standalone_collections :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { () <urn:empty> ?value . (<urn:only>) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	// The standalone singleton list contributes first/rest triples; the empty
	// collection is the rdf:nil term in the explicit triple.
	testing.expect_value(t, len(plan.triples), 3)
	nil_found := false
	for triple in plan.triples {
		if triple.object.kind == Slot_Kind.Term && triple.object.term.value == RDF_NIL do nil_found = true
	}
	testing.expect_value(t, nil_found, true)
}

@(test)
test_translate_compiles_alternative_property_paths_to_path_operators :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT * { ?subject <urn:p>|<urn:q> ?object }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	path_found := false
	for index in 0..<Operator_Count(&plan) {
		operator, operator_ok := Operator_At(&plan, index)
		if operator_ok && operator.Kind == Operator_Kind.Path do path_found = true
	}
	testing.expect_value(t, path_found, true)
}

@(test)
test_translate_preserves_service_endpoint_silent_and_select_star_visibility :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { { SELECT * { SERVICE SILENT ?endpoint { ?subject <urn:p> ?object } } } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
	service_found := false
	for index in 0..<Operator_Count(&plan) {
		operator, operator_ok := Operator_At(&plan, index)
		if !operator_ok || operator.Kind != .Service do continue
		service_found = true
		testing.expect_value(t, operator.Service.Kind, Slot_Kind.Variable)
		testing.expect_value(t, operator.Service_Silent, true)
	}
	testing.expect_value(t, service_found, true)
	testing.expect_value(t, len(plan.projection_variables), 3)
	expected_names := [3]string{"endpoint", "subject", "object"}
	for expected, index in expected_names {
		variable := plan.projection_variables[index]
		name, name_ok := Variable_Name(&plan, variable)
		testing.expect_value(t, name_ok, true)
		testing.expect_value(t, name, expected)
	}
}

@(test)
test_translate_supports_aggregate_subquery :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`ASK { { SELECT (SAMPLE(?value) AS ?sample) WHERE { ?subject <urn:value> ?value } } FILTER(?sample = 1) }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	plan, translate_error := translate(&query)
	defer destroy(&plan)
	testing.expect_value(t, translate_error, Error_Code.None)
}
