// Package graph_dataset exposes odin-graph through odin-sparql's public View
// boundary as a focused optional adapter test surface. The core
// sparql/dataset.Memory_Dataset remains independent of Graph.
package graph_dataset

import rdf "odin-rdf:rdf"
import rdf_dataset "odin-rdf:rdf/dataset"
import graph "odin-graph:graph"
import graph_sparql "odin-graph:adapter/sparql"
import dataset "odin-sparql:sparql/dataset"

// Options matches Memory_Dataset's observable admission limits. The graph
// kernel's term bound is deliberately left unbounded for compatibility.
Options :: struct {
	Max_Quads:         int,
	Max_Lexical_Bytes: int,
}

// Dataset owns one graph.Graph and exposes it after sealing through the public
// SPARQL Dataset View. It remains useful for adapter-focused integration tests
// without making Graph part of the core Dataset release boundary.
Dataset :: struct {
	storage:      graph.Graph,
	adapter:      graph_sparql.View,
	sealed:       bool,
	freeze_error: graph.Error,
}

@(private) map_error :: proc(error: graph.Error) -> dataset.Error_Code {
	#partial switch error {
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

// init prepares a graph-backed Dataset. Negative limits leave a safe-to-destroy value.
init :: proc(target: ^Dataset, options: Options = {}) -> dataset.Error_Code {
	target^ = {}
	return map_error(graph.init(&target.storage, {
		Max_Quads = options.Max_Quads,
		Max_Lexical_Bytes = options.Max_Lexical_Bytes,
	}))
}

destroy :: proc(target: ^Dataset) {
	graph.destroy(&target.storage)
	target^ = {}
}

// add copies one RDF quad into the graph-backed set.
add :: proc(target: ^Dataset, value: rdf.Quad) -> dataset.Error_Code {
	if target.sealed do return .Sealed
	return map_error(graph.add(&target.storage, value))
}

// sink adapts parser callbacks and retains independent graph-owned values.
sink :: proc(quad: rdf.Quad, user_data: rawptr) -> bool {
	return add(cast(^Dataset)user_data, quad) == .None
}

triple_sink :: proc(triple: rdf.Triple, user_data: rawptr) -> bool {
	return add(cast(^Dataset)user_data, rdf.default_graph_quad(triple)) == .None
}

// add_collector copies retained collector values into the graph set. It follows
// Memory_Dataset's existing partial-ingestion behavior on a later failure.
add_collector :: proc(target: ^Dataset, collector: ^rdf_dataset.Collector) -> dataset.Error_Code {
	if target.sealed do return .Sealed
	for quad in collector.quads {
		if error := add(target, quad); error != .None do return error
	}
	return .None
}

// seal freezes the graph. Repeated calls are successful and do not copy values.
// The API predates fallible index construction, so a freeze allocation failure
// is retained and reported by view while mutation remains permanently sealed.
seal :: proc(target: ^Dataset) {
	if target.sealed do return
	target.freeze_error = graph.freeze(&target.storage)
	target.sealed = true
}

quad_count :: proc(target: ^Dataset) -> int { return graph.quad_count(&target.storage) }

// view returns a public SPARQL Dataset view after seal.
view :: proc(target: ^Dataset) -> (dataset.View, dataset.Error_Code) {
	if !target.sealed do return {}, .Sealed
	if target.freeze_error != .None do return {}, map_error(target.freeze_error)
	if error := graph_sparql.init(&target.adapter, &target.storage); error != .None do return {}, map_error(error)
	return graph_sparql.dataset_view(&target.adapter), .None
}
