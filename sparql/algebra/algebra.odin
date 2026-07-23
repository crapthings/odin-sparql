// Package algebra translates parsed SPARQL source into executable algebra.
package algebra

import "core:strings"
import "core:strconv"
import rdf "odin-rdf:rdf"
import turtle "odin-rdf:rdf/turtle"
import sparql ".."

Error_Code :: enum {
	None,
	Unsupported_Query,
	Invalid_IRI,
	Unknown_Prefix,
	Invalid_Literal,
	Out_Of_Memory,
}

@(private) XSD_NAMESPACE :: "http://www.w3.org/2001/XMLSchema#"
@(private) XSD_INTEGER :: XSD_NAMESPACE + "integer"
@(private) XSD_DECIMAL :: XSD_NAMESPACE + "decimal"
@(private) XSD_BOOLEAN :: XSD_NAMESPACE + "boolean"
@(private) XSD_STRING :: XSD_NAMESPACE + "string"
@(private) XSD_FLOAT :: XSD_NAMESPACE + "float"
@(private) XSD_DOUBLE :: XSD_NAMESPACE + "double"
@(private) XSD_DATE :: XSD_NAMESPACE + "date"
@(private) XSD_DATE_TIME :: XSD_NAMESPACE + "dateTime"
@(private) XSD_TIME :: XSD_NAMESPACE + "time"

Slot_Kind :: enum { Term, Variable }

// Operator_Kind identifies one executable algebra node. M2 currently emits a
// single BGP root; later M3 operators retain the same owned Plan boundary.
Operator_Kind :: enum {
	Identity,
	BGP,
	Path,
	Join,
	Left_Join,
	Union,
	Minus,
	Filter,
	Extend,
	Order,
	Values,
	Graph,
	Service,
	// Project is the visibility boundary of a SELECT subquery. It retains only
	// the selected bindings before the subquery joins its enclosing group.
	Project,
	Distinct,
	Slice,
	Group,
}

// Expression_Kind is the resolved, executable subset used by M3 graph-pattern
// operators. Broader SPARQL expression support is scheduled for M4.
Expression_Kind :: enum {
	Term,
	Not,
	Unary_Plus,
	Unary_Minus,
	Add,
	Subtract,
	Multiply,
	Divide,
	Absolute,
	Ceiling,
	Floor,
	Round,
	Bound,
	Same_Term,
	Str,
	Lower,
	Upper,
	Lang,
	Lang_Matches,
	Datatype,
	Is_IRI,
	Is_Blank,
	Is_Literal,
	Is_Numeric,
	If,
	Coalesce,
	Concat,
	Str_Starts,
	Str_Ends,
	Contains,
	Regex,
	Replace,
	Str_Length,
	Substring,
	Str_Before,
	Str_After,
	Str_Datatype,
	Str_Language,
	BNode,
	Now,
	UUID,
	STRUUID,
	Rand,
	Year,
	Month,
	Day,
	Hours,
	Minutes,
	Seconds,
	Timezone,
	TZ,
	Cast_Integer,
	Cast_Decimal,
	Cast_Boolean,
	Cast_String,
	Cast_Float,
	Cast_Double,
	Cast_Date,
	Cast_Date_Time,
	Cast_Time,
	Exists,
	Not_Exists,
	Make_IRI,
	Encode_For_URI,
	MD5,
	SHA1,
	SHA256,
	SHA384,
	SHA512,
	In,
	Not_In,
	Equal,
	Not_Equal,
	Less,
	Less_Or_Equal,
	Greater,
	Greater_Or_Equal,
	And,
	Or,
	Count,
	Sum,
	Average,
	Group_Concat,
	Min,
	Max,
	Sample,
}

// Slot is either an RDF term or one query-local variable identity.
Slot :: struct {
	kind:     Slot_Kind,
	term:     rdf.Term,
	variable: int,
}

Triple_Pattern :: struct {
	subject:   Slot,
	predicate: Slot,
	object:    Slot,
}

Slot_View :: struct {
	Kind:     Slot_Kind,
	Term:     rdf.Term,
	Variable: int,
}

Triple_Pattern_View :: struct {
	Subject:   Slot_View,
	Predicate: Slot_View,
	Object:    Slot_View,
}

// Construct_Term_Kind separates template blank-node labels from query
// variables. A template blank label is allocated freshly for every solution,
// whereas an ordinary query blank label is an existential pattern variable.
Construct_Term_Kind :: enum { Term, Variable, Blank }

Construct_Term_View :: struct {
	Kind:     Construct_Term_Kind,
	Term:     rdf.Term,
	Variable: int,
	Blank:    string,
}

Construct_Triple_View :: struct {
	Subject:   Construct_Term_View,
	Predicate: Construct_Term_View,
	Object:    Construct_Term_View,
}

@(private) Construct_Term :: struct {
	kind:     Construct_Term_Kind,
	term:     rdf.Term,
	variable: int,
	blank:    string,
}

@(private) Construct_Template_Triple :: struct {
	subject:   Construct_Term,
	predicate: Construct_Term,
	object:    Construct_Term,
}

// Property_Path_Kind is the executable counterpart of the parsed SPARQL path
// tree. It is owned by Plan so evaluation never borrows parser storage.
Property_Path_Kind :: enum {
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

Property_Path_View :: struct {
	Kind:                Property_Path_Kind,
	Term:                Slot_View,
	Child_Count:         int,
	Negated_Term_Count:  int,
	Minimum:             int,
	Maximum:             int,
	Has_Maximum:         bool,
}

Property_Path_Pattern_View :: struct {
	Path:    int,
	Subject: Slot_View,
	Object:  Slot_View,
}

@(private) Property_Path :: struct {
	kind:               Property_Path_Kind,
	term:               Slot,
	first_child:        int,
	child_count:        int,
	first_negated_term: int,
	negated_term_count: int,
	minimum:            int,
	maximum:            int,
	has_maximum:        bool,
}

@(private) Property_Path_Pattern :: struct {
	path:    int,
	subject: Slot,
	object:  Slot,
}

Expression_View :: struct {
	Kind:        Expression_Kind,
	Term:        Slot_View,
	Child_Count: int,
	Relation:    int,
	Uses_Distinct: bool,
	Has_Separator: bool,
	Separator: Slot_View,
}

// Operator_View exposes an immutable algebra node without exposing Plan's
// storage layout. Child indexes are retrieved with Operator_Child.
Operator_View :: struct {
	Kind:          Operator_Kind,
	First_Triple:  int,
	Triple_Count:  int,
	Path_Pattern:  int,
	Child_Count:   int,
	Has_Graph:     bool,
	Graph:         Slot_View,
	Service:       Slot_View,
	Service_Silent: bool,
	First_Values_Variable: int,
	Values_Variable_Count: int,
	First_Values_Cell:     int,
	Values_Row_Count:      int,
	Expression:            int,
	Variable:              int,
	First_Order:           int,
	Order_Count:           int,
	First_Projection_Variable: int,
	Projection_Variable_Count: int,
	Slice_Offset: int,
	Slice_Limit: int,
	Has_Slice_Limit: bool,
	First_Group_Expression: int,
	Group_Expression_Count: int,
	First_Group_Aggregate: int,
	Group_Aggregate_Count: int,
}

@(private) Operator :: struct {
	kind:          Operator_Kind,
	first_triple:  int,
	triple_count:  int,
	path_pattern:  int,
	first_child:   int,
	child_count:   int,
	has_graph:     bool,
	graph:         Slot,
	service:       Slot,
	service_silent: bool,
	first_values_variable: int,
	values_variable_count: int,
	first_values_cell:     int,
	values_row_count:      int,
	expression:             int,
	variable:               int,
	first_order:            int,
	order_count:            int,
	first_projection_variable: int,
	projection_variable_count: int,
	slice_offset: int,
	slice_limit: int,
	has_slice_limit: bool,
	first_group_expression: int,
	group_expression_count: int,
	first_group_aggregate: int,
	group_aggregate_count: int,
}

@(private) Expression :: struct {
	kind:        Expression_Kind,
	term:        Slot,
	first_child: int,
	child_count: int,
	relation:    int,
	uses_distinct: bool,
	has_separator: bool,
	separator: Slot,
}

// Plan owns every RDF string, variable spelling, expression, and operator
// referenced by executable query algebra.
Plan :: struct {
	triples:   [dynamic]Triple_Pattern,
	construct_triples: [dynamic]Construct_Template_Triple,
	describe_targets: [dynamic]Construct_Term,
	paths:     [dynamic]Property_Path,
	path_children: [dynamic]int,
	path_negated_terms: [dynamic]Slot,
	path_negated_inverse: [dynamic]bool,
	path_patterns: [dynamic]Property_Path_Pattern,
	variables: [dynamic]string,
	owned:     [dynamic]string,
	operators: [dynamic]Operator,
	children:  [dynamic]int,
	root:      int,
	values_variables: [dynamic]int,
	values_cells:     [dynamic]Slot,
	values_unbound:   [dynamic]bool,
	expressions:      [dynamic]Expression,
	expression_children: [dynamic]int,
	order_expressions: [dynamic]int,
	order_descending:  [dynamic]bool,
	projection_variables: [dynamic]int,
	// result_variables records the requested top-level SELECT columns in source
	// order. Project remains reserved for subquery visibility boundaries.
	result_variables: [dynamic]int,
	group_expressions: [dynamic]int,
	group_variables: [dynamic]int,
	group_aggregates: [dynamic]int,
	dataset_default_graphs: [dynamic]rdf.Term,
	dataset_named_graphs:   [dynamic]rdf.Term,
	has_dataset_description: bool,
}

error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:              return "no error"
	case .Unsupported_Query: return "query feature is not implemented in this algebra slice"
	case .Invalid_IRI:       return "invalid or unresolved IRI reference"
	case .Unknown_Prefix:    return "unknown SPARQL prefix"
	case .Invalid_Literal:   return "invalid SPARQL literal"
	case .Out_Of_Memory:     return "memory allocation failed"
	}
	return "unknown algebra error"
}

destroy :: proc(plan: ^Plan) {
	for value in plan.owned do delete(value)
	delete(plan.owned)
	delete(plan.variables)
	delete(plan.triples)
	delete(plan.construct_triples)
	delete(plan.describe_targets)
	delete(plan.paths)
	delete(plan.path_children)
	delete(plan.path_negated_terms)
	delete(plan.path_negated_inverse)
	delete(plan.path_patterns)
	delete(plan.operators)
	delete(plan.children)
	delete(plan.values_variables)
	delete(plan.values_cells)
	delete(plan.values_unbound)
	delete(plan.expressions)
	delete(plan.expression_children)
	delete(plan.order_expressions)
	delete(plan.order_descending)
	delete(plan.projection_variables)
	delete(plan.result_variables)
	delete(plan.group_expressions)
	delete(plan.group_variables)
	delete(plan.group_aggregates)
	delete(plan.dataset_default_graphs)
	delete(plan.dataset_named_graphs)
	plan^ = {}
}

@(private) public_slot :: proc(value: Slot) -> Slot_View {
	return Slot_View{Kind = value.kind, Term = value.term, Variable = value.variable}
}

Triple_Count :: proc(plan: ^Plan) -> int { return len(plan.triples) }

Triple :: proc(plan: ^Plan, index: int) -> (Triple_Pattern_View, bool) {
	if index < 0 || index >= len(plan.triples) do return {}, false
	value := plan.triples[index]
	return Triple_Pattern_View{Subject = public_slot(value.subject), Predicate = public_slot(value.predicate), Object = public_slot(value.object)}, true
}

Construct_Triple_Count :: proc(plan: ^Plan) -> int { return len(plan.construct_triples) }

@(private) public_construct_term :: proc(value: Construct_Term) -> Construct_Term_View {
	return Construct_Term_View{Kind = value.kind, Term = value.term, Variable = value.variable, Blank = value.blank}
}

Construct_Triple :: proc(plan: ^Plan, index: int) -> (Construct_Triple_View, bool) {
	if index < 0 || index >= len(plan.construct_triples) do return {}, false
	value := plan.construct_triples[index]
	return Construct_Triple_View{Subject = public_construct_term(value.subject), Predicate = public_construct_term(value.predicate), Object = public_construct_term(value.object)}, true
}

Describe_Target_Count :: proc(plan: ^Plan) -> int { return len(plan.describe_targets) }

Describe_Target :: proc(plan: ^Plan, index: int) -> (Construct_Term_View, bool) {
	if index < 0 || index >= len(plan.describe_targets) do return {}, false
	return public_construct_term(plan.describe_targets[index]), true
}

Variable_Count :: proc(plan: ^Plan) -> int { return len(plan.variables) }

Variable_Name :: proc(plan: ^Plan, index: int) -> (string, bool) {
	if index < 0 || index >= len(plan.variables) do return "", false
	return plan.variables[index], true
}

Operator_Count :: proc(plan: ^Plan) -> int { return len(plan.operators) }

Root_Operator :: proc(plan: ^Plan) -> (int, bool) {
	return plan.root, plan.root >= 0 && plan.root < len(plan.operators)
}

Operator_At :: proc(plan: ^Plan, index: int) -> (Operator_View, bool) {
	if index < 0 || index >= len(plan.operators) do return {}, false
	value := plan.operators[index]
 return Operator_View{Kind = value.kind, First_Triple = value.first_triple, Triple_Count = value.triple_count, Path_Pattern = value.path_pattern, Child_Count = value.child_count, Has_Graph = value.has_graph, Graph = public_slot(value.graph), Service = public_slot(value.service), Service_Silent = value.service_silent, First_Values_Variable = value.first_values_variable, Values_Variable_Count = value.values_variable_count, First_Values_Cell = value.first_values_cell, Values_Row_Count = value.values_row_count, Expression = value.expression, Variable = value.variable, First_Order = value.first_order, Order_Count = value.order_count, First_Projection_Variable = value.first_projection_variable, Projection_Variable_Count = value.projection_variable_count, Slice_Offset = value.slice_offset, Slice_Limit = value.slice_limit, Has_Slice_Limit = value.has_slice_limit, First_Group_Expression = value.first_group_expression, Group_Expression_Count = value.group_expression_count, First_Group_Aggregate = value.first_group_aggregate, Group_Aggregate_Count = value.group_aggregate_count}, true
}

Property_Path_Pattern_At :: proc(plan: ^Plan, operator: int) -> (Property_Path_Pattern_View, bool) {
	if operator < 0 || operator >= len(plan.operators) do return {}, false
	node := plan.operators[operator]
	if node.kind != .Path || node.path_pattern < 0 || node.path_pattern >= len(plan.path_patterns) do return {}, false
	value := plan.path_patterns[node.path_pattern]
	return Property_Path_Pattern_View{Path = value.path, Subject = public_slot(value.subject), Object = public_slot(value.object)}, true
}

Property_Path_At :: proc(plan: ^Plan, index: int) -> (Property_Path_View, bool) {
	if index < 0 || index >= len(plan.paths) do return {}, false
	value := plan.paths[index]
	return Property_Path_View{Kind = value.kind, Term = public_slot(value.term), Child_Count = value.child_count, Negated_Term_Count = value.negated_term_count, Minimum = value.minimum, Maximum = value.maximum, Has_Maximum = value.has_maximum}, true
}

Property_Path_Child :: proc(plan: ^Plan, path, child: int) -> (int, bool) {
	if path < 0 || path >= len(plan.paths) do return -1, false
	value := plan.paths[path]
	if child < 0 || child >= value.child_count do return -1, false
	return plan.path_children[value.first_child + child], true
}

Property_Path_Negated_Term :: proc(plan: ^Plan, path, index: int) -> (term: Slot_View, inverse, ok: bool) {
	if path < 0 || path >= len(plan.paths) do return {}, false, false
	value := plan.paths[path]
	if index < 0 || index >= value.negated_term_count do return {}, false, false
	entry := value.first_negated_term + index
	return public_slot(plan.path_negated_terms[entry]), plan.path_negated_inverse[entry], true
}

Operator_Child :: proc(plan: ^Plan, operator, child: int) -> (int, bool) {
	if operator < 0 || operator >= len(plan.operators) do return -1, false
	value := plan.operators[operator]
	if child < 0 || child >= value.child_count do return -1, false
	return plan.children[value.first_child + child], true
}

Values_Variable :: proc(plan: ^Plan, operator, index: int) -> (int, bool) {
	if operator < 0 || operator >= len(plan.operators) do return -1, false
	value := plan.operators[operator]
	if value.kind != .Values || index < 0 || index >= value.values_variable_count do return -1, false
	return plan.values_variables[value.first_values_variable + index], true
}

Projection_Variable :: proc(plan: ^Plan, operator, index: int) -> (int, bool) {
	if operator < 0 || operator >= len(plan.operators) do return -1, false
	value := plan.operators[operator]
	if value.kind != .Project || index < 0 || index >= value.projection_variable_count do return -1, false
	return plan.projection_variables[value.first_projection_variable + index], true
}

// Result_Variable_Count and Result_Variable expose the requested columns of a
// translated top-level SELECT in query-source order. Non-SELECT plans have no
// result columns.
Result_Variable_Count :: proc(plan: ^Plan) -> int { return len(plan.result_variables) }

Result_Variable :: proc(plan: ^Plan, index: int) -> (int, bool) {
	if index < 0 || index >= len(plan.result_variables) do return -1, false
	return plan.result_variables[index], true
}

Group_Expression :: proc(plan: ^Plan, operator, index: int) -> (expression, variable: int, ok: bool) {
	if operator < 0 || operator >= len(plan.operators) do return -1, -1, false
	value := plan.operators[operator]
	if value.kind != .Group || index < 0 || index >= value.group_expression_count do return -1, -1, false
	return plan.group_expressions[value.first_group_expression + index], plan.group_variables[value.first_group_expression + index], true
}

Group_Aggregate :: proc(plan: ^Plan, operator, index: int) -> (int, bool) {
	if operator < 0 || operator >= len(plan.operators) do return -1, false
	value := plan.operators[operator]
	if value.kind != .Group || index < 0 || index >= value.group_aggregate_count do return -1, false
	return plan.group_aggregates[value.first_group_aggregate + index], true
}

// Values_Cell returns one resolved VALUES cell. Unbound cells carry no RDF
// term; callers must ignore Slot when Unbound is true.
Values_Cell :: proc(plan: ^Plan, operator, row, column: int) -> (slot: Slot_View, unbound: bool, ok: bool) {
	if operator < 0 || operator >= len(plan.operators) do return {}, false, false
	value := plan.operators[operator]
	if value.kind != .Values || row < 0 || row >= value.values_row_count || column < 0 || column >= value.values_variable_count do return {}, false, false
	index := value.first_values_cell + row * value.values_variable_count + column
	return public_slot(plan.values_cells[index]), plan.values_unbound[index], true
}

Expression_At :: proc(plan: ^Plan, index: int) -> (Expression_View, bool) {
	if index < 0 || index >= len(plan.expressions) do return {}, false
	value := plan.expressions[index]
	return Expression_View{Kind = value.kind, Term = public_slot(value.term), Child_Count = value.child_count, Relation = value.relation, Uses_Distinct = value.uses_distinct, Has_Separator = value.has_separator, Separator = public_slot(value.separator)}, true
}

Expression_Child :: proc(plan: ^Plan, expression, child: int) -> (int, bool) {
	if expression < 0 || expression >= len(plan.expressions) do return -1, false
	value := plan.expressions[expression]
	if child < 0 || child >= value.child_count do return -1, false
	return plan.expression_children[value.first_child + child], true
}

// Order_Condition returns one translated ORDER BY condition from an Order
// operator. Descending is false for both the default and explicit ASC forms.
Order_Condition :: proc(plan: ^Plan, operator, index: int) -> (expression: int, descending: bool, ok: bool) {
	if operator < 0 || operator >= len(plan.operators) do return -1, false, false
	value := plan.operators[operator]
	if value.kind != .Order || index < 0 || index >= value.order_count do return -1, false, false
	entry := value.first_order + index
	return plan.order_expressions[entry], plan.order_descending[entry], true
}

Has_Dataset_Description :: proc(plan: ^Plan) -> bool { return plan.has_dataset_description }
Dataset_Default_Graph_Count :: proc(plan: ^Plan) -> int { return len(plan.dataset_default_graphs) }
Dataset_Named_Graph_Count :: proc(plan: ^Plan) -> int { return len(plan.dataset_named_graphs) }

Dataset_Default_Graph :: proc(plan: ^Plan, index: int) -> (rdf.Term, bool) {
	if index < 0 || index >= len(plan.dataset_default_graphs) do return {}, false
	return plan.dataset_default_graphs[index], true
}

Dataset_Named_Graph :: proc(plan: ^Plan, index: int) -> (rdf.Term, bool) {
	if index < 0 || index >= len(plan.dataset_named_graphs) do return {}, false
	return plan.dataset_named_graphs[index], true
}

@(private) init :: proc(plan: ^Plan) {
 plan^ = Plan{triples = make([dynamic]Triple_Pattern), paths = make([dynamic]Property_Path), path_children = make([dynamic]int), path_negated_terms = make([dynamic]Slot), path_negated_inverse = make([dynamic]bool), path_patterns = make([dynamic]Property_Path_Pattern), variables = make([dynamic]string), owned = make([dynamic]string), operators = make([dynamic]Operator), children = make([dynamic]int), root = -1, values_variables = make([dynamic]int), values_cells = make([dynamic]Slot), values_unbound = make([dynamic]bool), expressions = make([dynamic]Expression), expression_children = make([dynamic]int), projection_variables = make([dynamic]int), result_variables = make([dynamic]int), group_expressions = make([dynamic]int), group_variables = make([dynamic]int), group_aggregates = make([dynamic]int), dataset_default_graphs = make([dynamic]rdf.Term), dataset_named_graphs = make([dynamic]rdf.Term)}
}

@(private) own :: proc(plan: ^Plan, value: string) -> (string, Error_Code) {
	cloned, clone_error := strings.clone(value)
	if clone_error != nil do return "", .Out_Of_Memory
	_, append_error := append(&plan.owned, cloned)
	if append_error != nil {
		delete(cloned)
		return "", .Out_Of_Memory
	}
	return cloned, .None
}

@(private) is_scheme_start :: #force_inline proc(value: byte) -> bool {
	return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
}

@(private) is_scheme_continue :: #force_inline proc(value: byte) -> bool {
	return is_scheme_start(value) || (value >= '0' && value <= '9') || value == '+' || value == '-' || value == '.'
}

@(private) is_absolute_iri :: proc(value: string) -> bool {
	if len(value) == 0 || !is_scheme_start(value[0]) do return false
	for index in 1..<len(value) {
		if value[index] == ':' do return true
		if !is_scheme_continue(value[index]) do return false
	}
	return false
}

@(private) resolve_iri :: proc(plan: ^Plan, base, reference: string) -> (string, Error_Code) {
	value := reference
	if !is_absolute_iri(value) {
		if len(base) == 0 do return "", .Invalid_IRI
		resolved, ok := turtle.resolve_iri_reference(base, value)
		if !ok do return "", .Invalid_IRI
		owned, error := own(plan, resolved)
		delete(resolved)
		return owned, error
	}
	return own(plan, value)
}

@(private) decode_local :: proc(plan: ^Plan, value: string) -> (string, Error_Code) {
	if strings.index_byte(value, '\\') < 0 do return own(plan, value)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for index := 0; index < len(value); {
		if value[index] == '\\' && index + 1 < len(value) {
			strings.write_byte(&builder, value[index + 1])
			index += 2
		} else {
			strings.write_byte(&builder, value[index])
			index += 1
		}
	}
	return own(plan, strings.to_string(builder))
}

@(private) decode_string :: proc(plan: ^Plan, lexical: string) -> (string, Error_Code) {
	if len(lexical) < 2 do return "", .Invalid_Literal
	delimiter := 1
	if len(lexical) >= 6 && lexical[0] == lexical[1] && lexical[0] == lexical[2] do delimiter = 3
	if len(lexical) < delimiter * 2 do return "", .Invalid_Literal
	value := lexical[delimiter:len(lexical)-delimiter]
	if strings.index_byte(value, '\\') < 0 do return own(plan, value)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for index := 0; index < len(value); {
		if value[index] != '\\' {
			strings.write_byte(&builder, value[index])
			index += 1
			continue
		}
		if index + 1 >= len(value) do return "", .Invalid_Literal
		index += 1
		escaped := value[index]
		switch escaped {
		case 't': strings.write_byte(&builder, '\t')
		case 'b': strings.write_byte(&builder, '\b')
		case 'n': strings.write_byte(&builder, '\n')
		case 'r': strings.write_byte(&builder, '\r')
		case 'f': strings.write_byte(&builder, '\f')
		case '"', '\'', '\\': strings.write_byte(&builder, escaped)
		case: return "", .Invalid_Literal
		}
		index += 1
	}
	return own(plan, strings.to_string(builder))
}

@(private) variable_index :: proc(plan: ^Plan, lexical: string) -> (int, Error_Code) {
	name := lexical
	if len(name) > 0 && (name[0] == '?' || name[0] == '$') do name = name[1:]
	for value, index in plan.variables do if value == name do return index, .None
	owned, error := own(plan, name)
	if error != .None do return -1, error
	_, append_error := append(&plan.variables, owned)
	if append_error != nil do return -1, .Out_Of_Memory
	return len(plan.variables) - 1, .None
}

@(private) resolve_prefixed_name :: proc(plan: ^Plan, query: ^sparql.Query, base, lexical: string) -> (string, Error_Code) {
	separator := strings.index_byte(lexical, ':')
	if separator < 0 do return "", .Unknown_Prefix
	prefix := lexical[:separator+1]
	local, local_error := decode_local(plan, lexical[separator+1:])
	if local_error != .None do return "", local_error
	for index := sparql.Query_Prefix_Count(query) - 1; index >= 0; index -= 1 {
		declaration, ok := sparql.Query_Prefix(query, index)
		if !ok || declaration.Prefix.Lexical != prefix do continue
		namespace, namespace_error := resolve_source_iri(plan, query, base, declaration.Namespace)
		if namespace_error != .None do return "", namespace_error
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		strings.write_string(&builder, namespace)
		strings.write_string(&builder, local)
		return own(plan, strings.to_string(builder))
	}
	return "", .Unknown_Prefix
}

@(private) resolve_source_iri :: proc(plan: ^Plan, query: ^sparql.Query, base: string, term: sparql.Term_View) -> (string, Error_Code) {
	#partial switch term.Kind {
	case .IRIREF:
		if len(term.Lexical) < 2 do return "", .Invalid_IRI
		return resolve_iri(plan, base, term.Lexical[1:len(term.Lexical)-1])
	case .Prefixed_Name:
		return resolve_prefixed_name(plan, query, base, term.Lexical)
	case .RDF_Type:
		return own(plan, "http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
	}
	return "", .Invalid_IRI
}

@(private) resolve_term :: proc(plan: ^Plan, query: ^sparql.Query, base: string, value: sparql.Term_View) -> (Slot, Error_Code) {
	if value.Kind == .Variable || value.Kind == .Blank_Node_Label {
		variable, error := variable_index(plan, value.Lexical)
		if error != .None do return {}, error
		return Slot{kind = .Variable, variable = variable}, .None
	}
	if value.Kind == .IRIREF || value.Kind == .Prefixed_Name || value.Kind == .RDF_Type {
		iri, error := resolve_source_iri(plan, query, base, value)
		if error != .None do return {}, error
		return Slot{kind = .Term, term = rdf.iri(iri)}, .None
	}
	if value.Kind == .String_Literal {
		lexical, error := decode_string(plan, value.Lexical)
		if error != .None do return {}, error
		if value.Has_Language {
			if len(value.Language) < 2 do return {}, .Invalid_Literal
			language, language_error := own(plan, value.Language[1:])
			if language_error != .None do return {}, language_error
			return Slot{kind = .Term, term = rdf.language_literal(lexical, language)}, .None
		}
		if value.Has_Datatype {
			datatype, datatype_error := resolve_source_iri(plan, query, base, sparql.Term_View{Kind = value.Datatype_Kind, Lexical = value.Datatype_Lexical})
			if datatype_error != .None do return {}, datatype_error
			return Slot{kind = .Term, term = rdf.typed_literal(lexical, datatype)}, .None
		}
		return Slot{kind = .Term, term = rdf.literal(lexical)}, .None
	}
	if value.Kind == .Boolean {
		// SPARQL keywords are case-insensitive, but the term introduced by a
		// boolean literal has the canonical xsd:boolean lexical form. Keep the
		// source AST untouched and normalize only at the RDF-value boundary.
		lexical := "false"
		if strings.equal_fold(value.Lexical, "true") do lexical = "true"
		return Slot{kind = .Term, term = rdf.typed_literal(lexical, "http://www.w3.org/2001/XMLSchema#boolean")}, .None
	}
	if value.Kind == .Integer || value.Kind == .Decimal || value.Kind == .Double {
		datatype := "http://www.w3.org/2001/XMLSchema#integer"
		#partial switch value.Kind {
		case .Decimal: datatype = "http://www.w3.org/2001/XMLSchema#decimal"
		case .Double: datatype = "http://www.w3.org/2001/XMLSchema#double"
		}
		lexical, lexical_error := own(plan, value.Lexical)
		if lexical_error != .None do return {}, lexical_error
		return Slot{kind = .Term, term = rdf.typed_literal(lexical, datatype)}, .None
	}
	return {}, .Unsupported_Query
}

// pattern_variable gives source-only graph-node forms a query-local existential
// variable. It is deliberately distinct from RDF data blank nodes and is
// hidden from SELECT * by its internal name prefix.
@(private) pattern_variable :: proc(plan: ^Plan, query: ^sparql.Query, prefix: string, node: sparql.Term_Node_Ref, ordinal: int = -1) -> (Slot, Error_Code) {
	scope_buffer: [64]byte
	node_buffer: [64]byte
	ordinal_buffer: [64]byte
	scope_text := strconv.write_uint(scope_buffer[:], u64(cast(uintptr)query), 10)
	node_text := strconv.write_int(node_buffer[:], i64(node), 10)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, prefix)
	strings.write_string(&builder, scope_text)
	strings.write_string(&builder, "_")
	strings.write_string(&builder, node_text)
	if ordinal >= 0 {
		strings.write_string(&builder, "_")
		ordinal_text := strconv.write_int(ordinal_buffer[:], i64(ordinal), 10)
		strings.write_string(&builder, ordinal_text)
	}
	variable, variable_error := variable_index(plan, strings.to_string(builder))
	if variable_error != .None do return {}, variable_error
	return Slot{kind = .Variable, variable = variable}, .None
}

@(private) blank_property_variable :: proc(plan: ^Plan, query: ^sparql.Query, node: sparql.Term_Node_Ref) -> (Slot, Error_Code) {
	return pattern_variable(plan, query, "_:odin_pattern_blank_", node)
}

@(private) collection_cell_variable :: proc(plan: ^Plan, query: ^sparql.Query, node: sparql.Term_Node_Ref, ordinal: int) -> (Slot, Error_Code) {
	return pattern_variable(plan, query, "_:odin_pattern_list_", node, ordinal)
}

@(private) path_variable :: proc(plan: ^Plan, query: ^sparql.Query, path: sparql.Path_Ref) -> (Slot, Error_Code) {
	return pattern_variable(plan, query, "_:odin_pattern_path_", sparql.Term_Node_Ref(path))
}

RDF_FIRST :: "http://www.w3.org/1999/02/22-rdf-syntax-ns#first"
RDF_REST  :: "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest"
RDF_NIL   :: "http://www.w3.org/1999/02/22-rdf-syntax-ns#nil"

// lower_collection expands source collection syntax into an RDF list chain.
// Each generated cell is existential and thus intentionally invisible to
// SELECT *, while graph-node items can recursively emit their own triples.
@(private) lower_collection :: proc(plan: ^Plan, query: ^sparql.Query, base: string, value: sparql.Term_View, path_operators: ^[dynamic]int) -> (Slot, Error_Code) {
	node, node_ok := sparql.Query_Term_Node(query, value.Syntax_Node)
	if !node_ok || node.Kind != .Collection do return {}, .Unsupported_Query
	item_count := sparql.Term_Node_Item_Count(query, value.Syntax_Node)
	if item_count == 0 do return Slot{kind = .Term, term = rdf.iri(RDF_NIL)}, .None
	head, head_error := collection_cell_variable(plan, query, value.Syntax_Node, 0)
	if head_error != .None do return {}, head_error
	for item_index in 0..<item_count {
		current, current_error := collection_cell_variable(plan, query, value.Syntax_Node, item_index)
		if current_error != .None do return {}, current_error
		item, item_ok := sparql.Term_Node_Item(query, value.Syntax_Node, item_index)
		if !item_ok do return {}, .Unsupported_Query
		object, object_error := lower_pattern_term(plan, query, base, item, path_operators)
		if object_error != .None do return {}, object_error
		if error := append_triple(plan, Triple_Pattern{subject = current, predicate = Slot{kind = .Term, term = rdf.iri(RDF_FIRST)}, object = object}); error != .None do return {}, error
		next := Slot{kind = .Term, term = rdf.iri(RDF_NIL)}
		if item_index + 1 < item_count {
			next, current_error = collection_cell_variable(plan, query, value.Syntax_Node, item_index + 1)
			if current_error != .None do return {}, current_error
		}
		if error := append_triple(plan, Triple_Pattern{subject = current, predicate = Slot{kind = .Term, term = rdf.iri(RDF_REST)}, object = next}); error != .None do return {}, error
	}
	return head, .None
}

// lower_path compiles the acyclic property-path subset into ordinary BGP
// triples. Inverse and sequence preserve the exact binding semantics of their
// algebraic expansions; alternatives and variable-length paths require their
// own duplicate-suppression traversal operator and remain a later slice.
@(private) lower_path :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Path_Ref, subject, object: Slot) -> Error_Code {
	path, path_ok := sparql.Path(query, reference)
	if !path_ok do return .Unsupported_Query
	if path.Kind == .Term {
		predicate, predicate_error := resolve_term(plan, query, base, path.Term)
		if predicate_error != .None do return predicate_error
		return append_triple(plan, Triple_Pattern{subject = subject, predicate = predicate, object = object})
	}
	if path.Kind == .Inverse {
		if sparql.Path_Child_Count(query, reference) != 1 do return .Unsupported_Query
		child, child_ok := sparql.Path_Child(query, reference, 0)
		if !child_ok do return .Unsupported_Query
		return lower_path(plan, query, base, child, object, subject)
	}
	if path.Kind == .Sequence {
		if sparql.Path_Child_Count(query, reference) != 2 do return .Unsupported_Query
		left, left_ok := sparql.Path_Child(query, reference, 0)
		right, right_ok := sparql.Path_Child(query, reference, 1)
		if !left_ok || !right_ok do return .Unsupported_Query
		middle, middle_error := path_variable(plan, query, reference)
		if middle_error != .None do return middle_error
		if left_error := lower_path(plan, query, base, left, subject, middle); left_error != .None do return left_error
		return lower_path(plan, query, base, right, middle, object)
	}
	return .Unsupported_Query
}

@(private) path_is_bgp_lowerable :: proc(query: ^sparql.Query, reference: sparql.Path_Ref) -> bool {
	path, path_ok := sparql.Path(query, reference)
	if !path_ok do return false
	if path.Kind == .Term do return true
	if path.Kind != .Inverse && path.Kind != .Sequence do return false
	for index in 0..<sparql.Path_Child_Count(query, reference) {
		child, child_ok := sparql.Path_Child(query, reference, index)
		if !child_ok || !path_is_bgp_lowerable(query, child) do return false
	}
	return true
}

@(private) compiled_path_kind :: proc(kind: sparql.Path_Kind) -> (Property_Path_Kind, bool) {
	#partial switch kind {
	case .Term:         return .Term, true
	case .Inverse:      return .Inverse, true
	case .Alternative:  return .Alternative, true
	case .Sequence:     return .Sequence, true
	case .Zero_Or_More: return .Zero_Or_More, true
	case .One_Or_More:  return .One_Or_More, true
	case .Zero_Or_One:  return .Zero_Or_One, true
	case .Bounded:      return .Bounded, true
	case .Negated_Set:  return .Negated_Set, true
	}
	return {}, false
}

@(private) compile_property_path :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Path_Ref) -> (int, Error_Code) {
	path, path_ok := sparql.Path(query, reference)
	if !path_ok do return -1, .Unsupported_Query
	kind, kind_ok := compiled_path_kind(path.Kind)
	if !kind_ok do return -1, .Unsupported_Query
	node := Property_Path{kind = kind, first_negated_term = len(plan.path_negated_terms)}
	if kind == .Bounded {
		node.minimum = path.Minimum
		node.maximum = path.Maximum
		node.has_maximum = path.Has_Maximum
	}
	if kind == .Term {
		term, term_error := resolve_term(plan, query, base, path.Term)
		if term_error != .None || term.kind != .Term do return -1, .Unsupported_Query
		node.term = term
	}
	children := make([dynamic]int)
	defer delete(children)
	for index in 0..<sparql.Path_Child_Count(query, reference) {
		child, child_ok := sparql.Path_Child(query, reference, index)
		if !child_ok do return -1, .Unsupported_Query
		compiled, compiled_error := compile_property_path(plan, query, base, child)
		if compiled_error != .None do return -1, compiled_error
		if _, append_error := append(&children, compiled); append_error != nil do return -1, .Out_Of_Memory
	}
	node.first_child = len(plan.path_children)
	for child in children {
		if _, append_error := append(&plan.path_children, child); append_error != nil do return -1, .Out_Of_Memory
		node.child_count += 1
	}
	for index in 0..<sparql.Path_Negated_Term_Count(query, reference) {
		term, inverse, term_ok := sparql.Path_Negated_Term(query, reference, index)
		if !term_ok do return -1, .Unsupported_Query
		resolved, resolved_error := resolve_term(plan, query, base, term)
		if resolved_error != .None || resolved.kind != .Term do return -1, .Unsupported_Query
		if _, append_error := append(&plan.path_negated_terms, resolved); append_error != nil do return -1, .Out_Of_Memory
		if _, append_error := append(&plan.path_negated_inverse, inverse); append_error != nil do return -1, .Out_Of_Memory
		node.negated_term_count += 1
	}
	if _, append_error := append(&plan.paths, node); append_error != nil do return -1, .Out_Of_Memory
	return len(plan.paths) - 1, .None
}

@(private) append_property_path_operator :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Path_Ref, subject, object: Slot) -> (int, Error_Code) {
	path, path_error := compile_property_path(plan, query, base, reference)
	if path_error != .None do return -1, path_error
	pattern := Property_Path_Pattern{path = path, subject = subject, object = object}
	if _, append_error := append(&plan.path_patterns, pattern); append_error != nil do return -1, .Out_Of_Memory
	return append_operator(plan, Operator{kind = .Path, path_pattern = len(plan.path_patterns) - 1})
}

// lower_pattern_term expands source-only blank-property lists and collections
// into ordinary BGP triples before query planning.
@(private) lower_pattern_term :: proc(plan: ^Plan, query: ^sparql.Query, base: string, value: sparql.Term_View, path_operators: ^[dynamic]int) -> (Slot, Error_Code) {
	if value.Kind == .Collection do return lower_collection(plan, query, base, value, path_operators)
	if value.Kind != .Blank_Property_List do return resolve_term(plan, query, base, value)
	node, node_ok := sparql.Query_Term_Node(query, value.Syntax_Node)
	if !node_ok || node.Kind != .Blank_Property_List do return {}, .Unsupported_Query
	subject, subject_error := blank_property_variable(plan, query, value.Syntax_Node)
	if subject_error != .None do return {}, subject_error
	for property_index in 0..<sparql.Term_Node_Property_Count(query, value.Syntax_Node) {
		property, property_ok := sparql.Term_Node_Property(query, value.Syntax_Node, property_index)
		if !property_ok do return {}, .Unsupported_Query
		for object_index in 0..<sparql.Term_Node_Property_Object_Count(query, value.Syntax_Node, property_index) {
			object_term, object_ok := sparql.Term_Node_Property_Object(query, value.Syntax_Node, property_index, object_index)
			if !object_ok do return {}, .Unsupported_Query
			object, object_error := lower_pattern_term(plan, query, base, object_term, path_operators)
			if object_error != .None do return {}, object_error
			if path_is_bgp_lowerable(query, property.Path) {
				if path_error := lower_path(plan, query, base, property.Path, subject, object); path_error != .None do return {}, path_error
			} else {
				path_operator, path_error := append_property_path_operator(plan, query, base, property.Path, subject, object)
				if path_error != .None do return {}, path_error
				if _, append_error := append(path_operators, path_operator); append_error != nil do return {}, .Out_Of_Memory
			}
		}
	}
	return subject, .None
}

@(private) base_iri :: proc(plan: ^Plan, query: ^sparql.Query) -> (string, Error_Code) {
	if !sparql.Query_Has_Base(query) do return "", .None
	return resolve_source_iri(plan, query, "", sparql.Query_Base(query))
}

@(private) translate_dataset_description :: proc(plan: ^Plan, query: ^sparql.Query, base: string) -> Error_Code {
	if sparql.Query_Dataset_Clause_Count(query) == 0 do return .None
	plan.has_dataset_description = true
	for index in 0..<sparql.Query_Dataset_Clause_Count(query) {
		clause, clause_ok := sparql.Query_Dataset_Clause(query, index)
		if !clause_ok do return .Unsupported_Query
		slot, slot_error := resolve_term(plan, query, base, clause.Source)
		if slot_error != .None || slot.kind != .Term || slot.term.kind != .IRI do return .Unsupported_Query
		target := &plan.dataset_default_graphs
		if clause.Named do target = &plan.dataset_named_graphs
		if _, append_error := append(target, slot.term); append_error != nil do return .Out_Of_Memory
	}
	return .None
}

@(private) append_triple :: proc(plan: ^Plan, value: Triple_Pattern) -> Error_Code {
	_, error := append(&plan.triples, value)
	if error != nil do return .Out_Of_Memory
	return .None
}

@(private) append_operator :: proc(plan: ^Plan, value: Operator, children: []int = nil) -> (int, Error_Code) {
	operator := value
	operator.first_child = len(plan.children)
	operator.child_count = len(children)
	for child in children {
		if child < 0 || child >= len(plan.operators) do return -1, .Unsupported_Query
		if _, error := append(&plan.children, child); error != nil do return -1, .Out_Of_Memory
	}
	if _, error := append(&plan.operators, operator); error != nil do return -1, .Out_Of_Memory
	return len(plan.operators) - 1, .None
}

@(private) append_expression :: proc(plan: ^Plan, value: Expression, children: []int = nil) -> (int, Error_Code) {
	expression := value
	expression.first_child = len(plan.expression_children)
	expression.child_count = len(children)
	for child in children {
		if child < 0 || child >= len(plan.expressions) do return -1, .Unsupported_Query
		if _, error := append(&plan.expression_children, child); error != nil do return -1, .Out_Of_Memory
	}
	if _, error := append(&plan.expressions, expression); error != nil do return -1, .Out_Of_Memory
	return len(plan.expressions) - 1, .None
}

@(private) aggregate_variable :: proc(plan: ^Plan) -> (int, Error_Code) {
	buffer: [64]byte
	ordinal := strconv.write_int(buffer[:], i64(len(plan.expressions)), 10)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "_:odin_aggregate_")
	strings.write_string(&builder, ordinal)
	return variable_index(plan, strings.to_string(builder))
}

@(private) translate_expression :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Expression_Ref) -> (int, Error_Code) {
	view, view_ok := sparql.Expression(query, reference)
	if !view_ok do return -1, .Unsupported_Query
	if view.Kind == .Term {
		slot, slot_error := resolve_term(plan, query, base, view.Term)
		if slot_error != .None do return -1, slot_error
		return append_expression(plan, Expression{kind = .Term, term = slot})
	}
	if view.Kind == .Exists || view.Kind == .Not_Exists {
		pattern, pattern_ok := sparql.Expression_Pattern(query, reference)
		if !pattern_ok do return -1, .Unsupported_Query
		relation, relation_error := translate_pattern(plan, query, base, pattern)
		if relation_error != .None do return -1, relation_error
		kind := Expression_Kind.Exists
		if view.Kind == .Not_Exists do kind = .Not_Exists
		return append_expression(plan, Expression{kind = kind, relation = relation})
	}
	if view.Kind == .Function && (strings.equal_fold(view.Name, "COUNT") || strings.equal_fold(view.Name, "SUM") || strings.equal_fold(view.Name, "AVG") || strings.equal_fold(view.Name, "GROUP_CONCAT") || strings.equal_fold(view.Name, "MIN") || strings.equal_fold(view.Name, "MAX") || strings.equal_fold(view.Name, "SAMPLE")) {
		if sparql.Expression_Child_Count(query, reference) != 1 do return -1, .Unsupported_Query
		variable, variable_error := aggregate_variable(plan)
		if variable_error != .None do return -1, variable_error
		argument, argument_ok := sparql.Expression_Child(query, reference, 0)
		if !argument_ok do return -1, .Unsupported_Query
		argument_view, argument_view_ok := sparql.Expression(query, argument)
		if !argument_view_ok do return -1, .Unsupported_Query
		children := make([dynamic]int)
		defer delete(children)
		kind := Expression_Kind.Count
		if strings.equal_fold(view.Name, "SUM") do kind = .Sum
		if strings.equal_fold(view.Name, "AVG") do kind = .Average
		if strings.equal_fold(view.Name, "GROUP_CONCAT") do kind = .Group_Concat
		if strings.equal_fold(view.Name, "MIN") do kind = .Min
		if strings.equal_fold(view.Name, "MAX") do kind = .Max
		if strings.equal_fold(view.Name, "SAMPLE") do kind = .Sample
		if argument_view.Kind == .Wildcard && kind != .Count do return -1, .Unsupported_Query
		if argument_view.Kind != .Wildcard {
			child, child_error := translate_expression(plan, query, base, argument)
			if child_error != .None do return -1, child_error
			if _, append_error := append(&children, child); append_error != nil do return -1, .Out_Of_Memory
		}
		expression := Expression{kind = kind, term = Slot{kind = .Variable, variable = variable}, uses_distinct = view.Uses_Distinct}
		if view.Has_Separator {
			if kind != .Group_Concat do return -1, .Unsupported_Query
			separator, separator_error := resolve_term(plan, query, base, view.Separator)
			if separator_error != .None || separator.kind != .Term || separator.term.kind != .Literal do return -1, .Unsupported_Query
			expression.has_separator = true
			expression.separator = separator
		}
		return append_expression(plan, expression, children[:])
	}
	function_iri := ""
	if view.Kind == .Function && (view.Term.Kind == .IRIREF || view.Term.Kind == .Prefixed_Name) {
		resolved_function_iri, resolved_function_error := resolve_source_iri(plan, query, base, view.Term)
		if resolved_function_error != .None do return -1, resolved_function_error
		function_iri = resolved_function_iri
	}
	kind: Expression_Kind
	if view.Kind == .Function && strings.equal_fold(view.Name, "BOUND") {
		kind = .Bound
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SAMETERM") {
		kind = .Same_Term
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STR") {
		kind = .Str
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "LCASE") {
		kind = .Lower
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "UCASE") {
		kind = .Upper
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "LANG") {
		kind = .Lang
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "LANGMATCHES") {
		kind = .Lang_Matches
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "DATATYPE") {
		kind = .Datatype
	} else if view.Kind == .Function && (strings.equal_fold(view.Name, "ISIRI") || strings.equal_fold(view.Name, "ISURI")) {
		kind = .Is_IRI
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "ISBLANK") {
		kind = .Is_Blank
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "ISLITERAL") {
		kind = .Is_Literal
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "ISNUMERIC") {
		kind = .Is_Numeric
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "IF") {
		kind = .If
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "COALESCE") {
		kind = .Coalesce
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "CONCAT") {
		kind = .Concat
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRSTARTS") {
		kind = .Str_Starts
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRENDS") {
		kind = .Str_Ends
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "CONTAINS") {
		kind = .Contains
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "REGEX") {
		kind = .Regex
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "REPLACE") {
		kind = .Replace
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRLEN") {
		kind = .Str_Length
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SUBSTR") {
		kind = .Substring
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRBEFORE") {
		kind = .Str_Before
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRAFTER") {
		kind = .Str_After
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRDT") {
		kind = .Str_Datatype
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRLANG") {
		kind = .Str_Language
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "BNODE") {
		kind = .BNode
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "NOW") {
		kind = .Now
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "UUID") {
		kind = .UUID
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "STRUUID") {
		kind = .STRUUID
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "RAND") {
		kind = .Rand
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "YEAR") {
		kind = .Year
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "MONTH") {
		kind = .Month
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "DAY") {
		kind = .Day
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "HOURS") {
		kind = .Hours
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "MINUTES") {
		kind = .Minutes
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SECONDS") {
		kind = .Seconds
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "TIMEZONE") {
		kind = .Timezone
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "TZ") {
		kind = .TZ
	} else if view.Kind == .Function && function_iri == XSD_INTEGER {
		kind = .Cast_Integer
	} else if view.Kind == .Function && function_iri == XSD_DECIMAL {
		kind = .Cast_Decimal
	} else if view.Kind == .Function && function_iri == XSD_BOOLEAN {
		kind = .Cast_Boolean
	} else if view.Kind == .Function && function_iri == XSD_STRING {
		kind = .Cast_String
	} else if view.Kind == .Function && function_iri == XSD_FLOAT {
		kind = .Cast_Float
	} else if view.Kind == .Function && function_iri == XSD_DOUBLE {
		kind = .Cast_Double
	} else if view.Kind == .Function && function_iri == XSD_DATE {
		kind = .Cast_Date
	} else if view.Kind == .Function && function_iri == XSD_DATE_TIME {
		kind = .Cast_Date_Time
	} else if view.Kind == .Function && function_iri == XSD_TIME {
		kind = .Cast_Time
	} else if view.Kind == .Function && (strings.equal_fold(view.Name, "IRI") || strings.equal_fold(view.Name, "URI")) {
		kind = .Make_IRI
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "ENCODE_FOR_URI") {
		kind = .Encode_For_URI
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "MD5") {
		kind = .MD5
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SHA1") {
		kind = .SHA1
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SHA256") {
		kind = .SHA256
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SHA384") {
		kind = .SHA384
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "SHA512") {
		kind = .SHA512
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "ABS") {
		kind = .Absolute
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "CEIL") {
		kind = .Ceiling
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "FLOOR") {
		kind = .Floor
	} else if view.Kind == .Function && strings.equal_fold(view.Name, "ROUND") {
		kind = .Round
	} else if view.Kind == .In {
		kind = .In
	} else if view.Kind == .Not_In {
		kind = .Not_In
	} else if view.Kind == .Unary && view.Operator == .Not {
		kind = .Not
	} else if view.Kind == .Unary && view.Operator == .Unary_Plus {
		kind = .Unary_Plus
	} else if view.Kind == .Unary && view.Operator == .Unary_Minus {
		kind = .Unary_Minus
	} else if view.Kind == .Binary && view.Operator == .Add {
		kind = .Add
	} else if view.Kind == .Binary && view.Operator == .Subtract {
		kind = .Subtract
	} else if view.Kind == .Binary && view.Operator == .Multiply {
		kind = .Multiply
	} else if view.Kind == .Binary && view.Operator == .Divide {
		kind = .Divide
	} else if view.Kind == .Binary && view.Operator == .Equal {
		kind = .Equal
	} else if view.Kind == .Binary && view.Operator == .Not_Equal {
		kind = .Not_Equal
	} else if view.Kind == .Binary && view.Operator == .Less {
		kind = .Less
	} else if view.Kind == .Binary && view.Operator == .Less_Or_Equal {
		kind = .Less_Or_Equal
	} else if view.Kind == .Binary && view.Operator == .Greater {
		kind = .Greater
	} else if view.Kind == .Binary && view.Operator == .Greater_Or_Equal {
		kind = .Greater_Or_Equal
	} else if view.Kind == .Binary && view.Operator == .And {
		kind = .And
	} else if view.Kind == .Binary && view.Operator == .Or {
		kind = .Or
	} else {
		return -1, .Unsupported_Query
	}
	expected_children := 2
	if kind == .Not || kind == .Unary_Plus || kind == .Unary_Minus || kind == .Absolute || kind == .Ceiling || kind == .Floor || kind == .Round || kind == .Bound || kind == .Str || kind == .Lower || kind == .Upper || kind == .Lang || kind == .Datatype || kind == .Is_IRI || kind == .Is_Blank || kind == .Is_Literal || kind == .Is_Numeric || kind == .Cast_Integer || kind == .Cast_Decimal || kind == .Cast_Boolean || kind == .Cast_String || kind == .Cast_Float || kind == .Cast_Double || kind == .Cast_Date || kind == .Cast_Date_Time || kind == .Cast_Time || kind == .Make_IRI || kind == .Encode_For_URI || kind == .MD5 || kind == .SHA1 || kind == .SHA256 || kind == .SHA384 || kind == .SHA512 || kind == .Year || kind == .Month || kind == .Day || kind == .Hours || kind == .Minutes || kind == .Seconds || kind == .Timezone || kind == .TZ do expected_children = 1
	if kind == .In || kind == .Not_In {
		expected_children = sparql.Expression_Child_Count(query, reference)
		if expected_children < 1 do return -1, .Unsupported_Query
	}
	if kind == .If do expected_children = 3
	if kind == .Coalesce do expected_children = sparql.Expression_Child_Count(query, reference)
	if kind == .Concat do expected_children = sparql.Expression_Child_Count(query, reference)
	if kind == .Regex {
		expected_children = sparql.Expression_Child_Count(query, reference)
		if expected_children != 2 && expected_children != 3 do return -1, .Unsupported_Query
	}
	if kind == .Replace {
		expected_children = sparql.Expression_Child_Count(query, reference)
		if expected_children != 3 && expected_children != 4 do return -1, .Unsupported_Query
	}
	if kind == .BNode {
		expected_children = sparql.Expression_Child_Count(query, reference)
		if expected_children != 0 && expected_children != 1 do return -1, .Unsupported_Query
	}
	if kind == .Now || kind == .UUID || kind == .STRUUID || kind == .Rand do expected_children = 0
	if kind == .Str_Length do expected_children = 1
	if kind == .Substring {
		expected_children = sparql.Expression_Child_Count(query, reference)
		if expected_children != 2 && expected_children != 3 do return -1, .Unsupported_Query
	}
	if sparql.Expression_Child_Count(query, reference) != expected_children do return -1, .Unsupported_Query
	children := make([dynamic]int)
	defer delete(children)
	for index in 0..<expected_children {
		child, child_ok := sparql.Expression_Child(query, reference, index)
		if !child_ok do return -1, .Unsupported_Query
		translated, translated_error := translate_expression(plan, query, base, child)
		if translated_error != .None do return -1, translated_error
		if kind == .Bound {
			argument, argument_ok := Expression_At(plan, translated)
			if !argument_ok || argument.Kind != .Term || argument.Term.Kind != .Variable do return -1, .Unsupported_Query
		}
		if _, append_error := append(&children, translated); append_error != nil do return -1, .Out_Of_Memory
	}
	expression := Expression{kind = kind}
	if kind == .Make_IRI do expression.term = Slot{kind = .Term, term = rdf.iri(base)}
	return append_expression(plan, expression, children[:])
}

@(private) translate_bgp :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref) -> (int, Error_Code) {
	view, ok := sparql.Pattern(query, reference)
	if !ok do return -1, .Unsupported_Query
	if view.Kind != .Basic_Graph_Pattern do return -1, .Unsupported_Query
	first_triple := len(plan.triples)
	path_operators := make([dynamic]int)
	defer delete(path_operators)
	for index in 0..<sparql.Pattern_Standalone_Node_Count(query, reference) {
		node, node_ok := sparql.Pattern_Standalone_Node(query, reference, index)
		if !node_ok do return -1, .Unsupported_Query
		if _, node_error := lower_pattern_term(plan, query, base, node, &path_operators); node_error != .None do return -1, node_error
	}
	for index in 0..<sparql.Pattern_Triple_Count(query, reference) {
		triple, triple_ok := sparql.Pattern_Triple(query, reference, index)
		if !triple_ok do return -1, .Unsupported_Query
		subject, subject_error := lower_pattern_term(plan, query, base, triple.Subject, &path_operators)
		if subject_error != .None do return -1, subject_error
		object, object_error := lower_pattern_term(plan, query, base, triple.Object, &path_operators)
		if object_error != .None do return -1, object_error
		if path_is_bgp_lowerable(query, triple.Path) {
			if path_error := lower_path(plan, query, base, triple.Path, subject, object); path_error != .None do return -1, path_error
		} else {
			path_operator, path_error := append_property_path_operator(plan, query, base, triple.Path, subject, object)
			if path_error != .None do return -1, path_error
			if _, append_error := append(&path_operators, path_operator); append_error != nil do return -1, .Out_Of_Memory
		}
	}
	static_count := len(plan.triples) - first_triple
	result := -1
	if static_count != 0 || len(path_operators) == 0 {
		static_operator, static_error := append_operator(plan, Operator{kind = .BGP, first_triple = first_triple, triple_count = static_count})
		if static_error != .None do return -1, static_error
		result = static_operator
	}
	for path_operator in path_operators {
		if result < 0 { result = path_operator; continue }
		joined, join_error := append_operator(plan, Operator{kind = .Join}, []int{result, path_operator})
		if join_error != .None do return -1, join_error
		result = joined
	}
	return result, .None
}

@(private) translate_group :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref) -> (int, Error_Code) {
	left, left_error := append_operator(plan, Operator{kind = .Identity})
	if left_error != .None do return -1, left_error
	filters := make([dynamic]int)
	defer delete(filters)
	has_left := false
	for index in 0..<sparql.Pattern_Child_Count(query, reference) {
		child, child_ok := sparql.Pattern_Child(query, reference, index)
		if !child_ok do return -1, .Unsupported_Query
		child_view, child_view_ok := sparql.Pattern(query, child)
		if !child_view_ok do return -1, .Unsupported_Query
		if child_view.Kind == .Optional || child_view.Kind == .Minus {
			if sparql.Pattern_Child_Count(query, child) != 1 do return -1, .Unsupported_Query
			right_ref, right_ok := sparql.Pattern_Child(query, child, 0)
			if !right_ok do return -1, .Unsupported_Query
			right, right_error := translate_pattern(plan, query, base, right_ref)
			if right_error != .None do return -1, right_error
			kind := Operator_Kind.Left_Join
			if child_view.Kind == .Minus do kind = .Minus
			left, left_error = append_operator(plan, Operator{kind = kind}, []int{left, right})
			if left_error != .None do return -1, left_error
			has_left = true
			continue
		}
		if child_view.Kind == .Union {
			branches := make([dynamic]int)
			for branch_index in 0..<sparql.Pattern_Child_Count(query, child) {
				branch_ref, branch_ok := sparql.Pattern_Child(query, child, branch_index)
				if !branch_ok { delete(branches); return -1, .Unsupported_Query }
				branch, branch_error := translate_pattern(plan, query, base, branch_ref)
				if branch_error != .None { delete(branches); return -1, branch_error }
				if _, append_error := append(&branches, branch); append_error != nil { delete(branches); return -1, .Out_Of_Memory }
			}
			union_op, union_error := append_operator(plan, Operator{kind = .Union}, branches[:])
			delete(branches)
			if union_error != .None do return -1, union_error
			if !has_left {
				left = union_op
			} else {
				left, left_error = append_operator(plan, Operator{kind = .Join}, []int{left, union_op})
				if left_error != .None do return -1, left_error
			}
			has_left = true
			continue
		}
		if child_view.Kind == .Filter {
			expression, expression_error := translate_expression(plan, query, base, child_view.Expression)
			if expression_error != .None do return -1, expression_error
			// A FILTER's variable scope is the enclosing group, rather than the
			// source position of the FILTER token. Buffering it until the group's
			// bindings have been constructed allows `FILTER(?z = 3) BIND(... AS
			// ?z)`, while still keeping filters inside nested OPTIONAL/UNION groups.
			if _, append_error := append(&filters, expression); append_error != nil do return -1, .Out_Of_Memory
			continue
		}
		if child_view.Kind == .Bind {
			expression, expression_error := translate_expression(plan, query, base, child_view.Expression)
			if expression_error != .None do return -1, expression_error
			variable, variable_error := resolve_term(plan, query, base, child_view.Variable)
			if variable_error != .None || variable.kind != .Variable do return -1, .Unsupported_Query
			left, left_error = append_operator(plan, Operator{kind = .Extend, expression = expression, variable = variable.variable}, []int{left})
			if left_error != .None do return -1, left_error
			has_left = true
			continue
		}
		right, right_error := translate_pattern(plan, query, base, child)
		if right_error != .None do return -1, right_error
		if !has_left {
			left = right
		} else {
			left, left_error = append_operator(plan, Operator{kind = .Join}, []int{left, right})
			if left_error != .None do return -1, left_error
		}
		has_left = true
	}
	for expression in filters {
		left, left_error = append_operator(plan, Operator{kind = .Filter, expression = expression}, []int{left})
		if left_error != .None do return -1, left_error
	}
	return left, .None
}

@(private) translate_values :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref) -> (int, Error_Code) {
	first_variable := len(plan.values_variables)
	variable_count := sparql.Pattern_Values_Variable_Count(query, reference)
	for index in 0..<variable_count {
		term, term_ok := sparql.Pattern_Values_Variable(query, reference, index)
		if !term_ok do return -1, .Unsupported_Query
		slot, slot_error := resolve_term(plan, query, base, term)
		if slot_error != .None || slot.kind != .Variable do return -1, .Unsupported_Query
		if _, append_error := append(&plan.values_variables, slot.variable); append_error != nil do return -1, .Out_Of_Memory
	}
	first_cell := len(plan.values_cells)
	row_count := sparql.Pattern_Values_Row_Count(query, reference)
	for row in 0..<row_count {
		for column in 0..<variable_count {
			term, unbound, cell_ok := sparql.Pattern_Values_Cell(query, reference, row, column)
			if !cell_ok do return -1, .Unsupported_Query
			slot: Slot
			if !unbound {
				slot_error: Error_Code
				slot, slot_error = resolve_term(plan, query, base, term)
				if slot_error != .None || slot.kind != .Term do return -1, .Unsupported_Query
			}
			if _, append_error := append(&plan.values_cells, slot); append_error != nil do return -1, .Out_Of_Memory
			if _, append_error := append(&plan.values_unbound, unbound); append_error != nil do return -1, .Out_Of_Memory
		}
	}
	return append_operator(plan, Operator{kind = .Values, first_values_variable = first_variable, values_variable_count = variable_count, first_values_cell = first_cell, values_row_count = row_count})
}

// append_projection_slot records one visible variable exactly once. Keeping the
// list in the Plan (rather than the engine result) makes a subquery a real
// algebra boundary: later joins cannot observe its private bindings.
@(private) append_projection_slot :: proc(plan: ^Plan, query: ^sparql.Query, base: string, term: sparql.Term_View, variables: ^[dynamic]int) -> Error_Code {
	slot, slot_error := resolve_term(plan, query, base, term)
	if slot_error != .None do return slot_error
	if slot.kind != .Variable do return .None
	for prior in variables^ do if prior == slot.variable do return .None
	if _, append_error := append(variables, slot.variable); append_error != nil do return .Out_Of_Memory
	return .None
}

// collect_visible_term_variables distinguishes source syntax that introduces a
// private existential binding from terms that name a query-visible variable.
// In particular, a blank property list is lowered to an internal subject slot;
// SELECT * must expose only variables written inside that list, never that slot.
@(private) collect_visible_term_variables :: proc(plan: ^Plan, query: ^sparql.Query, base: string, term: sparql.Term_View, variables: ^[dynamic]int) -> Error_Code {
	if term.Kind == .Collection {
		for item_index in 0..<sparql.Term_Node_Item_Count(query, term.Syntax_Node) {
			item, item_ok := sparql.Term_Node_Item(query, term.Syntax_Node, item_index)
			if !item_ok do return .Unsupported_Query
			if error := collect_visible_term_variables(plan, query, base, item, variables); error != .None do return error
		}
		return .None
	}
	if term.Kind != .Blank_Property_List do return append_projection_slot(plan, query, base, term, variables)
	for property_index in 0..<sparql.Term_Node_Property_Count(query, term.Syntax_Node) {
		property, property_ok := sparql.Term_Node_Property(query, term.Syntax_Node, property_index)
		if !property_ok do return .Unsupported_Query
		if error := collect_visible_path_variables(plan, query, base, property.Path, variables); error != .None do return error
		for object_index in 0..<sparql.Term_Node_Property_Object_Count(query, term.Syntax_Node, property_index) {
			object, object_ok := sparql.Term_Node_Property_Object(query, term.Syntax_Node, property_index, object_index)
			if !object_ok do return .Unsupported_Query
			if error := collect_visible_term_variables(plan, query, base, object, variables); error != .None do return error
		}
	}
	return .None
}

@(private) collect_visible_path_variables :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Path_Ref, variables: ^[dynamic]int) -> Error_Code {
	path, path_ok := sparql.Path(query, reference)
	if !path_ok do return .Unsupported_Query
	if path.Kind == .Term do return append_projection_slot(plan, query, base, path.Term, variables)
	for index in 0..<sparql.Path_Child_Count(query, reference) {
		child, child_ok := sparql.Path_Child(query, reference, index)
		if !child_ok do return .Unsupported_Query
		if error := collect_visible_path_variables(plan, query, base, child, variables); error != .None do return error
	}
	for index in 0..<sparql.Path_Negated_Term_Count(query, reference) {
		term, _, term_ok := sparql.Path_Negated_Term(query, reference, index)
		if !term_ok do return .Unsupported_Query
		if error := append_projection_slot(plan, query, base, term, variables); error != .None do return error
	}
	return .None
}

// collect_visible_pattern_variables implements SELECT *'s visibility rule for
// the supported graph-pattern subset. Expressions can read bindings but do not
// themselves introduce one; BIND, VALUES, GRAPH, and nested subquery outputs do.
@(private) collect_visible_pattern_variables :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref, variables: ^[dynamic]int) -> Error_Code {
	view, view_ok := sparql.Pattern(query, reference)
	if !view_ok do return .Unsupported_Query
	if view.Kind == .Basic_Graph_Pattern {
		for index in 0..<sparql.Pattern_Triple_Count(query, reference) {
			triple, triple_ok := sparql.Pattern_Triple(query, reference, index)
			if !triple_ok do return .Unsupported_Query
			if error := collect_visible_term_variables(plan, query, base, triple.Subject, variables); error != .None do return error
			if error := collect_visible_path_variables(plan, query, base, triple.Path, variables); error != .None do return error
			if error := collect_visible_term_variables(plan, query, base, triple.Object, variables); error != .None do return error
		}
		return .None
	}
	if view.Kind == .Values {
		for index in 0..<sparql.Pattern_Values_Variable_Count(query, reference) {
			variable, variable_ok := sparql.Pattern_Values_Variable(query, reference, index)
			if !variable_ok do return .Unsupported_Query
			if error := append_projection_slot(plan, query, base, variable, variables); error != .None do return error
		}
		return .None
	}
	if view.Kind == .Bind {
		return append_projection_slot(plan, query, base, view.Variable, variables)
	}
	if view.Kind == .Graph {
		if error := append_projection_slot(plan, query, base, view.Graph_Name, variables); error != .None do return error
	}
	if view.Kind == .Service {
		if error := append_projection_slot(plan, query, base, view.Service_Name, variables); error != .None do return error
	}
	if view.Kind == .Subquery {
		subquery, subquery_ok := sparql.Pattern_Subquery(query, reference)
		if !subquery_ok do return .Unsupported_Query
		if sparql.Query_Select_All(subquery) {
			root, root_ok := sparql.Query_Where_Pattern(subquery)
			if !root_ok do return .Unsupported_Query
			if error := collect_visible_pattern_variables(plan, subquery, base, root, variables); error != .None do return error
			return .None
		}
		for index in 0..<sparql.Query_Select_Projection_Count(subquery) {
			variable, _, _, projection_ok := sparql.Query_Select_Projection(subquery, index)
			if !projection_ok do return .Unsupported_Query
			if error := append_projection_slot(plan, subquery, base, variable, variables); error != .None do return error
		}
		return .None
	}
	for index in 0..<sparql.Pattern_Child_Count(query, reference) {
		child, child_ok := sparql.Pattern_Child(query, reference, index)
		if !child_ok do return .Unsupported_Query
		if error := collect_visible_pattern_variables(plan, query, base, child, variables); error != .None do return error
	}
	return .None
}

@(private) Select_Extension :: struct {
	expression: int,
	variable:   int,
}

// prepare_select_extensions resolves projection expressions before the Group
// operator is finalized, but defers Extend nodes until after a query-level
// VALUES clause. SPARQL applies final VALUES after HAVING and before SELECT
// expressions, while aggregates still need their expressions registered on the
// preceding Group operator.
@(private) prepare_select_extensions :: proc(plan: ^Plan, query: ^sparql.Query, base: string, extensions: ^[dynamic]Select_Extension) -> Error_Code {
	if sparql.Query_Select_All(query) do return .None
	for index in 0..<sparql.Query_Select_Projection_Count(query) {
		variable, expression_ref, has_expression, projection_ok := sparql.Query_Select_Projection(query, index)
		if !projection_ok || !has_expression || variable.Kind != .Variable do continue
		expression, expression_error := translate_expression(plan, query, base, expression_ref)
		if expression_error != .None do return expression_error
		target, target_error := resolve_term(plan, query, base, variable)
		if target_error != .None || target.kind != .Variable do return .Unsupported_Query
		if _, append_error := append(extensions, Select_Extension{expression = expression, variable = target.variable}); append_error != nil do return .Out_Of_Memory
	}
	return .None
}

@(private) append_select_extensions :: proc(plan: ^Plan, operator: int, extensions: []Select_Extension) -> (int, Error_Code) {
	result := operator
	for extension in extensions {
		operator_error: Error_Code
		result, operator_error = append_operator(plan, Operator{kind = .Extend, expression = extension.expression, variable = extension.variable}, []int{result})
		if operator_error != .None do return -1, operator_error
	}
	return result, .None
}

@(private) append_tail_values :: proc(plan: ^Plan, query: ^sparql.Query, base: string, operator: int) -> (int, Error_Code) {
	result := operator
	for index in 0..<sparql.Query_Tail_Values_Count(query) {
		tail, tail_ok := sparql.Query_Tail_Values(query, index)
		if !tail_ok do return -1, .Unsupported_Query
		tail_operator, tail_error := translate_pattern(plan, query, base, tail)
		if tail_error != .None do return -1, tail_error
		result, tail_error = append_operator(plan, Operator{kind = .Join}, []int{result, tail_operator})
		if tail_error != .None do return -1, tail_error
	}
	return result, .None
}

@(private) append_select_order :: proc(plan: ^Plan, query: ^sparql.Query, base: string, operator: int) -> (int, Error_Code) {
	if sparql.Query_Order_Count(query) == 0 do return operator, .None
	first_order := len(plan.order_expressions)
	for index in 0..<sparql.Query_Order_Count(query) {
		condition, condition_ok := sparql.Query_Order(query, index)
		if !condition_ok do return -1, .Unsupported_Query
		expression, expression_error := translate_expression(plan, query, base, condition.Expression)
		if expression_error != .None do return -1, expression_error
		if _, append_error := append(&plan.order_expressions, expression); append_error != nil do return -1, .Out_Of_Memory
		descending := condition.Direction == .Descending
		if _, append_error := append(&plan.order_descending, descending); append_error != nil do return -1, .Out_Of_Memory
	}
	return append_operator(plan, Operator{kind = .Order, first_order = first_order, order_count = sparql.Query_Order_Count(query)}, []int{operator})
}

@(private) expression_uses_aggregate :: proc(query: ^sparql.Query, reference: sparql.Expression_Ref) -> bool {
	view, view_ok := sparql.Expression(query, reference)
	if !view_ok do return false
	if view.Kind == .Function && (strings.equal_fold(view.Name, "COUNT") || strings.equal_fold(view.Name, "SUM") || strings.equal_fold(view.Name, "AVG") || strings.equal_fold(view.Name, "GROUP_CONCAT") || strings.equal_fold(view.Name, "MIN") || strings.equal_fold(view.Name, "MAX") || strings.equal_fold(view.Name, "SAMPLE")) do return true
	for index in 0..<sparql.Expression_Child_Count(query, reference) {
		child, child_ok := sparql.Expression_Child(query, reference, index)
		if child_ok && expression_uses_aggregate(query, child) do return true
	}
	return false
}

@(private) query_uses_aggregate :: proc(query: ^sparql.Query) -> bool {
	for index in 0..<sparql.Query_Select_Projection_Count(query) {
		_, expression, has_expression, projection_ok := sparql.Query_Select_Projection(query, index)
		if projection_ok && has_expression && expression_uses_aggregate(query, expression) do return true
	}
	for index in 0..<sparql.Query_Having_Count(query) {
		expression, expression_ok := sparql.Query_Having(query, index)
		if expression_ok && expression_uses_aggregate(query, expression) do return true
	}
	for index in 0..<sparql.Query_Order_Count(query) {
		condition, condition_ok := sparql.Query_Order(query, index)
		if condition_ok && expression_uses_aggregate(query, condition.Expression) do return true
	}
	return false
}

@(private) append_group :: proc(plan: ^Plan, query: ^sparql.Query, base: string, operator: int) -> (group_operator: int, group_error: Error_Code) {
	first_expression := len(plan.group_expressions)
	for index in 0..<sparql.Query_Group_By_Count(query) {
		reference, alias, has_alias, condition_ok := sparql.Query_Group_By(query, index)
		if !condition_ok do return -1, .Unsupported_Query
		expression, expression_error := translate_expression(plan, query, base, reference)
		if expression_error != .None do return -1, expression_error
		variable := -1
		if has_alias {
			target, target_error := resolve_term(plan, query, base, alias)
			if target_error != .None || target.kind != .Variable do return -1, .Unsupported_Query
			variable = target.variable
		} else {
			view, view_ok := Expression_At(plan, expression)
			if view_ok && view.Kind == .Term && view.Term.Kind == .Variable do variable = view.Term.Variable
		}
		if _, append_error := append(&plan.group_expressions, expression); append_error != nil do return -1, .Out_Of_Memory
		if _, append_error := append(&plan.group_variables, variable); append_error != nil do return -1, .Out_Of_Memory
	}
	return append_operator(plan, Operator{kind = .Group, first_group_expression = first_expression, group_expression_count = sparql.Query_Group_By_Count(query), first_group_aggregate = len(plan.group_aggregates)}, []int{operator})
}

@(private) append_having_filters :: proc(plan: ^Plan, query: ^sparql.Query, base: string, operator: int) -> (int, Error_Code) {
	result := operator
	for index in 0..<sparql.Query_Having_Count(query) {
		reference, having_ok := sparql.Query_Having(query, index)
		if !having_ok do return -1, .Unsupported_Query
		expression, expression_error := translate_expression(plan, query, base, reference)
		if expression_error != .None do return -1, expression_error
		result, expression_error = append_operator(plan, Operator{kind = .Filter, expression = expression}, []int{result})
		if expression_error != .None do return -1, expression_error
	}
	return result, .None
}

@(private) translate_subquery :: proc(plan: ^Plan, outer_query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref) -> (int, Error_Code) {
	query, query_ok := sparql.Pattern_Subquery(outer_query, reference)
	if !query_ok || sparql.Query_Form_Of(query) != .Select do return -1, .Unsupported_Query
	_, has_limit := sparql.Query_Limit(query)
	_, has_offset := sparql.Query_Offset(query)
	if sparql.Query_Dataset_Clause_Count(query) != 0 do return -1, .Unsupported_Query
	root, root_ok := sparql.Query_Where_Pattern(query)
	if !root_ok do return -1, .Unsupported_Query
	operator, operator_error := translate_pattern(plan, query, base, root)
	if operator_error != .None do return -1, operator_error
	group_operator := -1
	if sparql.Query_Group_By_Count(query) != 0 || query_uses_aggregate(query) {
		group_operator, operator_error = append_group(plan, query, base, operator)
		if operator_error != .None do return -1, operator_error
		operator = group_operator
	}
	first_aggregate := len(plan.expressions)
	extensions := make([dynamic]Select_Extension)
	defer delete(extensions)
	if extension_error := prepare_select_extensions(plan, query, base, &extensions); extension_error != .None do return -1, extension_error
	operator, operator_error = append_having_filters(plan, query, base, operator)
	if operator_error != .None do return -1, operator_error
	operator, operator_error = append_tail_values(plan, query, base, operator)
	if operator_error != .None do return -1, operator_error
	operator, operator_error = append_select_extensions(plan, operator, extensions[:])
	if operator_error != .None do return -1, operator_error
	operator, operator_error = append_select_order(plan, query, base, operator)
	if operator_error != .None do return -1, operator_error
	if group_operator >= 0 {
		first_group_aggregate := len(plan.group_aggregates)
		for expression in first_aggregate..<len(plan.expressions) {
			if plan.expressions[expression].kind != .Count && plan.expressions[expression].kind != .Sum && plan.expressions[expression].kind != .Average && plan.expressions[expression].kind != .Group_Concat && plan.expressions[expression].kind != .Min && plan.expressions[expression].kind != .Max && plan.expressions[expression].kind != .Sample do continue
			if _, append_error := append(&plan.group_aggregates, expression); append_error != nil do return -1, .Out_Of_Memory
		}
		plan.operators[group_operator].first_group_aggregate = first_group_aggregate
		plan.operators[group_operator].group_aggregate_count = len(plan.group_aggregates) - first_group_aggregate
	}
	first_projection_variable := len(plan.projection_variables)
	variables := make([dynamic]int)
	defer delete(variables)
	if sparql.Query_Select_All(query) {
		if error := collect_visible_pattern_variables(plan, query, base, root, &variables); error != .None do return -1, error
		for index in 0..<sparql.Query_Tail_Values_Count(query) {
			tail, tail_ok := sparql.Query_Tail_Values(query, index)
			if !tail_ok do return -1, .Unsupported_Query
			if error := collect_visible_pattern_variables(plan, query, base, tail, &variables); error != .None do return -1, error
		}
	} else {
		for index in 0..<sparql.Query_Select_Projection_Count(query) {
			variable, _, _, projection_ok := sparql.Query_Select_Projection(query, index)
			if !projection_ok do return -1, .Unsupported_Query
			if error := append_projection_slot(plan, query, base, variable, &variables); error != .None do return -1, error
		}
	}
	for variable in variables {
		if _, append_error := append(&plan.projection_variables, variable); append_error != nil do return -1, .Out_Of_Memory
	}
	operator, operator_error = append_operator(plan, Operator{kind = .Project, first_projection_variable = first_projection_variable, projection_variable_count = len(variables)}, []int{operator})
	if operator_error != .None do return -1, operator_error
	if sparql.Query_Select_Modifier(query) == .Distinct || sparql.Query_Select_Modifier(query) == .Reduced {
		operator, operator_error = append_operator(plan, Operator{kind = .Distinct}, []int{operator})
		if operator_error != .None do return -1, operator_error
	}
	if !has_limit && !has_offset do return operator, .None
	offset := 0
	if has_offset {
		value, value_ok := sparql.Query_Offset(query)
		if !value_ok || value.Kind != .Integer do return -1, .Unsupported_Query
		parsed, parsed_ok := strconv.parse_int(value.Lexical, 10)
		if !parsed_ok || parsed < 0 do return -1, .Unsupported_Query
		offset = parsed
	}
	limit := 0
	if has_limit {
		value, value_ok := sparql.Query_Limit(query)
		if !value_ok || value.Kind != .Integer do return -1, .Unsupported_Query
		parsed, parsed_ok := strconv.parse_int(value.Lexical, 10)
		if !parsed_ok || parsed < 0 do return -1, .Unsupported_Query
		limit = parsed
	}
	return append_operator(plan, Operator{kind = .Slice, slice_offset = offset, slice_limit = limit, has_slice_limit = has_limit}, []int{operator})
}

@(private) translate_pattern :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref) -> (int, Error_Code) {
	view, ok := sparql.Pattern(query, reference)
	if !ok do return -1, .Unsupported_Query
	#partial switch view.Kind {
	case .Basic_Graph_Pattern:
		return translate_bgp(plan, query, base, reference)
	case .Group:
		return translate_group(plan, query, base, reference)
	case .Values:
		return translate_values(plan, query, base, reference)
	case .Graph:
		if sparql.Pattern_Child_Count(query, reference) != 1 do return -1, .Unsupported_Query
		child, child_ok := sparql.Pattern_Child(query, reference, 0)
		if !child_ok do return -1, .Unsupported_Query
		graph, graph_error := resolve_term(plan, query, base, view.Graph_Name)
		if graph_error != .None do return -1, graph_error
		graph_child, child_error := translate_pattern(plan, query, base, child)
		if child_error != .None do return -1, child_error
		return append_operator(plan, Operator{kind = .Graph, has_graph = true, graph = graph}, []int{graph_child})
	case .Service:
		if sparql.Pattern_Child_Count(query, reference) != 1 do return -1, .Unsupported_Query
		child, child_ok := sparql.Pattern_Child(query, reference, 0)
		if !child_ok do return -1, .Unsupported_Query
		service, service_error := resolve_term(plan, query, base, view.Service_Name)
		if service_error != .None do return -1, service_error
		service_child, child_error := translate_pattern(plan, query, base, child)
		if child_error != .None do return -1, child_error
		return append_operator(plan, Operator{kind = .Service, service = service, service_silent = view.Service_Silent}, []int{service_child})
	case .Subquery:
		return translate_subquery(plan, query, base, reference)
	}
	return -1, .Unsupported_Query
}

@(private) resolve_construct_term :: proc(plan: ^Plan, query: ^sparql.Query, base: string, value: sparql.Term_View) -> (Construct_Term, Error_Code) {
	if value.Kind == .Blank_Node_Label {
		if len(value.Lexical) <= 2 || value.Lexical[0:2] != "_:" do return {}, .Unsupported_Query
		label, label_error := own(plan, value.Lexical[2:])
		if label_error != .None do return {}, label_error
		return Construct_Term{kind = .Blank, blank = label}, .None
	}
	slot, slot_error := resolve_term(plan, query, base, value)
	if slot_error != .None do return {}, slot_error
	if slot.kind == .Variable do return Construct_Term{kind = .Variable, variable = slot.variable}, .None
	return Construct_Term{kind = .Term, term = slot.term}, .None
}

@(private) construct_generated_blank :: proc(plan: ^Plan, query: ^sparql.Query, prefix: string, node: sparql.Term_Node_Ref, ordinal: int = -1) -> (Construct_Term, Error_Code) {
	scope_buffer: [64]byte
	node_buffer: [64]byte
	ordinal_buffer: [64]byte
	scope_text := strconv.write_uint(scope_buffer[:], u64(cast(uintptr)query), 10)
	node_text := strconv.write_int(node_buffer[:], i64(node), 10)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, prefix)
	strings.write_string(&builder, scope_text)
	strings.write_string(&builder, "_")
	strings.write_string(&builder, node_text)
	if ordinal >= 0 {
		strings.write_string(&builder, "_")
		ordinal_text := strconv.write_int(ordinal_buffer[:], i64(ordinal), 10)
		strings.write_string(&builder, ordinal_text)
	}
	label, label_error := own(plan, strings.to_string(builder))
	if label_error != .None do return {}, label_error
	return Construct_Term{kind = .Blank, blank = label}, .None
}

@(private) append_construct_triple :: proc(plan: ^Plan, subject, predicate, object: Construct_Term) -> Error_Code {
	if _, append_error := append(&plan.construct_triples, Construct_Template_Triple{subject = subject, predicate = predicate, object = object}); append_error != nil do return .Out_Of_Memory
	return .None
}

// lower_construct_term expands graph-node shorthand in a template into its
// explicit triples. Unlike WHERE lowering, generated nodes are template blanks
// so execution allocates them fresh for each solution mapping.
@(private) lower_construct_term :: proc(plan: ^Plan, query: ^sparql.Query, base: string, value: sparql.Term_View) -> (Construct_Term, Error_Code) {
	if value.Kind != .Collection && value.Kind != .Blank_Property_List do return resolve_construct_term(plan, query, base, value)
	if value.Kind == .Blank_Property_List {
		subject, subject_error := construct_generated_blank(plan, query, "odin_construct_blank_", value.Syntax_Node)
		if subject_error != .None do return {}, subject_error
		for property_index in 0..<sparql.Term_Node_Property_Count(query, value.Syntax_Node) {
			property, property_ok := sparql.Term_Node_Property(query, value.Syntax_Node, property_index)
			if !property_ok do return {}, .Unsupported_Query
			path, path_ok := sparql.Path(query, property.Path)
			if !path_ok || path.Kind != .Term do return {}, .Unsupported_Query
			predicate, predicate_error := resolve_construct_term(plan, query, base, path.Term)
			if predicate_error != .None do return {}, predicate_error
			for object_index in 0..<sparql.Term_Node_Property_Object_Count(query, value.Syntax_Node, property_index) {
				object, object_ok := sparql.Term_Node_Property_Object(query, value.Syntax_Node, property_index, object_index)
				if !object_ok do return {}, .Unsupported_Query
				lowered, lower_error := lower_construct_term(plan, query, base, object)
				if lower_error != .None do return {}, lower_error
				if error := append_construct_triple(plan, subject, predicate, lowered); error != .None do return {}, error
			}
		}
		return subject, .None
	}
	count := sparql.Term_Node_Item_Count(query, value.Syntax_Node)
	if count == 0 do return Construct_Term{kind = .Term, term = rdf.iri(RDF_NIL)}, .None
	heads := make([dynamic]Construct_Term)
	defer delete(heads)
	for index in 0..<count {
		head, head_error := construct_generated_blank(plan, query, "odin_construct_list_", value.Syntax_Node, index)
		if head_error != .None do return {}, head_error
		if _, append_error := append(&heads, head); append_error != nil do return {}, .Out_Of_Memory
	}
	first := Construct_Term{kind = .Term, term = rdf.iri(RDF_FIRST)}
	rest := Construct_Term{kind = .Term, term = rdf.iri(RDF_REST)}
	nil_term := Construct_Term{kind = .Term, term = rdf.iri(RDF_NIL)}
	for index in 0..<count {
		item, item_ok := sparql.Term_Node_Item(query, value.Syntax_Node, index)
		if !item_ok do return {}, .Unsupported_Query
		object, object_error := lower_construct_term(plan, query, base, item)
		if object_error != .None do return {}, object_error
		if error := append_construct_triple(plan, heads[index], first, object); error != .None do return {}, error
		next := nil_term
		if index + 1 < count do next = heads[index + 1]
		if error := append_construct_triple(plan, heads[index], rest, next); error != .None do return {}, error
	}
	return heads[0], .None
}

@(private) translate_construct_template :: proc(plan: ^Plan, query: ^sparql.Query, base: string, reference: sparql.Pattern_Ref) -> Error_Code {
	view, view_ok := sparql.Pattern(query, reference)
	if !view_ok do return .Unsupported_Query
	if view.Kind == .Group {
		for index in 0..<sparql.Pattern_Child_Count(query, reference) {
			child, child_ok := sparql.Pattern_Child(query, reference, index)
			if !child_ok do return .Unsupported_Query
			if error := translate_construct_template(plan, query, base, child); error != .None do return error
		}
		return .None
	}
	if view.Kind != .Basic_Graph_Pattern do return .Unsupported_Query
	// A CONSTRUCT template may contain a standalone blank-property list or
	// collection, such as `CONSTRUCT { [ :p ?value ] . }`. Lowering it has the
	// same side effect as when it appears in a triple term: it appends the
	// generated template triples, while the returned head has no enclosing
	// triple to attach to.
	for index in 0..<sparql.Pattern_Standalone_Node_Count(query, reference) {
		node, node_ok := sparql.Pattern_Standalone_Node(query, reference, index)
		if !node_ok do return .Unsupported_Query
		if _, node_error := lower_construct_term(plan, query, base, node); node_error != .None do return node_error
	}
	for index in 0..<sparql.Pattern_Triple_Count(query, reference) {
		triple, triple_ok := sparql.Pattern_Triple(query, reference, index)
		if !triple_ok do return .Unsupported_Query
		path, path_ok := sparql.Path(query, triple.Path)
		if !path_ok || path.Kind != .Term do return .Unsupported_Query
		subject, subject_error := lower_construct_term(plan, query, base, triple.Subject)
		if subject_error != .None do return subject_error
		predicate, predicate_error := resolve_construct_term(plan, query, base, path.Term)
		if predicate_error != .None do return predicate_error
		object, object_error := lower_construct_term(plan, query, base, triple.Object)
		if object_error != .None do return object_error
		if error := append_construct_triple(plan, subject, predicate, object); error != .None do return error
	}
	return .None
}

// translate creates an owned default-graph BGP plan for a SELECT or ASK query.
// The plan's operator root is deliberately explicit even for this one-node M2
// shape, so M3 can add recursive operations without changing ownership or the
// public traversal contract. Unsupported syntax is preserved by the parser but
// rejected here until its algebra operator is implemented.
translate :: proc(query: ^sparql.Query) -> (Plan, Error_Code) {
	plan: Plan
	init(&plan)
	base, base_error := base_iri(&plan, query)
	if base_error != .None { destroy(&plan); return {}, base_error }
	if description_error := translate_dataset_description(&plan, query, base); description_error != .None {
		destroy(&plan)
		return {}, description_error
	}
	if sparql.Query_Form_Of(query) == .Construct {
		template, template_ok := sparql.Query_Construct_Template(query)
		if !template_ok { destroy(&plan); return {}, .Unsupported_Query }
		if template_error := translate_construct_template(&plan, query, base, template); template_error != .None {
			destroy(&plan)
			return {}, template_error
		}
	}
	if sparql.Query_Form_Of(query) == .Describe && !sparql.Query_Describe_All(query) {
		for index in 0..<sparql.Query_Describe_Term_Count(query) {
			target, target_ok := sparql.Query_Describe_Term(query, index)
			if !target_ok { destroy(&plan); return {}, .Unsupported_Query }
			resolved, resolved_error := resolve_construct_term(&plan, query, base, target)
			if resolved_error != .None || resolved.kind == .Blank { destroy(&plan); return {}, .Unsupported_Query }
			if _, append_error := append(&plan.describe_targets, resolved); append_error != nil { destroy(&plan); return {}, .Out_Of_Memory }
		}
	}
	root, root_ok := sparql.Query_Where_Pattern(query)
	operator := -1
	operator_error: Error_Code
	if !root_ok {
		if sparql.Query_Form_Of(query) != .Describe { destroy(&plan); return {}, .Unsupported_Query }
		operator, operator_error = append_operator(&plan, Operator{kind = .Identity})
	} else {
		operator, operator_error = translate_pattern(&plan, query, base, root)
	}
	if operator_error != .None {
		destroy(&plan)
		return {}, operator_error
	}
	if sparql.Query_Form_Of(query) == .Select {
		group_operator := -1
		if sparql.Query_Group_By_Count(query) != 0 || query_uses_aggregate(query) {
			group_operator, operator_error = append_group(&plan, query, base, operator)
			if operator_error != .None { destroy(&plan); return {}, operator_error }
			operator = group_operator
		}
		first_aggregate := len(plan.expressions)
		extensions := make([dynamic]Select_Extension)
		defer delete(extensions)
		if extension_error := prepare_select_extensions(&plan, query, base, &extensions); extension_error != .None { destroy(&plan); return {}, extension_error }
		operator, operator_error = append_having_filters(&plan, query, base, operator)
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		operator, operator_error = append_tail_values(&plan, query, base, operator)
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		operator, operator_error = append_select_extensions(&plan, operator, extensions[:])
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		operator, operator_error = append_select_order(&plan, query, base, operator)
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		if group_operator >= 0 {
			first_group_aggregate := len(plan.group_aggregates)
			for expression in first_aggregate..<len(plan.expressions) {
			if plan.expressions[expression].kind != .Count && plan.expressions[expression].kind != .Sum && plan.expressions[expression].kind != .Average && plan.expressions[expression].kind != .Group_Concat && plan.expressions[expression].kind != .Min && plan.expressions[expression].kind != .Max && plan.expressions[expression].kind != .Sample do continue
				if _, append_error := append(&plan.group_aggregates, expression); append_error != nil { destroy(&plan); return {}, .Out_Of_Memory }
			}
			plan.operators[group_operator].first_group_aggregate = first_group_aggregate
			plan.operators[group_operator].group_aggregate_count = len(plan.group_aggregates) - first_group_aggregate
		}
		if sparql.Query_Select_All(query) {
			variables := make([dynamic]int)
			defer delete(variables)
			if error := collect_visible_pattern_variables(&plan, query, base, root, &variables); error != .None { destroy(&plan); return {}, error }
			for index in 0..<sparql.Query_Tail_Values_Count(query) {
				tail, tail_ok := sparql.Query_Tail_Values(query, index)
				if !tail_ok { destroy(&plan); return {}, .Unsupported_Query }
				if error := collect_visible_pattern_variables(&plan, query, base, tail, &variables); error != .None { destroy(&plan); return {}, error }
			}
			for variable in variables {
				if _, append_error := append(&plan.result_variables, variable); append_error != nil { destroy(&plan); return {}, .Out_Of_Memory }
			}
		} else {
			for index in 0..<sparql.Query_Select_Projection_Count(query) {
				variable, _, _, projection_ok := sparql.Query_Select_Projection(query, index)
				if !projection_ok || variable.Kind != .Variable { destroy(&plan); return {}, .Unsupported_Query }
				resolved, resolve_error := resolve_term(&plan, query, base, variable)
				if resolve_error != .None || resolved.kind != .Variable { destroy(&plan); return {}, .Unsupported_Query }
				if _, append_error := append(&plan.result_variables, resolved.variable); append_error != nil { destroy(&plan); return {}, .Out_Of_Memory }
			}
		}
	}
	if sparql.Query_Form_Of(query) == .Construct || sparql.Query_Form_Of(query) == .Describe || sparql.Query_Form_Of(query) == .Ask {
		group_operator := -1
		if sparql.Query_Group_By_Count(query) != 0 || query_uses_aggregate(query) {
			group_operator, operator_error = append_group(&plan, query, base, operator)
			if operator_error != .None { destroy(&plan); return {}, operator_error }
			operator = group_operator
		}
		first_aggregate := len(plan.expressions)
		operator, operator_error = append_having_filters(&plan, query, base, operator)
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		operator, operator_error = append_tail_values(&plan, query, base, operator)
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		operator, operator_error = append_select_order(&plan, query, base, operator)
		if operator_error != .None { destroy(&plan); return {}, operator_error }
		if group_operator >= 0 {
			first_group_aggregate := len(plan.group_aggregates)
			for expression in first_aggregate..<len(plan.expressions) {
				if plan.expressions[expression].kind != .Count && plan.expressions[expression].kind != .Sum && plan.expressions[expression].kind != .Average && plan.expressions[expression].kind != .Group_Concat && plan.expressions[expression].kind != .Min && plan.expressions[expression].kind != .Max && plan.expressions[expression].kind != .Sample do continue
				if _, append_error := append(&plan.group_aggregates, expression); append_error != nil { destroy(&plan); return {}, .Out_Of_Memory }
			}
			plan.operators[group_operator].first_group_aggregate = first_group_aggregate
			plan.operators[group_operator].group_aggregate_count = len(plan.group_aggregates) - first_group_aggregate
		}
	}
	plan.root = operator
	return plan, .None
}
