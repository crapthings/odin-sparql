// Package sparql_dataset provides read-only RDF dataset views for SPARQL evaluation.
package sparql_dataset

import graph "odin-graph:graph"
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

// Memory_Dataset is SPARQL's stable Dataset API over the shared Graph storage.
// It owns no separate quad or lexical-value store: Graph is the sole RDF
// Dataset implementation used by the parser, evaluator, and query results.
Memory_Dataset :: struct {
	storage:      graph.Graph,
	sealed:       bool,
	freeze_error: graph.Error,
}

@(private) map_graph_error :: proc(error: graph.Error) -> Error_Code {
	switch error {
	case .None:            return .None
	case .Invalid_Options: return .Invalid_Options
	case .Invalid_Quad:    return .Invalid_Quad
	case .Sealed:          return .Sealed
	case .Quad_Limit:      return .Quad_Limit
	case .Lexical_Limit:   return .Lexical_Limit
	case .Invalid_View:    return .Invalid_View
	case .Invalid_Sink:    return .Invalid_Sink
	case .Term_Limit, .Invalid_Derivation, .Out_Of_Memory: return .Out_Of_Memory
	}
	return .Out_Of_Memory
}

error_message :: proc(code: Error_Code) -> string {
	switch code {
	case .None: return "no error"
	case .Invalid_View: return "dataset view has no scan adapter"
	case .Invalid_Sink: return "dataset scan requires a sink callback"
	case .Invalid_Options: return "dataset options are invalid"
	case .Invalid_Quad: return "invalid RDF quad"
	case .Sealed: return "dataset is sealed"
	case .Quad_Limit: return "dataset quad limit reached"
	case .Lexical_Limit: return "dataset lexical byte limit reached"
	case .Out_Of_Memory: return "memory allocation failed"
	}
	return "unknown dataset error"
}

// init_with_options initializes Graph storage with the established SPARQL
// limits. A negative limit leaves a safe-to-destroy zero Dataset.
init_with_options :: proc(dataset: ^Memory_Dataset, options: Memory_Dataset_Options) -> Error_Code {
	dataset^ = {}
	return map_graph_error(graph.init(&dataset.storage, {
		Max_Quads = options.Max_Quads,
		Max_Lexical_Bytes = options.Max_Lexical_Bytes,
	}))
}

// init preserves the original memory-governed capacity behavior. Applications
// that ingest untrusted or bounded inputs should call init_with_options.
init :: proc(dataset: ^Memory_Dataset) { _ = init_with_options(dataset, {}) }

destroy :: proc(dataset: ^Memory_Dataset) {
	graph.destroy(&dataset.storage)
	dataset^ = {}
}

// add copies a valid quad into the shared Graph set. Equal quads are accepted
// as no-ops, preserving RDF Dataset set semantics.
add :: proc(dataset: ^Memory_Dataset, value: rdf.Quad) -> Error_Code {
	if dataset.sealed do return .Sealed
	return map_graph_error(graph.add(&dataset.storage, value))
}

// sink adapts Memory_Dataset to RDF quad parser callbacks. Graph copies each
// term before returning, so a parser may reuse its lexical buffers immediately.
sink :: proc(quad: rdf.Quad, user_data: rawptr) -> bool {
	store := cast(^Memory_Dataset)user_data
	return add(store, quad) == .None
}

// triple_sink adapts RDF graph parser callbacks to the default graph.
triple_sink :: proc(triple: rdf.Triple, user_data: rawptr) -> bool {
	store := cast(^Memory_Dataset)user_data
	return add(store, rdf.default_graph_quad(triple)) == .None
}

// add_collector copies every quad currently retained by an odin-rdf Collector
// into this Dataset. The shared Graph owns independent term copies and may
// outlive the Collector.
add_collector :: proc(dataset: ^Memory_Dataset, collector: ^rdf_dataset.Collector) -> Error_Code {
	if dataset.sealed do return .Sealed
	for quad in collector.quads {
		if error := add(dataset, quad); error != .None do return error
	}
	return .None
}

// seal freezes the shared Graph and builds its immutable scan indexes. It is
// idempotent. The API predates fallible freezing, so an allocation failure is
// retained and reported by view/scan while mutation remains permanently sealed.
seal :: proc(dataset: ^Memory_Dataset) {
	if dataset.sealed do return
	dataset.freeze_error = graph.freeze(&dataset.storage)
	dataset.sealed = true
}

quad_count :: proc(dataset: ^Memory_Dataset) -> int { return graph.quad_count(&dataset.storage) }

@(private) graph_pattern :: proc(pattern: Quad_Pattern) -> graph.Quad_Pattern {
	result := graph.Quad_Pattern{
		Graph = pattern.Graph,
		Has_Subject = pattern.Has_Subject,
		Subject = pattern.Subject,
		Has_Predicate = pattern.Has_Predicate,
		Predicate = pattern.Predicate,
		Has_Object = pattern.Has_Object,
		Object = pattern.Object,
	}
	switch pattern.Graph_Mode {
	case .Default: result.Graph_Mode = .Default
	case .Named: result.Graph_Mode = .Named
	case .Any_Named: result.Graph_Mode = .Any_Named
	}
	return result
}

@(private) Graph_Scan_State :: struct { sink: Scan_Sink, sink_data: rawptr }

@(private) graph_scan_sink :: proc(quad: rdf.Quad, data: rawptr) -> bool {
	state := cast(^Graph_Scan_State)data
	return state.sink(quad, state.sink_data)
}

@(private) memory_scan :: proc(data: rawptr, pattern: Quad_Pattern, sink: Scan_Sink, sink_data: rawptr) -> Error_Code {
	dataset := cast(^Memory_Dataset)data
	if !dataset.sealed do return .Sealed
	if dataset.freeze_error != .None do return map_graph_error(dataset.freeze_error)
	graph_view, graph_error := graph.view(&dataset.storage)
	if graph_error != .None do return map_graph_error(graph_error)
	state := Graph_Scan_State{sink = sink, sink_data = sink_data}
	return map_graph_error(graph.scan(graph_view, graph_pattern(pattern), graph_scan_sink, &state))
}

// view returns a borrowed read-only snapshot view after sealing.
view :: proc(dataset: ^Memory_Dataset) -> (View, Error_Code) {
	if !dataset.sealed do return {}, .Sealed
	if dataset.freeze_error != .None do return {}, map_graph_error(dataset.freeze_error)
	return custom_view(memory_scan, dataset), .None
}

// scan dispatches to a dataset view. It never owns terms yielded to the sink.
scan :: proc(view: View, pattern: Quad_Pattern, sink: Scan_Sink, sink_data: rawptr = nil) -> Error_Code {
	if view.scan == nil do return .Invalid_View
	if sink == nil do return .Invalid_Sink
	return view.scan(view.data, pattern, sink, sink_data)
}
