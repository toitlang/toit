// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import ..lsp-exports as lsp

class ModuleExports:
  classes/List  // Of ToplevelRef.
  functions/List  // Of ToplevelRef.
  globals/List  // Of ToplevelRef.
  ambiguous/List  // Of ToplevelRef.

  constructor
      --.classes
      --.functions
      --.globals
      --.ambiguous:

fill-transitive-exports exports/Map --uri/string --summaries/Map --shadowed/Set --seen/Set:
  if seen.contains uri: return
  seen.add uri

  module/lsp.Module := summaries[uri]

  // A set of identifiers that shadow any 'export *' from other modules.
  local-shadowed := {}
  local-shadowed.add-all shadowed

  add-export := : | name/string uri/string id/int |
    module-map := exports.get name --init=: {:}
    id-set := module-map.get uri --init=: {}
    id-set.add id

  add-local-element := : | node/lsp.ToplevelElement |
    if shadowed.contains node: continue.add-local-element
    add-export.call node.name uri node.toplevel-id
    local-shadowed.add node.name

  // Add all the entries that are defined in this module.
  // These entries will shadow any imported identifiers.
  module.classes.do add-local-element
  module.functions.do add-local-element
  module.globals.do add-local-element

  // Add the entries that are imported with 'show'.
  // These also shadow identifiers that would be reexported from 'show *'
  // modules.
  // Remember: the 'show' clause in Toit can be used to disambiguate imports.
  module.exports.do: | element/lsp.Export |
    if shadowed.contains element: continue.do

    local-shadowed.add element.name

    // TODO(florian): we lose the "ambiguous" indication here.
    // For programs without errors, this only happens if an identifier could
    //   resolve to two different modules. When we go through the collected exports
    //   later, we would catch this case again.
    // We only lose the kind, if a program has the same (non overloaded) toplevel
    //   in the same module.
    element.refs.do: | ref/lsp.ToplevelRef |
      add-export.call element.name ref.module-uri ref.id

  module.exported-modules.do: | export-uri/string |
    fill-transitive-exports exports
        --uri=export-uri
        --summaries=summaries
        --shadowed=local-shadowed
        --seen=seen

compute-module-exports --uri/string --summaries/Map -> ModuleExports:
  exports := {:}  // From uri (string) to a set of ids (int).

  fill-transitive-exports exports --uri=uri --summaries=summaries --shadowed={} --seen={}

  result-ambiguous := []
  result-classes := []
  result-functions := []
  result-globals := []

  exports.do: | name/string module-map/Map |
    // If the current uri is in the module-map, then the identifier is declared
    //   in the current module and doesn't need to be referenced through external
    //   toplevel references.
    if module-map.contains uri: continue.do

    toplevel-refs := []
    module-map.do: | export-uri/string id-set/Set |
      id-set.do: | id/int |
        toplevel-refs.add (lsp.ToplevelRef export-uri id)
    toplevel-refs.sort: | a/lsp.ToplevelRef b/lsp.ToplevelRef |
      a.module-uri.compare-to b.module-uri --if-equal=(: a.id.compare-to b.id)

    is-ambiguous := module-map.size > 1
    if is-ambiguous:
      ambigous := lsp.Export name lsp.Export.AMBIGUOUS toplevel-refs
      result-ambiguous.add ambigous
    else:
      toplevel-refs.do: | ref/lsp.ToplevelRef |
        node := (summaries[ref.module-uri] as lsp.Module).toplevel-element-with-id ref.id
        if node is lsp.Class:
          result-classes.add ref
        else if node is lsp.Method:
          method := node as lsp.Method
          if method.kind == lsp.Method.GLOBAL-KIND:
            result-globals.add ref
          else:
            result-functions.add ref

  return ModuleExports
      --classes=result-classes
      --functions=result-functions
      --globals=result-globals
      --ambiguous=result-ambiguous
