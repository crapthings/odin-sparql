// Package sparql_dataset provides read-only RDF dataset views for SPARQL evaluation.
package sparql_dataset

import "core:strings"
import rdf "odin-rdf:rdf"
import rdf_dataset "odin-rdf:rdf/dataset"

// Error_Code identifies setup, validation, mutation, and scan outcomes.
Error_Code :: enum {
	None,
	Invalid_View,
	Invalid_Sink,
	Invalid_Options,
	Invalid_Quad,
	Sealed,
	Quad_Limit,
	Lexical_Limit,
	Out_Of_Memory,
}

// Graph_Mode selects the graph scope for a Quad_Pattern. Default is the zero
// value so existing callers always retain SPARQL's default-graph semantics.
Graph_Mode :: enum { Default, Named, Any_Named }

// Quad_Pattern selects quads in one graph scope. A false Has_* field is a
// wildcard; a true field requires RDF-term equality. Graph is used only with
// Named; Any_Named is intended for GRAPH variables.
Quad_Pattern :: struct {
	Graph_Mode:    Graph_Mode,
	Graph:         rdf.Term,
	Has_Subject:   bool,
	Subject:       rdf.Term,
	Has_Predicate: bool,
	Predicate:     rdf.Term,
	Has_Object:    bool,
	Object:        rdf.Term,
}

// Scan_Sink receives dataset-borrowed quads. Return false to stop a scan
// successfully; sinks must not retain terms after the Dataset is destroyed.
Scan_Sink :: #type proc(quad: rdf.Quad, user_data: rawptr) -> bool

// Scan_Proc executes one graph-scoped scan for a borrowed View.
Scan_Proc :: #type proc(data: rawptr, pattern: Quad_Pattern, sink: Scan_Sink, sink_data: rawptr) -> Error_Code

// View is a borrowed read-only dataset snapshot. Its owner defines lifetime
// and synchronization; applications must not mutate that snapshot during a
// scan or evaluation.
View :: struct { scan: Scan_Proc, data: rawptr }

// custom_view constructs a borrowed dataset view from an application scan
// adapter. The caller owns data and must keep it valid for every scan.
custom_view :: proc(scan: Scan_Proc, data: rawptr) -> View { return View{scan = scan, data = data} }

// Memory_Dataset_Options configures an owned in-memory Dataset. A zero limit
// keeps the legacy memory-governed capacity; a positive value is a hard limit
// on either distinct quads or copied lexical-string bytes before seal.
Memory_Dataset_Options :: struct { Max_Quads: int, Max_Lexical_Bytes: int }

// Memory_Dataset owns a set of RDF quads and their lexical values. Its public
// API is deliberately independent of odin-graph: applications can release and
// use sparql/dataset with only odin-rdf. Graph-backed storage remains available
// through the separate sparql/graph_dataset adapter package.
Memory_Dataset :: struct {
	quads:             [dynamic]rdf.Quad,
	owned:              [dynamic]string,
	max_quads:          int,
	max_lexical_bytes:  int,
	lexical_bytes:      int,
	sealed:             bool,
}

error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None:            return "no error"
	case .Invalid_View:    return "dataset view has no scan adapter"
	case .Invalid_Sink:    return "dataset scan requires a sink callback"
	case .Invalid_Options: return "dataset options are invalid"
	case .Invalid_Quad:    return "invalid RDF quad"
	case .Sealed:          return "dataset is sealed"
	case .Quad_Limit:      return "dataset quad limit reached"
	case .Lexical_Limit:   return "dataset lexical byte limit reached"
	case .Out_Of_Memory:   return "memory allocation failed"
	}
	return "unknown dataset error"
}

// init_with_options initializes a Dataset with optional distinct-quad and
// copied-lexical-byte limits. A negative limit is invalid and leaves a
// safe-to-destroy zero Dataset. Once a positive limit is reached, a new quad
// returns its corresponding limit error; an equal quad remains a successful
// no-op.
init_with_options :: proc(dataset: ^Memory_Dataset, options: Memory_Dataset_Options) -> Error_Code {
	dataset^ = {}
	if options.Max_Quads < 0 || options.Max_Lexical_Bytes < 0 do return .Invalid_Options
	dataset^ = Memory_Dataset{
		quads = make([dynamic]rdf.Quad),
		owned = make([dynamic]string),
		max_quads = options.Max_Quads,
		max_lexical_bytes = options.Max_Lexical_Bytes,
	}
	return .None
}

// init preserves the original memory-governed capacity behavior. Applications
// that ingest untrusted or bounded inputs should call init_with_options.
init :: proc(dataset: ^Memory_Dataset) { _ = init_with_options(dataset, {}) }

// destroy releases all copied lexical values. A zero or failed-to-initialize
// Dataset is safe to destroy.
destroy :: proc(dataset: ^Memory_Dataset) {
	for value in dataset.owned do delete(value)
	delete(dataset.owned)
	delete(dataset.quads)
	dataset^ = {}
}

@(private) discard_owned_from :: proc(dataset: ^Memory_Dataset, start: int) {
	for index in start..<len(dataset.owned) do delete(dataset.owned[index])
	resize(&dataset.owned, start)
}

@(private) own_string :: proc(dataset: ^Memory_Dataset, value: string) -> (string, Error_Code) {
	if len(value) == 0 do return "", .None
	cloned, clone_error := strings.clone(value)
	if clone_error != nil do return "", .Out_Of_Memory
	_, append_error := append(&dataset.owned, cloned)
	if append_error != nil {
		delete(cloned)
		return "", .Out_Of_Memory
	}
	return cloned, .None
}

@(private) own_term :: proc(dataset: ^Memory_Dataset, value: rdf.Term) -> (rdf.Term, Error_Code) {
	result := value
	error: Error_Code
	result.value, error = own_string(dataset, value.value)
	if error != .None do return {}, error
	result.language, error = own_string(dataset, value.language)
	if error != .None do return {}, error
	result.datatype, error = own_string(dataset, value.datatype)
	if error != .None do return {}, error
	return result, .None
}

@(private) own_quad :: proc(dataset: ^Memory_Dataset, value: rdf.Quad) -> (rdf.Quad, Error_Code) {
	result: rdf.Quad
	error: Error_Code
	result.subject, error = own_term(dataset, value.subject)
	if error != .None do return {}, error
	result.predicate, error = own_term(dataset, value.predicate)
	if error != .None do return {}, error
	result.object, error = own_term(dataset, value.object)
	if error != .None do return {}, error
	result.has_graph = value.has_graph
	if value.has_graph {
		result.graph, error = own_term(dataset, value.graph)
		if error != .None do return {}, error
	}
	return result, .None
}

// lexical_bytes_needed computes whether a new quad fits the configured copied
// lexical payload budget without overflowing an integer during summation.
@(private) lexical_bytes_needed :: proc(dataset: ^Memory_Dataset, value: rdf.Quad) -> (int, bool) {
	if dataset.max_lexical_bytes == 0 do return 0, true
	remaining := dataset.max_lexical_bytes - dataset.lexical_bytes
	if remaining < 0 do return 0, false
	needed := 0
	terms := [4]rdf.Term{value.subject, value.predicate, value.object, value.graph}
	count := value.has_graph ? 4 : 3
	for term in terms[:count] {
		values := [3]string{term.value, term.language, term.datatype}
		for lexical in values {
			if len(lexical) > remaining - needed do return 0, false
			needed += len(lexical)
		}
	}
	return needed, true
}

@(private) equal_term :: proc(left, right: rdf.Term) -> bool {
	return left.kind == right.kind && left.value == right.value && strings.equal_fold(left.language, right.language) && left.datatype == right.datatype && left.scope == right.scope
}

@(private) equal_quad :: proc(left, right: rdf.Quad) -> bool {
	return left.has_graph == right.has_graph && equal_term(left.subject, right.subject) && equal_term(left.predicate, right.predicate) && equal_term(left.object, right.object) && (!left.has_graph || equal_term(left.graph, right.graph))
}

// add copies a valid quad into the set. An equal quad is accepted as a no-op.
add :: proc(dataset: ^Memory_Dataset, value: rdf.Quad) -> Error_Code {
	if dataset.sealed do return .Sealed
	if rdf.validate_quad_structure(value) != .None do return .Invalid_Quad
	for known in dataset.quads do if equal_quad(known, value) do return .None
	if dataset.max_quads > 0 && len(dataset.quads) >= dataset.max_quads do return .Quad_Limit
	lexical_bytes, within_lexical_limit := lexical_bytes_needed(dataset, value)
	if !within_lexical_limit do return .Lexical_Limit
	owned_start := len(dataset.owned)
	stored, own_error := own_quad(dataset, value)
	if own_error != .None {
		discard_owned_from(dataset, owned_start)
		return own_error
	}
	_, append_error := append(&dataset.quads, stored)
	if append_error != nil {
		discard_owned_from(dataset, owned_start)
		return .Out_Of_Memory
	}
	dataset.lexical_bytes += lexical_bytes
	return .None
}

// sink adapts Memory_Dataset to RDF quad parser callbacks. It copies each term
// before returning, so a parser may reuse its lexical buffers immediately.
sink :: proc(quad: rdf.Quad, user_data: rawptr) -> bool {
	return add(cast(^Memory_Dataset)user_data, quad) == .None
}

// triple_sink adapts RDF graph parser callbacks to the default graph.
triple_sink :: proc(triple: rdf.Triple, user_data: rawptr) -> bool {
	return add(cast(^Memory_Dataset)user_data, rdf.default_graph_quad(triple)) == .None
}

// add_collector copies every quad currently retained by an odin-rdf Collector
// into this Dataset. It is an ingestion boundary, not a borrowed view: the
// Memory_Dataset owns independent term copies and may outlive the Collector.
//
// Like add, this must be called before seal. Duplicate quads are accepted as
// no-ops. If an allocation failure occurs, quads copied before the failure
// remain in the Dataset; callers needing all-or-nothing ingestion should load
// a fresh Memory_Dataset and discard it on error.
add_collector :: proc(dataset: ^Memory_Dataset, collector: ^rdf_dataset.Collector) -> Error_Code {
	if dataset.sealed do return .Sealed
	for quad in collector.quads {
		if error := add(dataset, quad); error != .None do return error
	}
	return .None
}

// seal freezes a Memory_Dataset for read-only scans. It is idempotent.
seal :: proc(dataset: ^Memory_Dataset) { dataset.sealed = true }

quad_count :: proc(dataset: ^Memory_Dataset) -> int { return len(dataset.quads) }

@(private) matches :: proc(pattern: Quad_Pattern, quad: rdf.Quad) -> bool {
	switch pattern.Graph_Mode {
	case .Default:
		if quad.has_graph do return false
	case .Named:
		if !quad.has_graph || !equal_term(pattern.Graph, quad.graph) do return false
	case .Any_Named:
		if !quad.has_graph do return false
	}
	return (!pattern.Has_Subject || equal_term(pattern.Subject, quad.subject)) &&
		(!pattern.Has_Predicate || equal_term(pattern.Predicate, quad.predicate)) &&
		(!pattern.Has_Object || equal_term(pattern.Object, quad.object))
}

@(private) memory_scan :: proc(data: rawptr, pattern: Quad_Pattern, sink: Scan_Sink, sink_data: rawptr) -> Error_Code {
	dataset := cast(^Memory_Dataset)data
	if !dataset.sealed do return .Sealed
	for quad in dataset.quads {
		if matches(pattern, quad) && !sink(quad, sink_data) do break
	}
	return .None
}

// view returns a borrowed read-only snapshot view after sealing.
view :: proc(dataset: ^Memory_Dataset) -> (View, Error_Code) {
	if !dataset.sealed do return {}, .Sealed
	return custom_view(memory_scan, dataset), .None
}

// scan dispatches to a dataset view. It never owns terms yielded to the sink.
scan :: proc(view: View, pattern: Quad_Pattern, sink: Scan_Sink, sink_data: rawptr = nil) -> Error_Code {
	if view.scan == nil do return .Invalid_View
	if sink == nil do return .Invalid_Sink
	return view.scan(view.data, pattern, sink, sink_data)
}
