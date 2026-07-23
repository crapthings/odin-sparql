# M4 expression and solution-modifier design

M4 turns M3's deliberately small expression kernel into SPARQL value
semantics. It is staged because expression correctness depends on preserving
three states (`value`, `unbound`, `error`) through filter, extend, ordering,
grouping, and result serialization.

## Value model

Expression evaluation produces an internal tagged value, never a sentinel RDF
term. RDF terms remain the public binding representation. The first value
families are RDF terms, booleans, numeric values, strings/language strings,
and dates; every conversion records an error rather than coercing an invalid
lexical form.

`=` and `!=` use SPARQL value equality, not graph-pattern term equality. For
example, compatible numeric literals compare by numeric value, while an IRI
and a literal do not. `sameTerm` provides RDF-term equality.
Type errors and unbound operands are expression errors; `FILTER` discards
them, while `BIND` leaves its target unbound.

## Delivery order

1. Numeric lexical validation and promotion (`integer`, `decimal`, `float`,
   `double`), comparisons, and arithmetic; selected W3C `expr-equals` and
   `expr-ops` tests become gates.
2. Boolean operators with SPARQL error short-circuiting, string/language
   behavior, `BOUND`, `sameTerm`, `STR`, `LANG`, `DATATYPE`, and core casts.
3. `IN`, `NOT IN`, functions, regex, date/time, and `EXISTS`/`NOT EXISTS`.
4. Projection expressions, `DISTINCT`/`REDUCED`, `ORDER BY`, `LIMIT`, and
   `OFFSET`, with explicit materialization and cancellation policy.

## Current M4 increment

The first increment implements `=`, `!=`, `<`, `<=`, `>`, and `>=` for valid
`xsd:integer` and `xsd:decimal` values without machine-width narrowing or
floating-point conversion. It normalizes coefficient, sign, and decimal scale
over the original lexical string, so arbitrarily large values retain exact
semantics. Comparisons involving `xsd:float` or `xsd:double` use floating
promotion. Later increments added the ordered solution sequence and the wider
numeric built-in surface recorded below.

The temporal increment currently supports validated `xsd:date` literals in
`=`, `!=`, `<`, `<=`, `>`, and `>=`. Its parser accepts a non-zero four-or-more
digit year, validates the proleptic-Gregorian calendar, and accepts only `Z`
or legal `±hh:mm` timezone suffixes. Equality retains the distinction between
an absent and a present timezone when the same local date would otherwise be
ambiguous; relation operators compare calendar dates and normalize two
explicitly-zoned dates. `xsd:dateTime` also has validated relation comparison:
it accepts `T`-separated time values with optional fractional seconds, and
normalizes a pair of explicitly-zoned inputs before comparing them. Its value
equality also normalizes equivalent explicit offsets, `24:00:00` to the next
day, and fractional-second trailing zeroes. `xsd:date(...)`,
`xsd:dateTime(...)`, and `xsd:time(...)` accept an untagged/xsd:string lexical
form or an already matching temporal literal, validate it, and preserve its
lexical spelling under the target datatype. They reject language-tagged,
cross-temporal-type, and invalid lexical inputs. `ORDER BY` compares validated
same-datatype `xsd:date`, `xsd:dateTime`, and `xsd:time` values; explicitly
zoned values normalize their offsets before comparison.

`NOW()` captures one UTC `xsd:dateTime` at evaluation start and reuses it for
every invocation in that query. `engine.Options.Now_Lexical` permits a fixed,
validated instant for deterministic execution; an empty value captures the
system clock once.

`UUID()` returns a fresh `urn:uuid:` IRI and `STRUUID()` returns its 36-byte
string form. The default source is cryptographically secure UUID v4. For
deterministic execution, `engine.Options.UUID_Callback` supplies 16-byte
identifiers; the evaluator rejects a source that cannot produce a new value
within one query.

`RAND()` returns an `xsd:double` in `[0,1)`. It samples cryptographic entropy
by default, while `engine.Options.RAND_Callback` permits deterministic values
and validates the interval before exposing a result term.

`YEAR`, `MONTH`, and `DAY` accept validated `xsd:date` and `xsd:dateTime`
values. `HOURS`, `MINUTES`, and `SECONDS` accept `xsd:dateTime`; seconds
preserve a fractional lexical part as an `xsd:decimal`. `TIMEZONE` returns an
`xsd:dayTimeDuration` only for explicitly zoned values, while `TZ` returns the
canonical timezone string or the empty string for an absent timezone. Clock
extraction and timezone functions also accept validated `xsd:time` values;
calendar extraction deliberately does not.

Exact `+`, `-`, and `*` now operate on `xsd:integer` and `xsd:decimal`
through Odin's arbitrary-precision integer substrate plus an explicit decimal
scale. Results normalize insignificant coefficient zeroes and retain the
SPARQL numeric promotion rule that any decimal operand yields an
`xsd:decimal` result.

Integer and decimal division use arbitrary-precision quotient/remainder
arithmetic. A terminating decimal is returned exactly; a non-terminating
decimal uses a stable 34-significant-digit context and half-even rounding by
default. `Decimal_Division_Precision` makes that semantic precision explicit,
while `Max_Numeric_Digits` remains a hard resource bound for inputs,
intermediates, and rendered results. A zero integer/decimal divisor is an
ordinary expression error, so it leaves a `BIND` target unbound and causes a
`FILTER` to reject the solution. If either operand is `xsd:float` or
`xsd:double`, SPARQL promotion selects IEEE 754 division (`double` over
`float`); generated special values use the XSD lexical forms `INF`, `-INF`,
and `NaN`.

`ABS`, `CEIL`, `FLOOR`, and `ROUND` use the same exact lexical model for
`xsd:integer` and `xsd:decimal`. They never narrow through machine integers or
floating point. `ROUND` follows SPARQL's half-toward-positive-infinity rule,
including `ROUND(-1.5) = -1`. The same functions accept `xsd:float` and
`xsd:double` without widening the result type. Floating `ROUND` uses
`floor(value + 0.5)` rather than the host's away-from-zero rounding primitive,
while `ABS`, `CEIL`, and `FLOOR` preserve IEEE `NaN`, infinities, and the
underlying float width.

`eval.Options.Max_Numeric_Digits` / `engine.Options.Max_Numeric_Digits` is a
required positive bound for exact binary arithmetic and exact division. It
limits numeric input, alignment intermediates, and formatted results; a breach
returns the public `Numeric_Limit` error rather than becoming a FILTER error or
a truncated value. It does not choose a decimal division precision.

Unary `+` and `-` validate numeric operands. Unary plus preserves the operand
term's valid lexical form; unary minus creates an owned lexical form with the
same datatype. Generated expression terms have an explicit evaluator-local
ownership path before a relation result copies them.

`&&` and `||` use SPARQL's error-aware short-circuit truth tables: false on
the left of `&&` and true on the left of `||` suppress evaluation of the right
operand. An unbound or invalid operand is an expression error unless the other
operand determines the result. Numeric effective-boolean-value evaluation is
available for the same supported numeric families.

`BOUND(?variable)` is translated as a dedicated binding-state lookup rather
than an ordinary variable expression, so an unbound variable correctly returns
false without producing an expression error.

`sameTerm` is likewise a dedicated RDF-term comparison: it preserves literal
lexical form and datatype distinctions that `=` intentionally abstracts over.

`isIRI`/`isURI`, `isBlank`, and `isLiteral` inspect RDF term kind and return an
`xsd:boolean` term. They do not coerce values or accept unbound operands.

`langMatches` accepts plain or `xsd:string` literal lexical forms and applies
case-insensitive basic language-range matching: `*` matches a non-empty tag,
and a non-wildcard range must match the complete tag or a subtag boundary.

`IN` and `NOT IN` use SPARQL value equality. They retain a non-resource
expression error while scanning candidates, but a later equal candidate
determines the result; an empty `NOT IN` list is true.

`isNumeric` returns true for RDF literals with a supported SPARQL numeric
datatype (`xsd:integer`, `xsd:decimal`, `xsd:float`, or `xsd:double`).

`IF` evaluates only its selected branch after a valid condition EBV. `COALESCE`
evaluates arguments left-to-right and returns the first value, skipping ordinary
expression errors but propagating resource-limit and allocation failures.

`CONCAT` accepts string literals, owns its generated lexical form, and retains
a language tag only when every argument has the same language tag; otherwise
it returns an `xsd:string` literal.

`STRSTARTS`, `STRENDS`, and `CONTAINS` accept compatible string literals and
compare lexical forms. Two language-tagged operands must carry the same tag
case-insensitively; an incompatible pair is an expression error.

`STRLEN` counts Unicode code points, not UTF-8 bytes or grapheme clusters, and
returns an owned `xsd:integer` lexical form.

`ENCODE_FOR_URI` accepts string literals and returns an owned `xsd:string`.
It leaves RFC 3986 unreserved ASCII bytes unchanged and percent-encodes every
other UTF-8 byte with uppercase hexadecimal digits; it does not retain a
language tag.

`SUBSTR` accepts a string literal plus two or three exact numeric arguments
(`xsd:integer`, `xsd:decimal`, `xsd:float`, or `xsd:double`). It indexes
Unicode code points from one, uses SPARQL's half-toward-positive-infinity rule,
safely clamps arbitrarily large indexes to the finite input, and preserves the
source language tag. Non-finite float/double indexes are expression errors.

`MD5`, `SHA1`, `SHA256`, `SHA384`, and `SHA512` hash the UTF-8 lexical bytes
of a string literal and return a lowercase hexadecimal `xsd:string` without a
language tag. `MD5` and `SHA1` are present only because SPARQL 1.1 specifies
them; they are not recommended for new security-sensitive uses.

`UCASE` and `LCASE` apply Odin's Unicode code-point case mappings and preserve
language tags. The release gate covers both BMP and non-BMP vectors. This is a
deliberate code-point mapping scope; full Unicode mappings that expand one code
point into multiple code points remain outside the documented claim.

`REPLACE` accepts a string literal, a plain-string pattern and replacement,
and an optional SPARQL regex flag string. It replaces all non-overlapping
matches, preserves the source language tag, and expands `$1` through `$9`
against their syntactic capture-group slots; an unmatched capture expands to
the empty string. In replacement text, only `\\` and `\$` are valid escapes.
Zero-length-match patterns and invalid capture references are expression
errors.

`STRBEFORE` and `STRAFTER` return an owned substring of the first compatible
string argument and retain its language tag when a delimiter is found. An
absent delimiter returns an empty `xsd:string` literal.

`STRDT` constructs a typed literal from an unlanguage-tagged string literal
and an IRI datatype; a language-tagged input or non-IRI datatype is an
expression error. Its lexical form is copied into the generated expression
result so nested string-producing functions cannot leave a dangling term.

`REGEX` accepts a string/language-string text value, an untagged string
pattern, and an optional untagged string flag value. It applies the XML Schema
regular-expression surface through Odin's local regex engine. `i`, `m`, `s`,
and `x` have SPARQL behavior; default dot and multiline anchors are translated
where the engine differs. The pinned historic manifest additionally uses `q`,
which quotes every regex metacharacter. Invalid patterns, flags, and argument
types are ordinary expression errors.

`BNODE()` creates a fresh blank node for each zero-argument function
evaluation. `BNODE(string)` accepts an untagged string literal and returns a
node that is shared only by equal string arguments in the same input solution
mapping; a later mapping receives a fresh node. The evaluator gives generated
nodes a private query scope, records their labels until result copying is
complete, and excludes previously generated nodes from the input-mapping
fingerprint used to preserve sequential projection identity.

`STR`, `LANG`, and `DATATYPE` produce RDF terms from the operand's RDF-term
facets. `STR` accepts IRIs and literals and returns an `xsd:string` literal;
`LANG` and `DATATYPE` require a literal and respectively return its language
tag as `xsd:string` or its datatype IRI. These functions borrow source strings
only until the surrounding relation copies its binding result.

The first XSD cast slice resolves the function IRI rather than assuming a
particular source prefix. It implements exact `xsd:integer`, `xsd:decimal`,
`xsd:boolean`, and `xsd:string` conversions for compatible literals; numeric
integer conversion truncates decimal values toward zero and all malformed or
incompatible conversions remain ordinary expression errors. `xsd:string`
also accepts IRIs. `xsd:float` and `xsd:double` accept compatible numeric and
string literals plus booleans, perform their target IEEE 754 conversion, and
serialize `INF`, `-INF`, and `NaN` with XSD lexical forms. `xsd:date`,
`xsd:dateTime`, and `xsd:time` accept a validated string lexical form or an
already matching temporal literal and preserve its spelling under the target
datatype. Cross-temporal-type casts remain explicit errors rather than
silently discarding calendar or clock components.

`IRI` and its alias `URI` carry the resolved query BASE in the executable
expression rather than consulting source text at evaluation time. They accept
IRIs or untagged string literals, resolve relative runtime strings against
that captured base, and return an ordinary expression error when a relative
reference has no BASE or the argument is otherwise incompatible.

`EXISTS` and `NOT EXISTS` use a nested BGP relation root evaluated with the
current solution as its seed binding. Existing outer bindings constrain the
nested graph pattern before it can introduce new bindings; evaluation stops
after the first compatible nested solution and returns an `xsd:boolean`
without exposing nested bindings. The seeded path preserves `Max_Solutions`
and resource-error behavior. The same path evaluates an `OPTIONAL` right group
per left mapping and explicitly merges surviving results, so a right-side
`FILTER`, `BIND`, `GRAPH`, or `SERVICE` can use left-side bindings without a
subquery projection barrier discarding them. The pinned SPARQL 1.1 negation
gate covers `exists-01`, `exists-02`, and the correlated `NOT EXISTS` fixture
`subsetByExcl01`.

The W3C `sparql10/expr-equals` value-equality subset is the present M4 gate
(eight cases: numeric, string/IRI, boolean, float, and dateTime inputs). A second W3C
gate covers the applicable numeric `>=` and `<=` entries from
`sparql10/expr-ops`, plus all four `xsd:dateTime` relation entries from that
manifest. `eq-dateTime` and `cast-dT` are also gated. Local regression
coverage additionally exercises the date/time constructors; the pinned cast
manifest provides no corresponding vectors.
A third gate covers an `OPTIONAL`-scoped `&&` expression from
`sparql10/optional-filter`, including its `BOUND`-based unbound-variable case.
A fourth gate covers numeric unary `+` and `-` FILTER expressions from
`sparql10/expr-ops`.
A fifth gate covers integer `+`, `-`, and `*` FILTER expressions plus the four
mixed-type `*-numbers-cast` SELECT fixtures from the same manifest.

## Ordering and limits

`ORDER BY` is an explicit algebra operator, not a post-hoc mutation of public
engine rows. It materializes each sort expression once for every bounded
solution, then applies a stable insertion sort. It runs before the engine's
output projection, `DISTINCT`/`REDUCED`, `OFFSET`, and `LIMIT`, so an ordering
expression can read a non-projected binding. The current defined comparisons
cover unbound/error values, blank nodes, IRIs, exact numeric values, booleans,
simple/`xsd:string` literals, and validated same-datatype `xsd:date`,
`xsd:dateTime`, and `xsd:time` values. Explicit temporal offsets are
normalized before ordering. Pairs for which this slice has no defined SPARQL
value ordering retain input order; stability makes that behavior deterministic
without inventing a term order.

`DISTINCT` performs exact RDF-term and unbound-binding equality on the
projected ordered sequence. `REDUCED` currently uses the same complete
deduplication strategy, which is permitted by SPARQL's weaker contract. The
deduplication pass is bounded and quadratic in the current implementation;
the ordering pass is likewise bounded and quadratic. A future planner may use
hashable term keys and a better sort without changing public semantics. The
existing `Max_Solutions` remains an upstream hard cap: reaching it is an
explicit resource error, never an unmarked truncated result.
