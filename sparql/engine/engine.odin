// Package engine executes supported SPARQL query forms over Dataset views.
package engine

import "core:strings"
import "core:strconv"
import rdf "odin-rdf:rdf"
import sparql ".."
import algebra "../algebra"
import dataset "../dataset"
import eval "../eval"

Error_Code :: enum {
	None,
	Invalid_Options,
	Unsupported_Query,
	Algebra_Error,
	Evaluation_Error,
	Service_Error,
	Cancelled,
	Solution_Limit,
	Numeric_Limit,
	Invalid_Slice,
	Out_Of_Memory,
}

// Execution_Statistics is the optional evaluator counter set exposed through
// the public engine API.
Execution_Statistics :: eval.Execution_Statistics
// Service_Callback resolves a SERVICE endpoint into an application-owned View.
Service_Callback :: eval.Service_Callback
Cancellation_Callback :: eval.Cancellation_Callback
// UUID_Callback optionally supplies deterministic UUID values for one execute call.
UUID_Callback :: eval.UUID_Callback
// RAND_Callback optionally supplies deterministic RAND() values for one execute call.
RAND_Callback :: eval.RAND_Callback

Options :: struct {
	Max_Solutions:      int,
	Max_Numeric_Digits: int,
	// Decimal_Division_Precision controls non-terminating integer/decimal
	// division. Zero uses the stable 34-significant-digit default.
	Decimal_Division_Precision: int,
	// Service_Callback resolves explicit SERVICE endpoints into application-owned
	// Dataset views. A nil callback never performs network I/O.
	Service_Callback: Service_Callback,
	Service_Data:     rawptr,
	// Cancellation_Callback is polled at evaluator/operator and dataset-scan
	// boundaries. A true return aborts this execute call with Cancelled.
	Cancellation_Callback: Cancellation_Callback,
	Cancellation_Data:     rawptr,
	// Optimize_BGP opts into deterministic, constraint-only ordering for triple
	// patterns inside one BGP. The default retains source order.
	Optimize_BGP: bool,
	// Statistics may be nil and accumulates counters without changing results.
	Statistics: ^Execution_Statistics,
	// Now_Lexical fixes NOW() for one execution. It must be a valid xsd:dateTime
	// lexical form; an empty value captures the UTC system clock once.
	Now_Lexical: string,
	// UUID_Callback optionally supplies fresh UUID values for UUID()/STRUUID().
	// A nil callback uses the evaluator's cryptographically secure UUID v4 path.
	UUID_Callback: UUID_Callback,
	UUID_Data:     rawptr,
	// RAND_Callback optionally supplies finite [0,1) values for RAND().
	// A nil callback uses cryptographic entropy.
	RAND_Callback: RAND_Callback,
	RAND_Data:     rawptr,
}

Result_Kind :: enum { Select, Ask, Graph }

@(private) Row :: struct {
	values: [dynamic]rdf.Term,
	bound:  [dynamic]bool,
}

// Result owns its column names and RDF terms. Destroy it exactly once.
Result :: struct {
	kind:      Result_Kind,
	ask:       bool,
	variables: [dynamic]string,
	rows:      [dynamic]Row,
	triples:   [dynamic]rdf.Triple,
	owned:     [dynamic]string,
}

// Description_View derives SPARQL's query dataset from an application-owned
// base view. It never loads a graph URI: a FROM source is matched against an
// already-present named graph in that view.
@(private) Description_View :: struct {
	source: dataset.View,
	plan:   ^algebra.Plan,
}

@(private) Description_Scan :: struct {
	target:      dataset.Scan_Sink,
	target_data: rawptr,
	deduplicate: bool,
	seen:        [dynamic]rdf.Quad,
	owned:       [dynamic]string,
	error:       dataset.Error_Code,
	stopped:     bool,
}

error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:              return "no error"
	case .Invalid_Options:   return "execution options are invalid"
	case .Unsupported_Query: return "query feature is not implemented by this engine slice"
	case .Algebra_Error:     return "query could not be translated to algebra"
	case .Evaluation_Error:  return "basic graph pattern evaluation failed"
	case .Service_Error:     return "service callback could not provide a queryable dataset"
	case .Cancelled:         return "query execution was cancelled"
	case .Solution_Limit:    return "solution limit reached"
	case .Numeric_Limit:     return "numeric intermediate digit limit reached"
	case .Invalid_Slice:      return "LIMIT or OFFSET must fit a non-negative machine integer"
	case .Out_Of_Memory:     return "memory allocation failed"
	}
	return "unknown engine error"
}

@(private) map_evaluation_error :: proc(code: eval.Error_Code) -> Error_Code {
	switch code {
	case .None:             return .None
	case .Invalid_Options:  return .Invalid_Options
	case .Service_Error:    return .Service_Error
	case .Cancelled:        return .Cancelled
	case .Solution_Limit:   return .Solution_Limit
	case .Numeric_Limit:    return .Numeric_Limit
	case .Out_Of_Memory:    return .Out_Of_Memory
	case .Unsupported_Plan, .Dataset_Error: return .Evaluation_Error
	}
	return .Evaluation_Error
}

@(private) cancellation_requested :: proc(options: Options) -> bool {
	return options.Cancellation_Callback != nil && options.Cancellation_Callback(options.Cancellation_Data)
}

destroy :: proc(result: ^Result) {
	for value in result.owned do delete(value)
	delete(result.owned)
	delete(result.variables)
	for row in result.rows {
		delete(row.values)
		delete(row.bound)
	}
	delete(result.rows)
	delete(result.triples)
	result^ = {}
}

Kind :: proc(result: ^Result) -> Result_Kind { return result.kind }
Ask_Value :: proc(result: ^Result) -> (bool, bool) { return result.ask, result.kind == .Ask }
Variable_Count :: proc(result: ^Result) -> int { return len(result.variables) }
Row_Count :: proc(result: ^Result) -> int { return len(result.rows) }
Triple_Count :: proc(result: ^Result) -> int { return len(result.triples) }

Variable_Name :: proc(result: ^Result, index: int) -> (string, bool) {
	if index < 0 || index >= len(result.variables) do return "", false
	return result.variables[index], true
}

Cell :: proc(result: ^Result, row, variable: int) -> (term: rdf.Term, bound: bool, ok: bool) {
	if result.kind != .Select || row < 0 || row >= len(result.rows) || variable < 0 || variable >= len(result.variables) do return {}, false, false
	value := result.rows[row]
	return value.values[variable], value.bound[variable], true
}

// Triple returns one owned CONSTRUCT result statement. Graph results are RDF
// graphs, so repeated template instantiations of an equal triple occur once.
Triple :: proc(result: ^Result, index: int) -> (rdf.Triple, bool) {
	if result.kind != .Graph || index < 0 || index >= len(result.triples) do return {}, false
	return result.triples[index], true
}

@(private) own :: proc(result: ^Result, value: string) -> (string, Error_Code) {
	if len(value) == 0 do return "", .None
	cloned, clone_error := strings.clone(value)
	if clone_error != nil do return "", .Out_Of_Memory
	_, append_error := append(&result.owned, cloned)
	if append_error != nil { delete(cloned); return "", .Out_Of_Memory }
	return cloned, .None
}

@(private) discard_owned_from :: proc(result: ^Result, start: int) {
	for index in start..<len(result.owned) do delete(result.owned[index])
	resize(&result.owned, start)
}

@(private) copy_term :: proc(result: ^Result, value: rdf.Term) -> (rdf.Term, Error_Code) {
	copy := value
	error: Error_Code
	copy.value, error = own(result, value.value)
	if error != .None do return {}, error
	copy.language, error = own(result, value.language)
	if error != .None do return {}, error
	copy.datatype, error = own(result, value.datatype)
	if error != .None do return {}, error
	return copy, .None
}

@(private) equal_term :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value && left.language == right.language && left.datatype == right.datatype && left.scope == right.scope
}

@(private) equal_triple :: proc(left, right: rdf.Quad) -> bool {
	return equal_term(left.subject, right.subject) && equal_term(left.predicate, right.predicate) && equal_term(left.object, right.object)
}

@(private) equal_result_triple :: proc(left, right: rdf.Triple) -> bool {
	return equal_term(left.subject, right.subject) && equal_term(left.predicate, right.predicate) && equal_term(left.object, right.object)
}

@(private) description_own_string :: proc(scan: ^Description_Scan, value: string) -> (string, bool) {
	if len(value) == 0 do return "", true
	cloned, clone_error := strings.clone(value)
	if clone_error != nil do return "", false
	if _, append_error := append(&scan.owned, cloned); append_error != nil { delete(cloned); return "", false }
	return cloned, true
}

@(private) description_copy_term :: proc(scan: ^Description_Scan, value: rdf.Term) -> (rdf.Term, bool) {
	copy := value
	copy.value, _ = description_own_string(scan, value.value)
	if len(value.value) != 0 && len(copy.value) == 0 do return {}, false
	copy.language, _ = description_own_string(scan, value.language)
	if len(value.language) != 0 && len(copy.language) == 0 do return {}, false
	copy.datatype, _ = description_own_string(scan, value.datatype)
	if len(value.datatype) != 0 && len(copy.datatype) == 0 do return {}, false
	return copy, true
}

@(private) description_remember :: proc(scan: ^Description_Scan, value: rdf.Quad) -> bool {
	stored: rdf.Quad
	stored.subject, _ = description_copy_term(scan, value.subject)
	if len(value.subject.value) != 0 && len(stored.subject.value) == 0 do return false
	stored.predicate, _ = description_copy_term(scan, value.predicate)
	if len(value.predicate.value) != 0 && len(stored.predicate.value) == 0 do return false
	stored.object, _ = description_copy_term(scan, value.object)
	if len(value.object.value) != 0 && len(stored.object.value) == 0 do return false
	if _, append_error := append(&scan.seen, stored); append_error != nil do return false
	return true
}

@(private) description_relay :: proc(quad: rdf.Quad, data: rawptr) -> bool {
	scan := cast(^Description_Scan)data
	if scan.stopped || scan.error != .None do return false
	if scan.deduplicate {
		for known in scan.seen do if equal_triple(known, quad) do return true
		if !description_remember(scan, quad) { scan.error = .Out_Of_Memory; return false }
	}
	if !scan.target(quad, scan.target_data) { scan.stopped = true; return false }
	return true
}

@(private) description_scan_source :: proc(description: ^Description_View, pattern: dataset.Quad_Pattern, scan: ^Description_Scan) -> dataset.Error_Code {
	error := dataset.scan(description.source, pattern, description_relay, scan)
	if error != .None do return error
	return scan.error
}

@(private) prior_graph_matches :: proc(plan: ^algebra.Plan, named: bool, index: int, graph: rdf.Term) -> bool {
	for previous in 0..<index {
		candidate: rdf.Term
		candidate_ok: bool
		if named {
			candidate, candidate_ok = algebra.Dataset_Named_Graph(plan, previous)
		} else {
			candidate, candidate_ok = algebra.Dataset_Default_Graph(plan, previous)
		}
		if candidate_ok && equal_term(candidate, graph) do return true
	}
	return false
}

@(private) description_scan :: proc(data: rawptr, pattern: dataset.Quad_Pattern, sink: dataset.Scan_Sink, sink_data: rawptr) -> dataset.Error_Code {
	description := cast(^Description_View)data
	scan := Description_Scan{target = sink, target_data = sink_data, seen = make([dynamic]rdf.Quad), owned = make([dynamic]string)}
	defer {
		for value in scan.owned do delete(value)
		delete(scan.owned)
		delete(scan.seen)
	}
	switch pattern.Graph_Mode {
	case .Default:
		scan.deduplicate = true
		for index in 0..<algebra.Dataset_Default_Graph_Count(description.plan) {
			graph, graph_ok := algebra.Dataset_Default_Graph(description.plan, index)
			if !graph_ok || prior_graph_matches(description.plan, false, index, graph) do continue
			request := pattern
			request.Graph_Mode = .Named
			request.Graph = graph
			if error := description_scan_source(description, request, &scan); error != .None do return error
			if scan.stopped do break
		}
	case .Named:
		for index in 0..<algebra.Dataset_Named_Graph_Count(description.plan) {
			graph, graph_ok := algebra.Dataset_Named_Graph(description.plan, index)
			if !graph_ok || !equal_term(graph, pattern.Graph) do continue
			return description_scan_source(description, pattern, &scan)
		}
	case .Any_Named:
		for index in 0..<algebra.Dataset_Named_Graph_Count(description.plan) {
			graph, graph_ok := algebra.Dataset_Named_Graph(description.plan, index)
			if !graph_ok || prior_graph_matches(description.plan, true, index, graph) do continue
			request := pattern
			request.Graph_Mode = .Named
			request.Graph = graph
			if error := description_scan_source(description, request, &scan); error != .None do return error
			if scan.stopped do break
		}
	}
	return scan.error
}

@(private) append_column :: proc(result: ^Result, name: string, source_index: int, sources: ^[dynamic]int) -> Error_Code {
	owned, own_error := own(result, name)
	if own_error != .None do return own_error
	if _, error := append(&result.variables, owned); error != nil do return .Out_Of_Memory
	if _, error := append(sources, source_index); error != nil do return .Out_Of_Memory
	return .None
}

@(private) select_columns :: proc(result: ^Result, plan: ^algebra.Plan) -> ([dynamic]int, Error_Code) {
	sources := make([dynamic]int)
	for index in 0..<algebra.Result_Variable_Count(plan) {
		variable, variable_ok := algebra.Result_Variable(plan, index)
		name, name_ok := algebra.Variable_Name(plan, variable)
		if !variable_ok || !name_ok { delete(sources); return {}, .Algebra_Error }
		if error := append_column(result, name, variable, &sources); error != .None { delete(sources); return {}, error }
	}
	return sources, .None
}

@(private) append_row :: proc(result: ^Result, source: ^eval.Result, source_row: int, columns: [dynamic]int) -> Error_Code {
	row := Row{values = make([dynamic]rdf.Term), bound = make([dynamic]bool)}
	owned_start := len(result.owned)
	for column in columns {
		value: rdf.Term
		bound := false
		if column >= 0 {
			term, is_bound, ok := eval.Solution_Binding(source, source_row, column)
			if !ok { delete(row.values); delete(row.bound); discard_owned_from(result, owned_start); return .Evaluation_Error }
			bound = is_bound
			if bound {
				copy, copy_error := copy_term(result, term)
				if copy_error != .None { delete(row.values); delete(row.bound); discard_owned_from(result, owned_start); return copy_error }
				value = copy
			}
		}
		if _, error := append(&row.values, value); error != nil { delete(row.values); delete(row.bound); discard_owned_from(result, owned_start); return .Out_Of_Memory }
		if _, error := append(&row.bound, bound); error != nil { delete(row.values); delete(row.bound); discard_owned_from(result, owned_start); return .Out_Of_Memory }
	}
	if _, error := append(&result.rows, row); error != nil { delete(row.values); delete(row.bound); discard_owned_from(result, owned_start); return .Out_Of_Memory }
	return .None
}

// projected_rows_equal compares exactly the bindings exposed by SELECT. This
// intentionally runs after projection-expression lowering, so aliases and
// unbound projected variables participate in DISTINCT/REDUCED correctly.
@(private) projected_rows_equal :: proc(source: ^eval.Result, left, right: int, columns: [dynamic]int) -> (bool, Error_Code) {
	for column in columns {
		if column < 0 do continue
		left_term, left_bound, left_ok := eval.Solution_Binding(source, left, column)
		right_term, right_bound, right_ok := eval.Solution_Binding(source, right, column)
		if !left_ok || !right_ok do return false, .Evaluation_Error
		if left_bound != right_bound do return false, .None
		if left_bound && !equal_term(left_term, right_term) do return false, .None
	}
	return true, .None
}

@(private) slice_value :: proc(value: sparql.Term_View) -> (int, Error_Code) {
	if value.Kind != .Integer do return 0, .Invalid_Slice
	parsed, parsed_ok := strconv.parse_int(value.Lexical, 10)
	if !parsed_ok || parsed < 0 do return 0, .Invalid_Slice
	return parsed, .None
}

@(private) select_slice :: proc(query: ^sparql.Query) -> (offset, limit: int, error: Error_Code) {
	limit = -1
	if value, present := sparql.Query_Offset(query); present {
		parsed, parsed_error := slice_value(value)
		if parsed_error != .None do return 0, 0, parsed_error
		offset = parsed
	}
	if value, present := sparql.Query_Limit(query); present {
		parsed, parsed_error := slice_value(value)
		if parsed_error != .None do return 0, 0, parsed_error
		limit = parsed
	}
	return offset, limit, .None
}

@(private) append_graph_triple :: proc(result: ^Result, value: rdf.Triple) -> Error_Code {
	if rdf.validate_triple_structure(value) != .None do return .None
	for known in result.triples do if equal_result_triple(known, value) do return .None
	owned_start := len(result.owned)
	copy: rdf.Triple
	subject, subject_error := copy_term(result, value.subject)
	if subject_error != .None { discard_owned_from(result, owned_start); return subject_error }
	copy.subject = subject
	predicate, predicate_error := copy_term(result, value.predicate)
	if predicate_error != .None { discard_owned_from(result, owned_start); return predicate_error }
	copy.predicate = predicate
	object, object_error := copy_term(result, value.object)
	if object_error != .None { discard_owned_from(result, owned_start); return object_error }
	copy.object = object
	if _, append_error := append(&result.triples, copy); append_error != nil {
		discard_owned_from(result, owned_start)
		return .Out_Of_Memory
	}
	return .None
}

@(private) construct_term_value :: proc(term: algebra.Construct_Term_View, source: ^eval.Result, row: int, blank_scope: rdf.Blank_Node_Scope) -> (rdf.Term, bool) {
	if term.Kind == .Term do return term.Term, true
	if term.Kind == .Blank do return rdf.blank_node(term.Blank, blank_scope), true
	if term.Kind != .Variable || term.Variable < 0 do return {}, false
	value, bound, ok := eval.Solution_Binding(source, row, term.Variable)
	return value, bound && ok
}

@(private) execute_construct :: proc(query: ^sparql.Query, plan: ^algebra.Plan, view: dataset.View, options: Options) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	offset, limit, slice_error := select_slice(query)
	if slice_error != .None do return {}, slice_error
	intermediate, evaluation_error := eval.evaluate(plan, view, {Max_Solutions = options.Max_Solutions, Max_Numeric_Digits = options.Max_Numeric_Digits, Decimal_Division_Precision = options.Decimal_Division_Precision, Now_Lexical = options.Now_Lexical, UUID_Callback = options.UUID_Callback, UUID_Data = options.UUID_Data, RAND_Callback = options.RAND_Callback, RAND_Data = options.RAND_Data, Service_Callback = options.Service_Callback, Service_Data = options.Service_Data, Cancellation_Callback = options.Cancellation_Callback, Cancellation_Data = options.Cancellation_Data, Optimize_BGP = options.Optimize_BGP, Statistics = options.Statistics})
	if evaluation_error != .None do return {}, map_evaluation_error(evaluation_error)
	defer eval.destroy(&intermediate)
	result := Result{kind = .Graph, variables = make([dynamic]string), rows = make([dynamic]Row), triples = make([dynamic]rdf.Triple), owned = make([dynamic]string)}
	accepted := 0
	for row in 0..<eval.Solution_Count(&intermediate) {
		if cancellation_requested(options) { destroy(&result); return {}, .Cancelled }
		if accepted < offset { accepted += 1; continue }
		if limit >= 0 && accepted - offset >= limit do break
		// The scope—not merely the lexical label—makes template blank nodes fresh
		// per solution mapping while retaining shared labels within that mapping.
		blank_scope := rdf.new_blank_node_scope()
		for index in 0..<algebra.Construct_Triple_Count(plan) {
			if cancellation_requested(options) { destroy(&result); return {}, .Cancelled }
			template, template_ok := algebra.Construct_Triple(plan, index)
			if !template_ok { destroy(&result); return {}, .Algebra_Error }
			subject, subject_bound := construct_term_value(template.Subject, &intermediate, row, blank_scope)
			predicate, predicate_bound := construct_term_value(template.Predicate, &intermediate, row, blank_scope)
			object, object_bound := construct_term_value(template.Object, &intermediate, row, blank_scope)
			if !subject_bound || !predicate_bound || !object_bound do continue
			if error := append_graph_triple(&result, rdf.Triple{subject = subject, predicate = predicate, object = object}); error != .None { destroy(&result); return {}, error }
		}
		accepted += 1
	}
	return result, .None
}

@(private) append_describe_target :: proc(targets: ^[dynamic]rdf.Term, value: rdf.Term) -> Error_Code {
	if value.kind != .IRI && value.kind != .Blank_Node do return .None
	for known in targets^ do if equal_term(known, value) do return .None
	if _, append_error := append(targets, value); append_error != nil do return .Out_Of_Memory
	return .None
}

@(private) Describe_Scan :: struct {
	result:  ^Result,
	error:   Error_Code,
	options: Options,
}

@(private) describe_scan_sink :: proc(quad: rdf.Quad, data: rawptr) -> bool {
	state := cast(^Describe_Scan)data
	if state.error != .None do return false
	if cancellation_requested(state.options) {
		state.error = .Cancelled
		return false
	}
	state.error = append_graph_triple(state.result, rdf.Triple{subject = quad.subject, predicate = quad.predicate, object = quad.object})
	return state.error == .None
}

@(private) scan_describe_target :: proc(result: ^Result, view: dataset.View, target: rdf.Term, options: Options) -> Error_Code {
	if cancellation_requested(options) do return .Cancelled
	state := Describe_Scan{result = result, options = options}
	pattern := dataset.Quad_Pattern{Graph_Mode = .Default, Has_Subject = true, Subject = target}
	if scan_error := dataset.scan(view, pattern, describe_scan_sink, &state); scan_error != .None || state.error != .None {
		if state.error != .None do return state.error
		return .Evaluation_Error
	}
	return .None
}

// execute_describe implements the library's documented concise bounded
// description policy: evaluate the requested resources, then return their
// outgoing statements from the active default graph only. It never follows
// links, merges named graphs, or performs implicit network access.
@(private) execute_describe :: proc(query: ^sparql.Query, plan: ^algebra.Plan, view: dataset.View, options: Options) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	offset, limit, slice_error := select_slice(query)
	if slice_error != .None do return {}, slice_error
	targets := make([dynamic]rdf.Term)
	defer delete(targets)
	result := Result{kind = .Graph, variables = make([dynamic]string), rows = make([dynamic]Row), triples = make([dynamic]rdf.Triple), owned = make([dynamic]string)}
	completed := false
	defer if !completed do destroy(&result)
	// Explicit IRI targets are descriptions regardless of whether WHERE has a
	// solution. WHERE is only needed to discover variable targets (or the
	// resources selected by DESCRIBE *).
	needs_evaluation := sparql.Query_Describe_All(query)
	if !sparql.Query_Describe_All(query) {
		for index in 0..<algebra.Describe_Target_Count(plan) {
			if cancellation_requested(options) do return {}, .Cancelled
			target, target_ok := algebra.Describe_Target(plan, index)
			if !target_ok do return {}, .Algebra_Error
			if target.Kind == .Term {
				previous := len(targets)
				if error := append_describe_target(&targets, target.Term); error != .None do return {}, error
				if len(targets) > previous {
					if error := scan_describe_target(&result, view, target.Term, options); error != .None do return {}, error
				}
			} else if target.Kind == .Variable {
				needs_evaluation = true
			} else {
				return {}, .Algebra_Error
			}
		}
	}
	if needs_evaluation {
		intermediate, evaluation_error := eval.evaluate(plan, view, {Max_Solutions = options.Max_Solutions, Max_Numeric_Digits = options.Max_Numeric_Digits, Decimal_Division_Precision = options.Decimal_Division_Precision, Now_Lexical = options.Now_Lexical, UUID_Callback = options.UUID_Callback, UUID_Data = options.UUID_Data, RAND_Callback = options.RAND_Callback, RAND_Data = options.RAND_Data, Service_Callback = options.Service_Callback, Service_Data = options.Service_Data, Cancellation_Callback = options.Cancellation_Callback, Cancellation_Data = options.Cancellation_Data, Optimize_BGP = options.Optimize_BGP, Statistics = options.Statistics})
		if evaluation_error != .None do return {}, map_evaluation_error(evaluation_error)
		defer eval.destroy(&intermediate)
		accepted := 0
		for row in 0..<eval.Solution_Count(&intermediate) {
			if cancellation_requested(options) do return {}, .Cancelled
			if accepted < offset { accepted += 1; continue }
			if limit >= 0 && accepted - offset >= limit do break
			if sparql.Query_Describe_All(query) {
				for variable in 0..<algebra.Variable_Count(plan) {
					if cancellation_requested(options) do return {}, .Cancelled
					value, bound, value_ok := eval.Solution_Binding(&intermediate, row, variable)
					if !value_ok do return {}, .Evaluation_Error
					if bound {
						previous := len(targets)
						if error := append_describe_target(&targets, value); error != .None do return {}, error
						if len(targets) > previous {
							if error := scan_describe_target(&result, view, value, options); error != .None do return {}, error
						}
					}
				}
				accepted += 1
				continue
			}
			for index in 0..<algebra.Describe_Target_Count(plan) {
				if cancellation_requested(options) do return {}, .Cancelled
				target, target_ok := algebra.Describe_Target(plan, index)
				if !target_ok do return {}, .Algebra_Error
				if target.Kind != .Variable do continue
				value, bound, value_ok := eval.Solution_Binding(&intermediate, row, target.Variable)
				if !value_ok do return {}, .Evaluation_Error
				if bound {
					previous := len(targets)
					if error := append_describe_target(&targets, value); error != .None do return {}, error
					if len(targets) > previous {
						if error := scan_describe_target(&result, view, value, options); error != .None do return {}, error
					}
				}
			}
			accepted += 1
		}
	}
	completed = true
	return result, .None
}

@(private) execute_select :: proc(query: ^sparql.Query, plan: ^algebra.Plan, view: dataset.View, options: Options) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	offset, limit, slice_error := select_slice(query)
	if slice_error != .None do return {}, slice_error
	intermediate, evaluation_error := eval.evaluate(plan, view, {Max_Solutions = options.Max_Solutions, Max_Numeric_Digits = options.Max_Numeric_Digits, Decimal_Division_Precision = options.Decimal_Division_Precision, Now_Lexical = options.Now_Lexical, UUID_Callback = options.UUID_Callback, UUID_Data = options.UUID_Data, RAND_Callback = options.RAND_Callback, RAND_Data = options.RAND_Data, Service_Callback = options.Service_Callback, Service_Data = options.Service_Data, Cancellation_Callback = options.Cancellation_Callback, Cancellation_Data = options.Cancellation_Data, Optimize_BGP = options.Optimize_BGP, Statistics = options.Statistics})
	if evaluation_error != .None do return {}, map_evaluation_error(evaluation_error)
	defer eval.destroy(&intermediate)
	result := Result{kind = .Select, variables = make([dynamic]string), rows = make([dynamic]Row), owned = make([dynamic]string)}
	columns, column_error := select_columns(&result, plan)
	if column_error != .None { delete(columns); destroy(&result); return {}, column_error }
	defer delete(columns)
	seen := make([dynamic]int)
	defer delete(seen)
	accepted := 0
	for row in 0..<eval.Solution_Count(&intermediate) {
		if cancellation_requested(options) { destroy(&result); return {}, .Cancelled }
		modifier := sparql.Query_Select_Modifier(query)
		if modifier == .Distinct || modifier == .Reduced {
			duplicate := false
			for prior in seen {
				equal, equal_error := projected_rows_equal(&intermediate, prior, row, columns)
				if equal_error != .None { destroy(&result); return {}, equal_error }
				if equal { duplicate = true; break }
			}
			if duplicate do continue
			if _, seen_error := append(&seen, row); seen_error != nil { destroy(&result); return {}, .Out_Of_Memory }
		}
		if accepted < offset { accepted += 1; continue }
		if limit >= 0 && accepted - offset >= limit do break
		if error := append_row(&result, &intermediate, row, columns); error != .None { destroy(&result); return {}, error }
		accepted += 1
	}
	return result, .None
}

@(private) execute_ask :: proc(query: ^sparql.Query, plan: ^algebra.Plan, view: dataset.View, options: Options) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	offset, limit, slice_error := select_slice(query)
	if slice_error != .None do return {}, slice_error
	// A plain ASK can stop at its first mapping. Any solution modifier that can
	// discard, group, or reorder mappings must instead be evaluated as a bounded
	// sequence before its boolean is decided.
	modifies_sequence := offset != 0 || sparql.Query_Having_Count(query) != 0 || sparql.Query_Order_Count(query) != 0
	evaluation_options := eval.Options{Max_Solutions = modifies_sequence ? options.Max_Solutions : 1, Stop_When_Full = !modifies_sequence, Max_Numeric_Digits = options.Max_Numeric_Digits, Decimal_Division_Precision = options.Decimal_Division_Precision, Now_Lexical = options.Now_Lexical, UUID_Callback = options.UUID_Callback, UUID_Data = options.UUID_Data, RAND_Callback = options.RAND_Callback, RAND_Data = options.RAND_Data, Service_Callback = options.Service_Callback, Service_Data = options.Service_Data, Cancellation_Callback = options.Cancellation_Callback, Cancellation_Data = options.Cancellation_Data, Optimize_BGP = options.Optimize_BGP, Statistics = options.Statistics}
	// ASK may stop after one BGP solution, but a Group operator must consume its
	// complete bounded input before it can decide whether any grouped solution
	// survives. Propagating the one-row ASK cap into a group changes COUNT and
	// GROUP_CONCAT semantics.
	for operator in 0..<algebra.Operator_Count(plan) {
		node, node_ok := algebra.Operator_At(plan, operator)
		if node_ok && node.Kind == .Group {
			evaluation_options.Max_Solutions = options.Max_Solutions
			evaluation_options.Stop_When_Full = false
			break
		}
	}
	intermediate, evaluation_error := eval.evaluate(plan, view, evaluation_options)
	if evaluation_error != .None do return {}, map_evaluation_error(evaluation_error)
	defer eval.destroy(&intermediate)
	value := limit != 0 && eval.Solution_Count(&intermediate) > offset
	return Result{kind = .Ask, ask = value, variables = make([dynamic]string), rows = make([dynamic]Row), owned = make([dynamic]string)}, .None
}

// execute translates and evaluates the currently supported SELECT, ASK,
// CONSTRUCT, or documented-policy DESCRIBE query. It never opens a network
// connection and requires a bounded result limit even for ASK, where the limit
// serves as a resource-policy acknowledgement.
execute :: proc(query: ^sparql.Query, view: dataset.View, options: Options) -> (Result, Error_Code) {
	if cancellation_requested(options) do return {}, .Cancelled
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	plan, translation_error := algebra.translate(query)
	if translation_error != .None do return {}, .Algebra_Error
	defer algebra.destroy(&plan)
	execution_view := view
	description := Description_View{source = view, plan = &plan}
	if algebra.Has_Dataset_Description(&plan) do execution_view = dataset.custom_view(description_scan, &description)
	#partial switch sparql.Query_Form_Of(query) {
	case .Select: return execute_select(query, &plan, execution_view, options)
	case .Ask: return execute_ask(query, &plan, execution_view, options)
	case .Construct: return execute_construct(query, &plan, execution_view, options)
	case .Describe: return execute_describe(query, &plan, execution_view, options)
	}
	return {}, .Unsupported_Query
}
