// Package eval evaluates executable SPARQL algebra against Dataset views.
package eval

import "core:strings"
import "core:strconv"
import "core:math"
import big "core:math/big"
import time "core:time"
import datetime "core:time/datetime"
import "core:crypto"
import uuid "core:encoding/uuid"
import rand "core:math/rand"
import "base:runtime"
import regex_common "core:text/regex/common"
import regex_vm "core:text/regex/virtual_machine"
import "core:unicode/utf8"
import regex "core:text/regex"
import md5 "core:crypto/legacy/md5"
import sha1 "core:crypto/legacy/sha1"
import sha2 "core:crypto/sha2"
import rdf "odin-rdf:rdf"
import turtle "odin-rdf:rdf/turtle"
import algebra "../algebra"
import dataset "../dataset"

Error_Code :: enum {
	None,
	Invalid_Options,
	Unsupported_Plan,
	Dataset_Error,
	Service_Error,
	Cancelled,
	Solution_Limit,
	Numeric_Limit,
	Out_Of_Memory,
}

// Execution_Statistics accumulates optional, caller-owned execution counters.
// The evaluator never resets it, so one caller may measure a whole workload.
// Counts are diagnostic only and never affect query semantics or planning.
Execution_Statistics :: struct {
	Dataset_Scans:      u64,
	Dataset_Candidates: u64,
	BGP_Matches:        u64,
	BGP_Solutions:      u64,
	BGP_Reorders:       u64,
	Service_Calls:      u64,
}

// Options makes BGP materialization explicitly bounded. Max_Solutions must be
// positive; Stop_When_Full is for existence checks such as ASK.
Options :: struct {
	Max_Solutions:  int,
	Stop_When_Full: bool,
	// Optimize_BGP opts into a deterministic, constraint-only BGP order. The
	// default preserves source order; no storage-specific cardinality estimate
	// is inferred by the core.
	Optimize_BGP: bool,
	// Statistics may be nil. When present, it accumulates counters for this and
	// any nested evaluation performed through these options.
	Statistics: ^Execution_Statistics,
	// Max_Numeric_Digits bounds a single exact numeric intermediate or result.
	// It is required by binary exact arithmetic; 0 remains valid for plans that
	// do not evaluate such an expression.
	Max_Numeric_Digits: int,
	// Decimal_Division_Precision is the number of significant decimal digits
	// retained for a non-terminating integer/decimal division. Zero selects the
	// stable default (34); Max_Numeric_Digits remains a resource limit, not a
	// semantic precision setting.
	Decimal_Division_Precision: int,
	// Dataset_View is set internally by evaluate and makes correlated expression
	// evaluation independent of the surrounding relation operator.
	Dataset_View: dataset.View,
	// expression_scope is set internally for each operator evaluation. EXISTS
	// and NOT EXISTS reuse it so nested patterns retain the active GRAPH scope.
	expression_scope: ^Graph_Scope,
	// Now_Lexical optionally fixes NOW() for one evaluation. It must be a valid
	// xsd:dateTime lexical form. An empty value captures the UTC system clock
	// once when evaluate begins.
	Now_Lexical: string,
	// UUID_Callback optionally supplies query-local UUID identities. The
	// evaluator requires a fresh identifier for every UUID()/STRUUID() call;
	// returning ok=false or failing to advance yields an expression error.
	// A nil callback uses a cryptographically secure UUID v4 source.
	UUID_Callback: UUID_Callback,
	UUID_Data:     rawptr,
	// RAND_Callback optionally supplies one random double per RAND() call. It
	// must return a finite value in [0, 1); nil uses cryptographic entropy.
	RAND_Callback: RAND_Callback,
	RAND_Data:     rawptr,
	Service_Callback: Service_Callback,
	Service_Data:     rawptr,
	// Cancellation_Callback is polled at evaluator/operator and dataset-scan
	// boundaries. The first true return is latched for the full top-level
	// evaluation, so a one-shot request cannot be mistaken for an expression
	// error in a nested operation. It is never a successful scan stop. The
	// callback must be non-blocking.
	Cancellation_Callback: Cancellation_Callback,
	Cancellation_Data:     rawptr,
	cancellation_state:    ^Cancellation_State,
	// bnode_context is initialized per top-level evaluation. It is private so
	// callers cannot share fresh BNODE identities across queries.
	bnode_context: ^Blank_Node_Context,
	uuid_context:  ^UUID_Context,
}

// Service_Callback maps a SERVICE endpoint IRI to an application-owned
// dataset view. It is the evaluator's only federation boundary: callers own
// transport, authentication, caching, and returned-view lifetime. Returning
// ok=false makes the endpoint unavailable; SERVICE SILENT preserves its input.
Service_Callback :: #type proc(endpoint: rdf.Term, user_data: rawptr) -> (view: dataset.View, ok: bool)

// Cancellation_Callback reports whether the caller wants the current execute
// call to stop. It transfers no ownership and may be backed by a deadline,
// request context, or application synchronization primitive.
Cancellation_Callback :: #type proc(user_data: rawptr) -> bool

// Cancellation_State is private per top-level evaluate call. Nested Options
// copies share it so cancellation has monotonic, execution-wide semantics.
@(private) Cancellation_State :: struct { requested: bool }

// UUID_Callback supplies a UUID identifier without transferring ownership.
// It is chiefly useful for deterministic tests and replayable applications.
UUID_Callback :: #type proc(user_data: rawptr) -> (identifier: uuid.Identifier, ok: bool)

// RAND_Callback supplies a random double without transferring ownership.
// It is the deterministic execution boundary for RAND().
RAND_Callback :: #type proc(user_data: rawptr) -> (value: f64, ok: bool)

@(private) Binding :: struct {
	values: [dynamic]rdf.Term,
	bound:  [dynamic]bool,
}

// Blank_Node_Context tracks nodes manufactured by BNODE during one query
// evaluation. String arguments are scoped to a single input solution mapping;
// zero-argument calls deliberately bypass this map and are always fresh.
@(private) Blank_Node_Context :: struct {
	scope:  rdf.Blank_Node_Scope,
	next:   int,
	keys:   [dynamic]string,
	nodes:  [dynamic]rdf.Term,
	owned:  [dynamic]string,
}

// UUID_Context makes freshness an execution invariant rather than trusting a
// caller-provided deterministic source to remember it.
@(private) UUID_Context :: struct {
	issued: [dynamic]uuid.Identifier,
}

@(private) destroy_uuid_context :: proc(ctx: ^UUID_Context) {
	delete(ctx.issued)
	ctx^ = {}
}

@(private) destroy_blank_node_context :: proc(ctx: ^Blank_Node_Context) {
	for value in ctx.owned do delete(value)
	for key in ctx.keys do delete(key)
	delete(ctx.owned)
	delete(ctx.keys)
	delete(ctx.nodes)
	ctx^ = {}
}

@(private) Solution :: struct {
	values: [dynamic]rdf.Term,
	bound:  [dynamic]bool,
}

// Result owns solution term strings and variable names. It remains valid after
// the Plan and Dataset used for evaluation are destroyed.
Result :: struct {
	variables: [dynamic]string,
	solutions: [dynamic]Solution,
	owned:     [dynamic]string,
}

error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:            return "no error"
	case .Invalid_Options: return "max_solutions must be positive"
	case .Unsupported_Plan:return "algebra operator is not implemented by this evaluator"
	case .Dataset_Error:   return "dataset scan failed"
	case .Service_Error:   return "service callback could not provide a queryable dataset"
	case .Cancelled:       return "query execution was cancelled"
	case .Solution_Limit:  return "solution limit reached"
	case .Numeric_Limit:   return "numeric intermediate digit limit reached"
	case .Out_Of_Memory:   return "memory allocation failed"
	}
	return "unknown evaluation error"
}

// Cancellation_Requested is exposed so engine-level materialization can use
// the same callback boundary as evaluator operators.
Cancellation_Requested :: proc(options: Options) -> bool {
	if options.cancellation_state != nil && options.cancellation_state.requested do return true
	if options.Cancellation_Callback == nil || !options.Cancellation_Callback(options.Cancellation_Data) do return false
	if options.cancellation_state != nil do options.cancellation_state.requested = true
	return true
}

destroy :: proc(result: ^Result) {
	for value in result.owned do delete(value)
	delete(result.owned)
	delete(result.variables)
	for solution in result.solutions {
		delete(solution.values)
		delete(solution.bound)
	}
	delete(result.solutions)
	result^ = {}
}

Variable_Count :: proc(result: ^Result) -> int { return len(result.variables) }
Solution_Count :: proc(result: ^Result) -> int { return len(result.solutions) }

Variable_Name :: proc(result: ^Result, index: int) -> (string, bool) {
	if index < 0 || index >= len(result.variables) do return "", false
	return result.variables[index], true
}

// Solution_Binding returns one solution cell. Bound false means the variable is unbound
// and the returned RDF term must be ignored.
Solution_Binding :: proc(result: ^Result, solution, variable: int) -> (term: rdf.Term, bound: bool, ok: bool) {
	if solution < 0 || solution >= len(result.solutions) || variable < 0 || variable >= len(result.variables) do return {}, false, false
	value := result.solutions[solution]
	return value.values[variable], value.bound[variable], true
}

@(private) result_own :: proc(result: ^Result, value: string) -> (string, Error_Code) {
	if len(value) == 0 do return "", .None
	cloned, clone_error := strings.clone(value)
	if clone_error != nil do return "", .Out_Of_Memory
	_, append_error := append(&result.owned, cloned)
	if append_error != nil {
		delete(cloned)
		return "", .Out_Of_Memory
	}
	return cloned, .None
}

@(private) discard_owned_from :: proc(result: ^Result, start: int) {
	for index in start..<len(result.owned) do delete(result.owned[index])
	resize(&result.owned, start)
}

@(private) copy_term :: proc(result: ^Result, value: rdf.Term) -> (rdf.Term, Error_Code) {
	copy := value
	error: Error_Code
	copy.value, error = result_own(result, value.value)
	if error != .None do return {}, error
	copy.language, error = result_own(result, value.language)
	if error != .None do return {}, error
	copy.datatype, error = result_own(result, value.datatype)
	if error != .None do return {}, error
	return copy, .None
}

@(private) init_result :: proc(result: ^Result, plan: ^algebra.Plan) -> Error_Code {
	result^ = Result{variables = make([dynamic]string), solutions = make([dynamic]Solution), owned = make([dynamic]string)}
	for index in 0..<algebra.Variable_Count(plan) {
		name, ok := algebra.Variable_Name(plan, index)
		if !ok do return .Out_Of_Memory
		owned, error := result_own(result, name)
		if error != .None do return error
		if _, append_error := append(&result.variables, owned); append_error != nil do return .Out_Of_Memory
	}
	return .None
}

@(private) equal_term :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value && ascii_equal_fold(left.language, right.language) && left.datatype == right.datatype && left.scope == right.scope
}

@(private) init_binding :: proc(variable_count: int) -> (Binding, Error_Code) {
	result := Binding{values = make([dynamic]rdf.Term), bound = make([dynamic]bool)}
	for _ in 0..<variable_count {
		if _, error := append(&result.values, rdf.Term{}); error != nil { delete(result.values); delete(result.bound); return {}, .Out_Of_Memory }
		if _, error := append(&result.bound, false); error != nil { delete(result.values); delete(result.bound); return {}, .Out_Of_Memory }
	}
	return result, .None
}

@(private) destroy_binding :: proc(binding: ^Binding) {
	delete(binding.values)
	delete(binding.bound)
	binding^ = {}
}

@(private) clone_binding :: proc(value: Binding) -> (Binding, Error_Code) {
	result, init_error := init_binding(len(value.values))
	if init_error != .None do return {}, init_error
	for index in 0..<len(value.values) {
		result.values[index] = value.values[index]
		result.bound[index] = value.bound[index]
	}
	return result, .None
}

@(private) append_solution :: proc(result: ^Result, binding: Binding, maximum: int) -> Error_Code {
	if len(result.solutions) >= maximum do return .Solution_Limit
	solution := Solution{values = make([dynamic]rdf.Term), bound = make([dynamic]bool)}
	owned_start := len(result.owned)
	for index in 0..<len(binding.values) {
		value: rdf.Term
		if binding.bound[index] {
			copy_error: Error_Code
			value, copy_error = copy_term(result, binding.values[index])
			if copy_error != .None {
				delete(solution.values)
				delete(solution.bound)
				discard_owned_from(result, owned_start)
				return copy_error
			}
		}
		if _, error := append(&solution.values, value); error != nil { delete(solution.values); delete(solution.bound); discard_owned_from(result, owned_start); return .Out_Of_Memory }
		if _, error := append(&solution.bound, binding.bound[index]); error != nil { delete(solution.values); delete(solution.bound); discard_owned_from(result, owned_start); return .Out_Of_Memory }
	}
	if _, error := append(&result.solutions, solution); error != nil {
		delete(solution.values)
		delete(solution.bound)
		discard_owned_from(result, owned_start)
		return .Out_Of_Memory
	}
	return .None
}

@(private) binding_from_solution :: proc(result: ^Result, index: int) -> (Binding, bool) {
	if index < 0 || index >= len(result.solutions) do return {}, false
	solution := result.solutions[index]
	return Binding{values = solution.values, bound = solution.bound}, true
}

@(private) compatible :: proc(left, right: Binding) -> bool {
	if len(left.values) != len(right.values) do return false
	for index in 0..<len(left.values) {
		if left.bound[index] && right.bound[index] && !equal_term(left.values[index], right.values[index]) do return false
	}
	return true
}

@(private) has_shared_bound_variable :: proc(left, right: Binding) -> bool {
	if len(left.values) != len(right.values) do return false
	for index in 0..<len(left.values) do if left.bound[index] && right.bound[index] do return true
	return false
}

@(private) merge_bindings :: proc(left, right: Binding) -> (Binding, Error_Code) {
	if !compatible(left, right) do return {}, .Unsupported_Plan
	result, init_error := clone_binding(left)
	if init_error != .None do return {}, init_error
	for index in 0..<len(result.values) {
		if !result.bound[index] && right.bound[index] {
			result.values[index] = right.values[index]
			result.bound[index] = true
		}
	}
	return result, .None
}

@(private) identity_relation :: proc(plan: ^algebra.Plan, maximum: int) -> (Result, Error_Code) {
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	binding, binding_error := init_binding(algebra.Variable_Count(plan))
	if binding_error != .None { destroy(&result); return {}, binding_error }
	defer destroy_binding(&binding)
	if error := append_solution(&result, binding, maximum); error != .None { destroy(&result); return {}, error }
	return result, .None
}

@(private) values_relation :: proc(plan: ^algebra.Plan, operator: int, options: Options) -> (Result, Error_Code) {
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok || node.Kind != .Values do return {}, .Unsupported_Plan
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for row in 0..<node.Values_Row_Count {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		binding, binding_error := init_binding(algebra.Variable_Count(plan))
		if binding_error != .None { destroy(&result); return {}, binding_error }
		valid := true
		for column in 0..<node.Values_Variable_Count {
			variable, variable_ok := algebra.Values_Variable(plan, operator, column)
			slot, unbound, cell_ok := algebra.Values_Cell(plan, operator, row, column)
			if !variable_ok || !cell_ok || variable < 0 || variable >= len(binding.values) { destroy_binding(&binding); destroy(&result); return {}, .Unsupported_Plan }
			if unbound do continue
			if slot.Kind != .Term { destroy_binding(&binding); destroy(&result); return {}, .Unsupported_Plan }
			if binding.bound[variable] && !equal_term(binding.values[variable], slot.Term) {
				valid = false
				break
			}
			binding.values[variable] = slot.Term
			binding.bound[variable] = true
		}
		if valid {
			if error := append_solution(&result, binding, options.Max_Solutions); error != .None { destroy_binding(&binding); destroy(&result); return {}, error }
		}
		destroy_binding(&binding)
	}
	return result, .None
}

@(private) concatenate_relations :: proc(plan: ^algebra.Plan, left, right: ^Result, options: Options) -> (Result, Error_Code) {
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for source_index in 0..<2 {
		source := left
		if source_index == 1 do source = right
		for index in 0..<Solution_Count(source) {
			if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
			binding, ok := binding_from_solution(source, index)
			if !ok { destroy(&result); return {}, .Unsupported_Plan }
			if error := append_solution(&result, binding, options.Max_Solutions); error != .None { destroy(&result); return {}, error }
		}
	}
	return result, .None
}

@(private) join_relations :: proc(plan: ^algebra.Plan, left, right: ^Result, options: Options, optional, minus: bool) -> (Result, Error_Code) {
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for left_index in 0..<Solution_Count(left) {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		left_binding, left_ok := binding_from_solution(left, left_index)
		if !left_ok { destroy(&result); return {}, .Unsupported_Plan }
		matched := false
		for right_index in 0..<Solution_Count(right) {
			if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
			right_binding, right_ok := binding_from_solution(right, right_index)
			if !right_ok { destroy(&result); return {}, .Unsupported_Plan }
			if !compatible(left_binding, right_binding) do continue
			if minus {
				if has_shared_bound_variable(left_binding, right_binding) { matched = true; break }
				continue
			}
			merged, merge_error := merge_bindings(left_binding, right_binding)
			if merge_error != .None { destroy(&result); return {}, merge_error }
			if error := append_solution(&result, merged, options.Max_Solutions); error != .None { destroy_binding(&merged); destroy(&result); return {}, error }
			destroy_binding(&merged)
			matched = true
		}
		if (optional && !matched) || (minus && !matched) {
			if error := append_solution(&result, left_binding, options.Max_Solutions); error != .None { destroy(&result); return {}, error }
		}
	}
	return result, .None
}

@(private) State :: struct {
	plan:     ^algebra.Plan,
	view:     dataset.View,
	options:  Options,
	result:   ^Result,
	error:    Error_Code,
	stopped:  bool,
	first_triple: int,
	triple_count: int,
	bind_graph: bool,
	graph_slot: algebra.Slot_View,
	graph_mode: dataset.Graph_Mode,
	graph:      rdf.Term,
}

@(private) Scan_State :: struct {
	state:       ^State,
	triple:      algebra.Triple_Pattern_View,
	next_index:  int,
	binding:     ^Binding,
}

@(private) match_slot :: proc(slot: algebra.Slot_View, value: rdf.Term, binding: ^Binding) -> bool {
	if slot.Kind == .Term do return equal_term(slot.Term, value)
	if slot.Variable < 0 || slot.Variable >= len(binding.values) do return false
	if binding.bound[slot.Variable] do return equal_term(binding.values[slot.Variable], value)
	binding.values[slot.Variable] = value
	binding.bound[slot.Variable] = true
	return true
}

@(private) scan_sink :: proc(quad: rdf.Quad, data: rawptr) -> bool {
	scan := cast(^Scan_State)data
	state := scan.state
	if state.error != .None || state.stopped do return false
	if Cancellation_Requested(state.options) { state.error = .Cancelled; state.stopped = true; return false }
	if state.options.Statistics != nil do state.options.Statistics.Dataset_Candidates += 1
	next, clone_error := clone_binding(scan.binding^)
	if clone_error != .None { state.error = clone_error; return false }
	defer destroy_binding(&next)
	if !match_slot(scan.triple.Subject, quad.subject, &next) || !match_slot(scan.triple.Predicate, quad.predicate, &next) || !match_slot(scan.triple.Object, quad.object, &next) do return true
	if state.bind_graph && !match_slot(state.graph_slot, quad.graph, &next) do return true
	if state.options.Statistics != nil do state.options.Statistics.BGP_Matches += 1
	evaluate_from(state, &next, scan.next_index)
	return state.error == .None && !state.stopped
}

@(private) slot_pattern :: proc(slot: algebra.Slot_View, binding: Binding, has: ^bool, term: ^rdf.Term) {
	if slot.Kind == .Term {
		has^ = true
		term^ = slot.Term
		return
	}
	if slot.Variable >= 0 && slot.Variable < len(binding.values) && binding.bound[slot.Variable] {
		has^ = true
		term^ = binding.values[slot.Variable]
	}
}

@(private) evaluate_from :: proc(state: ^State, binding: ^Binding, triple_index: int) {
	if state.error != .None || state.stopped do return
	if Cancellation_Requested(state.options) { state.error = .Cancelled; state.stopped = true; return }
	if triple_index >= state.triple_count {
		state.error = append_solution(state.result, binding^, state.options.Max_Solutions)
		if state.error != .None {
			state.stopped = true
		} else {
			if state.options.Statistics != nil do state.options.Statistics.BGP_Solutions += 1
			if state.options.Stop_When_Full && Solution_Count(state.result) >= state.options.Max_Solutions do state.stopped = true
		}
		return
	}
	resolved_triple_index := state.first_triple + triple_index
	if state.options.Optimize_BGP && state.triple_count > 1 {
		order, reordered, order_error := build_bgp_order(state.plan, state.first_triple, state.triple_count)
		if order_error != .None {
			delete(order)
			state.error = order_error
			state.stopped = true
			return
		}
		if reordered {
			if triple_index >= len(order) {
				delete(order)
				state.error = .Unsupported_Plan
				state.stopped = true
				return
			}
			resolved_triple_index = order[triple_index]
		}
		delete(order)
	}
	triple, triple_ok := algebra.Triple(state.plan, resolved_triple_index)
	if !triple_ok { state.error = .Unsupported_Plan; state.stopped = true; return }
	pattern: dataset.Quad_Pattern
	pattern.Graph_Mode = state.graph_mode
	if state.graph_mode == .Named do pattern.Graph = state.graph
	slot_pattern(triple.Subject, binding^, &pattern.Has_Subject, &pattern.Subject)
	slot_pattern(triple.Predicate, binding^, &pattern.Has_Predicate, &pattern.Predicate)
	slot_pattern(triple.Object, binding^, &pattern.Has_Object, &pattern.Object)
	scan := Scan_State{state = state, triple = triple, next_index = triple_index + 1, binding = binding}
	if state.options.Statistics != nil do state.options.Statistics.Dataset_Scans += 1
	if dataset_error := dataset.scan(state.view, pattern, scan_sink, &scan); dataset_error != .None && state.error == .None {
		state.error = .Dataset_Error
		state.stopped = true
	}
}

@(private) triple_contains_variable :: proc(triple: algebra.Triple_Pattern_View, variable: int) -> bool {
	return (triple.Subject.Kind == .Variable && triple.Subject.Variable == variable) ||
		(triple.Predicate.Kind == .Variable && triple.Predicate.Variable == variable) ||
		(triple.Object.Kind == .Variable && triple.Object.Variable == variable)
}

@(private) slot_constraint_score :: proc(plan: ^algebra.Plan, first_triple, triple_count: int, slot: algebra.Slot_View) -> int {
	if slot.Kind == .Term do return 16
	if slot.Variable < 0 do return 0
	occurrences := 0
	for index in first_triple..<(first_triple + triple_count) {
		triple, triple_ok := algebra.Triple(plan, index)
		if triple_ok && triple_contains_variable(triple, slot.Variable) do occurrences += 1
	}
	return occurrences * 2
}

@(private) triple_constraint_score :: proc(plan: ^algebra.Plan, first_triple, triple_count, index: int) -> int {
	triple, triple_ok := algebra.Triple(plan, index)
	if !triple_ok do return -1
	return slot_constraint_score(plan, first_triple, triple_count, triple.Subject) +
		slot_constraint_score(plan, first_triple, triple_count, triple.Predicate) +
		slot_constraint_score(plan, first_triple, triple_count, triple.Object)
}

@(private) order_contains :: proc(order: []int, value: int) -> bool {
	for known in order do if known == value do return true
	return false
}

// build_bgp_order is deliberately independent of Dataset internals. It only
// prefers fixed terms and variables shared by more patterns; source position
// breaks ties, keeping the order deterministic across providers.
@(private) build_bgp_order :: proc(plan: ^algebra.Plan, first_triple, triple_count: int) -> (order: [dynamic]int, reordered: bool, error: Error_Code) {
	order = make([dynamic]int)
	for _ in 0..<triple_count {
		best := -1
		best_score := -1
		for candidate in first_triple..<(first_triple + triple_count) {
			if order_contains(order[:], candidate) do continue
			score := triple_constraint_score(plan, first_triple, triple_count, candidate)
			if score > best_score {
				best = candidate
				best_score = score
			}
		}
		if best < 0 { delete(order); return {}, false, .Unsupported_Plan }
		if _, append_error := append(&order, best); append_error != nil { delete(order); return {}, false, .Out_Of_Memory }
	}
	for offset in 0..<triple_count {
		if order[offset] != first_triple + offset do return order, true, .None
	}
	delete(order)
	return {}, false, .None
}

// evaluate_bgp can begin from a caller-owned seed binding. This is the
// correlation boundary used by future EXISTS/NOT EXISTS and subquery
// evaluation; BGP matching only extends compatible bindings and never mutates
// the seed itself.
@(private) evaluate_bgp :: proc(plan: ^algebra.Plan, first_triple, triple_count: int, view: dataset.View, options: Options, graph_mode: dataset.Graph_Mode = .Default, graph: rdf.Term = {}, graph_slot: algebra.Slot_View = {}, bind_graph: bool = false, seed: ^Binding = nil) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	if Cancellation_Requested(options) do return {}, .Cancelled
	if first_triple < 0 || triple_count < 0 || first_triple + triple_count > algebra.Triple_Count(plan) do return {}, .Unsupported_Plan
	result: Result
	if init_error := init_result(&result, plan); init_error != .None { destroy(&result); return {}, init_error }
	binding: Binding
	binding_error: Error_Code
	if seed != nil {
		if len(seed.values) != algebra.Variable_Count(plan) { destroy(&result); return {}, .Unsupported_Plan }
		binding, binding_error = clone_binding(seed^)
	} else {
		binding, binding_error = init_binding(algebra.Variable_Count(plan))
	}
	if binding_error != .None { destroy(&result); return {}, binding_error }
	defer destroy_binding(&binding)
	state := State{plan = plan, view = view, options = options, result = &result, first_triple = first_triple, triple_count = triple_count, graph_mode = graph_mode, graph = graph, graph_slot = graph_slot, bind_graph = bind_graph}
	if options.Optimize_BGP && triple_count > 1 {
		triple_order, reordered, order_error := build_bgp_order(plan, first_triple, triple_count)
		if order_error != .None { destroy(&result); return {}, order_error }
		defer delete(triple_order)
		if reordered && options.Statistics != nil do options.Statistics.BGP_Reorders += 1
	}
	evaluate_from(&state, &binding, 0)
	if state.error != .None {
		destroy(&result)
		return {}, state.error
	}
	return result, .None
}

@(private) Graph_Scope :: struct {
	mode:       dataset.Graph_Mode,
	graph:      rdf.Term,
	graph_slot: algebra.Slot_View,
	bind_graph: bool,
}

@(private) Path_Edge :: struct {
	subject:   rdf.Term,
	predicate: rdf.Term,
	object:    rdf.Term,
	graph:     rdf.Term,
}

@(private) Path_Scan :: struct {
	edges:   [dynamic]Path_Edge,
	error:   Error_Code,
	options: Options,
}

@(private) path_scan_sink :: proc(quad: rdf.Quad, data: rawptr) -> bool {
	scan := cast(^Path_Scan)data
	if Cancellation_Requested(scan.options) {
		scan.error = .Cancelled
		return false
	}
	if _, append_error := append(&scan.edges, Path_Edge{subject = quad.subject, predicate = quad.predicate, object = quad.object, graph = quad.graph}); append_error != nil {
		scan.error = .Out_Of_Memory
		return false
	}
	return true
}

@(private) append_unique_path_term :: proc(values: ^[dynamic]rdf.Term, value: rdf.Term) -> Error_Code {
	for known in values^ do if equal_term(known, value) do return .None
	if _, append_error := append(values, value); append_error != nil do return .Out_Of_Memory
	return .None
}

@(private) slot_value :: proc(slot: algebra.Slot_View, binding: Binding) -> (rdf.Term, bool) {
	if slot.Kind == .Term do return slot.Term, true
	if slot.Variable < 0 || slot.Variable >= len(binding.values) || !binding.bound[slot.Variable] do return {}, false
	return binding.values[slot.Variable], true
}

@(private) path_predicate_is_excluded :: proc(plan: ^algebra.Plan, path: int, predicate: rdf.Term, inverse: bool) -> (bool, Error_Code) {
	node, node_ok := algebra.Property_Path_At(plan, path)
	if !node_ok do return false, .Unsupported_Plan
	for index in 0..<node.Negated_Term_Count {
		term, term_inverse, term_ok := algebra.Property_Path_Negated_Term(plan, path, index)
		if !term_ok || term.Kind != .Term do return false, .Unsupported_Plan
		if term_inverse == inverse && equal_term(term.Term, predicate) do return true, .None
	}
	return false, .None
}

@(private) path_allows_orientation :: proc(plan: ^algebra.Plan, path: int, inverse: bool) -> (bool, Error_Code) {
	node, node_ok := algebra.Property_Path_At(plan, path)
	if !node_ok do return false, .Unsupported_Plan
	for index in 0..<node.Negated_Term_Count {
		_, term_inverse, term_ok := algebra.Property_Path_Negated_Term(plan, path, index)
		if !term_ok do return false, .Unsupported_Plan
		if term_inverse == inverse do return true, .None
	}
	return false, .None
}

// walk_path evaluates one path node from a fixed start term within one graph.
// Alternative and sequence preserve path multiplicity; the repeat operators
// suppress duplicate endpoints to terminate correctly on cyclic graphs.
@(private) walk_path :: proc(plan: ^algebra.Plan, path: int, start: rdf.Term, edges: []Path_Edge, options: Options, inverse: bool = false) -> ([dynamic]rdf.Term, Error_Code) {
	result := make([dynamic]rdf.Term)
	if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
	node, node_ok := algebra.Property_Path_At(plan, path)
	if !node_ok do return result, .Unsupported_Plan
	if node.Kind == .Term {
		if node.Term.Kind != .Term { delete(result); return {}, .Unsupported_Plan }
		for edge in edges {
			if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
			if !equal_term(edge.predicate, node.Term.Term) do continue
			if !inverse && equal_term(edge.subject, start) {
				if error := append_unique_path_term(&result, edge.object); error != .None { delete(result); return {}, error }
			} else if inverse && equal_term(edge.object, start) {
				if error := append_unique_path_term(&result, edge.subject); error != .None { delete(result); return {}, error }
			}
		}
		return result, .None
	}
	if node.Kind == .Inverse {
		child, child_ok := algebra.Property_Path_Child(plan, path, 0)
		if !child_ok { delete(result); return {}, .Unsupported_Plan }
		delete(result)
		return walk_path(plan, child, start, edges, options, !inverse)
	}
	if node.Kind == .Alternative {
		for index in 0..<node.Child_Count {
			if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
			child, child_ok := algebra.Property_Path_Child(plan, path, index)
			if !child_ok { delete(result); return {}, .Unsupported_Plan }
			values, walk_error := walk_path(plan, child, start, edges, options, inverse)
			if walk_error != .None { delete(values); delete(result); return {}, walk_error }
			for value in values {
				if _, append_error := append(&result, value); append_error != nil { delete(values); delete(result); return {}, .Out_Of_Memory }
			}
			delete(values)
		}
		return result, .None
	}
	if node.Kind == .Sequence {
		frontier := make([dynamic]rdf.Term)
		if error := append_unique_path_term(&frontier, start); error != .None { delete(result); return {}, error }
		for offset in 0..<node.Child_Count {
			if Cancellation_Requested(options) { delete(frontier); delete(result); return {}, .Cancelled }
			child_index := offset
			if inverse do child_index = node.Child_Count - 1 - offset
			child, child_ok := algebra.Property_Path_Child(plan, path, child_index)
			if !child_ok { delete(frontier); delete(result); return {}, .Unsupported_Plan }
			next := make([dynamic]rdf.Term)
			for value in frontier {
				if Cancellation_Requested(options) { delete(next); delete(frontier); delete(result); return {}, .Cancelled }
				walked, walk_error := walk_path(plan, child, value, edges, options, inverse)
				if walk_error != .None { delete(walked); delete(next); delete(frontier); delete(result); return {}, walk_error }
				for endpoint in walked {
					if _, append_error := append(&next, endpoint); append_error != nil { delete(walked); delete(next); delete(frontier); delete(result); return {}, .Out_Of_Memory }
				}
				delete(walked)
			}
			delete(frontier)
			frontier = next
		}
		return frontier, .None
	}
	if node.Kind == .Zero_Or_One || node.Kind == .Zero_Or_More || node.Kind == .One_Or_More {
		child, child_ok := algebra.Property_Path_Child(plan, path, 0)
		if !child_ok { delete(result); return {}, .Unsupported_Plan }
		if node.Kind != .One_Or_More {
			if error := append_unique_path_term(&result, start); error != .None { delete(result); return {}, error }
		}
		initial, initial_error := walk_path(plan, child, start, edges, options, inverse)
		if initial_error != .None { delete(initial); delete(result); return {}, initial_error }
		if node.Kind == .Zero_Or_One {
			for value in initial {
				if error := append_unique_path_term(&result, value); error != .None { delete(initial); delete(result); return {}, error }
			}
			delete(initial)
			return result, .None
		}
		queue := make([dynamic]rdf.Term)
		defer delete(queue)
		for value in initial {
			if error := append_unique_path_term(&result, value); error != .None { delete(initial); delete(result); return {}, error }
			if _, append_error := append(&queue, value); append_error != nil { delete(initial); delete(result); return {}, .Out_Of_Memory }
		}
		delete(initial)
		for cursor := 0; cursor < len(queue); cursor += 1 {
			if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
			next, next_error := walk_path(plan, child, queue[cursor], edges, options, inverse)
			if next_error != .None { delete(next); delete(result); return {}, next_error }
			for value in next {
				known := false
				for prior in result do if equal_term(prior, value) { known = true; break }
				if known do continue
				if error := append_unique_path_term(&result, value); error != .None { delete(next); delete(result); return {}, error }
				if _, append_error := append(&queue, value); append_error != nil { delete(next); delete(result); return {}, .Out_Of_Memory }
			}
			delete(next)
		}
		return result, .None
	}
	if node.Kind == .Bounded {
		if node.Minimum < 0 || (node.Has_Maximum && node.Maximum < node.Minimum) do return result, .Unsupported_Plan
		child, child_ok := algebra.Property_Path_Child(plan, path, 0)
		if !child_ok { delete(result); return {}, .Unsupported_Plan }
		frontier := make([dynamic]rdf.Term)
		if error := append_unique_path_term(&frontier, start); error != .None { delete(frontier); delete(result); return {}, error }
		for _ in 0..<node.Minimum {
			next := make([dynamic]rdf.Term)
			for value in frontier {
				if Cancellation_Requested(options) { delete(next); delete(frontier); delete(result); return {}, .Cancelled }
				walked, walk_error := walk_path(plan, child, value, edges, options, inverse)
				if walk_error != .None { delete(walked); delete(next); delete(frontier); delete(result); return {}, walk_error }
				for endpoint in walked {
					if error := append_unique_path_term(&next, endpoint); error != .None { delete(walked); delete(next); delete(frontier); delete(result); return {}, error }
				}
				delete(walked)
			}
			delete(frontier)
			frontier = next
			if len(frontier) == 0 do return result, .None
		}
		for value in frontier {
			if error := append_unique_path_term(&result, value); error != .None { delete(frontier); delete(result); return {}, error }
		}
		if !node.Has_Maximum {
			queue := make([dynamic]rdf.Term)
			defer delete(queue)
			for value in frontier {
				if _, append_error := append(&queue, value); append_error != nil { delete(frontier); delete(result); return {}, .Out_Of_Memory }
			}
			delete(frontier)
			for cursor := 0; cursor < len(queue); cursor += 1 {
				if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
				next, next_error := walk_path(plan, child, queue[cursor], edges, options, inverse)
				if next_error != .None { delete(next); delete(result); return {}, next_error }
				for value in next {
					known := false
					for prior in result do if equal_term(prior, value) { known = true; break }
					if known do continue
					if error := append_unique_path_term(&result, value); error != .None { delete(next); delete(result); return {}, error }
					if _, append_error := append(&queue, value); append_error != nil { delete(next); delete(result); return {}, .Out_Of_Memory }
				}
				delete(next)
			}
			return result, .None
		}
		for _ in node.Minimum..<node.Maximum {
			next := make([dynamic]rdf.Term)
			for value in frontier {
				if Cancellation_Requested(options) { delete(next); delete(frontier); delete(result); return {}, .Cancelled }
				walked, walk_error := walk_path(plan, child, value, edges, options, inverse)
				if walk_error != .None { delete(walked); delete(next); delete(frontier); delete(result); return {}, walk_error }
				for endpoint in walked {
					if error := append_unique_path_term(&next, endpoint); error != .None { delete(walked); delete(next); delete(frontier); delete(result); return {}, error }
				}
				delete(walked)
			}
			delete(frontier)
			frontier = next
			if len(frontier) == 0 do break
			for value in frontier {
				if error := append_unique_path_term(&result, value); error != .None { delete(frontier); delete(result); return {}, error }
			}
		}
		delete(frontier)
		return result, .None
	}
	if node.Kind == .Negated_Set {
		allow_direct, direct_error := path_allows_orientation(plan, path, false)
		if direct_error != .None { delete(result); return {}, direct_error }
		allow_inverse, inverse_error := path_allows_orientation(plan, path, true)
		if inverse_error != .None { delete(result); return {}, inverse_error }
		for edge in edges {
			if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
			if !inverse {
				if allow_direct && equal_term(edge.subject, start) {
					excluded, excluded_error := path_predicate_is_excluded(plan, path, edge.predicate, false)
					if excluded_error != .None { delete(result); return {}, excluded_error }
					if !excluded { if error := append_unique_path_term(&result, edge.object); error != .None { delete(result); return {}, error } }
				}
				if allow_inverse && equal_term(edge.object, start) {
					excluded, excluded_error := path_predicate_is_excluded(plan, path, edge.predicate, true)
					if excluded_error != .None { delete(result); return {}, excluded_error }
					if !excluded { if error := append_unique_path_term(&result, edge.subject); error != .None { delete(result); return {}, error } }
				}
			} else {
				if allow_direct && equal_term(edge.object, start) {
					excluded, excluded_error := path_predicate_is_excluded(plan, path, edge.predicate, false)
					if excluded_error != .None { delete(result); return {}, excluded_error }
					if !excluded { if error := append_unique_path_term(&result, edge.subject); error != .None { delete(result); return {}, error } }
				}
				if allow_inverse && equal_term(edge.subject, start) {
					excluded, excluded_error := path_predicate_is_excluded(plan, path, edge.predicate, true)
					if excluded_error != .None { delete(result); return {}, excluded_error }
					if !excluded { if error := append_unique_path_term(&result, edge.object); error != .None { delete(result); return {}, error } }
				}
			}
		}
		return result, .None
	}
	delete(result)
	return {}, .Unsupported_Plan
}

@(private) scan_path_edges :: proc(view: dataset.View, scope: Graph_Scope, seed: ^Binding, options: Options) -> ([dynamic]Path_Edge, Error_Code) {
	if Cancellation_Requested(options) do return {}, .Cancelled
	pattern := dataset.Quad_Pattern{Graph_Mode = scope.mode}
	if scope.mode == .Named {
		pattern.Graph = scope.graph
	} else if scope.mode == .Any_Named && scope.bind_graph {
		bound_graph, bound := slot_value(scope.graph_slot, seed^)
		if bound {
			pattern.Graph_Mode = .Named
			pattern.Graph = bound_graph
		}
	}
	scan := Path_Scan{edges = make([dynamic]Path_Edge), options = options}
	if dataset_error := dataset.scan(view, pattern, path_scan_sink, &scan); dataset_error != .None {
		delete(scan.edges)
		return {}, .Dataset_Error
	}
	if scan.error != .None {
		delete(scan.edges)
		return {}, scan.error
	}
	return scan.edges, .None
}

@(private) graph_edges :: proc(edges: []Path_Edge, graph: rdf.Term, named: bool, options: Options) -> ([dynamic]Path_Edge, Error_Code) {
	result := make([dynamic]Path_Edge)
	for edge in edges {
		if Cancellation_Requested(options) { delete(result); return {}, .Cancelled }
		if named && !equal_term(edge.graph, graph) do continue
		if _, append_error := append(&result, edge); append_error != nil { delete(result); return {}, .Out_Of_Memory }
	}
	return result, .None
}

@(private) path_universe :: proc(edges: []Path_Edge, options: Options) -> ([dynamic]rdf.Term, Error_Code) {
	terms := make([dynamic]rdf.Term)
	for edge in edges {
		if Cancellation_Requested(options) { delete(terms); return {}, .Cancelled }
		if error := append_unique_path_term(&terms, edge.subject); error != .None { delete(terms); return {}, error }
		if error := append_unique_path_term(&terms, edge.object); error != .None { delete(terms); return {}, error }
	}
	return terms, .None
}

@(private) append_path_pair :: proc(result: ^Result, pattern: algebra.Property_Path_Pattern_View, source, target: rdf.Term, graph: rdf.Term, bind_graph: bool, graph_slot: algebra.Slot_View, seed: ^Binding, options: Options) -> Error_Code {
	binding, binding_error := clone_binding(seed^)
	if binding_error != .None do return binding_error
	defer destroy_binding(&binding)
	if !match_slot(pattern.Subject, source, &binding) || !match_slot(pattern.Object, target, &binding) do return .None
	if bind_graph && !match_slot(graph_slot, graph, &binding) do return .None
	if error := append_solution(result, binding, options.Max_Solutions); error != .None {
		if options.Stop_When_Full && error == .Solution_Limit do return .None
		return error
	}
	return .None
}

@(private) evaluate_path_graph :: proc(plan: ^algebra.Plan, pattern: algebra.Property_Path_Pattern_View, edges: []Path_Edge, graph: rdf.Term, bind_graph: bool, graph_slot: algebra.Slot_View, seed: ^Binding, result: ^Result, options: Options) -> Error_Code {
	source, source_bound := slot_value(pattern.Subject, seed^)
	target, target_bound := slot_value(pattern.Object, seed^)
	starts := make([dynamic]rdf.Term)
	defer delete(starts)
	if source_bound {
		if error := append_unique_path_term(&starts, source); error != .None do return error
	} else if target_bound {
		if error := append_unique_path_term(&starts, target); error != .None do return error
	} else {
		universe, universe_error := path_universe(edges, options)
		if universe_error != .None do return universe_error
		defer delete(universe)
		for value in universe {
			if Cancellation_Requested(options) do return .Cancelled
			if error := append_unique_path_term(&starts, value); error != .None do return error
		}
	}
	backwards := !source_bound && target_bound
	for start in starts {
		if Cancellation_Requested(options) do return .Cancelled
		endpoints, path_error := walk_path(plan, pattern.Path, start, edges, options, backwards)
		if path_error != .None { delete(endpoints); return path_error }
		for endpoint in endpoints {
			if Cancellation_Requested(options) { delete(endpoints); return .Cancelled }
			actual_source, actual_target := start, endpoint
			if backwards do actual_source, actual_target = endpoint, start
			if target_bound && !equal_term(actual_target, target) do continue
			if error := append_path_pair(result, pattern, actual_source, actual_target, graph, bind_graph, graph_slot, seed, options); error != .None { delete(endpoints); return error }
			if options.Stop_When_Full && Solution_Count(result) >= options.Max_Solutions { delete(endpoints); return .None }
		}
		delete(endpoints)
	}
	return .None
}

@(private) path_relation :: proc(plan: ^algebra.Plan, operator: int, view: dataset.View, options: Options, scope: Graph_Scope, seed: ^Binding = nil) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	pattern, pattern_ok := algebra.Property_Path_Pattern_At(plan, operator)
	if !pattern_ok do return {}, .Unsupported_Plan
	initial: Binding
	initial_error: Error_Code
	if seed != nil {
		if len(seed.values) != algebra.Variable_Count(plan) do return {}, .Unsupported_Plan
		initial, initial_error = clone_binding(seed^)
	} else {
		initial, initial_error = init_binding(algebra.Variable_Count(plan))
	}
	if initial_error != .None do return {}, initial_error
	defer destroy_binding(&initial)
	edges, scan_error := scan_path_edges(view, scope, &initial, options)
	if scan_error != .None do return {}, scan_error
	defer delete(edges)
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	if scope.mode != .Any_Named {
		if error := evaluate_path_graph(plan, pattern, edges[:], scope.graph, scope.bind_graph, scope.graph_slot, &initial, &result, options); error != .None { destroy(&result); return {}, error }
		return result, .None
	}
	graphs := make([dynamic]rdf.Term)
	defer delete(graphs)
	for edge in edges {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		if error := append_unique_path_term(&graphs, edge.graph); error != .None { destroy(&result); return {}, error }
	}
	for graph in graphs {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		members, members_error := graph_edges(edges[:], graph, true, options)
		if members_error != .None { destroy(&result); return {}, members_error }
		error := evaluate_path_graph(plan, pattern, members[:], graph, scope.bind_graph, scope.graph_slot, &initial, &result, options)
		delete(members)
		if error != .None { destroy(&result); return {}, error }
		if options.Stop_When_Full && Solution_Count(&result) >= options.Max_Solutions do break
	}
	return result, .None
}

@(private) Expression_State :: enum { Term, Unbound, Error, Cancelled, Numeric_Limit, Out_Of_Memory }

@(private) Expression_Result :: struct {
	state: Expression_State,
	term:  rdf.Term,
	owned: string,
}

// Generated expression terms own their lexical string until a caller either
// copies the term into a relation result or finishes consuming it.
@(private) destroy_expression_result :: proc(value: ^Expression_Result) {
	if len(value.owned) != 0 do delete(value.owned)
	value^ = {}
}

@(private) boolean_term :: proc(value: bool) -> rdf.Term {
	if value do return rdf.typed_literal("true", "http://www.w3.org/2001/XMLSchema#boolean")
	return rdf.typed_literal("false", "http://www.w3.org/2001/XMLSchema#boolean")
}

@(private) ascii_equal_fold :: proc(left, right: string) -> bool {
	if len(left) != len(right) do return false
	for index in 0..<len(left) {
		left_byte := left[index]
		right_byte := right[index]
		if left_byte >= 'A' && left_byte <= 'Z' do left_byte += 'a' - 'A'
		if right_byte >= 'A' && right_byte <= 'Z' do right_byte += 'a' - 'A'
		if left_byte != right_byte do return false
	}
	return true
}

@(private) language_range_matches :: proc(language, range: string) -> bool {
	if len(language) == 0 do return false
	if range == "*" do return true
	if len(language) < len(range) || !ascii_equal_fold(language[:len(range)], range) do return false
	return len(language) == len(range) || language[len(range)] == '-'
}

@(private) effective_boolean :: proc(value: rdf.Term) -> (bool, bool) {
	if value.kind != .Literal do return false, false
	if value.datatype == "http://www.w3.org/2001/XMLSchema#boolean" {
		if value.value == "true" || value.value == "1" do return true, true
		if value.value == "false" || value.value == "0" do return false, true
		return false, false
	}
	if value.datatype == "http://www.w3.org/2001/XMLSchema#string" || value.datatype == "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString" do return len(value.value) != 0, true
	if is_integer(value) || is_decimal(value) {
		comparison, comparison_ok := decimal_compare(value.value, "0", is_decimal(value), false)
		if !comparison_ok do return false, false
		return comparison != 0, true
	}
	if is_floating(value) {
		floating, floating_ok := floating_value(value)
		if !floating_ok do return false, false
		return floating != 0 && !math.is_nan(floating), true
	}
	return false, false
}

@(private) XSD_INTEGER :: "http://www.w3.org/2001/XMLSchema#integer"
@(private) XSD_DECIMAL :: "http://www.w3.org/2001/XMLSchema#decimal"
@(private) XSD_DOUBLE :: "http://www.w3.org/2001/XMLSchema#double"
@(private) XSD_FLOAT :: "http://www.w3.org/2001/XMLSchema#float"
@(private) XSD_BOOLEAN :: "http://www.w3.org/2001/XMLSchema#boolean"
@(private) XSD_STRING :: "http://www.w3.org/2001/XMLSchema#string"
@(private) XSD_DATE :: "http://www.w3.org/2001/XMLSchema#date"
@(private) XSD_DATE_TIME :: "http://www.w3.org/2001/XMLSchema#dateTime"
@(private) XSD_TIME :: "http://www.w3.org/2001/XMLSchema#time"
@(private) XSD_DAY_TIME_DURATION :: "http://www.w3.org/2001/XMLSchema#dayTimeDuration"
@(private) RDF_LANG_STRING :: "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"

// XML Schema's integral derivation tree shares SPARQL's xsd:integer numeric
// value space. Arithmetic promotes any of these input datatypes to the base
// xsd:integer result (or onward to decimal/float/double as required).
@(private) is_integer_datatype :: proc(datatype: string) -> bool {
	return datatype == XSD_INTEGER ||
		datatype == "http://www.w3.org/2001/XMLSchema#long" ||
		datatype == "http://www.w3.org/2001/XMLSchema#int" ||
		datatype == "http://www.w3.org/2001/XMLSchema#short" ||
		datatype == "http://www.w3.org/2001/XMLSchema#byte" ||
		datatype == "http://www.w3.org/2001/XMLSchema#nonPositiveInteger" ||
		datatype == "http://www.w3.org/2001/XMLSchema#negativeInteger" ||
		datatype == "http://www.w3.org/2001/XMLSchema#nonNegativeInteger" ||
		datatype == "http://www.w3.org/2001/XMLSchema#positiveInteger" ||
		datatype == "http://www.w3.org/2001/XMLSchema#unsignedLong" ||
		datatype == "http://www.w3.org/2001/XMLSchema#unsignedInt" ||
		datatype == "http://www.w3.org/2001/XMLSchema#unsignedShort" ||
		datatype == "http://www.w3.org/2001/XMLSchema#unsignedByte"
}

@(private) is_integer :: proc(value: rdf.Term) -> bool {
	return value.kind == .Literal && is_integer_datatype(value.datatype)
}

@(private) is_decimal :: proc(value: rdf.Term) -> bool {
	return value.kind == .Literal && value.datatype == XSD_DECIMAL
}

@(private) is_floating :: proc(value: rdf.Term) -> bool {
	return value.kind == .Literal && (value.datatype == XSD_DOUBLE || value.datatype == XSD_FLOAT)
}

@(private) is_string_literal :: proc(value: rdf.Term) -> bool {
	return value.kind == .Literal && (value.datatype == XSD_STRING || value.datatype == RDF_LANG_STRING)
}

@(private) compatible_string_arguments :: proc(left, right: rdf.Term) -> bool {
	if !is_string_literal(left) || !is_string_literal(right) do return false
	// A language-tagged second argument requires an equally tagged first
	// argument. A plain/xsd:string second argument is compatible with either
	// kind of first argument and inherits that first argument's language tag.
	if len(right.language) == 0 do return true
	if len(left.language) == 0 do return false
	return ascii_equal_fold(left.language, right.language)
}

@(private) is_plain_string_literal :: proc(value: rdf.Term) -> bool {
	return value.kind == .Literal && value.datatype == XSD_STRING && len(value.language) == 0
}

// Odin's regex dot accepts newlines while SPARQL's default dot does not, so
// default dots become an explicit non-newline class. Its multiline anchors do
// not cover every SPARQL line-boundary case, so ^ and $ are expanded locally.
// Escapes and character classes are preserved verbatim.
@(private) regex_flagged_pattern :: proc(pattern: string, dotall, multiline: bool) -> (string, bool) {
	builder := strings.builder_make()
	escaped := false
	in_class := false
	for index in 0..<len(pattern) {
		byte := pattern[index]
		if escaped {
			if strings.write_byte(&builder, byte) != 1 { delete(builder.buf); return "", false }
			escaped = false
			continue
		}
		if byte == '\\' {
			if strings.write_byte(&builder, byte) != 1 { delete(builder.buf); return "", false }
			escaped = true
			continue
		}
		if byte == '[' do in_class = true
		if byte == ']' do in_class = false
		if byte == '.' && !in_class && !dotall {
			if strings.write_string(&builder, "[^\\n\\r]") != 7 { delete(builder.buf); return "", false }
			continue
		}
		if byte == '^' && !in_class && multiline {
			if strings.write_string(&builder, "(?:^|\\n|\\r)") != 11 { delete(builder.buf); return "", false }
			continue
		}
		if byte == '$' && !in_class && multiline {
			if strings.write_string(&builder, "(?:$|\\n|\\r)") != 11 { delete(builder.buf); return "", false }
			continue
		}
		if strings.write_byte(&builder, byte) != 1 { delete(builder.buf); return "", false }
	}
	return strings.to_string(builder), true
}

@(private) regex_quoted_pattern :: proc(pattern: string) -> (string, bool) {
	builder := strings.builder_make()
	for index in 0..<len(pattern) {
		byte := pattern[index]
		if byte == '\\' || byte == '^' || byte == '$' || byte == '.' || byte == '|' || byte == '?' || byte == '*' || byte == '+' || byte == '(' || byte == ')' || byte == '[' || byte == ']' || byte == '{' || byte == '}' {
			if strings.write_byte(&builder, '\\') != 1 { delete(builder.buf); return "", false }
		}
		if strings.write_byte(&builder, byte) != 1 { delete(builder.buf); return "", false }
	}
	return strings.to_string(builder), true
}

@(private) regex_flags :: proc(value: string) -> (regex.Flags, bool, bool, bool, bool) {
	flags: regex.Flags = {.Unicode, .No_Capture}
	dotall := false
	quote := false
	multiline := false
	for index in 0..<len(value) {
		byte := value[index]
		switch byte {
		case 'i': flags += {.Case_Insensitive}
		case 'm': multiline = true
		case 'x': flags += {.Ignore_Whitespace}
		case 's': dotall = true
		case 'q': quote = true
		case: return {}, false, false, false, false
		}
	}
	return flags, dotall, quote, multiline, true
}

@(private) regex_result :: proc(text, pattern: rdf.Term, flag_value: ^rdf.Term = nil) -> Expression_Result {
	if !is_string_literal(text) || !is_plain_string_literal(pattern) || !utf8.valid_string(text.value) || !utf8.valid_string(pattern.value) do return {state = .Error}
	flags, dotall, quote, multiline, flags_ok := regex_flags("")
	if !flags_ok do return {state = .Error}
	if flag_value != nil {
		if !is_plain_string_literal(flag_value^) || !utf8.valid_string(flag_value.value) do return {state = .Error}
		flags, dotall, quote, multiline, flags_ok = regex_flags(flag_value.value)
		if !flags_ok do return {state = .Error}
	}
	prepared := pattern.value
	owned := ""
	if quote {
		prepared, flags_ok = regex_quoted_pattern(pattern.value)
		if !flags_ok do return {state = .Out_Of_Memory}
		owned = prepared
	} else if !dotall || multiline {
		prepared, flags_ok = regex_flagged_pattern(pattern.value, dotall, multiline)
		if !flags_ok do return {state = .Out_Of_Memory}
		owned = prepared
	}
	defer if len(owned) != 0 do delete(owned)
	re, regex_error := regex.create(prepared, flags)
	if regex_error != nil do return {state = .Error}
	defer regex.destroy(re)
	_, matches := regex.match(re, text.value)
	return {state = .Term, term = boolean_term(matches)}
}

// Raw_Regex_Capture retains each VM save slot, unlike regex.Capture which
// deliberately compacts away unmatched groups.  REPLACE needs those holes so
// that `$2` means the second syntactic group even when that group did not
// participate in this particular alternation.
@(private) Raw_Regex_Capture :: struct {
	positions: [2 * regex_common.MAX_CAPTURE_GROUPS]int,
}

@(private) replace_iterator_next :: proc(iterator: ^regex.Match_Iterator, flags: regex.Flags) -> (Raw_Regex_Capture, bool) {
	if iterator.done do return {}, false
	if iterator.idx > 0 {
		iterator.vm.top_thread = 0
		iterator.vm.current_rune = rune(0)
		iterator.vm.current_rune_size = 0
		for index in 0..<iterator.threads {
			iterator.vm.threads[index] = {}
			iterator.vm.next_threads[index] = {}
		}
	}
	before := iterator.vm.string_pointer
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	saved: ^[2 * regex_common.MAX_CAPTURE_GROUPS]int
	ok := false
	{
		context.allocator = iterator.temp
		if .Unicode in flags {
			saved, ok = regex_vm.run(&iterator.vm, true)
		} else {
			saved, ok = regex_vm.run(&iterator.vm, false)
		}
	}
	if !ok || saved == nil do return {}, false
	result: Raw_Regex_Capture
	copy(result.positions[:], saved[:])
	if iterator.vm.string_pointer == before || iterator.vm.string_pointer == len(iterator.vm.memory) do iterator.done = true
	iterator.idx += 1
	return result, true
}

@(private) regex_capture_count :: proc(pattern: string) -> int {
	in_class := false
	escaped := false
	count := 0
	for index in 0..<len(pattern) {
		byte := pattern[index]
		if escaped { escaped = false; continue }
		if byte == '\\' { escaped = true; continue }
		if byte == '[' { in_class = true; continue }
		if byte == ']' { in_class = false; continue }
		if byte == '(' && !in_class && (index + 1 >= len(pattern) || pattern[index+1] != '?') do count += 1
	}
	return count
}

@(private) append_regex_replacement :: proc(builder: ^strings.Builder, replacement, source: string, capture: Raw_Regex_Capture, capture_count: int) -> (ok: bool, out_of_memory: bool) {
	for index := 0; index < len(replacement); index += 1 {
		byte := replacement[index]
		if byte == '\\' {
			if index + 1 >= len(replacement) do return false, false
			index += 1
			escaped := replacement[index]
			if escaped != '\\' && escaped != '$' do return false, false
			if strings.write_byte(builder, escaped) != 1 do return false, true
			continue
		}
		if byte == '$' {
			if index + 1 >= len(replacement) || replacement[index+1] < '1' || replacement[index+1] > '9' do return false, false
			index += 1
			group := int(replacement[index] - '0')
			if group > capture_count do return false, false
			start := capture.positions[2 * group]
			end := capture.positions[2 * group + 1]
			if start == -1 && end == -1 do continue
			if start < 0 || end < start || end > len(source) do return false, false
			if strings.write_string(builder, source[start:end]) != end - start do return false, true
			continue
		}
		if strings.write_byte(builder, byte) != 1 do return false, true
	}
	return true, false
}

// replace_result follows SPARQL's XPath-regex contract: every non-overlapping
// match is substituted; `$1` through `$9` name syntactic capture groups;
// unmatched groups expand to the empty string; and only `\\`/`\$` are valid
// replacement escapes.  A pattern matching the zero-length string is a type
// error, avoiding an ambiguous unbounded replacement sequence.
@(private) replace_result :: proc(text, pattern, replacement: rdf.Term, flag_value: ^rdf.Term = nil) -> Expression_Result {
	if !is_string_literal(text) || !is_plain_string_literal(pattern) || !is_plain_string_literal(replacement) || !utf8.valid_string(text.value) || !utf8.valid_string(pattern.value) || !utf8.valid_string(replacement.value) do return {state = .Error}
	flags, dotall, quote, multiline, flags_ok := regex_flags("")
	if !flags_ok do return {state = .Error}
	if flag_value != nil {
		if !is_plain_string_literal(flag_value^) || !utf8.valid_string(flag_value.value) do return {state = .Error}
		flags, dotall, quote, multiline, flags_ok = regex_flags(flag_value.value)
		if !flags_ok do return {state = .Error}
	}
	flags -= {.No_Capture}
	prepared := pattern.value
	owned := ""
	if quote {
		prepared, flags_ok = regex_quoted_pattern(pattern.value)
		if !flags_ok do return {state = .Out_Of_Memory}
		owned = prepared
	} else if !dotall || multiline {
		prepared, flags_ok = regex_flagged_pattern(pattern.value, dotall, multiline)
		if !flags_ok do return {state = .Out_Of_Memory}
		owned = prepared
	}
	defer if len(owned) != 0 do delete(owned)
	capture_count := regex_capture_count(prepared)
	if capture_count >= regex_common.MAX_CAPTURE_GROUPS do return {state = .Error}
	iterator, iterator_error := regex.create_iterator(text.value, prepared, flags)
	if iterator_error != nil do return {state = .Error}
	defer regex.destroy(iterator)
	builder := strings.builder_make()
	defer delete(builder.buf)
	previous := 0
	for {
		capture, matched := replace_iterator_next(&iterator, flags)
		if !matched do break
		start := capture.positions[0]
		end := capture.positions[1]
		if start < previous || end < start || end > len(text.value) || start == end do return {state = .Error}
		if strings.write_string(&builder, text.value[previous:start]) != start - previous do return {state = .Out_Of_Memory}
		replacement_ok, replacement_oom := append_regex_replacement(&builder, replacement.value, text.value, capture, capture_count)
		if !replacement_ok do return {state = replacement_oom ? .Out_Of_Memory : .Error}
		previous = end
	}
	if strings.write_string(&builder, text.value[previous:]) != len(text.value) - previous do return {state = .Out_Of_Memory}
	return string_result_like(text, strings.to_string(builder))
}

@(private) contains_bytes :: proc(value, part: string) -> bool {
	if len(part) == 0 do return true
	if len(part) > len(value) do return false
	for start in 0..<(len(value) - len(part) + 1) do if value[start:start + len(part)] == part do return true
	return false
}

@(private) index_bytes :: proc(value, part: string) -> int {
	if len(part) == 0 do return 0
	if len(part) > len(value) do return -1
	for start in 0..<(len(value) - len(part) + 1) do if value[start:start + len(part)] == part do return start
	return -1
}

@(private) string_result_like :: proc(source: rdf.Term, lexical: string) -> Expression_Result {
	owned, clone_error := strings.clone(lexical)
	if clone_error != nil do return {state = .Out_Of_Memory}
	if len(source.language) != 0 do return {state = .Term, term = rdf.language_literal(owned, source.language), owned = owned}
	return {state = .Term, term = rdf.literal(owned), owned = owned}
}

// A language literal needs both its lexical value and tag to outlive nested
// expression arguments. Keep both slices in one allocation, represented by
// Expression_Result.owned, so its normal destruction path remains sufficient.
@(private) language_literal_result :: proc(lexical, language: string) -> Expression_Result {
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_string(&builder, lexical) != len(lexical) do return {state = .Out_Of_Memory}
	if strings.write_string(&builder, language) != len(language) do return {state = .Out_Of_Memory}
	packed, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.language_literal(packed[:len(lexical)], packed[len(lexical):]), owned = packed}
}

@(private) write_bnode_term_fingerprint :: proc(builder: ^strings.Builder, value: rdf.Term) -> bool {
	if strings.write_int(builder, int(value.kind)) == 0 do return false
	if strings.write_byte(builder, ':') != 1 do return false
	if strings.write_int(builder, len(value.value)) == 0 || strings.write_byte(builder, ':') != 1 do return false
	if strings.write_string(builder, value.value) != len(value.value) do return false
	if strings.write_int(builder, len(value.language)) == 0 || strings.write_byte(builder, ':') != 1 do return false
	if strings.write_string(builder, value.language) != len(value.language) do return false
	if strings.write_int(builder, len(value.datatype)) == 0 || strings.write_byte(builder, ':') != 1 do return false
	if strings.write_string(builder, value.datatype) != len(value.datatype) do return false
	if strings.write_int(builder, int(cast(u64)value.scope)) == 0 || strings.write_byte(builder, ';') != 1 do return false
	return true
}

@(private) bnode_solution_key :: proc(ctx: ^Blank_Node_Context, binding: Binding, lexical: string) -> (string, bool) {
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_int(&builder, len(lexical)) == 0 || strings.write_byte(&builder, ':') != 1 do return "", false
	if strings.write_string(&builder, lexical) != len(lexical) || strings.write_byte(&builder, '|') != 1 do return "", false
	for index in 0..<len(binding.values) {
		// Unbound slots do not contribute a value to a solution mapping. In
		// particular, an Extend target is unbound before its BNODE expression
		// and generated afterwards, so neither state may split its identity.
		if !binding.bound[index] do continue
		value := binding.values[index]
		// Generated BNODE values belong to this query scope and must not split
		// the same source mapping when a later projection expression calls
		// BNODE with the same string.
		if value.kind == .Blank_Node && value.scope == ctx.scope {
			continue
		}
		if strings.write_int(&builder, index) == 0 || strings.write_byte(&builder, '=') != 1 || !write_bnode_term_fingerprint(&builder, value) do return "", false
	}
	key, clone_error := strings.clone(strings.to_string(builder))
	return key, clone_error == nil
}

@(private) fresh_bnode :: proc(ctx: ^Blank_Node_Context) -> Expression_Result {
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_string(&builder, "bnode-") != 6 || strings.write_int(&builder, ctx.next) == 0 do return {state = .Out_Of_Memory}
	ctx.next += 1
	label, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	if _, append_error := append(&ctx.owned, label); append_error != nil { delete(label); return {state = .Out_Of_Memory} }
	return {state = .Term, term = rdf.blank_node(label, ctx.scope)}
}

@(private) bnode_string_result :: proc(ctx: ^Blank_Node_Context, binding: Binding, value: rdf.Term) -> Expression_Result {
	if ctx == nil || !is_plain_string_literal(value) do return {state = .Error}
	key, key_error := bnode_solution_key(ctx, binding, value.value)
	if !key_error do return {state = .Out_Of_Memory}
	for index in 0..<len(ctx.keys) {
		if ctx.keys[index] == key {
			delete(key)
			return {state = .Term, term = ctx.nodes[index]}
		}
	}
	term := fresh_bnode(ctx)
	if term.state != .Term { delete(key); return term }
	if _, append_error := append(&ctx.keys, key); append_error != nil { delete(key); return {state = .Out_Of_Memory} }
	if _, append_error := append(&ctx.nodes, term.term); append_error != nil {
		resize(&ctx.keys, len(ctx.keys) - 1)
		delete(key)
		return {state = .Out_Of_Memory}
	}
	return term
}

@(private) Decimal_Lexical :: struct {
	text:     string,
	first:    int,
	last:     int,
	scale:    int,
	negative: bool,
}

// decimal_lexical validates the xsd:integer/xsd:decimal lexical spaces. The
// resulting range is already stripped of leading and trailing zeroes, and its
// digits remain views of the source string, so comparison has no size limit or
// allocation cost.
@(private) decimal_lexical :: proc(text: string, allow_decimal_point: bool) -> (Decimal_Lexical, bool) {
	if len(text) == 0 do return {}, false
	start := 0
	negative := false
	if text[0] == '+' || text[0] == '-' {
		negative = text[0] == '-'
		start = 1
	}
	if start == len(text) do return {}, false
	dot := -1
	digit_count := 0
	for index in start..<len(text) {
		character := text[index]
		if character >= '0' && character <= '9' {
			digit_count += 1
			continue
		}
		if allow_decimal_point && character == '.' && dot < 0 {
			dot = index
			continue
		}
		return {}, false
	}
	if digit_count == 0 do return {}, false

	first := start
	for first < len(text) && (text[first] == '0' || text[first] == '.') do first += 1
	last := len(text)
	trailing_zeroes := 0
	for last > start && text[last - 1] == '0' {
		last -= 1
		trailing_zeroes += 1
	}
	if last > start && text[last - 1] == '.' do last -= 1
	// All representations of zero have the same numeric sign and empty
	// significant range.
	if first >= last do return Decimal_Lexical{text = text, first = len(text), last = len(text)}, true
	// Removing a trailing coefficient zero increases the power of ten. This
	// produces a negative scale for integral values such as 100 (coefficient 1,
	// scale -2), preserving their magnitude after normalization.
	scale := -trailing_zeroes
	if dot >= 0 do scale += len(text) - dot - 1
	return Decimal_Lexical{text = text, first = first, last = last, scale = scale, negative = negative}, true
}

@(private) significant_digit_count :: proc(value: Decimal_Lexical) -> int {
	count := 0
	for index in value.first..<value.last do if value.text[index] != '.' do count += 1
	return count
}

@(private) next_significant_digit :: proc(value: Decimal_Lexical, cursor: ^int) -> (u8, bool) {
	for cursor^ < value.last {
		character := value.text[cursor^]
		cursor^ += 1
		if character != '.' do return character, true
	}
	return 0, false
}

// decimal_compare compares integer and decimal values exactly without bounded
// numeric conversion. The result is -1, 0, or 1 for left <, =, or > right.
@(private) decimal_compare :: proc(left, right: string, left_decimal, right_decimal: bool) -> (int, bool) {
	left_value, left_ok := decimal_lexical(left, left_decimal)
	right_value, right_ok := decimal_lexical(right, right_decimal)
	if !left_ok || !right_ok do return 0, false
	left_digits := significant_digit_count(left_value)
	right_digits := significant_digit_count(right_value)
	if left_digits == 0 || right_digits == 0 {
		if left_digits == 0 && right_digits == 0 do return 0, true
		if left_digits == 0 do return right_value.negative ? 1 : -1, true
		return left_value.negative ? -1 : 1, true
	}
	if left_value.negative != right_value.negative do return left_value.negative ? -1 : 1, true

	left_exponent := left_digits - left_value.scale
	right_exponent := right_digits - right_value.scale
	magnitude := 0
	if left_exponent < right_exponent {
		magnitude = -1
	} else if left_exponent > right_exponent {
		magnitude = 1
	} else {
		comparison_digits := max(left_digits, right_digits)
		left_cursor := left_value.first
		right_cursor := right_value.first
		for _ in 0..<comparison_digits {
			left_digit, left_present := next_significant_digit(left_value, &left_cursor)
			right_digit, right_present := next_significant_digit(right_value, &right_cursor)
			if !left_present do left_digit = '0'
			if !right_present do right_digit = '0'
			if left_digit < right_digit { magnitude = -1; break }
			if left_digit > right_digit { magnitude = 1; break }
		}
	}
	if left_value.negative do magnitude = -magnitude
	return magnitude, true
}

@(private) decimal_equal :: proc(left, right: string, left_decimal, right_decimal: bool) -> (bool, bool) {
	comparison, comparison_ok := decimal_compare(left, right, left_decimal, right_decimal)
	return comparison == 0, comparison_ok
}

@(private) is_numeric :: proc(value: rdf.Term) -> bool {
	return is_integer(value) || is_decimal(value) || is_floating(value)
}

// XSD_Date_Value is the evaluated xsd:date value used by the expression
// comparator.  The timezone-presence bit is retained because an unzoned date
// is not silently interchangeable with the same date at a known timezone.
@(private) XSD_Date_Value :: struct {
	ordinal:        datetime.Ordinal,
	utc_offset_min: int,
	has_timezone:   bool,
}

@(private) XSD_Date_Time_Value :: struct {
	date:     XSD_Date_Value,
	hour:     int,
	minute:   int,
	second:   int,
	fraction: string,
}

@(private) XSD_Time_Value :: struct {
	hour:           int,
	minute:         int,
	second:         int,
	fraction:       string,
	utc_offset_min: int,
	has_timezone:   bool,
}

@(private) ascii_decimal :: proc(text: string) -> (int, bool) {
	if len(text) == 0 do return 0, false
	value := 0
	for digit in text {
		if digit < '0' || digit > '9' do return 0, false
		if value > (max(int) - int(digit - '0')) / 10 do return 0, false
		value = value * 10 + int(digit - '0')
	}
	return value, true
}

@(private) parse_xsd_date_prefix :: proc(text: string) -> (XSD_Date_Value, int, bool) {
	index := 0
	negative := false
	if len(text) > 0 && text[0] == '-' {
		negative = true
		index += 1
	}
	year_start := index
	for index < len(text) && text[index] >= '0' && text[index] <= '9' do index += 1
	if index - year_start < 4 || index >= len(text) || text[index] != '-' do return {}, 0, false
	year_digits := text[year_start:index]
	year, year_ok := strconv.parse_i64_of_base(year_digits, 10)
	if !year_ok || year == 0 do return {}, 0, false
	if negative do year = -year
	index += 1
	if index + 2 >= len(text) do return {}, 0, false
	month, month_ok := ascii_decimal(text[index:index+2])
	if !month_ok || text[index+2] != '-' do return {}, 0, false
	index += 3
	if index + 2 > len(text) do return {}, 0, false
	day, day_ok := ascii_decimal(text[index:index+2])
	if !day_ok do return {}, 0, false
	index += 2
	ordinal, date_error := datetime.components_to_ordinal(year, i64(month), i64(day))
	if date_error != .None do return {}, 0, false
	return {ordinal = ordinal}, index, true
}

@(private) parse_xsd_timezone :: proc(text: string, index: int) -> (utc_offset_min: int, has_timezone: bool, next: int, ok: bool) {
	cursor := index
	offset := 0
	if cursor < len(text) {
		switch text[cursor] {
		case 'Z':
			has_timezone = true
			cursor += 1
		case '+', '-':
			sign := text[cursor]
			if cursor + 6 > len(text) || text[cursor+3] != ':' do return 0, false, 0, false
			hours, hours_ok := ascii_decimal(text[cursor+1:cursor+3])
			minutes, minutes_ok := ascii_decimal(text[cursor+4:cursor+6])
			if !hours_ok || !minutes_ok || hours > 14 || minutes > 59 || (hours == 14 && minutes != 0) do return 0, false, 0, false
			offset = hours * 60 + minutes
			if sign == '-' do offset = -offset
			has_timezone = true
			cursor += 6
		case:
			return 0, false, 0, false
		}
	}
	return offset, has_timezone, cursor, true
}

// parse_xsd_date accepts the XML Schema date lexical form needed by the
// evaluator: a four-or-more digit non-zero year, month/day, and an optional
// Z or +/-hh:mm timezone.  Calendar validity is delegated to Odin's
// proleptic-Gregorian datetime package rather than inferred from the text.
@(private) parse_xsd_date :: proc(text: string) -> (XSD_Date_Value, bool) {
	date, index, date_ok := parse_xsd_date_prefix(text)
	if !date_ok do return {}, false
	offset, has_timezone, next, timezone_ok := parse_xsd_timezone(text, index)
	if !timezone_ok || next != len(text) do return {}, false
	date.utc_offset_min = offset
	date.has_timezone = has_timezone
	return date, true
}

@(private) parse_xsd_date_time :: proc(text: string) -> (XSD_Date_Time_Value, bool) {
	date, index, date_ok := parse_xsd_date_prefix(text)
	if !date_ok || index >= len(text) || text[index] != 'T' do return {}, false
	index += 1
	if index + 8 > len(text) || text[index+2] != ':' || text[index+5] != ':' do return {}, false
	hour, hour_ok := ascii_decimal(text[index:index+2])
	minute, minute_ok := ascii_decimal(text[index+3:index+5])
	second, second_ok := ascii_decimal(text[index+6:index+8])
	if !hour_ok || !minute_ok || !second_ok do return {}, false
	if hour > 24 || minute > 59 || second > 59 do return {}, false
	index += 8
	fraction_start := index
	if index < len(text) && text[index] == '.' {
		index += 1
		fraction_start = index
		for index < len(text) && text[index] >= '0' && text[index] <= '9' do index += 1
		if index == fraction_start do return {}, false
	}
	fraction := text[fraction_start:index]
	if fraction_start > 0 && text[fraction_start-1] != '.' do fraction = ""
	if hour == 24 {
		if minute != 0 || second != 0 do return {}, false
		for digit in fraction do if digit != '0' do return {}, false
		date.ordinal += 1
		hour = 0
	} else if _, time_error := datetime.components_to_time(i64(hour), i64(minute), i64(second)); time_error != .None {
		return {}, false
	}
	offset, has_timezone, next, timezone_ok := parse_xsd_timezone(text, index)
	if !timezone_ok || next != len(text) do return {}, false
	date.utc_offset_min = offset
	date.has_timezone = has_timezone
	return {date = date, hour = hour, minute = minute, second = second, fraction = fraction}, true
}

// write_fixed_decimal writes a non-negative integer in an exact decimal width.
@(private) write_fixed_decimal :: proc(buffer: []byte, offset, width, value: int) -> bool {
	if offset < 0 || width <= 0 || offset + width > len(buffer) || value < 0 do return false
	remaining := value
	for index := width - 1; index >= 0; index -= 1 {
		buffer[offset + index] = byte('0') + byte(remaining % 10)
		remaining /= 10
	}
	return remaining == 0
}

// generated_now_lexical writes the default NOW() value into caller-owned
// storage. Unlike time_to_rfc3339's allocator-backed string, this survives
// temporary-allocator reuse throughout a complete query evaluation.
@(private) generated_now_lexical :: proc(buffer: ^[20]byte) -> (string, bool) {
	value, value_ok := time.time_to_datetime(time.now())
	if !value_ok || value.year < 1 || value.year > 9_999 do return "", false
	if !write_fixed_decimal(buffer[:], 0, 4, int(value.year)) ||
		!write_fixed_decimal(buffer[:], 5, 2, int(value.month)) ||
		!write_fixed_decimal(buffer[:], 8, 2, int(value.day)) ||
		!write_fixed_decimal(buffer[:], 11, 2, int(value.hour)) ||
		!write_fixed_decimal(buffer[:], 14, 2, int(value.minute)) ||
		!write_fixed_decimal(buffer[:], 17, 2, int(value.second)) {
		return "", false
	}
	buffer[4] = '-'
	buffer[7] = '-'
	buffer[10] = 'T'
	buffer[13] = ':'
	buffer[16] = ':'
	buffer[19] = 'Z'
	return string(buffer[:]), true
}

// parse_xsd_time shares dateTime's clock and timezone grammar but deliberately
// has no calendar component.  `24:00:00` is the permitted end-of-day lexical
// form and is represented as midnight for component extraction.
@(private) parse_xsd_time :: proc(text: string) -> (XSD_Time_Value, bool) {
	index := 0
	if len(text) < 8 || text[2] != ':' || text[5] != ':' do return {}, false
	hour, hour_ok := ascii_decimal(text[0:2])
	minute, minute_ok := ascii_decimal(text[3:5])
	second, second_ok := ascii_decimal(text[6:8])
	if !hour_ok || !minute_ok || !second_ok || hour > 24 || minute > 59 || second > 59 do return {}, false
	index = 8
	fraction_start := index
	if index < len(text) && text[index] == '.' {
		index += 1
		fraction_start = index
		for index < len(text) && text[index] >= '0' && text[index] <= '9' do index += 1
		if index == fraction_start do return {}, false
	}
	fraction := text[fraction_start:index]
	if fraction_start > 0 && text[fraction_start-1] != '.' do fraction = ""
	if hour == 24 {
		if minute != 0 || second != 0 do return {}, false
		for digit in fraction do if digit != '0' do return {}, false
		hour = 0
	} else if _, time_error := datetime.components_to_time(i64(hour), i64(minute), i64(second)); time_error != .None {
		return {}, false
	}
	offset, has_timezone, next, timezone_ok := parse_xsd_timezone(text, index)
	if !timezone_ok || next != len(text) do return {}, false
	return {hour = hour, minute = minute, second = second, fraction = fraction, utc_offset_min = offset, has_timezone = has_timezone}, true
}

// xsd_date_compare orders two parsed date values.  When both values carry an
// explicit timezone it compares their normalized midnight instants.  A
// timezone-absent date remains ordered by its calendar fields, which is the
// relational ordering exercised by the SPARQL 1.0 open-world date cases.
@(private) xsd_date_compare :: proc(left, right: rdf.Term) -> (int, bool) {
	if left.kind != .Literal || right.kind != .Literal || left.datatype != XSD_DATE || right.datatype != XSD_DATE do return 0, false
	left_date, left_ok := parse_xsd_date(left.value)
	right_date, right_ok := parse_xsd_date(right.value)
	if !left_ok || !right_ok do return 0, false
	if !left_date.has_timezone || !right_date.has_timezone {
		if left_date.ordinal < right_date.ordinal do return -1, true
		if left_date.ordinal > right_date.ordinal do return 1, true
		return 0, true
	}
	if left_date.ordinal == right_date.ordinal {
		if left_date.utc_offset_min > right_date.utc_offset_min do return -1, true
		if left_date.utc_offset_min < right_date.utc_offset_min do return 1, true
		return 0, true
	}
	if left_date.ordinal < right_date.ordinal {
		if left_date.ordinal < right_date.ordinal - 1 do return -1, true
		minutes := 24 * 60 - left_date.utc_offset_min + right_date.utc_offset_min
		if minutes < 0 do return -1, true
		if minutes > 0 do return 1, true
		return 0, true
	}
	if right_date.ordinal < left_date.ordinal - 1 do return 1, true
	minutes := -24 * 60 - left_date.utc_offset_min + right_date.utc_offset_min
	if minutes < 0 do return -1, true
	if minutes > 0 do return 1, true
	return 0, true
}

// xsd_date_equal keeps timezone absence observable.  A mixed pair whose
// calendar dates coincide has no determinate equality result in this slice;
// a different calendar day is conclusively unequal.  This is deliberately
// separate from relational comparison, whose conformance behavior is defined
// above.
@(private) xsd_date_equal :: proc(left, right: rdf.Term) -> (bool, bool) {
	left_date, left_ok := parse_xsd_date(left.value)
	right_date, right_ok := parse_xsd_date(right.value)
	if !left_ok || !right_ok do return false, false
	if left_date.has_timezone != right_date.has_timezone {
		if left_date.ordinal != right_date.ordinal do return false, true
		return false, false
	}
	comparison, comparable := xsd_date_compare(left, right)
	if !comparable do return false, false
	return comparison == 0, true
}

@(private) normalized_fraction_compare :: proc(left, right: string) -> int {
	left_end := len(left)
	for left_end > 0 && left[left_end-1] == '0' do left_end -= 1
	right_end := len(right)
	for right_end > 0 && right[right_end-1] == '0' do right_end -= 1
	width := left_end
	if right_end > width do width = right_end
	for index in 0..<width {
		left_digit := index < left_end ? left[index] : byte('0')
		right_digit := index < right_end ? right[index] : byte('0')
		if left_digit < right_digit do return -1
		if left_digit > right_digit do return 1
	}
	return 0
}

@(private) xsd_date_time_compare :: proc(left, right: rdf.Term) -> (int, bool) {
	if left.kind != .Literal || right.kind != .Literal || left.datatype != XSD_DATE_TIME || right.datatype != XSD_DATE_TIME do return 0, false
	left_time, left_ok := parse_xsd_date_time(left.value)
	right_time, right_ok := parse_xsd_date_time(right.value)
	if !left_ok || !right_ok do return 0, false
	left_ordinal := left_time.date.ordinal
	right_ordinal := right_time.date.ordinal
	left_minutes := left_time.hour * 60 + left_time.minute
	right_minutes := right_time.hour * 60 + right_time.minute
	if left_time.date.has_timezone && right_time.date.has_timezone {
		left_minutes -= left_time.date.utc_offset_min
		right_minutes -= right_time.date.utc_offset_min
		if left_minutes < 0 { left_ordinal -= 1; left_minutes += 24 * 60 }
		if right_minutes < 0 { right_ordinal -= 1; right_minutes += 24 * 60 }
		if left_minutes >= 24 * 60 { left_ordinal += 1; left_minutes -= 24 * 60 }
		if right_minutes >= 24 * 60 { right_ordinal += 1; right_minutes -= 24 * 60 }
	}
	if left_ordinal < right_ordinal do return -1, true
	if left_ordinal > right_ordinal do return 1, true
	if left_minutes < right_minutes do return -1, true
	if left_minutes > right_minutes do return 1, true
	if left_time.second < right_time.second do return -1, true
	if left_time.second > right_time.second do return 1, true
	return normalized_fraction_compare(left_time.fraction, right_time.fraction), true
}

@(private) xsd_date_time_equal :: proc(left, right: rdf.Term) -> (bool, bool) {
	left_time, left_ok := parse_xsd_date_time(left.value)
	right_time, right_ok := parse_xsd_date_time(right.value)
	if !left_ok || !right_ok do return false, false
	// A known timezone and an absent timezone are distinct value categories.
	// They cannot be made equal by interpreting the absent offset as UTC.
	if left_time.date.has_timezone != right_time.date.has_timezone do return false, true
	comparison, comparable := xsd_date_time_compare(left, right)
	if !comparable do return false, false
	return comparison == 0, true
}

@(private) xsd_time_compare :: proc(left, right: rdf.Term) -> (int, bool) {
	if left.kind != .Literal || right.kind != .Literal || left.datatype != XSD_TIME || right.datatype != XSD_TIME do return 0, false
	left_time, left_ok := parse_xsd_time(left.value)
	right_time, right_ok := parse_xsd_time(right.value)
	if !left_ok || !right_ok do return 0, false
	left_minutes := left_time.hour * 60 + left_time.minute
	right_minutes := right_time.hour * 60 + right_time.minute
	if left_time.has_timezone && right_time.has_timezone {
		left_minutes -= left_time.utc_offset_min
		right_minutes -= right_time.utc_offset_min
		if left_minutes < 0 do left_minutes += 24 * 60
		if right_minutes < 0 do right_minutes += 24 * 60
		if left_minutes >= 24 * 60 do left_minutes -= 24 * 60
		if right_minutes >= 24 * 60 do right_minutes -= 24 * 60
	}
	if left_minutes < right_minutes do return -1, true
	if left_minutes > right_minutes do return 1, true
	if left_time.second < right_time.second do return -1, true
	if left_time.second > right_time.second do return 1, true
	return normalized_fraction_compare(left_time.fraction, right_time.fraction), true
}

@(private) xsd_time_equal :: proc(left, right: rdf.Term) -> (bool, bool) {
	left_time, left_ok := parse_xsd_time(left.value)
	right_time, right_ok := parse_xsd_time(right.value)
	if !left_ok || !right_ok do return false, false
	if left_time.has_timezone != right_time.has_timezone do return false, true
	comparison, comparable := xsd_time_compare(left, right)
	if !comparable do return false, false
	return comparison == 0, true
}

// sparql_numeric_compare promotes to floating point only when SPARQL's type
// promotion requires it. Exact integer/decimal pairs stay in their decimal
// value space, including values beyond machine width.
@(private) sparql_numeric_compare :: proc(left, right: rdf.Term) -> (int, bool) {
	if !is_numeric(left) || !is_numeric(right) do return 0, false
	if !is_floating(left) && !is_floating(right) do return decimal_compare(left.value, right.value, is_decimal(left), is_decimal(right))
	left_value, left_ok := floating_value(left)
	right_value, right_ok := floating_value(right)
	if !left_ok || !right_ok || math.is_nan(left_value) || math.is_nan(right_value) do return 0, false
	if left_value < right_value do return -1, true
	if left_value > right_value do return 1, true
	return 0, true
}

// sparql_relational_compare implements the value-ordering subset used by
// FILTER's relational operators. Besides numeric promotion, simple and
// xsd:string literals compare lexically; language-tagged and differently typed
// literals remain type errors until their corresponding value models exist.
@(private) sparql_relational_compare :: proc(left, right: rdf.Term) -> (int, bool) {
	if comparison, comparable := sparql_numeric_compare(left, right); comparable do return comparison, true
	if comparison, comparable := xsd_date_compare(left, right); comparable do return comparison, true
	if comparison, comparable := xsd_date_time_compare(left, right); comparable do return comparison, true
	if comparison, comparable := xsd_time_compare(left, right); comparable do return comparison, true
	if left.kind == .Literal && right.kind == .Literal && left.datatype == XSD_STRING && right.datatype == XSD_STRING && len(left.language) == 0 && len(right.language) == 0 do return strings.compare(left.value, right.value), true
	return 0, false
}

@(private) floating_value :: proc(value: rdf.Term) -> (f64, bool) {
	if is_integer(value) || is_decimal(value) || is_floating(value) do return strconv.parse_f64(value.value)
	return 0, false
}

@(private) unary_numeric_result :: proc(value: rdf.Term, negate: bool) -> Expression_Result {
	if !is_numeric(value) do return {state = .Error}
	if is_integer(value) || is_decimal(value) {
		if _, valid := decimal_lexical(value.value, is_decimal(value)); !valid do return {state = .Error}
	} else if _, valid := floating_value(value); !valid {
		return {state = .Error}
	}
	if !negate do return {state = .Term, term = value}
	start := 0
	if len(value.value) > 0 && (value.value[0] == '-' || value.value[0] == '+') do start = 1
	lexical: string
	if len(value.value) > 0 && value.value[0] == '-' {
		copy, clone_error := strings.clone(value.value[start:])
		if clone_error != nil do return {state = .Error}
		lexical = copy
	} else {
		parts := [2]string{"-", value.value[start:]}
		joined, join_error := strings.concatenate(parts[:])
		if join_error != nil do return {state = .Error}
		lexical = joined
	}
	return {state = .Term, term = rdf.typed_literal(lexical, value.datatype), owned = lexical}
}

@(private) Exact_Error :: enum { None, Invalid, Limit, Out_Of_Memory }

@(private) Exact_Number :: struct {
	coefficient: big.Int,
	scale:       int,
	digits:      int,
}

@(private) exact_error_state :: proc(error: Exact_Error) -> Expression_State {
	#partial switch error {
	case .Limit: return .Numeric_Limit
	case .Out_Of_Memory: return .Out_Of_Memory
	case: return .Error
	}
}

@(private) destroy_exact_number :: proc(value: ^Exact_Number) {
	big.destroy(&value.coefficient)
	value^ = {}
}

@(private) write_exact_byte :: proc(builder: ^strings.Builder, value: u8) -> bool {
	return strings.write_byte(builder, value) == 1
}

@(private) parse_exact_number :: proc(term: rdf.Term, maximum_digits: int) -> (Exact_Number, Exact_Error) {
	if !is_integer(term) && !is_decimal(term) do return {}, .Invalid
	view, valid := decimal_lexical(term.value, is_decimal(term))
	if !valid do return {}, .Invalid
	lexical_digits := 0
	for character in term.value do if character >= '0' && character <= '9' do lexical_digits += 1
	if maximum_digits <= 0 || lexical_digits > maximum_digits do return {}, .Limit
	result := Exact_Number{scale = view.scale, digits = significant_digit_count(view)}
	builder := strings.builder_make()
	defer delete(builder.buf)
	if view.negative && !write_exact_byte(&builder, '-') { destroy_exact_number(&result); return {}, .Out_Of_Memory }
	cursor := view.first
	for cursor < view.last {
		digit, present := next_significant_digit(view, &cursor)
		if present && !write_exact_byte(&builder, digit) { destroy_exact_number(&result); return {}, .Out_Of_Memory }
	}
	if big.atoi(&result.coefficient, strings.to_string(builder)) != nil {
		destroy_exact_number(&result)
		return {}, .Out_Of_Memory
	}
	return result, .None
}

// decimal_fractional_scale retains source precision that decimal_lexical
// intentionally discards for numerical comparison. Arithmetic needs both:
// compare values after normalization, but render decimal results with at least
// their declared fractional precision (and at least one decimal place).
@(private) decimal_fractional_scale :: proc(term: rdf.Term) -> int {
	if !is_decimal(term) do return 0
	dot := strings.index_byte(term.value, '.')
	if dot < 0 do return 0
	return len(term.value) - dot - 1
}

@(private) align_exact_scale :: proc(value: ^Exact_Number, target_scale, maximum_digits: int) -> Exact_Error {
	delta := target_scale - value.scale
	if delta < 0 do return .Invalid
	if value.digits > maximum_digits - delta do return .Limit
	for _ in 0..<delta {
		if big.int_mul_digit(&value.coefficient, &value.coefficient, big.DIGIT(10)) != nil do return .Out_Of_Memory
	}
	value.scale = target_scale
	value.digits += delta
	return .None
}

// normalize_exact removes coefficient zeroes while preserving value by moving
// them into the decimal scale. This yields stable lexical forms such as 5
// rather than 5.00 after exact decimal arithmetic.
@(private) normalize_exact :: proc(value: ^Exact_Number) -> Exact_Error {
	raw, raw_error := big.itoa(&value.coefficient)
	if raw_error != nil do return .Out_Of_Memory
	defer delete(raw)
	value.digits = len(raw)
	if len(raw) > 0 && raw[0] == '-' do value.digits -= 1
	zero, zero_error := big.is_zero(&value.coefficient)
	if zero_error != nil do return .Out_Of_Memory
	if zero {
		value.scale = 0
		value.digits = 1
		return .None
	}
	for value.digits > 1 {
		remainder, remainder_error := big.int_mod_digit(&value.coefficient, big.DIGIT(10))
		if remainder_error != nil do return .Out_Of_Memory
		if remainder != 0 do break
		if big.int_div_digit(&value.coefficient, &value.coefficient, big.DIGIT(10)) != nil do return .Out_Of_Memory
		value.scale -= 1
		value.digits -= 1
	}
	return .None
}

@(private) exact_lexical :: proc(value: ^Exact_Number, maximum_digits: int) -> (string, Exact_Error) {
	raw, raw_error := big.itoa(&value.coefficient)
	if raw_error != nil do return "", .Out_Of_Memory
	defer delete(raw)
	negative := len(raw) > 0 && raw[0] == '-'
	digits := raw
	if negative do digits = raw[1:]
	lexical_digits := len(digits) + max(-value.scale, 0)
	if value.scale > 0 do lexical_digits = max(len(digits), value.scale + 1)
	if lexical_digits > maximum_digits do return "", .Limit
	builder := strings.builder_make()
	defer delete(builder.buf)
	if negative && !write_exact_byte(&builder, '-') do return "", .Out_Of_Memory
	if value.scale <= 0 {
		if strings.write_string(&builder, digits) != len(digits) do return "", .Out_Of_Memory
		for _ in 0..<(-value.scale) do if !write_exact_byte(&builder, '0') do return "", .Out_Of_Memory
	} else if value.scale >= len(digits) {
		if !write_exact_byte(&builder, '0') || !write_exact_byte(&builder, '.') do return "", .Out_Of_Memory
		for _ in 0..<(value.scale - len(digits)) do if !write_exact_byte(&builder, '0') do return "", .Out_Of_Memory
		if strings.write_string(&builder, digits) != len(digits) do return "", .Out_Of_Memory
	} else {
		before := len(digits) - value.scale
		if strings.write_string(&builder, digits[:before]) != before do return "", .Out_Of_Memory
		if !write_exact_byte(&builder, '.') do return "", .Out_Of_Memory
		if strings.write_string(&builder, digits[before:]) != len(digits) - before do return "", .Out_Of_Memory
	}
	lexical, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return "", .Out_Of_Memory
	return lexical, .None
}

// SPARQL arithmetic returns an xsd:decimal whenever either operand is decimal
// (and for exact division). Normalization removes insignificant zeroes, but a
// decimal operand's scale remains observable in the W3C result vectors: 1.0 +
// 2 yields 3.0, while 3^^xsd:decimal + 3 yields 6^^xsd:decimal. Restore only
// the minimum scale required by the operation rather than always appending .0.
@(private) exact_decimal_lexical :: proc(value: ^Exact_Number, maximum_digits, minimum_scale: int) -> (string, Exact_Error) {
	lexical, lexical_error := exact_lexical(value, maximum_digits)
	if lexical_error != .None do return "", lexical_error
	effective_minimum_scale := max(minimum_scale, 0)
	dot := strings.index_byte(lexical, '.')
	fractional_digits := 0
	if dot >= 0 do fractional_digits = len(lexical) - dot - 1
	if fractional_digits >= effective_minimum_scale do return lexical, .None
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_string(&builder, lexical) != len(lexical) { delete(lexical); return "", .Out_Of_Memory }
	if dot < 0 && !write_exact_byte(&builder, '.') { delete(lexical); return "", .Out_Of_Memory }
	for _ in fractional_digits..<effective_minimum_scale do if !write_exact_byte(&builder, '0') { delete(lexical); return "", .Out_Of_Memory }
	decimal, clone_error := strings.clone(strings.to_string(builder))
	delete(lexical)
	if clone_error != nil do return "", .Out_Of_Memory
	return decimal, .None
}

@(private) DEFAULT_DECIMAL_DIVISION_PRECISION :: 34

@(private) decimal_division_precision :: proc(value: int) -> int {
	if value > 0 do return value
	return DEFAULT_DECIMAL_DIVISION_PRECISION
}

@(private) exact_coefficient_magnitude :: proc(value: ^Exact_Number) -> (magnitude: string, negative: bool, error: Exact_Error) {
	raw, raw_error := big.itoa(&value.coefficient)
	if raw_error != nil do return "", false, .Out_Of_Memory
	defer delete(raw)
	start := 0
	if len(raw) > 0 && raw[0] == '-' {
		negative = true
		start = 1
	}
	copied, clone_error := strings.clone(raw[start:])
	if clone_error != nil do return "", false, .Out_Of_Memory
	return copied, negative, .None
}

@(private) reduce_exact_fraction :: proc(numerator, denominator: ^big.Int) -> Exact_Error {
	divisor: big.Int
	defer big.destroy(&divisor)
	if big.gcd(&divisor, numerator, denominator) != nil do return .Out_Of_Memory
	if big.int_div(numerator, numerator, &divisor) != nil do return .Out_Of_Memory
	if big.int_div(denominator, denominator, &divisor) != nil do return .Out_Of_Memory
	return .None
}

@(private) scale_exact_fraction_by_ten :: proc(value: ^big.Int, count, maximum_digits: int) -> Exact_Error {
	for _ in 0..<count {
		if big.int_mul_digit(value, value, big.DIGIT(10)) != nil do return .Out_Of_Memory
		raw, raw_error := big.itoa(value)
		if raw_error != nil do return .Out_Of_Memory
		digit_count := len(raw)
		defer delete(raw)
		if digit_count > maximum_digits do return .Limit
	}
	return .None
}

@(private) decimal_division_terminates :: proc(denominator: ^big.Int) -> (bool, Exact_Error) {
	remaining: big.Int
	defer big.destroy(&remaining)
	if big.int_copy(&remaining, denominator) != nil do return false, .Out_Of_Memory
	factors := [2]big.DIGIT{2, 5}
	for factor in factors {
		for {
			remainder, remainder_error := big.int_mod_digit(&remaining, factor)
			if remainder_error != nil do return false, .Out_Of_Memory
			if remainder != 0 do break
			if big.int_div_digit(&remaining, &remaining, factor) != nil do return false, .Out_Of_Memory
		}
	}
	comparison, comparison_error := big.int_compare_digit(&remaining, big.DIGIT(1))
	if comparison_error != nil do return false, .Out_Of_Memory
	return comparison == 0, .None
}

@(private) division_fraction_digit :: proc(remainder, denominator: ^big.Int) -> (u8, Exact_Error) {
	digit: big.Int
	defer big.destroy(&digit)
	if big.int_mul_digit(remainder, remainder, big.DIGIT(10)) != nil do return 0, .Out_Of_Memory
	if big.int_divmod(&digit, remainder, remainder, denominator) != nil do return 0, .Out_Of_Memory
	raw, raw_error := big.itoa(&digit)
	if raw_error != nil do return 0, .Out_Of_Memory
	defer delete(raw)
	if len(raw) != 1 || raw[0] < '0' || raw[0] > '9' do return 0, .Invalid
	return raw[0], .None
}

@(private) round_half_even :: proc(coefficient, discarded: string, has_more: bool) -> bool {
	if len(discarded) == 0 do return false
	if discarded[0] > '5' do return true
	if discarded[0] < '5' do return false
	for digit in discarded[1:] do if digit != '0' do return true
	if has_more do return true
	return len(coefficient) > 0 && (coefficient[len(coefficient) - 1] - '0') % 2 != 0
}

@(private) division_result :: proc(negative: bool, whole: string, fraction: []u8, precision, maximum_digits, minimum_scale: int, round, has_more: bool) -> Expression_Result {
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_string(&builder, whole) != len(whole) do return {state = .Out_Of_Memory}
	for digit in fraction do if !write_exact_byte(&builder, digit) do return {state = .Out_Of_Memory}
	coefficient, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	defer delete(coefficient)
	first_significant := 0
	for first_significant < len(coefficient) && coefficient[first_significant] == '0' do first_significant += 1
	if first_significant == len(coefficient) {
		zero := Exact_Number{}
		defer destroy_exact_number(&zero)
		lexical, lexical_error := exact_decimal_lexical(&zero, maximum_digits, minimum_scale)
		if lexical_error != .None do return {state = exact_error_state(lexical_error)}
		return {state = .Term, term = rdf.typed_literal(lexical, XSD_DECIMAL), owned = lexical}
	}
	removed := 0
	if round {
		significant_count := len(coefficient) - first_significant
		removed = significant_count - precision
		if removed < 1 do return {state = .Error}
	}
	kept := coefficient[:len(coefficient) - removed]
	if len(kept) == 0 do return {state = .Error}
	if round && round_half_even(kept, coefficient[len(kept):], has_more) {
		incremented, increment_error := increment_magnitude(kept)
		if increment_error != .Term do return {state = increment_error}
		defer delete(incremented)
		kept = incremented
	}
	signed := strings.builder_make()
	defer delete(signed.buf)
	if negative && !write_exact_byte(&signed, '-') do return {state = .Out_Of_Memory}
	if strings.write_string(&signed, kept) != len(kept) do return {state = .Out_Of_Memory}
	result := Exact_Number{scale = len(fraction) - removed}
	defer destroy_exact_number(&result)
	if big.atoi(&result.coefficient, strings.to_string(signed)) != nil do return {state = .Out_Of_Memory}
	if normalize_error := normalize_exact(&result); normalize_error != .None do return {state = exact_error_state(normalize_error)}
	lexical, lexical_error := exact_decimal_lexical(&result, maximum_digits, minimum_scale)
	if lexical_error != .None do return {state = exact_error_state(lexical_error)}
	return {state = .Term, term = rdf.typed_literal(lexical, XSD_DECIMAL), owned = lexical}
}

@(private) exact_divide_result :: proc(left, right: rdf.Term, maximum_digits, requested_precision: int) -> Expression_Result {
	left_number, left_error := parse_exact_number(left, maximum_digits)
	if left_error != .None do return {state = exact_error_state(left_error)}
	defer destroy_exact_number(&left_number)
	right_number, right_error := parse_exact_number(right, maximum_digits)
	if right_error != .None do return {state = exact_error_state(right_error)}
	defer destroy_exact_number(&right_number)
	minimum_scale := max(1, max(decimal_fractional_scale(left), decimal_fractional_scale(right)))
	numerator_text, left_negative, numerator_text_error := exact_coefficient_magnitude(&left_number)
	if numerator_text_error != .None do return {state = exact_error_state(numerator_text_error)}
	defer delete(numerator_text)
	denominator_text, right_negative, denominator_text_error := exact_coefficient_magnitude(&right_number)
	if denominator_text_error != .None do return {state = exact_error_state(denominator_text_error)}
	defer delete(denominator_text)
	numerator, denominator: big.Int
	defer big.destroy(&numerator, &denominator)
	if big.atoi(&numerator, numerator_text) != nil || big.atoi(&denominator, denominator_text) != nil do return {state = .Out_Of_Memory}
	zero_denominator, zero_error := big.is_zero(&denominator)
	if zero_error != nil do return {state = .Out_Of_Memory}
	if zero_denominator do return {state = .Error}
	zero_numerator, numerator_zero_error := big.is_zero(&numerator)
	if numerator_zero_error != nil do return {state = .Out_Of_Memory}
	if zero_numerator {
		zero := Exact_Number{}
		defer destroy_exact_number(&zero)
		lexical, lexical_error := exact_decimal_lexical(&zero, maximum_digits, minimum_scale)
		if lexical_error != .None do return {state = exact_error_state(lexical_error)}
		return {state = .Term, term = rdf.typed_literal(lexical, XSD_DECIMAL), owned = lexical}
	}
	if reduce_error := reduce_exact_fraction(&numerator, &denominator); reduce_error != .None do return {state = exact_error_state(reduce_error)}
	scale_delta := right_number.scale - left_number.scale
	if scale_delta > 0 {
		if scale_error := scale_exact_fraction_by_ten(&numerator, scale_delta, maximum_digits); scale_error != .None do return {state = exact_error_state(scale_error)}
	} else if scale_delta < 0 {
		if scale_error := scale_exact_fraction_by_ten(&denominator, -scale_delta, maximum_digits); scale_error != .None do return {state = exact_error_state(scale_error)}
	}
	if reduce_error := reduce_exact_fraction(&numerator, &denominator); reduce_error != .None do return {state = exact_error_state(reduce_error)}
	terminates, termination_error := decimal_division_terminates(&denominator)
	if termination_error != .None do return {state = exact_error_state(termination_error)}
	whole_value, remainder: big.Int
	defer big.destroy(&whole_value, &remainder)
	if big.int_divmod(&whole_value, &remainder, &numerator, &denominator) != nil do return {state = .Out_Of_Memory}
	whole, whole_error := big.itoa(&whole_value)
	if whole_error != nil do return {state = .Out_Of_Memory}
	defer delete(whole)
	fraction := make([dynamic]u8)
	defer delete(fraction)
	if terminates {
		for {
			zero, remainder_zero_error := big.is_zero(&remainder)
			if remainder_zero_error != nil do return {state = .Out_Of_Memory}
			if zero do break
			if len(fraction) >= maximum_digits do return {state = .Numeric_Limit}
			digit, digit_error := division_fraction_digit(&remainder, &denominator)
			if digit_error != .None do return {state = exact_error_state(digit_error)}
			if _, append_error := append(&fraction, digit); append_error != nil do return {state = .Out_Of_Memory}
		}
		return division_result(left_negative != right_negative, whole, fraction[:], 0, maximum_digits, minimum_scale, false, false)
	}
	precision := decimal_division_precision(requested_precision)
	if precision > maximum_digits do return {state = .Numeric_Limit}
	whole_significant := len(whole)
	if whole == "0" do whole_significant = 0
	if whole_significant > precision do return division_result(left_negative != right_negative, whole, fraction[:], precision, maximum_digits, minimum_scale, true, true)
	target_significant := precision + 1
	significant := whole_significant
	for significant < target_significant {
		if len(fraction) >= maximum_digits do return {state = .Numeric_Limit}
		digit, digit_error := division_fraction_digit(&remainder, &denominator)
		if digit_error != .None do return {state = exact_error_state(digit_error)}
		if _, append_error := append(&fraction, digit); append_error != nil do return {state = .Out_Of_Memory}
		if digit != '0' || significant > 0 do significant += 1
	}
	return division_result(left_negative != right_negative, whole, fraction[:], precision, maximum_digits, minimum_scale, true, true)
}

@(private) floating_input_f64 :: proc(value: rdf.Term) -> (f64, bool) {
	if !is_numeric(value) do return 0, false
	if value.value == "INF" do return math.INF_F64, true
	if value.value == "-INF" do return math.NEG_INF_F64, true
	if value.value == "NaN" do return math.QNAN_F64, true
	return strconv.parse_f64(value.value)
}

@(private) floating_input_f32 :: proc(value: rdf.Term) -> (f32, bool) {
	if !is_numeric(value) do return 0, false
	if value.value == "INF" do return math.INF_F32, true
	if value.value == "-INF" do return math.NEG_INF_F32, true
	if value.value == "NaN" do return math.QNAN_F32, true
	return strconv.parse_f32(value.value)
}

@(private) floating_result :: proc(value: f64, datatype: string) -> Expression_Result {
	lexical: string
	if math.is_nan(value) {
		lexical = "NaN"
	} else if math.is_inf(value, 1) {
		lexical = "INF"
	} else if math.is_inf(value, -1) {
		lexical = "-INF"
	} else {
		builder := strings.builder_make()
		defer delete(builder.buf)
		if strings.write_f64(&builder, value, 'g') == 0 do return {state = .Out_Of_Memory}
		copied, clone_error := strings.clone(strings.to_string(builder))
		if clone_error != nil do return {state = .Out_Of_Memory}
		lexical = copied
	}
	if lexical == "NaN" || lexical == "INF" || lexical == "-INF" do return {state = .Term, term = rdf.typed_literal(lexical, datatype)}
	return {state = .Term, term = rdf.typed_literal(lexical, datatype), owned = lexical}
}

@(private) floating_result_f32 :: proc(value: f32) -> Expression_Result {
	if math.is_nan(value) do return {state = .Term, term = rdf.typed_literal("NaN", XSD_FLOAT)}
	if math.is_inf(value, 1) do return {state = .Term, term = rdf.typed_literal("INF", XSD_FLOAT)}
	if math.is_inf(value, -1) do return {state = .Term, term = rdf.typed_literal("-INF", XSD_FLOAT)}
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_f32(&builder, value, 'g') == 0 do return {state = .Out_Of_Memory}
	lexical, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.typed_literal(lexical, XSD_FLOAT), owned = lexical}
}

// canonical_floating_result emits the XSD canonical scientific lexical form.
// MIN, MAX, and SAMPLE expose selected floating RDF values, for which the W3C
// aggregate fixtures require canonicalization even when the source spelling
// used a permitted non-canonical form such as `2E-1`.
@(private) canonical_floating_result :: proc(value: f64, datatype: string) -> Expression_Result {
	if math.is_nan(value) do return {state = .Term, term = rdf.typed_literal("NaN", datatype)}
	if math.is_inf(value, 1) do return {state = .Term, term = rdf.typed_literal("INF", datatype)}
	if math.is_inf(value, -1) do return {state = .Term, term = rdf.typed_literal("-INF", datatype)}
	raw_builder := strings.builder_make()
	defer delete(raw_builder.buf)
	if strings.write_f64(&raw_builder, value, 'g') == 0 do return {state = .Out_Of_Memory}
	raw := strings.to_string(raw_builder)
	start := 0
	negative := false
	if len(raw) > 0 && (raw[0] == '-' || raw[0] == '+') {
		negative = raw[0] == '-'
		start = 1
	}
	exponent_start := len(raw)
	for index in start..<len(raw) {
		if raw[index] == 'e' || raw[index] == 'E' { exponent_start = index; break }
	}
	external_exponent := 0
	if exponent_start < len(raw) {
		cursor := exponent_start + 1
		exponent_negative := false
		if cursor < len(raw) && (raw[cursor] == '-' || raw[cursor] == '+') {
			exponent_negative = raw[cursor] == '-'
			cursor += 1
		}
		if cursor == len(raw) do return {state = .Error}
		for cursor < len(raw) {
			if raw[cursor] < '0' || raw[cursor] > '9' do return {state = .Error}
			if external_exponent > 100_000 do return {state = .Error}
			external_exponent = external_exponent * 10 + int(raw[cursor] - '0')
			cursor += 1
		}
		if exponent_negative do external_exponent = -external_exponent
	}
	digits := make([dynamic]u8)
	defer delete(digits)
	before_decimal := 0
	seen_decimal := false
	for index in start..<exponent_start {
		if raw[index] == '.' {
			if seen_decimal do return {state = .Error}
			seen_decimal = true
			continue
		}
		if raw[index] < '0' || raw[index] > '9' do return {state = .Error}
		if !seen_decimal do before_decimal += 1
		if _, append_error := append(&digits, raw[index]); append_error != nil do return {state = .Out_Of_Memory}
	}
	first := 0
	for first < len(digits) && digits[first] == '0' do first += 1
	if first == len(digits) {
		lexical := negative ? "-0.0E0" : "0.0E0"
		return {state = .Term, term = rdf.typed_literal(lexical, datatype)}
	}
	last := len(digits)
	for last > first + 1 && digits[last - 1] == '0' do last -= 1
	exponent := before_decimal - first - 1 + external_exponent
	builder := strings.builder_make()
	defer delete(builder.buf)
	if negative && !write_exact_byte(&builder, '-') do return {state = .Out_Of_Memory}
	if !write_exact_byte(&builder, digits[first]) || !write_exact_byte(&builder, '.') do return {state = .Out_Of_Memory}
	if last == first + 1 {
		if !write_exact_byte(&builder, '0') do return {state = .Out_Of_Memory}
	} else {
		for index in first + 1..<last do if !write_exact_byte(&builder, digits[index]) do return {state = .Out_Of_Memory}
	}
	if !write_exact_byte(&builder, 'E') do return {state = .Out_Of_Memory}
	buffer: [64]byte
	written := strconv.write_int(buffer[:], i64(exponent), 10)
	if strings.write_string(&builder, written) != len(written) do return {state = .Out_Of_Memory}
	lexical, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.typed_literal(lexical, datatype), owned = lexical}
}

@(private) floating_divide_result :: proc(left, right: rdf.Term) -> Expression_Result {
	if !is_numeric(left) || !is_numeric(right) do return {state = .Error}
	if left.datatype == XSD_DOUBLE || right.datatype == XSD_DOUBLE {
		left_value, left_ok := floating_input_f64(left)
		right_value, right_ok := floating_input_f64(right)
		if !left_ok || !right_ok do return {state = .Error}
		return floating_result(left_value / right_value, XSD_DOUBLE)
	}
	left_value, left_ok := floating_input_f32(left)
	right_value, right_ok := floating_input_f32(right)
	if !left_ok || !right_ok do return {state = .Error}
	return floating_result_f32(left_value / right_value)
}

@(private) floating_binary_result :: proc(left, right: rdf.Term, operation: algebra.Expression_Kind) -> Expression_Result {
	if !is_numeric(left) || !is_numeric(right) do return {state = .Error}
	if left.datatype == XSD_DOUBLE || right.datatype == XSD_DOUBLE {
		left_value, left_ok := floating_input_f64(left)
		right_value, right_ok := floating_input_f64(right)
		if !left_ok || !right_ok do return {state = .Error}
		if operation == .Add do return floating_result(left_value + right_value, XSD_DOUBLE)
		if operation == .Subtract do return floating_result(left_value - right_value, XSD_DOUBLE)
		if operation == .Multiply do return floating_result(left_value * right_value, XSD_DOUBLE)
		return {state = .Error}
	}
	left_value, left_ok := floating_input_f32(left)
	right_value, right_ok := floating_input_f32(right)
	if !left_ok || !right_ok do return {state = .Error}
	if operation == .Add do return floating_result_f32(left_value + right_value)
	if operation == .Subtract do return floating_result_f32(left_value - right_value)
	if operation == .Multiply do return floating_result_f32(left_value * right_value)
	return {state = .Error}
}

@(private) exact_binary_result :: proc(left, right: rdf.Term, operation: algebra.Expression_Kind, maximum_digits: int) -> Expression_Result {
	left_number, left_error := parse_exact_number(left, maximum_digits)
	if left_error != .None do return {state = exact_error_state(left_error)}
	defer destroy_exact_number(&left_number)
	right_number, right_error := parse_exact_number(right, maximum_digits)
	if right_error != .None do return {state = exact_error_state(right_error)}
	defer destroy_exact_number(&right_number)
	result: Exact_Number
	defer destroy_exact_number(&result)
	minimum_scale := 0
	if operation == .Add || operation == .Subtract {
		target_scale := max(left_number.scale, right_number.scale)
		if error := align_exact_scale(&left_number, target_scale, maximum_digits); error != .None do return {state = exact_error_state(error)}
		if error := align_exact_scale(&right_number, target_scale, maximum_digits); error != .None do return {state = exact_error_state(error)}
		result.scale = target_scale
		if operation == .Add {
			if big.add(&result.coefficient, &left_number.coefficient, &right_number.coefficient) != nil do return {state = .Out_Of_Memory}
		} else if big.sub(&result.coefficient, &left_number.coefficient, &right_number.coefficient) != nil {
			return {state = .Out_Of_Memory}
		}
	} else if operation == .Multiply {
		if left_number.digits > maximum_digits - right_number.digits do return {state = .Numeric_Limit}
		result.scale = left_number.scale + right_number.scale
		if big.mul(&result.coefficient, &left_number.coefficient, &right_number.coefficient) != nil do return {state = .Out_Of_Memory}
	} else {
		return {state = .Error}
	}
	if normalize_error := normalize_exact(&result); normalize_error != .None do return {state = exact_error_state(normalize_error)}
	datatype := XSD_INTEGER
	if is_decimal(left) || is_decimal(right) do datatype = XSD_DECIMAL
	if datatype == XSD_DECIMAL {
		left_scale := decimal_fractional_scale(left)
		right_scale := decimal_fractional_scale(right)
		if operation == .Multiply {
			minimum_scale = max(1, left_scale + right_scale)
		} else {
			minimum_scale = max(1, max(left_scale, right_scale))
		}
	}
	lexical: string
	lexical_error: Exact_Error
	if datatype == XSD_DECIMAL {
		lexical, lexical_error = exact_decimal_lexical(&result, maximum_digits, minimum_scale)
	} else {
		lexical, lexical_error = exact_lexical(&result, maximum_digits)
	}
	if lexical_error != .None do return {state = exact_error_state(lexical_error)}
	return {state = .Term, term = rdf.typed_literal(lexical, datatype), owned = lexical}
}

// integer_magnitude returns a canonical, non-negative integral magnitude plus
// the relation of the discarded fractional portion to one half. It avoids
// machine-width conversion, so FLOOR/CEIL/ROUND work for arbitrary-length
// integer and decimal lexical forms.
@(private) integer_magnitude :: proc(value: rdf.Term) -> (negative: bool, magnitude: string, has_fraction: bool, fraction_to_half: int, valid: bool) {
	if !is_integer(value) && !is_decimal(value) do return
	if _, valid = decimal_lexical(value.value, is_decimal(value)); !valid do return
	start := 0
	if len(value.value) > 0 && (value.value[0] == '-' || value.value[0] == '+') {
		negative = value.value[0] == '-'
		start = 1
	}
	dot := -1
	for index in start..<len(value.value) {
		if value.value[index] == '.' { dot = index; break }
	}
	integer_end := len(value.value)
	if dot >= 0 do integer_end = dot
	first := start
	for first < integer_end && value.value[first] == '0' do first += 1
	if first == integer_end {
		magnitude = "0"
	} else {
		magnitude = value.value[first:integer_end]
	}
	if dot < 0 do return
	first_fraction := dot + 1
	for index in first_fraction..<len(value.value) {
		if value.value[index] != '0' { has_fraction = true; break }
	}
	if !has_fraction do return
	if value.value[first_fraction] < '5' {
		fraction_to_half = -1
	} else if value.value[first_fraction] > '5' {
		fraction_to_half = 1
	} else {
		for index in first_fraction + 1..<len(value.value) {
			if value.value[index] != '0' { fraction_to_half = 1; return }
		}
	}
	return
}

@(private) increment_magnitude :: proc(value: string) -> (string, Expression_State) {
	last_non_nine := len(value) - 1
	for last_non_nine >= 0 && value[last_non_nine] == '9' do last_non_nine -= 1
	builder := strings.builder_make()
	defer delete(builder.buf)
	if last_non_nine < 0 {
		if !write_exact_byte(&builder, '1') do return "", .Out_Of_Memory
		for _ in 0..<len(value) do if !write_exact_byte(&builder, '0') do return "", .Out_Of_Memory
	} else {
		if strings.write_string(&builder, value[:last_non_nine]) != last_non_nine do return "", .Out_Of_Memory
		if !write_exact_byte(&builder, value[last_non_nine] + 1) do return "", .Out_Of_Memory
		for _ in last_non_nine + 1..<len(value) do if !write_exact_byte(&builder, '0') do return "", .Out_Of_Memory
	}
	owned, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return "", .Out_Of_Memory
	return owned, .Term
}

@(private) integer_result :: proc(magnitude: string, negative: bool, datatype: string) -> Expression_Result {
	builder := strings.builder_make()
	defer delete(builder.buf)
	if negative && magnitude != "0" && !write_exact_byte(&builder, '-') do return {state = .Out_Of_Memory}
	if strings.write_string(&builder, magnitude) != len(magnitude) do return {state = .Out_Of_Memory}
	owned, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.typed_literal(owned, datatype), owned = owned}
}

@(private) uri_unreserved :: proc(value: u8) -> bool {
	return value >= 'A' && value <= 'Z' || value >= 'a' && value <= 'z' || value >= '0' && value <= '9' || value == '-' || value == '.' || value == '_' || value == '~'
}

@(private) encode_for_uri_result :: proc(value: rdf.Term) -> Expression_Result {
	if !is_string_literal(value) || !utf8.valid_string(value.value) do return {state = .Error}
	hex := "0123456789ABCDEF"
	builder := strings.builder_make()
	defer delete(builder.buf)
	for index in 0..<len(value.value) {
		byte := value.value[index]
		if uri_unreserved(byte) {
			if !write_exact_byte(&builder, byte) do return {state = .Out_Of_Memory}
		} else {
			if !write_exact_byte(&builder, '%') || !write_exact_byte(&builder, hex[byte >> 4]) || !write_exact_byte(&builder, hex[byte & 0x0f]) do return {state = .Out_Of_Memory}
		}
	}
	owned, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.literal(owned), owned = owned}
}

@(private) hex_digest_result :: proc(value: rdf.Term, kind: algebra.Expression_Kind) -> Expression_Result {
	if !is_string_literal(value) || !utf8.valid_string(value.value) do return {state = .Error}
	data := transmute([]byte)value.value
	digest: [sha2.DIGEST_SIZE_512]byte
	digest_count := 0
	if kind == .MD5 {
		ctx: md5.Context
		md5.init(&ctx)
		md5.update(&ctx, data)
		md5.final(&ctx, digest[:md5.DIGEST_SIZE])
		digest_count = md5.DIGEST_SIZE
	} else if kind == .SHA1 {
		ctx: sha1.Context
		sha1.init(&ctx)
		sha1.update(&ctx, data)
		sha1.final(&ctx, digest[:sha1.DIGEST_SIZE])
		digest_count = sha1.DIGEST_SIZE
	} else if kind == .SHA256 {
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, data)
		sha2.final(&ctx, digest[:sha2.DIGEST_SIZE_256])
		digest_count = sha2.DIGEST_SIZE_256
	} else if kind == .SHA384 {
		ctx: sha2.Context_512
		sha2.init_384(&ctx)
		sha2.update(&ctx, data)
		sha2.final(&ctx, digest[:sha2.DIGEST_SIZE_384])
		digest_count = sha2.DIGEST_SIZE_384
	} else if kind == .SHA512 {
		ctx: sha2.Context_512
		sha2.init_512(&ctx)
		sha2.update(&ctx, data)
		sha2.final(&ctx, digest[:sha2.DIGEST_SIZE_512])
		digest_count = sha2.DIGEST_SIZE_512
	} else {
		return {state = .Error}
	}
	const_hex := "0123456789abcdef"
	builder := strings.builder_make()
	defer delete(builder.buf)
	for byte in digest[:digest_count] {
		if !write_exact_byte(&builder, const_hex[byte >> 4]) || !write_exact_byte(&builder, const_hex[byte & 0x0f]) do return {state = .Out_Of_Memory}
	}
	owned, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.literal(owned), owned = owned}
}

// rounded_string_index rounds a SPARQL numeric argument with the
// XPath/SPARQL half-toward-positive-infinity rule, then clamps it to the
// finite range that can affect a string of the supplied size. Exact values
// avoid machine-width conversion; finite float/double values are clamped
// before their rounded value enters machine-width arithmetic.
@(private) rounded_string_index :: proc(value: rdf.Term, cap: int) -> (int, Expression_State) {
	if is_floating(value) {
		floating: f64
		valid: bool
		if value.datatype == XSD_DOUBLE {
			floating, valid = floating_input_f64(value)
		} else {
			single, single_valid := floating_input_f32(value)
			floating = f64(single)
			valid = single_valid
		}
		if !valid || math.is_nan(floating) || math.is_inf(floating, 0) do return 0, .Error
		bound := f64(cap)
		if floating >= bound do return cap, .Term
		if floating <= -bound do return -cap, .Term
		rounded := math.floor(floating + 0.5)
		if rounded >= bound do return cap, .Term
		if rounded <= -bound do return -cap, .Term
		return int(rounded), .Term
	}
	negative, magnitude, has_fraction, fraction_to_half, valid := integer_magnitude(value)
	if !valid do return 0, .Error
	owned_magnitude := ""
	if has_fraction && (fraction_to_half > 0 || (fraction_to_half == 0 && !negative)) {
		incremented, increment_state := increment_magnitude(magnitude)
		if increment_state != .Term do return 0, increment_state
		magnitude = incremented
		owned_magnitude = incremented
	}
	defer if len(owned_magnitude) != 0 do delete(owned_magnitude)
	if magnitude == "0" do return 0, .Term
	buffer: [32]byte
	cap_lexical := strconv.write_int(buffer[:], i64(cap), 10)
	if len(magnitude) > len(cap_lexical) || len(magnitude) == len(cap_lexical) && strings.compare(magnitude, cap_lexical) > 0 {
		return negative ? -cap : cap, .Term
	}
	parsed, parsed_ok := strconv.parse_int(magnitude, 10)
	if !parsed_ok do return 0, .Error
	return negative ? -parsed : parsed, .Term
}

@(private) clamped_string_index_add :: proc(left, right, cap: int) -> int {
	if right > 0 && left > cap - right do return cap
	if right < 0 && left < -cap - right do return -cap
	return left + right
}

@(private) substring_result :: proc(value, start_value: rdf.Term, length_value: ^rdf.Term = nil) -> Expression_Result {
	if !is_string_literal(value) || !utf8.valid_string(value.value) do return {state = .Error}
	rune_count := utf8.rune_count_in_string(value.value)
	cap := rune_count + 1
	start, start_state := rounded_string_index(start_value, cap)
	if start_state != .Term do return {state = start_state}
	end := cap
	if length_value != nil {
		length, length_state := rounded_string_index(length_value^, cap)
		if length_state != .Term do return {state = length_state}
		end = clamped_string_index_add(start, length, cap)
	}
	first_position := max(start, 1)
	last_position := min(end, cap)
	if first_position >= last_position do return string_result_like(value, "")
	first_byte := utf8.rune_offset(value.value, first_position - 1)
	last_byte := len(value.value)
	if last_position < cap do last_byte = utf8.rune_offset(value.value, last_position - 1)
	if first_byte < 0 || last_byte < 0 do return {state = .Error}
	return string_result_like(value, value.value[first_byte:last_byte])
}

@(private) exact_rounding_result :: proc(value: rdf.Term, operation: algebra.Expression_Kind) -> Expression_Result {
	negative, magnitude, has_fraction, fraction_to_half, valid := integer_magnitude(value)
	if !valid do return {state = .Error}
	if operation == .Absolute {
		start := 0
		if len(value.value) > 0 && (value.value[0] == '-' || value.value[0] == '+') do start = 1
		owned, clone_error := strings.clone(value.value[start:])
		if clone_error != nil do return {state = .Out_Of_Memory}
		return {state = .Term, term = rdf.typed_literal(owned, value.datatype), owned = owned}
	}
	increment := false
	if operation == .Ceiling {
		increment = has_fraction && !negative
	} else if operation == .Floor {
		increment = has_fraction && negative
	} else if operation == .Round {
		increment = has_fraction && (fraction_to_half > 0 || (fraction_to_half == 0 && !negative))
	} else {
		return {state = .Error}
	}
	owned_magnitude := ""
	if increment {
		incremented, increment_state := increment_magnitude(magnitude)
		if increment_state != .Term do return {state = increment_state}
		magnitude = incremented
		owned_magnitude = incremented
	}
	defer if len(owned_magnitude) != 0 do delete(owned_magnitude)
	return integer_result(magnitude, negative, value.datatype)
}

// floating_rounding_result applies the SPARQL numeric functions without
// widening xsd:float to xsd:double. ROUND is deliberately not math.round:
// SPARQL follows XPath's half-toward-positive-infinity rule, for which
// floor(x + 0.5) gives ROUND(-1.5) = -1. The core math functions preserve
// IEEE NaN, infinities, and signed zero for ABS/CEIL/FLOOR; the ROUND formula
// intentionally converts the negative half-to-zero case to positive zero,
// matching the exact-number result representation.
@(private) floating_rounding_result :: proc(value: rdf.Term, operation: algebra.Expression_Kind) -> Expression_Result {
	if value.datatype == XSD_DOUBLE {
		floating, valid := floating_input_f64(value)
		if !valid do return {state = .Error}
		#partial switch operation {
		case .Absolute: return floating_result(math.abs(floating), XSD_DOUBLE)
		case .Ceiling:  return floating_result(math.ceil(floating), XSD_DOUBLE)
		case .Floor:    return floating_result(math.floor(floating), XSD_DOUBLE)
		case .Round:    return floating_result(math.floor(floating + 0.5), XSD_DOUBLE)
		}
		return {state = .Error}
	}
	if value.datatype == XSD_FLOAT {
		floating, valid := floating_input_f32(value)
		if !valid do return {state = .Error}
		#partial switch operation {
		case .Absolute: return floating_result_f32(math.abs(floating))
		case .Ceiling:  return floating_result_f32(math.ceil(floating))
		case .Floor:    return floating_result_f32(math.floor(floating))
		case .Round:    return floating_result_f32(math.floor(floating + 0.5))
		}
		return {state = .Error}
	}
	return {state = .Error}
}

@(private) cast_lexical_result :: proc(lexical, datatype: string) -> Expression_Result {
	owned, clone_error := strings.clone(lexical)
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.typed_literal(owned, datatype), owned = owned}
}

// cast_floating_integer_result truncates a finite float/double toward zero
// without routing the result through a machine-width integer. The canonical
// scientific spelling bounds the exponent and gives an exact digit/exponent
// decomposition for the conversion.
@(private) cast_floating_integer_result :: proc(value: rdf.Term) -> Expression_Result {
	floating: f64
	valid: bool
	if value.datatype == XSD_DOUBLE {
		floating, valid = floating_input_f64(value)
	} else {
		single, single_valid := floating_input_f32(value)
		floating = f64(single)
		valid = single_valid
	}
	if !valid || math.is_nan(floating) || math.is_inf(floating, 0) do return {state = .Error}
	canonical := canonical_floating_result(floating, value.datatype)
	if canonical.state != .Term do return canonical
	defer destroy_expression_result(&canonical)
	lexical := canonical.term.value
	start := 0
	negative := false
	if len(lexical) > 0 && lexical[0] == '-' {
		negative = true
		start = 1
	}
	decimal := -1
	exponent_start := -1
	for index in start..<len(lexical) {
		if lexical[index] == '.' { decimal = index; continue }
		if lexical[index] == 'E' { exponent_start = index; break }
	}
	if decimal < 0 || exponent_start < 0 || exponent_start + 1 >= len(lexical) do return {state = .Error}
	exponent := 0
	exponent_negative := false
	cursor := exponent_start + 1
	if lexical[cursor] == '-' || lexical[cursor] == '+' {
		exponent_negative = lexical[cursor] == '-'
		cursor += 1
	}
	if cursor == len(lexical) do return {state = .Error}
	for cursor < len(lexical) {
		if lexical[cursor] < '0' || lexical[cursor] > '9' do return {state = .Error}
		exponent = exponent * 10 + int(lexical[cursor] - '0')
		cursor += 1
	}
	if exponent_negative do exponent = -exponent
	decimal_position := decimal - start + exponent
	if decimal_position <= 0 do return integer_result("0", false, XSD_INTEGER)
	builder := strings.builder_make()
	defer delete(builder.buf)
	digits := 0
	for index in start..<exponent_start {
		if lexical[index] == '.' do continue
		if digits >= decimal_position do break
		if strings.write_byte(&builder, lexical[index]) != 1 do return {state = .Out_Of_Memory}
		digits += 1
	}
	for digits < decimal_position {
		if strings.write_byte(&builder, '0') != 1 do return {state = .Out_Of_Memory}
		digits += 1
	}
	return integer_result(strings.to_string(builder), negative, XSD_INTEGER)
}

// Numeric casts preserve arbitrary magnitude. Decimal and floating inputs
// truncate toward zero, as required by the XPath numeric cast used by SPARQL.
@(private) cast_integer_result :: proc(value: rdf.Term) -> Expression_Result {
	if value.kind != .Literal do return {state = .Error}
	if value.datatype == XSD_BOOLEAN {
		boolean, valid := strconv.parse_bool(value.value)
		if !valid do return {state = .Error}
		return integer_result(boolean ? "1" : "0", false, XSD_INTEGER)
	}
	source := value
	if value.datatype == XSD_STRING do source = rdf.typed_literal(value.value, XSD_INTEGER)
	if is_floating(source) do return cast_floating_integer_result(source)
	if !is_integer(source) && !is_decimal(source) do return {state = .Error}
	negative, magnitude, _, _, valid := integer_magnitude(source)
	if !valid do return {state = .Error}
	return integer_result(magnitude, negative, XSD_INTEGER)
}

@(private) cast_decimal_result :: proc(value: rdf.Term) -> Expression_Result {
	if value.kind != .Literal do return {state = .Error}
	if value.datatype == XSD_BOOLEAN {
		boolean, valid := strconv.parse_bool(value.value)
		if !valid do return {state = .Error}
		return cast_lexical_result(boolean ? "1" : "0", XSD_DECIMAL)
	}
	source := value
	if value.datatype == XSD_STRING do source = rdf.typed_literal(value.value, XSD_DECIMAL)
	if !is_integer(source) && !is_decimal(source) do return {state = .Error}
	if _, valid := decimal_lexical(source.value, is_decimal(source)); !valid do return {state = .Error}
	return cast_lexical_result(source.value, XSD_DECIMAL)
}

@(private) cast_boolean_result :: proc(value: rdf.Term) -> Expression_Result {
	if value.kind != .Literal do return {state = .Error}
	if value.datatype == XSD_BOOLEAN {
		boolean, valid := strconv.parse_bool(value.value)
		if !valid do return {state = .Error}
		return {state = .Term, term = boolean_term(boolean)}
	}
	if is_integer(value) || is_decimal(value) {
		comparison, valid := decimal_compare(value.value, "0", is_decimal(value), false)
		if !valid do return {state = .Error}
		return {state = .Term, term = boolean_term(comparison != 0)}
	}
	if value.datatype == XSD_STRING {
		boolean, valid := strconv.parse_bool(value.value)
		if !valid do return {state = .Error}
		return {state = .Term, term = boolean_term(boolean)}
	}
	return {state = .Error}
}

@(private) cast_string_result :: proc(value: rdf.Term) -> Expression_Result {
	if value.kind != .IRI && value.kind != .Literal do return {state = .Error}
	return cast_lexical_result(value.value, XSD_STRING)
}

@(private) cast_float_result :: proc(value: rdf.Term) -> Expression_Result {
	if value.kind != .Literal do return {state = .Error}
	if value.datatype == XSD_BOOLEAN {
		boolean, valid := strconv.parse_bool(value.value)
		if !valid do return {state = .Error}
		return floating_result_f32(boolean ? 1 : 0)
	}
	if value.datatype == XSD_STRING {
		source := rdf.typed_literal(value.value, XSD_FLOAT)
		floating, valid := floating_input_f32(source)
		if !valid do return {state = .Error}
		return floating_result_f32(floating)
	}
	floating, valid := floating_input_f32(value)
	if !valid do return {state = .Error}
	return floating_result_f32(floating)
}

@(private) cast_double_result :: proc(value: rdf.Term) -> Expression_Result {
	if value.kind != .Literal do return {state = .Error}
	if value.datatype == XSD_BOOLEAN {
		boolean, valid := strconv.parse_bool(value.value)
		if !valid do return {state = .Error}
		return floating_result(boolean ? 1 : 0, XSD_DOUBLE)
	}
	if value.datatype == XSD_STRING {
		source := rdf.typed_literal(value.value, XSD_DOUBLE)
		floating, valid := floating_input_f64(source)
		if !valid do return {state = .Error}
		return floating_result(floating, XSD_DOUBLE)
	}
	floating, valid := floating_input_f64(value)
	if !valid do return {state = .Error}
	return floating_result(floating, XSD_DOUBLE)
}

// cast_temporal_result accepts an untagged/xsd:string lexical form or an
// already matching temporal literal. Parsing validates the lexical value while
// preserving its spelling: an XSD constructor changes the datatype but does
// not impose a serializer's preferred canonical form.
@(private) cast_temporal_result :: proc(value: rdf.Term, datatype: string) -> Expression_Result {
	if value.kind != .Literal || len(value.language) != 0 do return {state = .Error}
	if value.datatype != XSD_STRING && value.datatype != datatype do return {state = .Error}
	valid := false
	switch datatype {
	case XSD_DATE:
		_, valid = parse_xsd_date(value.value)
	case XSD_DATE_TIME:
		_, valid = parse_xsd_date_time(value.value)
	case XSD_TIME:
		_, valid = parse_xsd_time(value.value)
	case:
		return {state = .Error}
	}
	if !valid do return {state = .Error}
	return cast_lexical_result(value.value, datatype)
}

@(private) now_result :: proc(options: Options) -> Expression_Result {
	// evaluate validates and freezes Now_Lexical before any operator can run.
	// Re-validating here is both redundant and risks turning a valid captured
	// host-clock string into an ordinary BIND error on nested evaluation paths.
	if len(options.Now_Lexical) == 0 do return {state = .Error}
	return cast_lexical_result(options.Now_Lexical, XSD_DATE_TIME)
}

@(private) equal_uuid :: proc(left, right: uuid.Identifier) -> bool {
	for index in 0..<len(left) do if left[index] != right[index] do return false
	return true
}

@(private) uuid_result :: proc(options: Options, as_iri: bool) -> Expression_Result {
	if options.uuid_context == nil do return {state = .Error}
	if !crypto.HAS_RAND_BYTES && options.UUID_Callback == nil do return {state = .Error}
	uuid_context := options.uuid_context
	for _ in 0..<32 {
		identifier: uuid.Identifier
		ok := true
		if options.UUID_Callback != nil {
			identifier, ok = options.UUID_Callback(options.UUID_Data)
		} else {
			// The standard UUID implementation requires the active random source
			// to be cryptographic. Restore the caller context immediately after
			// generating this one identifier.
			previous_random_generator := context.random_generator
			context.random_generator = crypto.random_generator()
			identifier = uuid.generate_v4()
			context.random_generator = previous_random_generator
		}
		if !ok do return {state = .Error}
		duplicate := false
		for prior in uuid_context.issued do if equal_uuid(prior, identifier) { duplicate = true; break }
		if duplicate do continue
		if _, append_error := append(&uuid_context.issued, identifier); append_error != nil do return {state = .Out_Of_Memory}
		buffer: [36]byte
		lexical := uuid.to_string(identifier, buffer[:])
		if !as_iri do return cast_lexical_result(lexical, XSD_STRING)
		parts := [2]string{"urn:uuid:", lexical}
		iri_lexical, concatenate_error := strings.concatenate(parts[:])
		if concatenate_error != nil do return {state = .Out_Of_Memory}
		return {state = .Term, term = rdf.iri(iri_lexical), owned = iri_lexical}
	}
	return {state = .Error}
}

@(private) rand_result :: proc(options: Options) -> Expression_Result {
	value: f64
	ok := true
	if options.RAND_Callback != nil {
		value, ok = options.RAND_Callback(options.RAND_Data)
	} else {
		if !crypto.HAS_RAND_BYTES do return {state = .Error}
		// Keep the top 53 random bits, yielding every representable f64 point in
		// [0, 1) with equal probability and without rounding up to one.
		value = f64(rand.uint64(crypto.random_generator()) >> 11) / f64(1 << 53)
	}
	if !ok || math.is_nan(value) || math.is_inf(value, 0) || value < 0 || value >= 1 do return {state = .Error}
	return floating_result(value, XSD_DOUBLE)
}

@(private) temporal_date_value :: proc(value: rdf.Term) -> (XSD_Date_Value, bool) {
	if value.kind != .Literal do return {}, false
	if value.datatype == XSD_DATE do return parse_xsd_date(value.value)
	if value.datatype == XSD_DATE_TIME {
		date_time, ok := parse_xsd_date_time(value.value)
		return date_time.date, ok
	}
	return {}, false
}

@(private) temporal_date_time_value :: proc(value: rdf.Term) -> (XSD_Date_Time_Value, bool) {
	if value.kind != .Literal || value.datatype != XSD_DATE_TIME do return {}, false
	return parse_xsd_date_time(value.value)
}

@(private) temporal_time_value :: proc(value: rdf.Term) -> (XSD_Time_Value, bool) {
	if value.kind != .Literal do return {}, false
	if value.datatype == XSD_TIME do return parse_xsd_time(value.value)
	if value.datatype != XSD_DATE_TIME do return {}, false
	date_time, ok := parse_xsd_date_time(value.value)
	if !ok do return {}, false
	return {hour = date_time.hour, minute = date_time.minute, second = date_time.second, fraction = date_time.fraction, utc_offset_min = date_time.date.utc_offset_min, has_timezone = date_time.date.has_timezone}, true
}

@(private) temporal_timezone_value :: proc(value: rdf.Term) -> (utc_offset_min: int, has_timezone: bool, ok: bool) {
	if value.kind != .Literal do return
	if value.datatype == XSD_DATE {
		date, date_ok := parse_xsd_date(value.value)
		return date.utc_offset_min, date.has_timezone, date_ok
	}
	if value.datatype == XSD_DATE_TIME {
		date_time, date_time_ok := parse_xsd_date_time(value.value)
		return date_time.date.utc_offset_min, date_time.date.has_timezone, date_time_ok
	}
	if value.datatype == XSD_TIME {
		time, time_ok := parse_xsd_time(value.value)
		return time.utc_offset_min, time.has_timezone, time_ok
	}
	return
}

@(private) temporal_integer_result :: proc(value: i64) -> Expression_Result {
	negative := value < 0
	magnitude := value
	if negative do magnitude = -magnitude
	buffer: [32]byte
	return integer_result(strconv.write_int(buffer[:], magnitude, 10), negative, XSD_INTEGER)
}

@(private) seconds_result :: proc(second: int, fraction: string) -> Expression_Result {
	builder := strings.builder_make()
	defer delete(builder.buf)
	if strings.write_int(&builder, second) == 0 do return {state = .Out_Of_Memory}
	if len(fraction) != 0 {
		if strings.write_byte(&builder, '.') != 1 || strings.write_string(&builder, fraction) != len(fraction) do return {state = .Out_Of_Memory}
	}
	return cast_lexical_result(strings.to_string(builder), XSD_DECIMAL)
}

@(private) timezone_result :: proc(offset: int, has_timezone: bool) -> Expression_Result {
	if !has_timezone do return {state = .Error}
	if offset == 0 do return cast_lexical_result("PT0S", XSD_DAY_TIME_DURATION)
	minutes_offset := offset
	builder := strings.builder_make()
	defer delete(builder.buf)
	if minutes_offset < 0 {
		if strings.write_byte(&builder, '-') != 1 do return {state = .Out_Of_Memory}
		minutes_offset = -minutes_offset
	}
	if strings.write_string(&builder, "PT") != 2 do return {state = .Out_Of_Memory}
	hours := minutes_offset / 60
	minutes := minutes_offset % 60
	if hours != 0 && strings.write_int(&builder, hours) == 0 || hours != 0 && strings.write_byte(&builder, 'H') != 1 do return {state = .Out_Of_Memory}
	if minutes != 0 && strings.write_int(&builder, minutes) == 0 || minutes != 0 && strings.write_byte(&builder, 'M') != 1 do return {state = .Out_Of_Memory}
	return cast_lexical_result(strings.to_string(builder), XSD_DAY_TIME_DURATION)
}

@(private) tz_result :: proc(offset: int, has_timezone: bool) -> Expression_Result {
	if !has_timezone do return cast_lexical_result("", XSD_STRING)
	if offset == 0 do return cast_lexical_result("Z", XSD_STRING)
	minutes_offset := offset
	buffer: [6]byte
	if minutes_offset < 0 { buffer[0] = '-'; minutes_offset = -minutes_offset } else { buffer[0] = '+' }
	hours := minutes_offset / 60
	minutes := minutes_offset % 60
	buffer[1] = byte('0' + hours / 10)
	buffer[2] = byte('0' + hours % 10)
	buffer[3] = ':'
	buffer[4] = byte('0' + minutes / 10)
	buffer[5] = byte('0' + minutes % 10)
	return cast_lexical_result(string(buffer[:]), XSD_STRING)
}

@(private) temporal_component_result :: proc(value: rdf.Term, kind: algebra.Expression_Kind) -> Expression_Result {
	if kind == .Timezone || kind == .TZ {
		offset, has_timezone, ok := temporal_timezone_value(value)
		if !ok do return {state = .Error}
		if kind == .Timezone do return timezone_result(offset, has_timezone)
		return tz_result(offset, has_timezone)
	}
	if kind == .Year || kind == .Month || kind == .Day {
		date, ok := temporal_date_value(value)
		if !ok do return {state = .Error}
		calendar, calendar_error := datetime.ordinal_to_date(date.ordinal)
		if calendar_error != .None do return {state = .Error}
		if kind == .Year do return temporal_integer_result(calendar.year)
		if kind == .Month do return temporal_integer_result(i64(calendar.month))
		return temporal_integer_result(i64(calendar.day))
	}
	time, ok := temporal_time_value(value)
	if !ok do return {state = .Error}
	if kind == .Hours do return temporal_integer_result(i64(time.hour))
	if kind == .Minutes do return temporal_integer_result(i64(time.minute))
	if kind == .Seconds do return seconds_result(time.second, time.fraction)
	return {state = .Error}
}

@(private) iri_scheme_start :: #force_inline proc(value: byte) -> bool {
	return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
}

@(private) iri_scheme_continue :: #force_inline proc(value: byte) -> bool {
	return iri_scheme_start(value) || (value >= '0' && value <= '9') || value == '+' || value == '-' || value == '.'
}

@(private) iri_is_absolute :: proc(value: string) -> bool {
	if len(value) == 0 || !iri_scheme_start(value[0]) do return false
	for index in 1..<len(value) {
		if value[index] == ':' do return true
		if !iri_scheme_continue(value[index]) do return false
	}
	return false
}

// make_iri_result evaluates SPARQL IRI()/URI() against the base captured by
// algebra translation. It accepts IRI terms directly and untagged string
// literals as IRI references; result text is always evaluator-owned.
@(private) make_iri_result :: proc(value: rdf.Term, base: string) -> Expression_Result {
	if value.kind == .IRI {
		owned, clone_error := strings.clone(value.value)
		if clone_error != nil do return {state = .Out_Of_Memory}
		return {state = .Term, term = rdf.iri(owned), owned = owned}
	}
	if !is_string_literal(value) || len(value.language) != 0 do return {state = .Error}
	if iri_is_absolute(value.value) {
		owned, clone_error := strings.clone(value.value)
		if clone_error != nil do return {state = .Out_Of_Memory}
		return {state = .Term, term = rdf.iri(owned), owned = owned}
	}
	if len(base) == 0 do return {state = .Error}
	resolved, resolved_ok := turtle.resolve_iri_reference(base, value.value)
	if !resolved_ok do return {state = .Error}
	return {state = .Term, term = rdf.iri(resolved), owned = resolved}
}

// sparql_value_equal implements the currently supported SPARQL value-space
// comparisons. RDF-term-identical literals compare equal even when their
// datatype's value space is not implemented or their lexical form is invalid.
// Distinct literals in an unsupported value space remain expression errors:
// treating their lexical forms as unequal would make an unsound closed-world
// claim about a datatype the evaluator does not understand.
@(private) sparql_value_equal :: proc(left, right: rdf.Term) -> (bool, bool) {
	if left.kind != .Literal || right.kind != .Literal do return equal_term(left, right), true
	if equal_term(left, right) do return true, true
	// A language-tagged literal is never value-equal to a distinct RDF literal
	// with a different language identity or datatype. Unlike two unknown typed
	// literals, that conclusion follows directly from the RDF language-string
	// value space and does not need a datatype-specific value model.
	if len(left.language) != 0 || len(right.language) != 0 do return false, true
	if (is_integer(left) || is_decimal(left)) && (is_integer(right) || is_decimal(right)) {
		return decimal_equal(left.value, right.value, is_decimal(left), is_decimal(right))
	}
	if is_numeric(left) && is_numeric(right) {
		left_value, left_ok := floating_value(left)
		right_value, right_ok := floating_value(right)
		if !left_ok || !right_ok do return false, false
		return left_value == right_value, true
	}
	if left.datatype == XSD_BOOLEAN && right.datatype == XSD_BOOLEAN {
		left_value, left_ok := strconv.parse_bool(left.value)
		right_value, right_ok := strconv.parse_bool(right.value)
		if !left_ok || !right_ok do return false, false
		return left_value == right_value, true
	}
	if left.datatype == XSD_DATE || right.datatype == XSD_DATE {
		if left.datatype != right.datatype do return false, true
		return xsd_date_equal(left, right)
	}
	if left.datatype == XSD_DATE_TIME || right.datatype == XSD_DATE_TIME {
		if left.datatype != right.datatype do return false, true
		return xsd_date_time_equal(left, right)
	}
	if left.datatype == XSD_TIME || right.datatype == XSD_TIME {
		if left.datatype != right.datatype do return false, true
		return xsd_time_equal(left, right)
	}
	if is_string_literal(left) && is_string_literal(right) && left.datatype == right.datatype && ascii_equal_fold(left.language, right.language) do return left.value == right.value, true
	return false, false
}

@(private) exists_result :: proc(plan: ^algebra.Plan, relation: int, binding: Binding, view: dataset.View, options: Options, negate: bool) -> Expression_Result {
	nested_options := options
	nested_options.Max_Solutions = 1
	nested_options.Stop_When_Full = true
	seed := binding
	scope: Graph_Scope
	if options.expression_scope != nil do scope = options.expression_scope^
	nested, nested_error := evaluate_operator_seeded(plan, relation, view, nested_options, scope, &seed)
	if nested_error == .Numeric_Limit do return {state = .Numeric_Limit}
	if nested_error == .Out_Of_Memory do return {state = .Out_Of_Memory}
	if nested_error != .None do return {state = .Error}
	defer destroy(&nested)
	present := Solution_Count(&nested) != 0
	if negate do present = !present
	return {state = .Term, term = boolean_term(present)}
}

@(private) evaluate_expression :: proc(plan: ^algebra.Plan, expression: int, binding: Binding, options: Options) -> Expression_Result {
	node, node_ok := algebra.Expression_At(plan, expression)
	if !node_ok do return {state = .Error}
	if node.Kind == .Exists || node.Kind == .Not_Exists {
		return exists_result(plan, node.Relation, binding, options.Dataset_View, options, node.Kind == .Not_Exists)
	}
	if node.Kind == .Count || node.Kind == .Sum || node.Kind == .Average || node.Kind == .Group_Concat || node.Kind == .Min || node.Kind == .Max || node.Kind == .Sample {
		if node.Term.Kind != .Variable || node.Term.Variable < 0 || node.Term.Variable >= len(binding.values) || !binding.bound[node.Term.Variable] do return {state = .Unbound}
		return {state = .Term, term = binding.values[node.Term.Variable]}
	}
	if node.Kind == .Term {
		if node.Term.Kind == .Term do return {state = .Term, term = node.Term.Term}
		if node.Term.Kind != .Variable || node.Term.Variable < 0 || node.Term.Variable >= len(binding.values) || !binding.bound[node.Term.Variable] do return {state = .Unbound}
		return {state = .Term, term = binding.values[node.Term.Variable]}
	}
	if node.Kind == .UUID || node.Kind == .STRUUID {
		if node.Child_Count != 0 do return {state = .Error}
		return uuid_result(options, node.Kind == .UUID)
	}
	if node.Kind == .Rand {
		if node.Child_Count != 0 do return {state = .Error}
		return rand_result(options)
	}
	if node.Kind == .Year || node.Kind == .Month || node.Kind == .Day || node.Kind == .Hours || node.Kind == .Minutes || node.Kind == .Seconds || node.Kind == .Timezone || node.Kind == .TZ {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		return temporal_component_result(value.term, node.Kind)
	}
	if node.Kind == .Not {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		boolean, boolean_ok := effective_boolean(value.term)
		if !boolean_ok do return {state = .Error}
		return {state = .Term, term = boolean_term(!boolean)}
	}
	if node.Kind == .Unary_Plus || node.Kind == .Unary_Minus {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory { destroy_expression_result(&value); return {state = value.state} }
		if value.state != .Term { destroy_expression_result(&value); return {state = .Error} }
		result := unary_numeric_result(value.term, node.Kind == .Unary_Minus)
		destroy_expression_result(&value)
		return result
	}
	if node.Kind == .Absolute || node.Kind == .Ceiling || node.Kind == .Floor || node.Kind == .Round {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		if value.term.datatype == XSD_FLOAT || value.term.datatype == XSD_DOUBLE do return floating_rounding_result(value.term, node.Kind)
		return exact_rounding_result(value.term, node.Kind)
	}
	if node.Kind == .Bound {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		argument, argument_ok := algebra.Expression_At(plan, child)
		if !argument_ok || argument.Kind != .Term || argument.Term.Kind != .Variable || argument.Term.Variable < 0 || argument.Term.Variable >= len(binding.bound) do return {state = .Error}
		return {state = .Term, term = boolean_term(binding.bound[argument.Term.Variable])}
	}
	if node.Kind == .Same_Term {
		if node.Child_Count != 2 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		right_index, right_ok := algebra.Expression_Child(plan, expression, 1)
		if !left_ok || !right_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		right := evaluate_expression(plan, right_index, binding, options)
		defer destroy_expression_result(&left)
		defer destroy_expression_result(&right)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		if right.state == .Numeric_Limit || right.state == .Out_Of_Memory do return {state = right.state}
		if left.state != .Term || right.state != .Term do return {state = .Error}
		return {state = .Term, term = boolean_term(equal_term(left.term, right.term))}
	}
	if node.Kind == .Str || node.Kind == .Lower || node.Kind == .Upper || node.Kind == .Lang || node.Kind == .Datatype {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		if node.Kind == .Str {
			if value.term.kind != .IRI && value.term.kind != .Literal do return {state = .Error}
			return {state = .Term, term = rdf.literal(value.term.value)}
		}
		if value.term.kind != .Literal do return {state = .Error}
		if node.Kind == .Lower || node.Kind == .Upper {
			if !is_string_literal(value.term) || !utf8.valid_string(value.term.value) do return {state = .Error}
			mapped: string
			mapping_error: runtime.Allocator_Error
			if node.Kind == .Lower {
				mapped, mapping_error = strings.to_lower(value.term.value)
			} else {
				mapped, mapping_error = strings.to_upper(value.term.value)
			}
			if mapping_error != nil do return {state = .Out_Of_Memory}
			if len(value.term.language) != 0 do return {state = .Term, term = rdf.language_literal(mapped, value.term.language), owned = mapped}
			return {state = .Term, term = rdf.literal(mapped), owned = mapped}
		}
		if node.Kind == .Lang do return {state = .Term, term = rdf.literal(value.term.language)}
		return {state = .Term, term = rdf.iri(value.term.datatype)}
	}
	if node.Kind == .Cast_Integer || node.Kind == .Cast_Decimal || node.Kind == .Cast_Boolean || node.Kind == .Cast_String || node.Kind == .Cast_Float || node.Kind == .Cast_Double || node.Kind == .Cast_Date || node.Kind == .Cast_Date_Time || node.Kind == .Cast_Time {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		if node.Kind == .Cast_Integer do return cast_integer_result(value.term)
		if node.Kind == .Cast_Decimal do return cast_decimal_result(value.term)
		if node.Kind == .Cast_Boolean do return cast_boolean_result(value.term)
		if node.Kind == .Cast_String do return cast_string_result(value.term)
		if node.Kind == .Cast_Float do return cast_float_result(value.term)
		if node.Kind == .Cast_Date do return cast_temporal_result(value.term, XSD_DATE)
		if node.Kind == .Cast_Date_Time do return cast_temporal_result(value.term, XSD_DATE_TIME)
		if node.Kind == .Cast_Time do return cast_temporal_result(value.term, XSD_TIME)
		return cast_double_result(value.term)
	}
	if node.Kind == .Make_IRI {
		if node.Child_Count != 1 || node.Term.Kind != .Term || node.Term.Term.kind != .IRI do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		return make_iri_result(value.term, node.Term.Term.value)
	}
	if node.Kind == .Is_IRI || node.Kind == .Is_Blank || node.Kind == .Is_Literal || node.Kind == .Is_Numeric {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		matches := node.Kind == .Is_IRI && value.term.kind == .IRI ||
			node.Kind == .Is_Blank && value.term.kind == .Blank_Node ||
			node.Kind == .Is_Literal && value.term.kind == .Literal ||
			node.Kind == .Is_Numeric && (is_integer(value.term) || is_decimal(value.term) || is_floating(value.term))
		return {state = .Term, term = boolean_term(matches)}
	}
	if node.Kind == .Lang_Matches {
		if node.Child_Count != 2 do return {state = .Error}
		language_index, language_ok := algebra.Expression_Child(plan, expression, 0)
		range_index, range_ok := algebra.Expression_Child(plan, expression, 1)
		if !language_ok || !range_ok do return {state = .Error}
		language := evaluate_expression(plan, language_index, binding, options)
		range := evaluate_expression(plan, range_index, binding, options)
		defer destroy_expression_result(&language)
		defer destroy_expression_result(&range)
		if language.state == .Numeric_Limit || language.state == .Out_Of_Memory do return {state = language.state}
		if range.state == .Numeric_Limit || range.state == .Out_Of_Memory do return {state = range.state}
		if language.state != .Term || range.state != .Term || language.term.kind != .Literal || range.term.kind != .Literal || len(language.term.language) != 0 || len(range.term.language) != 0 do return {state = .Error}
		return {state = .Term, term = boolean_term(language_range_matches(language.term.value, range.term.value))}
	}
	if node.Kind == .In || node.Kind == .Not_In {
		if node.Child_Count < 1 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		if !left_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		defer destroy_expression_result(&left)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		if left.state != .Term do return {state = .Error}
		has_error := false
		for child_offset in 1..<node.Child_Count {
			right_index, right_index_ok := algebra.Expression_Child(plan, expression, child_offset)
			if !right_index_ok do return {state = .Error}
			right := evaluate_expression(plan, right_index, binding, options)
			if right.state == .Numeric_Limit || right.state == .Out_Of_Memory {
				state := right.state
				destroy_expression_result(&right)
				return {state = state}
			}
			if right.state != .Term {
				destroy_expression_result(&right)
				has_error = true
				continue
			}
			equal, equal_ok := sparql_value_equal(left.term, right.term)
			destroy_expression_result(&right)
			if !equal_ok {
				has_error = true
				continue
			}
			if equal do return {state = .Term, term = boolean_term(node.Kind == .In)}
		}
		if has_error do return {state = .Error}
		return {state = .Term, term = boolean_term(node.Kind == .Not_In)}
	}
	if node.Kind == .If {
		if node.Child_Count != 3 do return {state = .Error}
		condition_index, condition_ok := algebra.Expression_Child(plan, expression, 0)
		if !condition_ok do return {state = .Error}
		condition := evaluate_expression(plan, condition_index, binding, options)
		defer destroy_expression_result(&condition)
		if condition.state == .Numeric_Limit || condition.state == .Out_Of_Memory do return {state = condition.state}
		if condition.state != .Term do return {state = .Error}
		truth, truth_ok := effective_boolean(condition.term)
		if !truth_ok do return {state = .Error}
		branch_index, branch_ok := algebra.Expression_Child(plan, expression, 2)
		if truth do branch_index, branch_ok = algebra.Expression_Child(plan, expression, 1)
		if !branch_ok do return {state = .Error}
		return evaluate_expression(plan, branch_index, binding, options)
	}
	if node.Kind == .Coalesce {
		for child_offset in 0..<node.Child_Count {
			child, child_ok := algebra.Expression_Child(plan, expression, child_offset)
			if !child_ok do return {state = .Error}
			value := evaluate_expression(plan, child, binding, options)
			if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return value
			if value.state == .Term do return value
			destroy_expression_result(&value)
		}
		return {state = .Error}
	}
	if node.Kind == .Concat {
		builder := strings.builder_make()
		defer delete(builder.buf)
		all_same_language := true
		has_language := false
		language := ""
		for child_offset in 0..<node.Child_Count {
			child, child_ok := algebra.Expression_Child(plan, expression, child_offset)
			if !child_ok do return {state = .Error}
			value := evaluate_expression(plan, child, binding, options)
			if value.state == .Numeric_Limit || value.state == .Out_Of_Memory {
				state := value.state
				destroy_expression_result(&value)
				return {state = state}
			}
			if value.state != .Term || !is_string_literal(value.term) {
				destroy_expression_result(&value)
				return {state = .Error}
			}
			if strings.write_string(&builder, value.term.value) != len(value.term.value) {
				destroy_expression_result(&value)
				return {state = .Out_Of_Memory}
			}
			if len(value.term.language) == 0 {
				all_same_language = false
			} else if !has_language {
				has_language = true
				language = value.term.language
			} else if language != value.term.language {
				all_same_language = false
			}
			destroy_expression_result(&value)
		}
		lexical, clone_error := strings.clone(strings.to_string(builder))
		if clone_error != nil do return {state = .Out_Of_Memory}
		if all_same_language && has_language do return {state = .Term, term = rdf.language_literal(lexical, language), owned = lexical}
		return {state = .Term, term = rdf.literal(lexical), owned = lexical}
	}
	if node.Kind == .Str_Starts || node.Kind == .Str_Ends || node.Kind == .Contains {
		if node.Child_Count != 2 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		right_index, right_ok := algebra.Expression_Child(plan, expression, 1)
		if !left_ok || !right_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		right := evaluate_expression(plan, right_index, binding, options)
		defer destroy_expression_result(&left)
		defer destroy_expression_result(&right)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		if right.state == .Numeric_Limit || right.state == .Out_Of_Memory do return {state = right.state}
		if left.state != .Term || right.state != .Term || !compatible_string_arguments(left.term, right.term) do return {state = .Error}
		matches := false
		if node.Kind == .Str_Starts do matches = strings.has_prefix(left.term.value, right.term.value)
		if node.Kind == .Str_Ends do matches = strings.has_suffix(left.term.value, right.term.value)
		if node.Kind == .Contains do matches = contains_bytes(left.term.value, right.term.value)
		return {state = .Term, term = boolean_term(matches)}
	}
	if node.Kind == .Regex {
		if node.Child_Count != 2 && node.Child_Count != 3 do return {state = .Error}
		text_index, text_ok := algebra.Expression_Child(plan, expression, 0)
		pattern_index, pattern_ok := algebra.Expression_Child(plan, expression, 1)
		if !text_ok || !pattern_ok do return {state = .Error}
		text := evaluate_expression(plan, text_index, binding, options)
		pattern := evaluate_expression(plan, pattern_index, binding, options)
		defer destroy_expression_result(&text)
		defer destroy_expression_result(&pattern)
		if text.state == .Numeric_Limit || text.state == .Out_Of_Memory do return {state = text.state}
		if pattern.state == .Numeric_Limit || pattern.state == .Out_Of_Memory do return {state = pattern.state}
		if text.state != .Term || pattern.state != .Term do return {state = .Error}
		if node.Child_Count == 2 do return regex_result(text.term, pattern.term)
		flag_index, flag_ok := algebra.Expression_Child(plan, expression, 2)
		if !flag_ok do return {state = .Error}
		flag_value := evaluate_expression(plan, flag_index, binding, options)
		defer destroy_expression_result(&flag_value)
		if flag_value.state == .Numeric_Limit || flag_value.state == .Out_Of_Memory do return {state = flag_value.state}
		if flag_value.state != .Term do return {state = .Error}
		return regex_result(text.term, pattern.term, &flag_value.term)
	}
	if node.Kind == .Replace {
		if node.Child_Count != 3 && node.Child_Count != 4 do return {state = .Error}
		text_index, text_ok := algebra.Expression_Child(plan, expression, 0)
		pattern_index, pattern_ok := algebra.Expression_Child(plan, expression, 1)
		replacement_index, replacement_ok := algebra.Expression_Child(plan, expression, 2)
		if !text_ok || !pattern_ok || !replacement_ok do return {state = .Error}
		text := evaluate_expression(plan, text_index, binding, options)
		pattern := evaluate_expression(plan, pattern_index, binding, options)
		replacement := evaluate_expression(plan, replacement_index, binding, options)
		defer destroy_expression_result(&text)
		defer destroy_expression_result(&pattern)
		defer destroy_expression_result(&replacement)
		if text.state == .Numeric_Limit || text.state == .Out_Of_Memory do return {state = text.state}
		if pattern.state == .Numeric_Limit || pattern.state == .Out_Of_Memory do return {state = pattern.state}
		if replacement.state == .Numeric_Limit || replacement.state == .Out_Of_Memory do return {state = replacement.state}
		if text.state != .Term || pattern.state != .Term || replacement.state != .Term do return {state = .Error}
		if node.Child_Count == 3 do return replace_result(text.term, pattern.term, replacement.term)
		flag_index, flag_ok := algebra.Expression_Child(plan, expression, 3)
		if !flag_ok do return {state = .Error}
		flag_value := evaluate_expression(plan, flag_index, binding, options)
		defer destroy_expression_result(&flag_value)
		if flag_value.state == .Numeric_Limit || flag_value.state == .Out_Of_Memory do return {state = flag_value.state}
		if flag_value.state != .Term do return {state = .Error}
		return replace_result(text.term, pattern.term, replacement.term, &flag_value.term)
	}
	if node.Kind == .Str_Length {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term || !is_string_literal(value.term) do return {state = .Error}
		buffer: [32]byte
		lexical := strconv.write_int(buffer[:], i64(utf8.rune_count_in_string(value.term.value)), 10)
		owned, clone_error := strings.clone(lexical)
		if clone_error != nil do return {state = .Out_Of_Memory}
		return {state = .Term, term = rdf.typed_literal(owned, XSD_INTEGER), owned = owned}
	}
	if node.Kind == .Substring {
		if node.Child_Count != 2 && node.Child_Count != 3 do return {state = .Error}
		string_index, string_ok := algebra.Expression_Child(plan, expression, 0)
		start_index, start_ok := algebra.Expression_Child(plan, expression, 1)
		if !string_ok || !start_ok do return {state = .Error}
		value := evaluate_expression(plan, string_index, binding, options)
		start := evaluate_expression(plan, start_index, binding, options)
		defer destroy_expression_result(&value)
		defer destroy_expression_result(&start)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if start.state == .Numeric_Limit || start.state == .Out_Of_Memory do return {state = start.state}
		if value.state != .Term || start.state != .Term do return {state = .Error}
		if node.Child_Count == 2 do return substring_result(value.term, start.term)
		length_index, length_ok := algebra.Expression_Child(plan, expression, 2)
		if !length_ok do return {state = .Error}
		length := evaluate_expression(plan, length_index, binding, options)
		defer destroy_expression_result(&length)
		if length.state == .Numeric_Limit || length.state == .Out_Of_Memory do return {state = length.state}
		if length.state != .Term do return {state = .Error}
		return substring_result(value.term, start.term, &length.term)
	}
	if node.Kind == .Encode_For_URI {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		return encode_for_uri_result(value.term)
	}
	if node.Kind == .MD5 || node.Kind == .SHA1 || node.Kind == .SHA256 || node.Kind == .SHA384 || node.Kind == .SHA512 {
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		return hex_digest_result(value.term, node.Kind)
	}
	if node.Kind == .Str_Before || node.Kind == .Str_After {
		if node.Child_Count != 2 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		right_index, right_ok := algebra.Expression_Child(plan, expression, 1)
		if !left_ok || !right_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		right := evaluate_expression(plan, right_index, binding, options)
		defer destroy_expression_result(&left)
		defer destroy_expression_result(&right)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		if right.state == .Numeric_Limit || right.state == .Out_Of_Memory do return {state = right.state}
		if left.state != .Term || right.state != .Term || !compatible_string_arguments(left.term, right.term) do return {state = .Error}
		index := index_bytes(left.term.value, right.term.value)
		// SPARQL returns a simple/xsd:string empty literal when the lexical
		// delimiter is absent, rather than preserving the first argument's tag.
		if index < 0 do return string_result_like(rdf.literal(""), "")
		if node.Kind == .Str_Before do return string_result_like(left.term, left.term.value[:index])
		return string_result_like(left.term, left.term.value[index + len(right.term.value):])
	}
	if node.Kind == .Str_Datatype {
		if node.Child_Count != 2 do return {state = .Error}
		lexical_index, lexical_ok := algebra.Expression_Child(plan, expression, 0)
		datatype_index, datatype_ok := algebra.Expression_Child(plan, expression, 1)
		if !lexical_ok || !datatype_ok do return {state = .Error}
		lexical := evaluate_expression(plan, lexical_index, binding, options)
		datatype := evaluate_expression(plan, datatype_index, binding, options)
		defer destroy_expression_result(&lexical)
		defer destroy_expression_result(&datatype)
		if lexical.state == .Numeric_Limit || lexical.state == .Out_Of_Memory do return {state = lexical.state}
		if datatype.state == .Numeric_Limit || datatype.state == .Out_Of_Memory do return {state = datatype.state}
		if lexical.state != .Term || datatype.state != .Term || !is_string_literal(lexical.term) || len(lexical.term.language) != 0 || datatype.term.kind != .IRI do return {state = .Error}
		owned, clone_error := strings.clone(lexical.term.value)
		if clone_error != nil do return {state = .Out_Of_Memory}
		return {state = .Term, term = rdf.typed_literal(owned, datatype.term.value), owned = owned}
	}
	if node.Kind == .Str_Language {
		if node.Child_Count != 2 do return {state = .Error}
		lexical_index, lexical_ok := algebra.Expression_Child(plan, expression, 0)
		language_index, language_ok := algebra.Expression_Child(plan, expression, 1)
		if !lexical_ok || !language_ok do return {state = .Error}
		lexical := evaluate_expression(plan, lexical_index, binding, options)
		language := evaluate_expression(plan, language_index, binding, options)
		defer destroy_expression_result(&lexical)
		defer destroy_expression_result(&language)
		if lexical.state == .Numeric_Limit || lexical.state == .Out_Of_Memory do return {state = lexical.state}
		if language.state == .Numeric_Limit || language.state == .Out_Of_Memory do return {state = language.state}
		if lexical.state != .Term || language.state != .Term || !is_plain_string_literal(lexical.term) || !is_plain_string_literal(language.term) do return {state = .Error}
		return language_literal_result(lexical.term.value, language.term.value)
	}
	if node.Kind == .BNode {
		if options.bnode_context == nil do return {state = .Error}
		if node.Child_Count == 0 do return fresh_bnode(options.bnode_context)
		if node.Child_Count != 1 do return {state = .Error}
		child, child_ok := algebra.Expression_Child(plan, expression, 0)
		if !child_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		defer destroy_expression_result(&value)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory do return {state = value.state}
		if value.state != .Term do return {state = .Error}
		return bnode_string_result(options.bnode_context, binding, value.term)
	}
	if node.Kind == .Now {
		if node.Child_Count != 0 do return {state = .Error}
		return now_result(options)
	}
	if node.Kind == .Add || node.Kind == .Subtract || node.Kind == .Multiply || node.Kind == .Divide {
		if node.Child_Count != 2 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		right_index, right_ok := algebra.Expression_Child(plan, expression, 1)
		if !left_ok || !right_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		defer destroy_expression_result(&left)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		if left.state != .Term do return {state = .Error}
		right := evaluate_expression(plan, right_index, binding, options)
		defer destroy_expression_result(&right)
		if right.state == .Numeric_Limit || right.state == .Out_Of_Memory do return {state = right.state}
		if right.state != .Term do return {state = .Error}
		if node.Kind == .Divide {
			if is_floating(left.term) || is_floating(right.term) do return floating_divide_result(left.term, right.term)
			return exact_divide_result(left.term, right.term, options.Max_Numeric_Digits, options.Decimal_Division_Precision)
		}
		if is_floating(left.term) || is_floating(right.term) do return floating_binary_result(left.term, right.term, node.Kind)
		return exact_binary_result(left.term, right.term, node.Kind, options.Max_Numeric_Digits)
	}
	if node.Kind == .And || node.Kind == .Or {
		if node.Child_Count != 2 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		right_index, right_ok := algebra.Expression_Child(plan, expression, 1)
		if !left_ok || !right_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		defer destroy_expression_result(&left)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		left_boolean := false
		left_boolean_ok := left.state == .Term
		if left_boolean_ok do left_boolean, left_boolean_ok = effective_boolean(left.term)
		if node.Kind == .And && left_boolean_ok && !left_boolean do return {state = .Term, term = boolean_term(false)}
		if node.Kind == .Or && left_boolean_ok && left_boolean do return {state = .Term, term = boolean_term(true)}

		right := evaluate_expression(plan, right_index, binding, options)
		defer destroy_expression_result(&right)
		if right.state == .Numeric_Limit || right.state == .Out_Of_Memory do return {state = right.state}
		right_boolean := false
		right_boolean_ok := right.state == .Term
		if right_boolean_ok do right_boolean, right_boolean_ok = effective_boolean(right.term)
		if !left_boolean_ok {
			if node.Kind == .And && right_boolean_ok && !right_boolean do return {state = .Term, term = boolean_term(false)}
			if node.Kind == .Or && right_boolean_ok && right_boolean do return {state = .Term, term = boolean_term(true)}
			return {state = .Error}
		}
		if !right_boolean_ok do return {state = .Error}
		return {state = .Term, term = boolean_term(right_boolean)}
	}
	if node.Kind == .Equal || node.Kind == .Not_Equal || node.Kind == .Less || node.Kind == .Less_Or_Equal || node.Kind == .Greater || node.Kind == .Greater_Or_Equal {
		if node.Child_Count != 2 do return {state = .Error}
		left_index, left_ok := algebra.Expression_Child(plan, expression, 0)
		right_index, right_ok := algebra.Expression_Child(plan, expression, 1)
		if !left_ok || !right_ok do return {state = .Error}
		left := evaluate_expression(plan, left_index, binding, options)
		right := evaluate_expression(plan, right_index, binding, options)
		defer destroy_expression_result(&left)
		defer destroy_expression_result(&right)
		if left.state == .Numeric_Limit || left.state == .Out_Of_Memory do return {state = left.state}
		if right.state == .Numeric_Limit || right.state == .Out_Of_Memory do return {state = right.state}
		if left.state != .Term || right.state != .Term do return {state = .Error}
		if node.Kind == .Equal || node.Kind == .Not_Equal {
			equal, comparison_ok := sparql_value_equal(left.term, right.term)
			if !comparison_ok do return {state = .Error}
			if node.Kind == .Not_Equal do equal = !equal
			return {state = .Term, term = boolean_term(equal)}
		}
		comparison, comparison_ok := sparql_relational_compare(left.term, right.term)
		if !comparison_ok do return {state = .Error}
		matches := node.Kind == .Less && comparison < 0 ||
			node.Kind == .Less_Or_Equal && comparison <= 0 ||
			node.Kind == .Greater && comparison > 0 ||
			node.Kind == .Greater_Or_Equal && comparison >= 0
		return {state = .Term, term = boolean_term(matches)}
	}
	return {state = .Error}
}

@(private) Order_Key :: struct {
	state: Expression_State,
	term:  rdf.Term,
	owned: string,
}

@(private) destroy_order_keys :: proc(keys: ^[dynamic]Order_Key) {
	for key in keys^ do if len(key.owned) != 0 do delete(key.owned)
	delete(keys^)
}

// order_term_category follows SPARQL's defined broad ordering: blank nodes,
// IRIs, then literals. Expression errors and unbound values are handled by the
// caller as the lower category. Pairs without a defined SPARQL value ordering
// deliberately compare equal and retain their input order.
@(private) order_term_category :: proc(value: rdf.Term) -> int {
	#partial switch value.kind {
	case .Blank_Node: return 0
	case .IRI: return 1
	case .Literal: return 2
	}
	return 3
}

@(private) order_boolean_compare :: proc(left, right: rdf.Term) -> (int, bool) {
	if left.datatype != XSD_BOOLEAN || right.datatype != XSD_BOOLEAN do return 0, false
	left_value, left_ok := strconv.parse_bool(left.value)
	right_value, right_ok := strconv.parse_bool(right.value)
	if !left_ok || !right_ok do return 0, false
	if left_value == right_value do return 0, true
	return left_value ? 1 : -1, true
}

@(private) order_literal_compare :: proc(left, right: rdf.Term) -> int {
	if is_numeric(left) && is_numeric(right) {
		comparison, comparable := sparql_numeric_compare(left, right)
		if comparable do return comparison
		return 0
	}
	if comparison, comparable := order_boolean_compare(left, right); comparable do return comparison
	if left.datatype == XSD_DATE && right.datatype == XSD_DATE {
		comparison, comparable := xsd_date_compare(left, right)
		if comparable do return comparison
		return 0
	}
	if left.datatype == XSD_DATE_TIME && right.datatype == XSD_DATE_TIME {
		comparison, comparable := xsd_date_time_compare(left, right)
		if comparable do return comparison
		return 0
	}
	if left.datatype == XSD_TIME && right.datatype == XSD_TIME {
		comparison, comparable := xsd_time_compare(left, right)
		if comparable do return comparison
		return 0
	}
	// Simple literals and xsd:string literals share their lexical ordering.
	if left.datatype == XSD_STRING && right.datatype == XSD_STRING && len(left.language) == 0 && len(right.language) == 0 do return strings.compare(left.value, right.value)
	return 0
}

@(private) order_term_compare :: proc(left, right: rdf.Term) -> int {
	left_category := order_term_category(left)
	right_category := order_term_category(right)
	if left_category < right_category do return -1
	if left_category > right_category do return 1
	#partial switch left.kind {
	case .IRI:
		return strings.compare(left.value, right.value)
	case .Literal:
		return order_literal_compare(left, right)
	case .Blank_Node:
		// Relative blank-node ordering is intentionally unspecified by SPARQL.
		return 0
	}
	return 0
}

@(private) order_key_compare :: proc(left, right: Order_Key) -> int {
	left_term := left.state == .Term
	right_term := right.state == .Term
	if !left_term && !right_term do return 0
	if !left_term do return -1
	if !right_term do return 1
	return order_term_compare(left.term, right.term)
}

@(private) ordered_row_less :: proc(keys: []Order_Key, condition_count, left, right: int, plan: ^algebra.Plan, operator: int) -> (bool, Error_Code) {
	for condition in 0..<condition_count {
		_, descending, condition_ok := algebra.Order_Condition(plan, operator, condition)
		if !condition_ok do return false, .Unsupported_Plan
		comparison := order_key_compare(keys[left * condition_count + condition], keys[right * condition_count + condition])
		if comparison == 0 do continue
		if descending do comparison = -comparison
		return comparison < 0, .None
	}
	return false, .None
}

// order_relation materializes expression keys once, then uses a stable
// insertion sort over the bounded solution relation. Stability is important:
// SPARQL leaves ties unspecified, while preserving input order keeps this
// engine deterministic without inventing an RDF-term ordering for them.
@(private) order_relation :: proc(plan: ^algebra.Plan, operator: int, source: ^Result, options: Options) -> Error_Code {
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok || node.Kind != .Order || node.Child_Count != 1 || node.Order_Count <= 0 do return .Unsupported_Plan
	keys := make([dynamic]Order_Key)
	defer destroy_order_keys(&keys)
	for row in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) do return .Cancelled
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok do return .Unsupported_Plan
		for condition in 0..<node.Order_Count {
			expression, _, condition_ok := algebra.Order_Condition(plan, operator, condition)
			if !condition_ok do return .Unsupported_Plan
			value := evaluate_expression(plan, expression, binding, options)
			if value.state == .Numeric_Limit { destroy_expression_result(&value); return .Numeric_Limit }
			if value.state == .Out_Of_Memory { destroy_expression_result(&value); return .Out_Of_Memory }
			key := Order_Key{state = value.state, term = value.term, owned = value.owned}
			value.owned = ""
			if _, append_error := append(&keys, key); append_error != nil { if len(key.owned) != 0 do delete(key.owned); return .Out_Of_Memory }
		}
	}
	order := make([dynamic]int)
	defer delete(order)
	for row in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) do return .Cancelled
		if _, append_error := append(&order, row); append_error != nil do return .Out_Of_Memory
		position := len(order) - 1
		for position > 0 {
			if Cancellation_Requested(options) do return .Cancelled
			less, less_error := ordered_row_less(keys[:], node.Order_Count, row, order[position - 1], plan, operator)
			if less_error != .None do return less_error
			if !less do break
			order[position] = order[position - 1]
			position -= 1
		}
		order[position] = row
	}
	reordered := make([dynamic]Solution)
	for row in order {
		if Cancellation_Requested(options) do return .Cancelled
		if _, append_error := append(&reordered, source.solutions[row]); append_error != nil { delete(reordered); return .Out_Of_Memory }
	}
	delete(source.solutions)
	source.solutions = reordered
	return .None
}

@(private) filter_relation :: proc(plan: ^algebra.Plan, source: ^Result, expression: int, options: Options) -> (Result, Error_Code) {
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for index in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		binding, binding_ok := binding_from_solution(source, index)
		if !binding_ok { destroy(&result); return {}, .Unsupported_Plan }
		value := evaluate_expression(plan, expression, binding, options)
		if value.state == .Numeric_Limit { destroy_expression_result(&value); destroy(&result); return {}, .Numeric_Limit }
		if value.state == .Out_Of_Memory { destroy_expression_result(&value); destroy(&result); return {}, .Out_Of_Memory }
		if value.state != .Term { destroy_expression_result(&value); continue }
		keep, keep_ok := effective_boolean(value.term)
		if !keep_ok || !keep { destroy_expression_result(&value); continue }
		if error := append_solution(&result, binding, options.Max_Solutions); error != .None { destroy_expression_result(&value); destroy(&result); return {}, error }
		destroy_expression_result(&value)
	}
	return result, .None
}

@(private) extend_relation :: proc(plan: ^algebra.Plan, source: ^Result, expression, variable: int, options: Options) -> (Result, Error_Code) {
	if variable < 0 || variable >= algebra.Variable_Count(plan) do return {}, .Unsupported_Plan
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for index in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		binding, binding_ok := binding_from_solution(source, index)
		if !binding_ok { destroy(&result); return {}, .Unsupported_Plan }
		extended, clone_error := clone_binding(binding)
		if clone_error != .None { destroy(&result); return {}, clone_error }
		value := evaluate_expression(plan, expression, binding, options)
		if value.state == .Numeric_Limit { destroy_expression_result(&value); destroy_binding(&extended); destroy(&result); return {}, .Numeric_Limit }
		if value.state == .Out_Of_Memory { destroy_expression_result(&value); destroy_binding(&extended); destroy(&result); return {}, .Out_Of_Memory }
		if value.state == .Term && !extended.bound[variable] {
			extended.values[variable] = value.term
			extended.bound[variable] = true
		}
		if error := append_solution(&result, extended, options.Max_Solutions); error != .None { destroy_expression_result(&value); destroy_binding(&extended); destroy(&result); return {}, error }
		destroy_expression_result(&value)
		destroy_binding(&extended)
	}
	return result, .None
}

// project_relation removes every non-selected binding from each solution. The
// copied result is intentional: source bindings may be shared by a recursive
// relation, while Project establishes a SPARQL subquery visibility boundary.
@(private) project_relation :: proc(plan: ^algebra.Plan, operator: int, source: ^Result, options: Options) -> (Result, Error_Code) {
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok || node.Kind != .Project do return {}, .Unsupported_Plan
	visible := make([dynamic]bool)
	defer delete(visible)
	for _ in 0..<algebra.Variable_Count(plan) {
		if _, append_error := append(&visible, false); append_error != nil do return {}, .Out_Of_Memory
	}
	for index in 0..<node.Projection_Variable_Count {
		variable, variable_ok := algebra.Projection_Variable(plan, operator, index)
		if !variable_ok || variable < 0 || variable >= len(visible) do return {}, .Unsupported_Plan
		visible[variable] = true
	}
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for index in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		binding, binding_ok := binding_from_solution(source, index)
		if !binding_ok { destroy(&result); return {}, .Unsupported_Plan }
		projected, clone_error := clone_binding(binding)
		if clone_error != .None { destroy(&result); return {}, clone_error }
		for variable in 0..<len(projected.bound) {
			if visible[variable] do continue
			projected.values[variable] = {}
			projected.bound[variable] = false
		}
		if error := append_solution(&result, projected, options.Max_Solutions); error != .None { destroy_binding(&projected); destroy(&result); return {}, error }
		destroy_binding(&projected)
	}
	return result, .None
}

@(private) equal_bindings :: proc(left, right: Binding) -> bool {
	if len(left.values) != len(right.values) do return false
	for variable in 0..<len(left.values) {
		if left.bound[variable] != right.bound[variable] do return false
		if left.bound[variable] && !equal_term(left.values[variable], right.values[variable]) do return false
	}
	return true
}

// distinct_relation is intentionally applied after Project for a subquery, so
// equality observes only the bindings that its SELECT exposes.
@(private) distinct_relation :: proc(plan: ^algebra.Plan, source: ^Result, options: Options) -> (Result, Error_Code) {
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for row in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok { destroy(&result); return {}, .Unsupported_Plan }
		duplicate := false
		for prior in 0..<Solution_Count(&result) {
			if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
			prior_binding, prior_ok := binding_from_solution(&result, prior)
			if !prior_ok { destroy(&result); return {}, .Unsupported_Plan }
			if equal_bindings(binding, prior_binding) { duplicate = true; break }
		}
		if duplicate do continue
		if error := append_solution(&result, binding, options.Max_Solutions); error != .None { destroy(&result); return {}, error }
	}
	return result, .None
}

@(private) slice_relation :: proc(plan: ^algebra.Plan, operator: int, source: ^Result, options: Options) -> (Result, Error_Code) {
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok || node.Kind != .Slice || node.Slice_Offset < 0 || node.Slice_Limit < 0 do return {}, .Unsupported_Plan
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	end := Solution_Count(source)
	start := node.Slice_Offset
	if start >= end do return result, .None
	if node.Has_Slice_Limit && node.Slice_Limit < end - start do end = start + node.Slice_Limit
	for row in start..<end {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok { destroy(&result); return {}, .Unsupported_Plan }
		if error := append_solution(&result, binding, options.Max_Solutions); error != .None { destroy(&result); return {}, error }
	}
	return result, .None
}

@(private) Group_Bucket :: struct {
	representative: Binding,
	key_values:     [dynamic]rdf.Term,
	key_bound:      [dynamic]bool,
	key_owned:      [dynamic]string,
	members:        [dynamic]int,
}

@(private) destroy_group_bucket :: proc(bucket: ^Group_Bucket) {
	destroy_binding(&bucket.representative)
	delete(bucket.key_values)
	delete(bucket.key_bound)
	for value in bucket.key_owned do delete(value)
	delete(bucket.key_owned)
	delete(bucket.members)
	bucket^ = {}
}

@(private) destroy_owned_strings :: proc(owned: ^[dynamic]string) {
	for value in owned^ do delete(value)
	delete(owned^)
}

// retain_expression_term gives a DISTINCT cache an independent lexical copy.
// The evaluated value may still be consumed by an aggregate accumulator.
@(private) retain_expression_term :: proc(owned: ^[dynamic]string, value: ^Expression_Result, stored: ^rdf.Term) -> Error_Code {
	if len(value.owned) == 0 do return .None
	copy, clone_error := strings.clone(value.owned)
	if clone_error != nil do return .Out_Of_Memory
	if _, append_error := append(owned, copy); append_error != nil { delete(copy); return .Out_Of_Memory }
	stored.value = copy
	return .None
}

@(private) group_key_matches :: proc(bucket: ^Group_Bucket, values: []rdf.Term, bound: []bool) -> bool {
	if len(bucket.key_values) != len(values) || len(bucket.key_bound) != len(bound) do return false
	for index in 0..<len(values) {
		if bucket.key_bound[index] != bound[index] do return false
		if bound[index] && !equal_term(bucket.key_values[index], values[index]) do return false
	}
	return true
}

@(private) count_group :: proc(plan: ^algebra.Plan, aggregate: int, source: ^Result, members: []int, options: Options) -> Expression_Result {
	node, node_ok := algebra.Expression_At(plan, aggregate)
	if !node_ok || node.Kind != .Count do return {state = .Error}
	seen := make([dynamic]rdf.Term)
	defer delete(seen)
	seen_owned := make([dynamic]string)
	defer destroy_owned_strings(&seen_owned)
	seen_rows := make([dynamic]int)
	defer delete(seen_rows)
	count := 0
	for row in members {
		if Cancellation_Requested(options) do return {state = .Cancelled}
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok do return {state = .Error}
		include := node.Child_Count == 0
		value: Expression_Result
		if node.Child_Count == 1 {
			child, child_ok := algebra.Expression_Child(plan, aggregate, 0)
			if !child_ok do return {state = .Error}
			value = evaluate_expression(plan, child, binding, options)
			if value.state == .Numeric_Limit || value.state == .Out_Of_Memory { destroy_expression_result(&value); return {state = value.state} }
			include = value.state == .Term
		}
		if include && node.Uses_Distinct && node.Child_Count == 0 {
			duplicate := false
			for prior_row in seen_rows {
				if Cancellation_Requested(options) do return {state = .Cancelled}
				prior, prior_ok := binding_from_solution(source, prior_row)
				if !prior_ok do return {state = .Error}
				if equal_bindings(binding, prior) { duplicate = true; break }
			}
			if !duplicate {
				if _, append_error := append(&seen_rows, row); append_error != nil do return {state = .Out_Of_Memory}
			} else {
				include = false
			}
		} else if include && node.Uses_Distinct {
			duplicate := false
			for prior in seen {
				if Cancellation_Requested(options) { destroy_expression_result(&value); return {state = .Cancelled} }
				if equal_term(prior, value.term) { duplicate = true; break }
			}
			if !duplicate {
				if _, append_error := append(&seen, value.term); append_error != nil { destroy_expression_result(&value); return {state = .Out_Of_Memory} }
				if ownership_error := retain_expression_term(&seen_owned, &value, &seen[len(seen) - 1]); ownership_error != .None { destroy_expression_result(&value); return {state = ownership_error == .Out_Of_Memory ? .Out_Of_Memory : .Error} }
			} else {
				include = false
			}
		}
		if include do count += 1
		destroy_expression_result(&value)
	}
	buffer: [64]byte
	return integer_result(strconv.write_int(buffer[:], i64(count), 10), false, XSD_INTEGER)
}

// numeric_group shares SUM and AVG's accumulator semantics. Expression errors
// are omitted from the multiset; a successfully evaluated non-numeric term is
// an aggregate type error. The accumulator deliberately reuses the ordinary
// SPARQL arithmetic helpers so promotion and numeric resource limits stay
// identical in scalar and aggregate contexts.
@(private) numeric_group :: proc(plan: ^algebra.Plan, aggregate: int, source: ^Result, members: []int, options: Options) -> (Expression_Result, int) {
	node, node_ok := algebra.Expression_At(plan, aggregate)
	if !node_ok || (node.Kind != .Sum && node.Kind != .Average) || node.Child_Count != 1 do return {state = .Error}, 0
	child, child_ok := algebra.Expression_Child(plan, aggregate, 0)
	if !child_ok do return {state = .Error}, 0
	seen := make([dynamic]rdf.Term)
	defer delete(seen)
	seen_owned := make([dynamic]string)
	defer destroy_owned_strings(&seen_owned)
	found := false
	count := 0
	sum: Expression_Result
	for row in members {
		if Cancellation_Requested(options) { destroy_expression_result(&sum); return {state = .Cancelled}, 0 }
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok { destroy_expression_result(&sum); return {state = .Error}, 0 }
		value := evaluate_expression(plan, child, binding, options)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory { destroy_expression_result(&value); destroy_expression_result(&sum); return {state = value.state}, 0 }
		if value.state != .Term { destroy_expression_result(&value); continue }
		if node.Uses_Distinct {
			duplicate := false
			for prior in seen {
				if Cancellation_Requested(options) { destroy_expression_result(&value); destroy_expression_result(&sum); return {state = .Cancelled}, 0 }
				if equal_term(prior, value.term) { duplicate = true; break }
			}
			if duplicate { destroy_expression_result(&value); continue }
			if _, append_error := append(&seen, value.term); append_error != nil { destroy_expression_result(&value); destroy_expression_result(&sum); return {state = .Out_Of_Memory}, 0 }
			if ownership_error := retain_expression_term(&seen_owned, &value, &seen[len(seen) - 1]); ownership_error != .None { destroy_expression_result(&value); destroy_expression_result(&sum); return {state = ownership_error == .Out_Of_Memory ? .Out_Of_Memory : .Error}, 0 }
		}
		if !is_numeric(value.term) { destroy_expression_result(&value); destroy_expression_result(&sum); return {state = .Error}, 0 }
		if !found {
			sum = value
			value = {}
			found = true
		} else {
			combined: Expression_Result
			if is_floating(sum.term) || is_floating(value.term) {
				combined = floating_binary_result(sum.term, value.term, .Add)
			} else {
				combined = exact_binary_result(sum.term, value.term, .Add, options.Max_Numeric_Digits)
			}
			destroy_expression_result(&sum)
			destroy_expression_result(&value)
			if combined.state != .Term {
				state := combined.state
				destroy_expression_result(&combined)
				return {state = state}, 0
			}
			sum = combined
		}
		count += 1
	}
	if !found do return integer_result("0", false, XSD_INTEGER), 0
	return sum, count
}

@(private) average_group :: proc(plan: ^algebra.Plan, aggregate: int, source: ^Result, members: []int, options: Options) -> Expression_Result {
	sum, count := numeric_group(plan, aggregate, source, members, options)
	if sum.state != .Term do return sum
	if count == 0 { destroy_expression_result(&sum); return integer_result("0", false, XSD_INTEGER) }
	buffer: [64]byte
	denominator := rdf.typed_literal(strconv.write_int(buffer[:], i64(count), 10), XSD_INTEGER)
	if is_floating(sum.term) {
		result := floating_divide_result(sum.term, denominator)
		destroy_expression_result(&sum)
		return result
	}
	result := exact_divide_result(sum.term, denominator, options.Max_Numeric_Digits, options.Decimal_Division_Precision)
	destroy_expression_result(&sum)
	if result.state != .Term || result.term.datatype != XSD_DECIMAL || strings.index_byte(result.term.value, '.') >= 0 do return result
	parts := [2]string{result.term.value, ".0"}
	lexical, lexical_error := strings.concatenate(parts[:])
	if lexical_error != nil { destroy_expression_result(&result); return {state = .Out_Of_Memory} }
	destroy_expression_result(&result)
	return {state = .Term, term = rdf.typed_literal(lexical, XSD_DECIMAL), owned = lexical}
}

@(private) group_concat :: proc(plan: ^algebra.Plan, aggregate: int, source: ^Result, members: []int, options: Options) -> Expression_Result {
	node, node_ok := algebra.Expression_At(plan, aggregate)
	if !node_ok || node.Kind != .Group_Concat || node.Child_Count != 1 do return {state = .Error}
	child, child_ok := algebra.Expression_Child(plan, aggregate, 0)
	if !child_ok do return {state = .Error}
	separator := " "
	if node.Has_Separator {
		if node.Separator.Kind != .Term || node.Separator.Term.kind != .Literal do return {state = .Error}
		separator = node.Separator.Term.value
	}
	seen := make([dynamic]rdf.Term)
	defer delete(seen)
	seen_owned := make([dynamic]string)
	defer destroy_owned_strings(&seen_owned)
	builder := strings.builder_make()
	defer delete(builder.buf)
	appended := false
	for row in members {
		if Cancellation_Requested(options) do return {state = .Cancelled}
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory { destroy_expression_result(&value); return {state = value.state} }
		if value.state != .Term { destroy_expression_result(&value); continue }
		if node.Uses_Distinct {
			duplicate := false
			for prior in seen {
				if Cancellation_Requested(options) { destroy_expression_result(&value); return {state = .Cancelled} }
				if equal_term(prior, value.term) { duplicate = true; break }
			}
			if duplicate { destroy_expression_result(&value); continue }
			if _, append_error := append(&seen, value.term); append_error != nil { destroy_expression_result(&value); return {state = .Out_Of_Memory} }
			if ownership_error := retain_expression_term(&seen_owned, &value, &seen[len(seen) - 1]); ownership_error != .None { destroy_expression_result(&value); return {state = ownership_error == .Out_Of_Memory ? .Out_Of_Memory : .Error} }
		}
		if appended && strings.write_string(&builder, separator) != len(separator) { destroy_expression_result(&value); return {state = .Out_Of_Memory} }
		if strings.write_string(&builder, value.term.value) != len(value.term.value) { destroy_expression_result(&value); return {state = .Out_Of_Memory} }
		appended = true
		destroy_expression_result(&value)
	}
	lexical, clone_error := strings.clone(strings.to_string(builder))
	if clone_error != nil do return {state = .Out_Of_Memory}
	return {state = .Term, term = rdf.literal(lexical), owned = lexical}
}

@(private) selection_group :: proc(plan: ^algebra.Plan, aggregate: int, source: ^Result, members: []int, options: Options) -> Expression_Result {
	node, node_ok := algebra.Expression_At(plan, aggregate)
	if !node_ok || (node.Kind != .Min && node.Kind != .Max && node.Kind != .Sample) || node.Child_Count != 1 do return {state = .Error}
	child, child_ok := algebra.Expression_Child(plan, aggregate, 0)
	if !child_ok do return {state = .Error}
	found := false
	best: rdf.Term
	best_owned := ""
	defer if len(best_owned) != 0 do delete(best_owned)
	for row in members {
		if Cancellation_Requested(options) do return {state = .Cancelled}
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok do return {state = .Error}
		value := evaluate_expression(plan, child, binding, options)
		if value.state == .Numeric_Limit || value.state == .Out_Of_Memory { destroy_expression_result(&value); return {state = value.state} }
		if value.state != .Term { destroy_expression_result(&value); continue }
		select := !found
		if found && node.Kind != .Sample {
			comparison := order_term_compare(value.term, best)
			select = (node.Kind == .Min && comparison < 0) || (node.Kind == .Max && comparison > 0)
		}
		if select {
			if len(best_owned) != 0 { delete(best_owned); best_owned = "" }
			best = value.term
			best_owned = value.owned
			value.owned = ""
			found = true
		}
		destroy_expression_result(&value)
		if node.Kind == .Sample && found do break
	}
	if !found do return {state = .Error}
	if best.datatype == XSD_DOUBLE {
		value, value_ok := floating_input_f64(best)
		if !value_ok do return {state = .Error}
		return canonical_floating_result(value, XSD_DOUBLE)
	}
	if best.datatype == XSD_FLOAT {
		value, value_ok := floating_input_f32(best)
		if !value_ok do return {state = .Error}
		return canonical_floating_result(f64(value), XSD_FLOAT)
	}
	result := Expression_Result{state = .Term, term = best, owned = best_owned}
	best_owned = ""
	return result
}

// group_relation materializes SPARQL groups over a bounded input multiset. It
// establishes aggregate bindings before downstream Extend, HAVING, and ORDER
// operators run, keeping aggregate evaluation out of the presentation layer.
@(private) group_relation :: proc(plan: ^algebra.Plan, operator: int, source: ^Result, options: Options) -> (Result, Error_Code) {
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok || node.Kind != .Group || node.Child_Count != 1 do return {}, .Unsupported_Plan
	buckets := make([dynamic]Group_Bucket)
	defer {
		for index in 0..<len(buckets) do destroy_group_bucket(&buckets[index])
		delete(buckets)
	}
	for row in 0..<Solution_Count(source) {
		if Cancellation_Requested(options) do return {}, .Cancelled
		binding, binding_ok := binding_from_solution(source, row)
		if !binding_ok do return {}, .Unsupported_Plan
		values := make([dynamic]rdf.Term)
		bound := make([dynamic]bool)
		owned := make([dynamic]string)
		valid := true
		for key in 0..<node.Group_Expression_Count {
			expression, _, key_ok := algebra.Group_Expression(plan, operator, key)
			if !key_ok { valid = false; break }
			value := evaluate_expression(plan, expression, binding, options)
			if value.state == .Numeric_Limit || value.state == .Out_Of_Memory { destroy_expression_result(&value); delete(values); delete(bound); destroy_owned_strings(&owned); return {}, value.state == .Numeric_Limit ? .Numeric_Limit : .Out_Of_Memory }
			is_bound := value.state == .Term
			if _, append_error := append(&values, value.term); append_error != nil { destroy_expression_result(&value); delete(values); delete(bound); destroy_owned_strings(&owned); return {}, .Out_Of_Memory }
			if _, append_error := append(&bound, is_bound); append_error != nil { destroy_expression_result(&value); delete(values); delete(bound); destroy_owned_strings(&owned); return {}, .Out_Of_Memory }
			if _, append_error := append(&owned, value.owned); append_error != nil { destroy_expression_result(&value); delete(values); delete(bound); destroy_owned_strings(&owned); return {}, .Out_Of_Memory }
			value.owned = ""
			destroy_expression_result(&value)
		}
		if !valid { delete(values); delete(bound); destroy_owned_strings(&owned); return {}, .Unsupported_Plan }
		matched := -1
		for index in 0..<len(buckets) {
			if Cancellation_Requested(options) { delete(values); delete(bound); destroy_owned_strings(&owned); return {}, .Cancelled }
			if group_key_matches(&buckets[index], values[:], bound[:]) { matched = index; break }
		}
		if matched < 0 {
			representative, clone_error := clone_binding(binding)
			if clone_error != .None { delete(values); delete(bound); destroy_owned_strings(&owned); return {}, clone_error }
			bucket := Group_Bucket{representative = representative, key_values = values, key_bound = bound, key_owned = owned, members = make([dynamic]int)}
			if _, append_error := append(&buckets, bucket); append_error != nil { destroy_group_bucket(&bucket); return {}, .Out_Of_Memory }
			matched = len(buckets) - 1
		} else { delete(values); delete(bound); destroy_owned_strings(&owned) }
		if _, append_error := append(&buckets[matched].members, row); append_error != nil do return {}, .Out_Of_Memory
	}
	if Solution_Count(source) == 0 && node.Group_Expression_Count == 0 {
		empty, empty_error := init_binding(algebra.Variable_Count(plan))
		if empty_error != .None do return {}, empty_error
		bucket := Group_Bucket{representative = empty, key_values = make([dynamic]rdf.Term), key_bound = make([dynamic]bool), members = make([dynamic]int)}
		if _, append_error := append(&buckets, bucket); append_error != nil { destroy_group_bucket(&bucket); return {}, .Out_Of_Memory }
	}
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for bucket in &buckets {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		output, clone_error := clone_binding(bucket.representative)
		if clone_error != .None { destroy(&result); return {}, clone_error }
		// A group emits only its keys and aggregate bindings. Keeping the
		// representative's other bindings would leak an arbitrary input row into
		// downstream HAVING, VALUES, projection, or ORDER evaluation.
		for variable in 0..<len(output.bound) do output.bound[variable] = false
		aggregate_owned := make([dynamic]string)
		for key in 0..<node.Group_Expression_Count {
			_, variable, key_ok := algebra.Group_Expression(plan, operator, key)
			if !key_ok { delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Unsupported_Plan }
			if variable >= 0 {
				output.bound[variable] = bucket.key_bound[key]
				if bucket.key_bound[key] do output.values[variable] = bucket.key_values[key]
			}
		}
		for index in 0..<node.Group_Aggregate_Count {
			if Cancellation_Requested(options) { delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Cancelled }
			aggregate, aggregate_ok := algebra.Group_Aggregate(plan, operator, index)
			if !aggregate_ok { delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Unsupported_Plan }
			aggregate_node, aggregate_node_ok := algebra.Expression_At(plan, aggregate)
			if !aggregate_node_ok { delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Unsupported_Plan }
			value := count_group(plan, aggregate, source, bucket.members[:], options)
			if aggregate_node.Kind == .Sum {
				value, _ = numeric_group(plan, aggregate, source, bucket.members[:], options)
			} else if aggregate_node.Kind == .Average {
				value = average_group(plan, aggregate, source, bucket.members[:], options)
			} else if aggregate_node.Kind == .Group_Concat {
				value = group_concat(plan, aggregate, source, bucket.members[:], options)
			} else if aggregate_node.Kind != .Count {
				value = selection_group(plan, aggregate, source, bucket.members[:], options)
			}
			if value.state == .Cancelled { destroy_expression_result(&value); delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Cancelled }
			if value.state == .Numeric_Limit { destroy_expression_result(&value); delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Numeric_Limit }
			if value.state == .Out_Of_Memory { destroy_expression_result(&value); delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Out_Of_Memory }
			if aggregate_node.Term.Kind != .Variable { destroy_expression_result(&value); delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Unsupported_Plan }
			// SPARQL aggregate errors are scoped to their output binding. A group
			// survives, but its aggregate alias remains unbound; downstream
			// expressions and HAVING then apply their ordinary error semantics.
			if value.state == .Term {
				output.values[aggregate_node.Term.Variable] = value.term
				output.bound[aggregate_node.Term.Variable] = true
				if len(value.owned) != 0 {
					if _, append_error := append(&aggregate_owned, value.owned); append_error != nil { delete(value.owned); delete(aggregate_owned); destroy_binding(&output); destroy(&result); return {}, .Out_Of_Memory }
					value.owned = ""
				}
			}
			destroy_expression_result(&value)
		}
		if error := append_solution(&result, output, options.Max_Solutions); error != .None {
			for owned in aggregate_owned do delete(owned)
			delete(aggregate_owned)
			destroy_binding(&output)
			destroy(&result)
			return {}, error
		}
		for owned in aggregate_owned do delete(owned)
		delete(aggregate_owned)
		destroy_binding(&output)
	}
	return result, .None
}

@(private) seeded_identity_relation :: proc(plan: ^algebra.Plan, seed: ^Binding, maximum: int) -> (Result, Error_Code) {
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	if seed == nil {
		binding, binding_error := init_binding(algebra.Variable_Count(plan))
		if binding_error != .None { destroy(&result); return {}, binding_error }
		defer destroy_binding(&binding)
		if error := append_solution(&result, binding, maximum); error != .None { destroy(&result); return {}, error }
		return result, .None
	}
	if len(seed.values) != algebra.Variable_Count(plan) { destroy(&result); return {}, .Unsupported_Plan }
	if error := append_solution(&result, seed^, maximum); error != .None { destroy(&result); return {}, error }
	return result, .None
}

@(private) service_relation :: proc(plan: ^algebra.Plan, operator: int, options: Options, seed: ^Binding = nil) -> (Result, Error_Code) {
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok || node.Kind != .Service || node.Child_Count != 1 do return {}, .Unsupported_Plan
	child, child_ok := algebra.Operator_Child(plan, operator, 0)
	if !child_ok do return {}, .Unsupported_Plan
	binding: Binding
	binding_error: Error_Code
	if seed != nil {
		binding, binding_error = clone_binding(seed^)
	} else {
		binding, binding_error = init_binding(algebra.Variable_Count(plan))
	}
	if binding_error != .None do return {}, binding_error
	defer destroy_binding(&binding)
	endpoint, endpoint_bound := slot_value(node.Service, binding)
	if !endpoint_bound || endpoint.kind != .IRI || options.Service_Callback == nil {
		if node.Service_Silent do return seeded_identity_relation(plan, seed, options.Max_Solutions)
		return {}, .Service_Error
	}
	if options.Statistics != nil do options.Statistics.Service_Calls += 1
	service_view, available := options.Service_Callback(endpoint, options.Service_Data)
	if !available {
		if node.Service_Silent do return seeded_identity_relation(plan, seed, options.Max_Solutions)
		return {}, .Service_Error
	}
	service_options := options
	service_options.Dataset_View = service_view
	result, service_error := evaluate_operator_seeded(plan, child, service_view, service_options, {}, seed)
	if service_error == .None do return result, .None
	destroy(&result)
	// Cancellation belongs to the enclosing execution, not to the SERVICE
	// endpoint. In particular SERVICE SILENT must not convert it to identity.
	if service_error == .Cancelled || service_error == .Out_Of_Memory || service_error == .Solution_Limit || service_error == .Numeric_Limit do return {}, service_error
	if node.Service_Silent do return seeded_identity_relation(plan, seed, options.Max_Solutions)
	return {}, .Service_Error
}

@(private) correlated_service_join :: proc(plan: ^algebra.Plan, left_operator, service_operator: int, optional: bool, view: dataset.View, options: Options, scope: Graph_Scope) -> (Result, Error_Code) {
	left, left_error := evaluate_operator(plan, left_operator, view, options, scope)
	if left_error != .None do return {}, left_error
	defer destroy(&left)
	result: Result
	if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
	for row in 0..<Solution_Count(&left) {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		left_binding, left_ok := binding_from_solution(&left, row)
		if !left_ok { destroy(&result); return {}, .Unsupported_Plan }
		right, right_error := evaluate_operator_seeded(plan, service_operator, view, options, scope, &left_binding)
		if right_error != .None { destroy(&result); return {}, right_error }
		matched := false
		for right_row in 0..<Solution_Count(&right) {
			if Cancellation_Requested(options) { destroy(&right); destroy(&result); return {}, .Cancelled }
			right_binding, right_ok := binding_from_solution(&right, right_row)
			if !right_ok { destroy(&right); destroy(&result); return {}, .Unsupported_Plan }
			if !compatible(left_binding, right_binding) do continue
			merged, merge_error := merge_bindings(left_binding, right_binding)
			if merge_error != .None { destroy(&right); destroy(&result); return {}, merge_error }
			if append_error := append_solution(&result, merged, options.Max_Solutions); append_error != .None { destroy_binding(&merged); destroy(&right); destroy(&result); return {}, append_error }
			destroy_binding(&merged)
			matched = true
		}
		if optional && !matched {
			if append_error := append_solution(&result, left_binding, options.Max_Solutions); append_error != .None { destroy(&right); destroy(&result); return {}, append_error }
		}
		destroy(&right)
	}
	return result, .None
}

// evaluate_operator_seeded is the correlation entry point. The first complete
// slice supports seeded BGPs; composite seeded operators are added here rather
// than as EXISTS-specific behavior.
@(private) Named_Graph_Collect_State :: struct {
	graphs: ^[dynamic]rdf.Term,
	error:  Error_Code,
}

@(private) collect_named_graph :: proc(quad: rdf.Quad, data: rawptr) -> bool {
	state := cast(^Named_Graph_Collect_State)data
	if !quad.has_graph do return true
	state.error = append_unique_path_term(state.graphs, quad.graph)
	return state.error == .None
}

@(private) Named_Graph_Exists_State :: struct { found: bool }

@(private) find_named_graph :: proc(_: rdf.Quad, data: rawptr) -> bool {
	state := cast(^Named_Graph_Exists_State)data
	state.found = true
	return false
}

@(private) named_graph_exists :: proc(view: dataset.View, graph: rdf.Term) -> (bool, Error_Code) {
	state: Named_Graph_Exists_State
	if scan_error := dataset.scan(view, {Graph_Mode = .Named, Graph = graph}, find_named_graph, &state); scan_error != .None do return false, .Dataset_Error
	return state.found, .None
}

@(private) empty_relation :: proc(plan: ^algebra.Plan) -> (Result, Error_Code) {
	result: Result
	if init_error := init_result(&result, plan); init_error != .None { destroy(&result); return {}, init_error }
	return result, .None
}

// graph_variable_relation applies GRAPH ?g's binding only after its pattern
// has been evaluated against one concrete named graph. In particular, ?g is
// not in scope inside a nested OPTIONAL in that pattern, while occurrences of
// ?g in an ordinary inner BGP still join with the graph binding afterwards.
@(private) graph_variable_relation :: proc(plan: ^algebra.Plan, child: int, graph_slot: algebra.Slot_View, view: dataset.View, options: Options, seed: ^Binding = nil) -> (Result, Error_Code) {
	graphs := make([dynamic]rdf.Term)
	defer delete(graphs)
	collect_state := Named_Graph_Collect_State{graphs = &graphs}
	if scan_error := dataset.scan(view, {Graph_Mode = .Any_Named}, collect_named_graph, &collect_state); scan_error != .None do return {}, .Dataset_Error
	if collect_state.error != .None do return {}, collect_state.error
	result: Result
	if init_error := init_result(&result, plan); init_error != .None { destroy(&result); return {}, init_error }
	for graph in graphs {
		if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
		if seed != nil {
			bound_graph, bound := slot_value(graph_slot, seed^)
			if bound && !equal_term(bound_graph, graph) do continue
		}
		scope := Graph_Scope{mode = .Named, graph = graph}
		source: Result
		source_error: Error_Code
		if seed != nil {
			source, source_error = evaluate_operator_seeded(plan, child, view, options, scope, seed)
		} else {
			source, source_error = evaluate_operator(plan, child, view, options, scope)
		}
		if source_error != .None { destroy(&result); return {}, source_error }
		for row in 0..<Solution_Count(&source) {
			if Cancellation_Requested(options) { destroy(&source); destroy(&result); return {}, .Cancelled }
			binding, binding_ok := binding_from_solution(&source, row)
			if !binding_ok { destroy(&source); destroy(&result); return {}, .Unsupported_Plan }
			extended, clone_error := clone_binding(binding)
			if clone_error != .None { destroy(&source); destroy(&result); return {}, clone_error }
			if match_slot(graph_slot, graph, &extended) {
				if append_error := append_solution(&result, extended, options.Max_Solutions); append_error != .None { destroy_binding(&extended); destroy(&source); destroy(&result); return {}, append_error }
			}
			destroy_binding(&extended)
		}
		destroy(&source)
	}
	return result, .None
}

@(private) evaluate_operator_seeded :: proc(plan: ^algebra.Plan, operator: int, view: dataset.View, options: Options, scope: Graph_Scope, seed: ^Binding) -> (Result, Error_Code) {
	if Cancellation_Requested(options) do return {}, .Cancelled
	previous_scope: Graph_Scope
	has_expression_scope := options.expression_scope != nil
	if options.expression_scope != nil {
		previous_scope = options.expression_scope^
		options.expression_scope^ = scope
	}
	defer if has_expression_scope do options.expression_scope^ = previous_scope
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok do return {}, .Unsupported_Plan
	// A nested LeftJoin is a fresh algebra relation. In particular, a binding
	// inherited from an enclosing OPTIONAL must not constrain the nested join's
	// own BGPs: the enclosing operator performs the compatibility merge after
	// this relation is evaluated. Propagating the seed here turns an
	// incompatible inner match into an unbound optional match, which changes
	// SPARQL's nested-OPTIONAL semantics.
	if node.Kind == .Left_Join && seed != nil do return evaluate_operator(plan, operator, view, options, scope)
	if node.Kind == .Identity do return seeded_identity_relation(plan, seed, options.Max_Solutions)
	if node.Kind == .BGP do return evaluate_bgp(plan, node.First_Triple, node.Triple_Count, view, options, scope.mode, scope.graph, scope.graph_slot, scope.bind_graph, seed)
	if node.Kind == .Path do return path_relation(plan, operator, view, options, scope, seed)
	if node.Kind == .Values {
		values, values_error := values_relation(plan, operator, options)
		if values_error != .None do return {}, values_error
		defer destroy(&values)
		identity, identity_error := seeded_identity_relation(plan, seed, options.Max_Solutions)
		if identity_error != .None do return {}, identity_error
		defer destroy(&identity)
		return join_relations(plan, &identity, &values, options, false, false)
	}
	if node.Kind == .Service do return service_relation(plan, operator, options, seed)
	if node.Kind == .Filter || node.Kind == .Extend {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		source, source_error := evaluate_operator_seeded(plan, child, view, options, scope, seed)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		if node.Kind == .Filter do return filter_relation(plan, &source, node.Expression, options)
		return extend_relation(plan, &source, node.Expression, node.Variable, options)
	}
	if node.Kind == .Project {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		// A subquery is evaluated independently of the outer seed. Its Project
		// node is the explicit correlation barrier required by SPARQL algebra.
		source, source_error := evaluate_operator(plan, child, view, options, scope)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		return project_relation(plan, operator, &source, options)
	}
	if node.Kind == .Distinct || node.Kind == .Slice {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		source, source_error := evaluate_operator(plan, child, view, options, scope)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		if node.Kind == .Distinct do return distinct_relation(plan, &source, options)
		return slice_relation(plan, operator, &source, options)
	}
	if node.Kind == .Graph {
		if node.Child_Count != 1 || !node.Has_Graph do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		graph_scope: Graph_Scope
		if node.Graph.Kind == .Term {
			exists, exists_error := named_graph_exists(view, node.Graph.Term)
			if exists_error != .None do return {}, exists_error
			if !exists do return empty_relation(plan)
			graph_scope.mode = .Named
			graph_scope.graph = node.Graph.Term
		} else if node.Graph.Kind == .Variable {
			return graph_variable_relation(plan, child, node.Graph, view, options, seed)
		} else { return {}, .Unsupported_Plan }
		return evaluate_operator_seeded(plan, child, view, options, graph_scope, seed)
	}
	if node.Kind == .Union {
		if node.Child_Count == 0 do return {}, .Unsupported_Plan
		first, first_ok := algebra.Operator_Child(plan, operator, 0)
		if !first_ok do return {}, .Unsupported_Plan
		result, result_error := evaluate_operator_seeded(plan, first, view, options, scope, seed)
		if result_error != .None do return {}, result_error
		for child_index in 1..<node.Child_Count {
			child, child_ok := algebra.Operator_Child(plan, operator, child_index)
			if !child_ok { destroy(&result); return {}, .Unsupported_Plan }
			right, right_error := evaluate_operator_seeded(plan, child, view, options, scope, seed)
			if right_error != .None { destroy(&result); return {}, right_error }
			joined, joined_error := concatenate_relations(plan, &result, &right, options)
			destroy(&right)
			destroy(&result)
			if joined_error != .None do return {}, joined_error
			result = joined
		}
		return result, .None
	}
	if node.Kind == .Join || node.Kind == .Left_Join {
		if node.Child_Count != 2 do return {}, .Unsupported_Plan
		left_operator, left_ok := algebra.Operator_Child(plan, operator, 0)
		right_operator, right_ok := algebra.Operator_Child(plan, operator, 1)
		if !left_ok || !right_ok do return {}, .Unsupported_Plan
		left, left_error := evaluate_operator_seeded(plan, left_operator, view, options, scope, seed)
		if left_error != .None do return {}, left_error
		defer destroy(&left)
		result: Result
		if error := init_result(&result, plan); error != .None { destroy(&result); return {}, error }
		for row in 0..<Solution_Count(&left) {
			if Cancellation_Requested(options) { destroy(&result); return {}, .Cancelled }
			left_binding, binding_ok := binding_from_solution(&left, row)
			if !binding_ok { destroy(&result); return {}, .Unsupported_Plan }
			right, right_error := evaluate_operator_seeded(plan, right_operator, view, options, scope, &left_binding)
			if right_error != .None { destroy(&result); return {}, right_error }
			matched := false
			for right_row in 0..<Solution_Count(&right) {
				if Cancellation_Requested(options) { destroy(&right); destroy(&result); return {}, .Cancelled }
				right_binding, right_binding_ok := binding_from_solution(&right, right_row)
				if !right_binding_ok { destroy(&right); destroy(&result); return {}, .Unsupported_Plan }
				if !compatible(left_binding, right_binding) do continue
				merged, merge_error := merge_bindings(left_binding, right_binding)
				if merge_error != .None { destroy(&right); destroy(&result); return {}, merge_error }
				if error := append_solution(&result, merged, options.Max_Solutions); error != .None { destroy_binding(&merged); destroy(&right); destroy(&result); return {}, error }
				destroy_binding(&merged)
				matched = true
			}
			if node.Kind == .Left_Join && !matched {
				if error := append_solution(&result, left_binding, options.Max_Solutions); error != .None { destroy(&right); destroy(&result); return {}, error }
			}
			destroy(&right)
		}
		return result, .None
	}
	return {}, .Unsupported_Plan
}

@(private) evaluate_operator :: proc(plan: ^algebra.Plan, operator: int, view: dataset.View, options: Options, scope: Graph_Scope) -> (Result, Error_Code) {
	if Cancellation_Requested(options) do return {}, .Cancelled
	previous_scope: Graph_Scope
	has_expression_scope := options.expression_scope != nil
	if options.expression_scope != nil {
		previous_scope = options.expression_scope^
		options.expression_scope^ = scope
	}
	defer if has_expression_scope do options.expression_scope^ = previous_scope
	node, node_ok := algebra.Operator_At(plan, operator)
	if !node_ok do return {}, .Unsupported_Plan
	if node.Kind == .Identity do return identity_relation(plan, options.Max_Solutions)
	if node.Kind == .BGP do return evaluate_bgp(plan, node.First_Triple, node.Triple_Count, view, options, scope.mode, scope.graph, scope.graph_slot, scope.bind_graph)
	if node.Kind == .Path do return path_relation(plan, operator, view, options, scope)
	if node.Kind == .Values do return values_relation(plan, operator, options)
	if node.Kind == .Service do return service_relation(plan, operator, options)
	if node.Kind == .Filter || node.Kind == .Extend {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		source, source_error := evaluate_operator(plan, child, view, options, scope)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		if node.Kind == .Filter do return filter_relation(plan, &source, node.Expression, options)
		return extend_relation(plan, &source, node.Expression, node.Variable, options)
	}
	if node.Kind == .Order {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		result, result_error := evaluate_operator(plan, child, view, options, scope)
		if result_error != .None do return {}, result_error
		if order_error := order_relation(plan, operator, &result, options); order_error != .None {
			destroy(&result)
			return {}, order_error
		}
		return result, .None
	}
	if node.Kind == .Group {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		source, source_error := evaluate_operator(plan, child, view, options, scope)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		return group_relation(plan, operator, &source, options)
	}
	if node.Kind == .Project {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		source, source_error := evaluate_operator(plan, child, view, options, scope)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		return project_relation(plan, operator, &source, options)
	}
	if node.Kind == .Distinct || node.Kind == .Slice {
		if node.Child_Count != 1 do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		source, source_error := evaluate_operator(plan, child, view, options, scope)
		if source_error != .None do return {}, source_error
		defer destroy(&source)
		if node.Kind == .Distinct do return distinct_relation(plan, &source, options)
		return slice_relation(plan, operator, &source, options)
	}
	if node.Kind == .Graph {
		if node.Child_Count != 1 || !node.Has_Graph do return {}, .Unsupported_Plan
		child, child_ok := algebra.Operator_Child(plan, operator, 0)
		if !child_ok do return {}, .Unsupported_Plan
		graph_scope: Graph_Scope
		if node.Graph.Kind == .Term {
			exists, exists_error := named_graph_exists(view, node.Graph.Term)
			if exists_error != .None do return {}, exists_error
			if !exists do return empty_relation(plan)
			graph_scope.mode = .Named
			graph_scope.graph = node.Graph.Term
		} else if node.Graph.Kind == .Variable {
			return graph_variable_relation(plan, child, node.Graph, view, options)
		} else {
			return {}, .Unsupported_Plan
		}
		return evaluate_operator(plan, child, view, options, graph_scope)
	}
	if node.Kind == .Union {
		if node.Child_Count == 0 do return {}, .Unsupported_Plan
		first, first_ok := algebra.Operator_Child(plan, operator, 0)
		if !first_ok do return {}, .Unsupported_Plan
		result, result_error := evaluate_operator(plan, first, view, options, scope)
		if result_error != .None do return {}, result_error
		for child_index in 1..<node.Child_Count {
			child, child_ok := algebra.Operator_Child(plan, operator, child_index)
			if !child_ok { destroy(&result); return {}, .Unsupported_Plan }
			right, right_error := evaluate_operator(plan, child, view, options, scope)
			if right_error != .None { destroy(&result); return {}, right_error }
			joined, joined_error := concatenate_relations(plan, &result, &right, options)
			destroy(&right)
			destroy(&result)
			if joined_error != .None do return {}, joined_error
			result = joined
		}
		return result, .None
	}
	if node.Kind == .Left_Join {
		// OPTIONAL's right group is correlated with its left mapping: a FILTER,
		// BIND, GRAPH, or SERVICE there may read bindings produced by the left.
		// The seeded path merges explicitly so a subquery projection barrier on
		// the right does not discard that left mapping.
		return evaluate_operator_seeded(plan, operator, view, options, scope, nil)
	}
	if node.Kind == .Join || node.Kind == .Minus {
		if node.Child_Count != 2 do return {}, .Unsupported_Plan
		left_operator, left_ok := algebra.Operator_Child(plan, operator, 0)
		right_operator, right_ok := algebra.Operator_Child(plan, operator, 1)
		if !left_ok || !right_ok do return {}, .Unsupported_Plan
		if node.Kind != .Minus {
			right_node, right_node_ok := algebra.Operator_At(plan, right_operator)
			if !right_node_ok do return {}, .Unsupported_Plan
			if right_node.Kind == .Service do return correlated_service_join(plan, left_operator, right_operator, node.Kind == .Left_Join, view, options, scope)
		}
		left, left_error := evaluate_operator(plan, left_operator, view, options, scope)
		if left_error != .None do return {}, left_error
		defer destroy(&left)
		right, right_error := evaluate_operator(plan, right_operator, view, options, scope)
		if right_error != .None do return {}, right_error
		defer destroy(&right)
		return join_relations(plan, &left, &right, options, node.Kind == .Left_Join, node.Kind == .Minus)
	}
	return {}, .Unsupported_Plan
}

// evaluate materializes a bounded multiset of BGP solutions. It requires a
// sealed Dataset view and a positive Max_Solutions bound. Recursive operator
// plans are introduced by M3 and are evaluated through this same entry point.
evaluate :: proc(plan: ^algebra.Plan, view: dataset.View, options: Options) -> (Result, Error_Code) {
	if options.Max_Solutions <= 0 do return {}, .Invalid_Options
	configured := options
	cancellation_state: Cancellation_State
	configured.cancellation_state = &cancellation_state
	if Cancellation_Requested(configured) do return {}, .Cancelled
	root, root_ok := algebra.Root_Operator(plan)
	if !root_ok do return {}, .Unsupported_Plan
	configured.Dataset_View = view
	generated_now_storage: [20]byte
	if len(configured.Now_Lexical) == 0 {
		// Second precision is sufficient for SPARQL NOW() and avoids exposing a
		// host clock's non-portable sub-second representation in result values.
		generated_now, generated_ok := generated_now_lexical(&generated_now_storage)
		if !generated_ok do return {}, .Out_Of_Memory
		configured.Now_Lexical = generated_now
	}
	if _, valid := parse_xsd_date_time(configured.Now_Lexical); !valid do return {}, .Invalid_Options
	bnode_context := Blank_Node_Context{scope = rdf.new_blank_node_scope(), keys = make([dynamic]string), nodes = make([dynamic]rdf.Term), owned = make([dynamic]string)}
	defer destroy_blank_node_context(&bnode_context)
	configured.bnode_context = &bnode_context
	uuid_context := UUID_Context{issued = make([dynamic]uuid.Identifier)}
	defer destroy_uuid_context(&uuid_context)
	configured.uuid_context = &uuid_context
	expression_scope: Graph_Scope
	configured.expression_scope = &expression_scope
	result, evaluation_error := evaluate_operator(plan, root, view, configured, {})
	if Cancellation_Requested(configured) {
		destroy(&result)
		return {}, .Cancelled
	}
	return result, evaluation_error
}
