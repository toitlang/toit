// Copyright (C) 2021 Toitware ApS.
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

package toitdoc

import (
	"sort"
	"strings"

	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
)

type moduleExport struct {
	Classes   []*toit.TopLevelReference
	Functions []*toit.TopLevelReference
	Globals   []*toit.TopLevelReference
	Ambiguous []toit.Export
}

/**
computeTransitiveExports, Finds all exported identifiers and adds them to the exports map.
The values of the exports map are maps from URI to top-level identifier.
The shadowed set block-lists names that have already been seen on a "shorter"
  more direct path.
The seen set contains a list of module URIs that have already been seen (to
  avoid infinite recursion).
*/
func computeTransitiveExports(exports exports, uri lsp.DocumentURI, summaries Summaries, shadowed StringSet, seen uri.Set) {
	if seen.Contains(uri) {
		return
	}
	seen.Add(uri)

	summary := summaries[uri]

	var localShadowed StringSet
	localShadowed.AddFrom(shadowed)

	addExport := func(name string, uri lsp.DocumentURI, id toit.ID) {
		moduleMap, ok := exports[name]
		if !ok {
			moduleMap = map[lsp.DocumentURI]ToitIDSet{}
			exports[name] = moduleMap
		}

		idSet, ok := moduleMap[uri]
		if !ok {
			idSet = NewToitIDSet()
			moduleMap[uri] = idSet
		}
		idSet.Add(id)
	}

	topLevelElement := func(node toit.TopLevelElement) {
		if shadowed.Contains(node.GetName()) {
			return
		}

		addExport(node.GetName(), uri, node.GetID())
		localShadowed.Add(node.GetName())
	}

	// Add all the entries that are defined in this module.
	// These entries will shadow any imported identifiers.
	for _, c := range summary.Classes {
		topLevelElement(c)
	}
	for _, fn := range summary.Functions {
		topLevelElement(fn)
	}
	for _, g := range summary.Globals {
		topLevelElement(g)
	}

	// Add the entries that are imported with 'show'.
	// These also shadow identifiers that would be reexported from `show *` modules.
	// Remember: the `show` clause in Toit can be used to disambiguate imports.
	for _, export := range summary.Exports {
		if shadowed.Contains(export.Name) {
			continue
		}

		localShadowed.Add(export.Name)
		// TODO(florian): we lose the "ambiguous" indication here.
		// For programs without errors, this only happens if an identifier could resolve
		//   to two different modules. When we go through the collected exports later, we
		//   would catch this case again.
		// We only lose the kind, if a program has the same (non overloaded) toplevel element
		//   in the same module.
		for _, ref := range export.References {
			addExport(export.Name, ref.Module, ref.ID)
		}
	}

	for _, uri := range summary.ExportedModules {
		computeTransitiveExports(exports, uri, summaries, localShadowed, seen)
	}
	return
}

type exports map[string]map[lsp.DocumentURI]ToitIDSet

func computeModuleExports(docuri lsp.DocumentURI, summaries Summaries) moduleExport {
	var res moduleExport

	exports := exports{}
	computeTransitiveExports(exports, docuri, summaries, NewStringSet(), uri.NewSet())

	for name, moduleMap := range exports {
		// If the current uri is in the module_map, then the identifier is declared in
		//   the current module and doesn't need to be referenced through external
		//   toplevel references.
		if _, ok := moduleMap[docuri]; ok {
			continue
		}

		var topLevelRefs []*toit.TopLevelReference
		for uri, ids := range moduleMap {
			for id := range ids {
				topLevelRefs = append(topLevelRefs, &toit.TopLevelReference{
					Module: uri,
					ID:     id,
				})
			}
		}
		sort.Slice(topLevelRefs, func(i, j int) bool {
			a, b := topLevelRefs[i], topLevelRefs[j]
			comp := strings.Compare(string(a.Module), string(b.Module))
			if comp == 0 {
				return a.ID > a.ID
			}
			return comp > 0
		})

		if isAmbiguous := len(moduleMap) > 1; isAmbiguous {
			res.Ambiguous = append(res.Ambiguous, toit.Export{
				Name:       name,
				Kind:       toit.ExportKindAmbiguous,
				References: topLevelRefs,
			})
		} else {
			for i := range topLevelRefs {
				ref := topLevelRefs[i]
				node := summaries[ref.Module].TopLevelElementByID(ref.ID)
				switch t := node.(type) {
				case *toit.Class:
					res.Classes = append(res.Classes, ref)
				case *toit.TopLevelFunction:
					if t.Kind == toit.MethodKindGlobal {
						res.Globals = append(res.Globals, ref)
					} else {
						res.Functions = append(res.Functions, ref)
					}
				}
			}
		}
	}

	return res
}
