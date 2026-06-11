// Determinism for if / else / else-if chains.
//
// Inline form is reserved for `if cond: body` (no else). With an else
// or else-if chain the formatter always emits broken form, however
// short the branches — `if A: a else: b` packs three semantic chunks
// on one line and is strictly less readable than the broken layout.

main:
  // Source-broken short if/else: stays broken (chains never inline).
  if x:
    print "yes"
  else:
    print "no"

  // Source-inline short if/else: forced to broken (chains never inline).
  if x: print "yes" else: print "no"

  // Source-inline short else-if chain: forced to broken.
  if x: a else if y: b else: c

  // Source-broken short else-if chain: stays broken.
  if x:
    a
  else if y:
    b
  else:
    c

  // The broken form is also used when the inline render would have
  // exceeded INLINE_CONTROL_FLOW_WIDTH anyway (60 cols).
  if some-condition:
    do-a-call with-args here
  else:
    do-other-call with-args also

x := false
y := false
print msg: return msg
a: return 0
b: return 0
c: return 0
some-condition: return false
do-a-call a b c -> any: return 0
do-other-call a b c -> any: return 0
with-args: return 0
here: return 0
also: return 0
