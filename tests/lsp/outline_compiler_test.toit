// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.protocol.document_symbol as lsp
import .utils

import host.directory
import expect show *

main args:
  run_client_test args: test it "$(directory.cwd)/outline.toit"
  run_client_test --use_toitlsp args: test it "$(directory.cwd)/outline.toit"
  run_client_test args: test it "$(directory.cwd)/error_outline.toit"
  run_client_test --use_toitlsp args: test it "$(directory.cwd)/error_outline.toit"

class ExpectedSymbol:
  static hash_code_counter := 0

  hash_code ::= hash_code_counter++
  name / string ::= ?
  parent / string? ::= ?
  kind / string ::= ?
  detail / Set ::= ?
  location / Location ::= ?

  constructor .name .parent .kind .detail .location:

  lsp_kind:
    if kind == "class":              return lsp.SymbolKind.CLASS
    if kind == "abstract class":     return lsp.SymbolKind.CLASS
    if kind == "interface":          return lsp.SymbolKind.INTERFACE
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

  matches_actual actual/Map actual_parent/string?:
    if name != actual["name"]: return false
    if parent != actual_parent: return false
    if lsp_kind != actual["kind"]: return false
    actual_detail := actual.get "detail"
    if actual_detail == "": actual_detail = null
    if not actual_detail and not detail.is_empty: return false
    if actual_detail:
      // For now, just make sure they all appear.
      split := actual_detail.split " "
      if split.size != detail.size: return false
      split.do: if not detail.contains it: return false
    actual_start := actual["selectionRange"]["start"]
    if location.line != actual_start["line"]: return false
    if location.column != actual_start["character"]: return false
    return true

test client/LspClient outline_path/string:
  locations := extract_locations outline_path

  // Decode the information that is part of the location names.
  expected_outline := {:}
  locations.do: |encoded location|
    first_colon := encoded.index_of ": "
    kind := encoded.copy 0 first_colon
    rest := encoded.copy first_colon + 2
    parts := rest.split " "
    combined_name := parts[0]
    parent := null
    name := null
    dot_pos := combined_name.index_of "."
    if dot_pos == -1:
      name = combined_name
    else:
      parent = combined_name.copy 0 dot_pos
      name = combined_name.copy dot_pos + 1
    detail := {}
    for i := 1; i < parts.size; i++: detail.add parts[i]

    (expected_outline.get name --init=:[]).add
        ExpectedSymbol name parent kind detail location

  client.send_did_open --path=outline_path
  outline_response := client.send_outline_request --path=outline_path

  expected_symbol_count := locations.size

  symbol_count := 0
  checked := {}

  check_symbol := null
  check_symbol = :: |symbol parent_name|
    symbol_count++
    name := symbol["name"]
    candidates := expected_outline[name]
    found_expected_symbol := false
    for i := 0; i < candidates.size; i++:
      candidate := candidates[i]
      if checked.contains candidate: continue
      if candidate.matches_actual symbol parent_name:
        checked.add candidate
        found_expected_symbol = true
        break
    if not found_expected_symbol:
      print "Couldn't find expected symbol for (parent: $parent_name): $symbol"
      throw "NOT FOUND"
    children := symbol.get "children"
    if children:
      children.do: check_symbol.call it name

  outline_response.do: |symbol|
    check_symbol.call symbol null
