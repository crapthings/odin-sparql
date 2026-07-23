package main

import "core:fmt"
import "core:os"
import sparql "../../../sparql"

main :: proc() {
	if len(os.args) != 3 || (os.args[1] != "positive" && os.args[1] != "negative") {
		fmt.eprintln("usage: syntax_runner <positive|negative> <query.rq>")
		os.exit(2)
	}
	data, read_error := os.read_entire_file(os.args[2], context.allocator)
	if read_error != nil {
		fmt.eprintf("cannot read %s: %v\n", os.args[2], read_error)
		os.exit(2)
	}
	query, parse_error := sparql.Parse(string(data))
	valid := sparql.Parse_Error_Code(parse_error) == .None
	want_valid := os.args[1] == "positive"
	if valid == want_valid {
		sparql.Destroy(&query)
		delete(data)
		return
	}
	if want_valid {
		fmt.eprintf("%s: expected valid SPARQL query, got %v\n", os.args[2], sparql.Parse_Error_Code(parse_error))
	} else {
		fmt.eprintf("%s: expected invalid SPARQL query, got valid input\n", os.args[2])
	}
	sparql.Destroy(&query)
	delete(data)
	os.exit(1)
}
