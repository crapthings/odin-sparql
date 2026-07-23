// Package sparql provides SPARQL 1.1 query parsing and execution for Odin.
package sparql

import "core:strings"

// Source_Position identifies a UTF-8 location in the original query string.
// byte_offset is zero-based; line and column are one-based.
Source_Position :: struct {
	byte_offset: int,
	line:        int,
	column:      int,
}

// Source_Span is a half-open range in the original query string.
Source_Span :: struct {
	start: Source_Position,
	end:   Source_Position,
}

// Source_Location is a public copy of a source position. All fields are
// one-based except Byte_Offset, which is zero-based.
Source_Location :: struct {
	Byte_Offset: int,
	Line:        int,
	Column:      int,
}

// Source_Range is the public half-open source range returned by AST views.
Source_Range :: struct {
	Start: Source_Location,
	End:   Source_Location,
}

// Arena references are valid only for the Query that returned them. Their
// integer representation is intentionally not an AST layout guarantee.
Pattern_Ref :: int
Expression_Ref :: int
Path_Ref :: int
Term_Node_Ref :: int

Invalid_Pattern_Ref :: Pattern_Ref(-1)
Invalid_Expression_Ref :: Expression_Ref(-1)
Invalid_Path_Ref :: Path_Ref(-1)
Invalid_Term_Node_Ref :: Term_Node_Ref(-1)

// Query_Form identifies the SPARQL query form represented by Query.
Query_Form :: enum {
	Select,
	Ask,
	Construct,
	Describe,
}

// Select_Modifier controls duplicate handling for a SELECT query.
Select_Modifier :: enum {
	None,
	Distinct,
	Reduced,
}

// Order_Direction preserves explicit ASC/DESC syntax. Default leaves ordering
// direction to SPARQL's default ascending rule during evaluation.
Order_Direction :: enum {
	Default,
	Ascending,
	Descending,
}

// Order_Condition is one ORDER BY expression.
Order_Condition :: struct {
	direction:  Order_Direction,
	expression: int,
	span:       Source_Span,
}

// Term_Kind identifies a source-level SPARQL term. IRI expansion, literal
// unescaping, and query blank-node semantics are handled during algebra
// translation rather than while preserving syntax.
Term_Kind :: enum {
	Variable,
	IRIREF,
	Prefixed_Name,
	Blank_Node_Label,
	String_Literal,
	Integer,
	Decimal,
	Double,
	Boolean,
	RDF_Type,
	Blank_Property_List,
	Collection,
}

// Term is an owned source-level term. lexical preserves normalized SPARQL
// spelling, including delimiters such as `<...>` and string quotes. Variable
// lexical values retain their `?` or `$` marker until algebra translation.
// Blank property lists and collections refer to Query.term_nodes instead.
Term :: struct {
	kind:              Term_Kind,
	lexical:           string,
	has_language:      bool,
	language:          string,
	has_datatype:      bool,
	datatype_kind:     Term_Kind,
	datatype_lexical:  string,
	syntax_node:       int,
	span:              Source_Span,
}

// Term_Node_Kind identifies source constructs that later lower to generated
// algebra variables and triples. They deliberately remain distinct from
// dataset blank nodes.
Term_Node_Kind :: enum {
	Blank_Property_List,
	Collection,
}

// Property_List preserves the predicate/object shorthand inside a blank
// property list before algebra lowering expands its implicit subject.
Property_List :: struct {
	predicate: Term,
	path:      int,
	objects:   [dynamic]Term,
	span:      Source_Span,
}

// Term_Node preserves a blank property list or collection in source form.
Term_Node :: struct {
	kind:       Term_Node_Kind,
	span:       Source_Span,
	properties: [dynamic]Property_List,
	items:      [dynamic]Term,
}

// Path_Kind preserves SPARQL property-path structure for later algebra
// translation. A Term path holds one ordinary predicate term.
Path_Kind :: enum {
	Term,
	Inverse,
	Alternative,
	Sequence,
	Zero_Or_More,
	One_Or_More,
	Zero_Or_One,
	Bounded,
	Negated_Set,
}

// Path_Node belongs to Query.paths. children are path-node indices. A negated
// set stores its terms and whether each is inverse in parallel arrays.
Path_Node :: struct {
	kind:          Path_Kind,
	span:          Source_Span,
	term:          Term,
	children:      [dynamic]int,
	negated_terms: [dynamic]Term,
	negated_inverse: [dynamic]bool,
	minimum:       int,
	maximum:       int,
	has_maximum:   bool,
}

// Invalid_Path identifies a triple predicate that has not been represented
// as a property path. New parser output always assigns a path node.
Invalid_Path :: -1

// Invalid_Term_Node identifies an ordinary Term without source-node content.
Invalid_Term_Node :: -1

// Pattern_Kind identifies a source-level group graph-pattern item. Only Group
// and Basic_Graph_Pattern are populated during the first parser slice; the
// remaining kinds reserve the recursive AST shape required by SPARQL 1.1.
Pattern_Kind :: enum {
	Group,
	Basic_Graph_Pattern,
	Optional,
	Union,
	Minus,
	Graph,
	Filter,
	Bind,
	Values,
	Service,
	Subquery,
}

// Expression_Kind identifies a source-level expression node. Evaluation
// resolves RDF values and function behavior only after algebra translation.
Expression_Kind :: enum {
	Term,
	Wildcard,
	Unary,
	Binary,
	Function,
	Exists,
	Not_Exists,
	In,
	Not_In,
}

// Expression_Operator identifies the parsed operator where applicable.
Expression_Operator :: enum {
	None,
	Not,
	Unary_Plus,
	Unary_Minus,
	Multiply,
	Divide,
	Add,
	Subtract,
	Equal,
	Not_Equal,
	Less,
	Less_Or_Equal,
	Greater,
	Greater_Or_Equal,
	And,
	Or,
}

// Expression_Node belongs to Query.expressions. Its children are expression
// indexes, except EXISTS nodes whose single child is a pattern index.
Expression_Node :: struct {
	kind:     Expression_Kind,
	operator: Expression_Operator,
	span:     Source_Span,
	term:     Term,
	name:     string,
	uses_distinct: bool,
	has_separator: bool,
	separator: Term,
	children: [dynamic]int,
}

// Values_Row is one VALUES binding row. values and unbound have equal length;
// an unbound entry does not carry an RDF term.
Values_Row :: struct {
	values:  [dynamic]Term,
	unbound: [dynamic]bool,
	span:    Source_Span,
}

// Invalid_Expression identifies an absent optional expression.
Invalid_Expression :: -1

// Pattern_Node belongs to Query.patterns. children retain source-order item
// relationships by index; triples is populated only by a BGP node.
Pattern_Node :: struct {
	kind:       Pattern_Kind,
	span:       Source_Span,
	triples:    [dynamic]Triple_Pattern,
	standalone_nodes: [dynamic]Term,
	children:   [dynamic]int,
	graph_name: Term,
	expression: int,
	variable:   Term,
	values_variables: [dynamic]Term,
	values_rows:      [dynamic]Values_Row,
	subquery:          int,
	service_name:      Term,
	service_silent:    bool,
}

// Invalid_Pattern identifies an absent optional group pattern.
Invalid_Pattern :: -1

// Ask_Query contains the group graph pattern tested for the existence of at
// least one solution.
Ask_Query :: struct {
	where_pattern: int,
}

// Construct_Query separates a source template from the WHERE graph pattern.
// Template blank-node labels remain source terms until algebra translation.
Construct_Query :: struct {
	template:        int,
	where_pattern:   int,
	where_shorthand: bool,
}

// Describe_Query preserves requested resources and an optional WHERE pattern.
// A DESCRIBE result policy deliberately belongs to evaluation, not parsing.
Describe_Query :: struct {
	describe_all: bool,
	terms:        [dynamic]Term,
	where_pattern: int,
	has_where:    bool,
}

// Dataset_Clause identifies a default or named source selected by FROM.
Dataset_Clause :: struct {
	named:  bool,
	source: Term,
	span:   Source_Span,
}

// Prefix_Decl preserves one PREFIX declaration in source order.
Prefix_Decl :: struct {
	prefix:    Term,
	namespace: Term,
	span:      Source_Span,
}

// Triple_Pattern is one expanded BGP statement before property-list and
// collection syntax are lowered.
Triple_Pattern :: struct {
	subject:   Term,
	predicate: Term,
	path:      int,
	object:    Term,
	span:      Source_Span,
}

// Select_Query contains the projection and group pattern for a SELECT query.
// projection and projection_expressions have equal length; an
// Invalid_Expression entry represents an ordinary projected variable.
Select_Query :: struct {
	modifier:   Select_Modifier,
	select_all: bool,
	projection: [dynamic]Term,
	projection_expressions: [dynamic]int,
	where_pattern: int,
}

// Query owns every lexical string referenced by its fields. Call destroy once
// after use, even if later lowering or evaluation fails.
Query :: struct {
	form:          Query_Form,
	base:          Term,
	has_base:      bool,
	prefixes:      [dynamic]Prefix_Decl,
	dataset:       [dynamic]Dataset_Clause,
	patterns:      [dynamic]Pattern_Node,
	expressions:   [dynamic]Expression_Node,
	term_nodes:    [dynamic]Term_Node,
	paths:         [dynamic]Path_Node,
	subqueries:    [dynamic]Query,
	tail_values:   [dynamic]int,
	group_by:       [dynamic]int,
	group_aliases:  [dynamic]Term,
	having:         [dynamic]int,
	order:         [dynamic]Order_Condition,
	has_limit:     bool,
	limit:         Term,
	has_offset:    bool,
	offset:        Term,
	select:        Select_Query,
	ask:           Ask_Query,
	construct:     Construct_Query,
	describe:      Describe_Query,
	span:          Source_Span,
	owned: [dynamic]string,
}

// destroy releases every string and dynamic AST sequence owned by query. The
// zero value is safe to destroy and the Query must not be reused afterwards.
destroy :: proc(query: ^Query) {
	for value in query.owned do delete(value)
	delete(query.owned)
	delete(query.prefixes)
	delete(query.dataset)
	delete(query.group_by)
	delete(query.group_aliases)
	delete(query.having)
	delete(query.order)
	for node in query.term_nodes {
		for property in node.properties do delete(property.objects)
		delete(node.properties)
		delete(node.items)
	}
	delete(query.term_nodes)
	for path in query.paths {
		delete(path.children)
		delete(path.negated_terms)
		delete(path.negated_inverse)
	}
	delete(query.paths)
	for index in 0..<len(query.subqueries) do destroy(&query.subqueries[index])
	delete(query.subqueries)
	delete(query.tail_values)
	delete(query.select.projection)
	delete(query.select.projection_expressions)
	delete(query.describe.terms)
	for pattern in query.patterns {
		delete(pattern.triples)
		delete(pattern.standalone_nodes)
		delete(pattern.children)
		delete(pattern.values_variables)
		for row in pattern.values_rows {
			delete(row.values)
			delete(row.unbound)
		}
		delete(pattern.values_rows)
	}
	delete(query.patterns)
	for expression in query.expressions do delete(expression.children)
	delete(query.expressions)
	query^ = {}
}

@(private) init_query :: proc(query: ^Query) {
	query^ = Query{
		prefixes = make([dynamic]Prefix_Decl),
		dataset = make([dynamic]Dataset_Clause),
		patterns = make([dynamic]Pattern_Node),
		expressions = make([dynamic]Expression_Node),
		term_nodes = make([dynamic]Term_Node),
		paths = make([dynamic]Path_Node),
		subqueries = make([dynamic]Query),
		tail_values = make([dynamic]int),
		group_by = make([dynamic]int),
		group_aliases = make([dynamic]Term),
		having = make([dynamic]int),
		order = make([dynamic]Order_Condition),
		select = {
			projection = make([dynamic]Term),
			projection_expressions = make([dynamic]int),
			where_pattern = Invalid_Pattern,
		},
		ask = {where_pattern = Invalid_Pattern},
		construct = {
			template = Invalid_Pattern,
			where_pattern = Invalid_Pattern,
		},
		describe = {
			terms = make([dynamic]Term),
			where_pattern = Invalid_Pattern,
		},
		owned = make([dynamic]string),
	}
}

@(private) own_string :: proc(query: ^Query, value: string) -> (string, bool) {
	cloned, clone_error := strings.clone(value)
	if clone_error != nil do return "", false
	_, append_error := append(&query.owned, cloned)
	if append_error != nil {
		delete(cloned)
		return "", false
	}
	return cloned, true
}
