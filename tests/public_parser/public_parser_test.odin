package public_parser_test

import "core:testing"
import sparql "../../sparql"

@(test)
test_public_parser_zero_query_is_safe_to_destroy_after_failure :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT {`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.Expected_Variable)
}

@(test)
test_public_parser_api_traverses_source_patterns :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX ex: <urn:example:>
		SELECT ?subject { ?subject ex:parent/ex:name ?name . FILTER(?name = "Ada") }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Query_Form_Of(&query), sparql.Query_Form.Select)
	testing.expect_value(t, sparql.Query_Prefix_Count(&query), 1)

	root, root_ok := sparql.Query_Where_Pattern(&query)
	testing.expect_value(t, root_ok, true)
	testing.expect_value(t, sparql.Pattern_Child_Count(&query, root), 2)
	bgp, bgp_ok := sparql.Pattern_Child(&query, root, 0)
	testing.expect_value(t, bgp_ok, true)
	testing.expect_value(t, sparql.Pattern_Triple_Count(&query, bgp), 1)
	triple, triple_ok := sparql.Pattern_Triple(&query, bgp, 0)
	testing.expect_value(t, triple_ok, true)
	testing.expect_value(t, triple.Subject.Lexical, "?subject")
	path, path_ok := sparql.Path(&query, triple.Path)
	testing.expect_value(t, path_ok, true)
	testing.expect_value(t, path.Kind, sparql.Path_Kind.Sequence)
	testing.expect_value(t, sparql.Path_Child_Count(&query, triple.Path), 2)

	filter, filter_ok := sparql.Pattern_Child(&query, root, 1)
	testing.expect_value(t, filter_ok, true)
	filter_view, filter_view_ok := sparql.Pattern(&query, filter)
	testing.expect_value(t, filter_view_ok, true)
	testing.expect_value(t, filter_view.Kind, sparql.Pattern_Kind.Filter)
	expression, expression_ok := sparql.Expression(&query, filter_view.Expression)
	testing.expect_value(t, expression_ok, true)
	testing.expect_value(t, expression.Operator, sparql.Expression_Operator.Equal)
}

@(test)
test_public_parser_api_exposes_bounded_path_cardinality :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`SELECT ?end WHERE { <urn:start> <urn:p>{2,} ?end }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	root, root_ok := sparql.Query_Where_Pattern(&query)
	testing.expect_value(t, root_ok, true)
	bgp, bgp_ok := sparql.Pattern_Child(&query, root, 0)
	testing.expect_value(t, bgp_ok, true)
	triple, triple_ok := sparql.Pattern_Triple(&query, bgp, 0)
	testing.expect_value(t, triple_ok, true)
	path, path_ok := sparql.Path(&query, triple.Path)
	testing.expect_value(t, path_ok, true)
	testing.expect_value(t, path.Kind, sparql.Path_Kind.Bounded)
	testing.expect_value(t, path.Minimum, 2)
	testing.expect_value(t, path.Has_Maximum, false)
	testing.expect_value(t, sparql.Path_Child_Count(&query, triple.Path), 1)
}

@(test)
test_public_parser_api_exposes_term_nodes_and_values :: proc(t: ^testing.T) {
	query, parse_error := sparql.Parse(`PREFIX ex: <urn:example:>
		SELECT * { [ ex:label ?label ] VALUES ?label { "Ada" UNDEF } }`)
	defer sparql.Destroy(&query)
	testing.expect_value(t, sparql.Parse_Error_Code(parse_error), sparql.Error_Code.None)
	root, root_ok := sparql.Query_Where_Pattern(&query)
	testing.expect_value(t, root_ok, true)
	bgp, bgp_ok := sparql.Pattern_Child(&query, root, 0)
	testing.expect_value(t, bgp_ok, true)
	node_term, node_term_ok := sparql.Pattern_Standalone_Node(&query, bgp, 0)
	testing.expect_value(t, node_term_ok, true)
	testing.expect_value(t, node_term.Kind, sparql.Term_Kind.Blank_Property_List)
	node, node_ok := sparql.Query_Term_Node(&query, node_term.Syntax_Node)
	testing.expect_value(t, node_ok, true)
	testing.expect_value(t, node.Kind, sparql.Term_Node_Kind.Blank_Property_List)
	testing.expect_value(t, sparql.Term_Node_Property_Count(&query, node_term.Syntax_Node), 1)

	values, values_ok := sparql.Pattern_Child(&query, root, 1)
	testing.expect_value(t, values_ok, true)
	testing.expect_value(t, sparql.Pattern_Values_Variable_Count(&query, values), 1)
	testing.expect_value(t, sparql.Pattern_Values_Row_Count(&query, values), 2)
	first, first_unbound, first_ok := sparql.Pattern_Values_Cell(&query, values, 0, 0)
	testing.expect_value(t, first_ok, true)
	testing.expect_value(t, first_unbound, false)
	testing.expect_value(t, first.Lexical, `"Ada"`)
	_, second_unbound, second_ok := sparql.Pattern_Values_Cell(&query, values, 1, 0)
	testing.expect_value(t, second_ok, true)
	testing.expect_value(t, second_unbound, true)
}

@(test)
test_public_parser_api_exposes_construct_describe_and_diagnostics :: proc(t: ^testing.T) {
	construct, construct_error := sparql.Parse(`CONSTRUCT { ?subject <urn:p> ?object } WHERE { ?subject <urn:p> ?object }`)
	defer sparql.Destroy(&construct)
	testing.expect_value(t, sparql.Parse_Error_Code(construct_error), sparql.Error_Code.None)
	template, template_ok := sparql.Query_Construct_Template(&construct)
	testing.expect_value(t, template_ok, true)
	testing.expect_value(t, sparql.Query_Construct_Where_Shorthand(&construct), false)
	template_bgp, template_bgp_ok := sparql.Pattern_Child(&construct, template, 0)
	testing.expect_value(t, template_bgp_ok, true)
	testing.expect_value(t, sparql.Pattern_Triple_Count(&construct, template_bgp), 1)

	describe, describe_error := sparql.Parse(`DESCRIBE <urn:ada> ?friend WHERE { ?friend <urn:knows> <urn:ada> }`)
	defer sparql.Destroy(&describe)
	testing.expect_value(t, sparql.Parse_Error_Code(describe_error), sparql.Error_Code.None)
	testing.expect_value(t, sparql.Query_Describe_All(&describe), false)
	testing.expect_value(t, sparql.Query_Describe_Term_Count(&describe), 2)
	first, first_ok := sparql.Query_Describe_Term(&describe, 0)
	testing.expect_value(t, first_ok, true)
	testing.expect_value(t, first.Lexical, "<urn:ada>")

	_, invalid_error := sparql.Parse(`SELECT {`)
	testing.expect_value(t, sparql.Parse_Error_Code(invalid_error), sparql.Error_Code.Expected_Variable)
	testing.expect_value(t, sparql.Parse_Error_Message(invalid_error), "expected query variable")
	testing.expect_value(t, sparql.Parse_Error_Range(invalid_error).Start.Line, 1)
}
