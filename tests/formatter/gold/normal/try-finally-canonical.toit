// Determinism for try / finally: always emitted broken from AST. The
// inline form (`try: a finally: b`) packs three semantic chunks on
// one line and is harder to read than the broken layout, just like
// `if A: a else: b`.

main:
  // Source-broken: stays broken.
  try:
    foo
  finally:
    bar

  // Source-inline: forced to broken.
  try: foo finally: bar

  // Mixed source layouts: both halves canonicalised.
  try: foo
  finally:
    bar

  try:
    foo
  finally: bar

foo: return null
bar: return null
