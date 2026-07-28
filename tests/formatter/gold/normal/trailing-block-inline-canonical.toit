// Determinism for Calls with a trailing Block / Lambda argument
// whose body is a single statement. Inline-vs-broken decision is by
// AST + width. Block params (`| x y |`) are handled.

main:
  // Source-broken short trailing block: collapsed to inline.
  list.do:
    print 1

  // Source-inline short trailing block: stays inline (handled by
  // `try_emit_call_flat_canonical`).
  list.do: print 2

  // Lambda variant uses `::`.
  task::
    print 3
  task:: print 4

  // Block parameters: `| x y |` rendered inline.
  list.do: | item |
    print item
  list.do: | item | print item

  // Two block params, source-broken vs source-inline.
  map.do: | k v |
    print "$k=$v"
  map.do: | k v | print "$k=$v"

  // Inline form too wide → broken.
  list.do:
    process some-fairly-long-arg another-arg final-arg

list := null
map := null
print msg: return msg
process a b c -> any: return 0
some-fairly-long-arg := 0
another-arg := 0
final-arg := 0
task body/Lambda: return null
