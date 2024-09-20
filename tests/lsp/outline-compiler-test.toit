// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.protocol.document-symbol as lsp
import .utils

import host.directory
import expect show *

main args:
  run-client-test args: test it "$(directory.cwd)/outline.toit"
  run-client-test args: test it "$(directory.cwd)/error-outline.toit"

class ExpectedSymbol:
  static hash-code-counter := 0

  hash-code ::= hash-code-counter++
  name / string ::= ?
  parent / string? ::= ?
  kind / string ::= ?
  detail / Set ::= ?
  location / Location ::= ?

  constructor .name .parent .kind .detail .location:

  lsp-kind:
    if kind == "class":              return lsp.SymbolKind.CLASS
    if kind == "abstract class":     return lsp.SymbolKind.CLASS
    if kind == "interface":          return lsp.SymbolKind.INTERFACE
    if kind == "mixin":              return lsp.SymbolKind.CLASS
    if kind == "constructor":        return lsp.SymbolKind.CONSTRUCTOR
    if kind == "named constructor":  return lsp.SymbolKind.CONSTRUCTOR
    if kind == "factory":            return lsp.SymbolKind.CONSTRUCTOR
    if kind == "method":             return lsp.SymbolKind.METHOD
    if kind == "setter":             return lsp.SymbolKind.METHOD
    if kind == "abstract method":    return lsp.SymbolKind.METHOD
    if kind == "interface method":   return lsp.SymbolKind.METHOD
    if kind == "field":              return lsp.SymbolKind.FIELD
    if kind == "final field":        return lsp.SymbolKind.FIELD
    if kind == "global":             return lsp.SymbolKind.VARIABLE
    if kind == "final global":       return lsp.SymbolKind.VARIABLE
    if kind == "constant":           return lsp.SymbolKind.VARIABLE
    if kind == "static field":       return lsp.SymbolKind.VARIABLE
    if kind == "static final field": return lsp.SymbolKind.VARIABLE
    if kind == "static constant":    return lsp.SymbolKind.VARIABLE
    if kind == "global function":    return lsp.SymbolKind.FUNCTION
    if kind == "static method":      return lsp.SymbolKind.FUNCTION
    throw "Unexpected kind: $kind"

  matches-actual actual/Map actual-parent/string?:
    if name != actual["name"]: return false
    if parent != actual-parent: return false
    if lsp-kind != actual["kind"]: return false
    actual-detail := actual.get "detail"
    if actual-detail == "": actual-detail = null
    if not actual-detail and not detail.is-empty: return false
    if actual-detail:
      // For now, just make sure they all appear.
      split := actual-detail.split " "
      if split.size != detail.size: return false
      split.do: if not detail.contains it: return false
    actual-start := actual["selectionRange"]["start"]
    if location.line != actual-start["line"]: return false
    if location.column != actual-start["character"]: return false
    return true

test client/LspClient outline-path/string:
  locations := extract-locations outline-path

  // Decode the information that is part of the location names.
  expected-outline := {:}
  locations.do: |encoded location|
    first-colon := encoded.index-of ": "
    kind := encoded.copy 0 first-colon
    rest := encoded.copy first-colon + 2
    parts := rest.split " "
    combined-name := parts[0]
    parent := null
    name := null
    dot-pos := combined-name.index-of "."
    if dot-pos == -1:
      name = combined-name
    else:
      parent = combined-name.copy 0 dot-pos
      name = combined-name.copy dot-pos + 1
    detail := {}
    for i := 1; i < parts.size; i++: detail.add parts[i]

    (expected-outline.get name --init=:[]).add
        ExpectedSymbol name parent kind detail location

  client.send-did-open --path=outline-path
  outline-response := client.send-outline-request --path=outline-path

  expected-symbol-count := locations.size

  symbol-count := 0
  checked := {}

  check-symbol := null
  check-symbol = :: |symbol parent-name|
    symbol-count++
    name := symbol["name"]
    candidates := expected-outline[name]
    found-expected-symbol := false
    for i := 0; i < candidates.size; i++:
      candidate := candidates[i]
      if checked.contains candidate: continue
      if candidate.matches-actual symbol parent-name:
        checked.add candidate
        found-expected-symbol = true
        break
    if not found-expected-symbol:
      print "Couldn't find expected symbol for (parent: $parent-name): $symbol"
      throw "NOT FOUND"
    children := symbol.get "children"
    if children:
      children.do: check-symbol.call it name

  outline-response.do: |symbol|
    check-symbol.call symbol null
