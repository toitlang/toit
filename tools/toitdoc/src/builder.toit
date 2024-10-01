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

import fs
import system

import .exports
import .inheritance as inheritance
import .tweaks
import .util

import ..lsp-exports as lsp

class DocsBuilder implements lsp.ToitdocVisitor:
  summaries/Map
  project-uri/string?
  root-path/string
  sdk-uri/string
  pkg-name/string?
  version/string?
  exclude-sdk/bool
  exclude-pkgs/bool
  include-private/bool
  is-sdk-doc/bool

  inheritance_/inheritance.Result

  constructor .summaries
      --.project-uri
      --.root-path
      --.sdk-uri
      --.pkg-name
      --.version
      --.is-sdk-doc
      --.exclude-sdk
      --.exclude-pkgs
      --.include-private:
    inheritance_ = inheritance.compute summaries

  build -> Map:
    // TODO(florian): don't rely on hardcoded ".packages" path.
    // Ideally, we should get a lock-file mapping in and use that
    // to figure out which package a file is in.
    package-uri := "$(lsp.to-uri root-path)/.packages/"

    sdk-path/List := module-path-segments sdk-uri
    pkg-packages-path/List? := null
    pkg-names/Map? := null
    if pkg-name:
      pkg-packages-path = module-path-segments package-uri
      pkg-names = load-package-names project-uri

    libraries := {:}  // From module-name (last segment) to Library

    summaries.do: | uri/string module/lsp.Module |
      if exclude-sdk and uri.starts-with sdk-uri: continue.do
      if exclude-pkgs and uri.starts-with package-uri: continue.do

      segments := module-path-segments uri --trim-extension
      module-name := segments.last
      segments[segments.size - 1] = module-name
      module-category := is-sdk-doc
          ? category-for-sdk-library segments
          : null

      if is-sdk-library-hidden segments: continue.do
      if not include-element module-name: continue.do

      // Remove the module-name from the segments. We now have it in a variable.
      segments.resize (segments.size - 1)

      parent-libraries := libraries
      library/Library? := null
      for i := 0; i < segments.size; i++:
        segment := segments[i]
        library = parent-libraries.get segment --init=:
          category := is-sdk-doc and i == 0
              ? category-for-sdk-library segments[.. i + 1]
              : null
          Library
              --name=segment
              --path=segments[..i]
              --libraries={:}
              --modules={:}
              --category=category
        parent-libraries = library.libraries

      if not library:
        library = Library
            --name=module-name
            --path=segments
            --libraries={:}
            --modules={:}
            --category=module-category
        libraries[module-name] = library

      split := build-classes-interfaces-and-mixins module.classes
      classes := split[0]
      interfaces := split[1]
      mixins := split[2]

      exports := compute-module-exports --uri=uri --summaries=summaries
      split = build-classes-interfaces-and-mixins-from-refs exports.classes
      export-classes := split[0]
      export-interfaces := split[1]
      export-mixins := split[2]

      functions := build-functions module.functions
      export-functions := build-function-refs exports.functions

      globals := build-globals module.globals
      export-globals := build-global-refs exports.globals

      toitdoc := build-toitdoc module.toitdoc

      library.modules[module-name] = Module
          --name=module-name
          --is-private=is-private module-name
          --classes=classes
          --interfaces=interfaces
          --mixins=mixins
          --export-classes=export-classes
          --export-interfaces=export-interfaces
          --export-mixins=export-mixins
          --functions=functions
          --export-functions=export-functions
          --globals=globals
          --export-globals=export-globals
          --toitdoc=toitdoc
          --category=module-category

    sdk-version := is-sdk-doc and version ? version : system.app-sdk-version
    result := Doc
        --sdk-version=sdk-version
        --version=is-sdk-doc ? null : version
        --pkg-name=pkg-name
        --sdk-path=sdk-path
        --packages-path=pkg-packages-path
        --package-names=pkg-names
        --libraries=libraries

    return result.to-json

  /**
  Builds the given $classes.

  Filters out elements that should not be included (see $include-class).

  Splits the result into three lists: classes, interfaces, and mixins.
  Returns a three-element list, with each element being a list of classes.
  */
  build-classes-interfaces-and-mixins classes/List -> List:
    result-classes := []
    result-interfaces := []
    result-mixins := []

    classes.do: | klass/lsp.Class |
      if not include-class klass: continue.do
      built := build-class klass
      if klass.is-interface: result-interfaces.add built
      else if klass.is-mixin: result-mixins.add built
      else: result-classes.add built

    return [result-classes, result-interfaces, result-mixins]

  /**
  Builds the given $refs.

  Variant of $build-classes-interfaces-and-mixins that works on references.
  */
  build-classes-interfaces-and-mixins-from-refs refs/List -> List:
    result-classes := []
    result-interfaces := []
    result-mixins := []

    refs.do: | ref/lsp.ToplevelRef |
      klass := resolve-class ref
      if not include-class klass: continue.do
      built := build-class klass --ref=ref
      if klass.is-interface: result-interfaces.add built
      else if klass.is-mixin: result-mixins.add built
      else: result-classes.add built

    return [result-classes, result-interfaces, result-mixins]

  /**
  Builds the given $methods.

  Filters the functions that should not be included (see $include-method).
  */
  build-functions methods/List -> List:
    result := []
    methods.do: | method/lsp.Method |
      if not include-method method: continue.do
      built := build-method method
      result.add built
    return result

  /**
  Builds the given $refs.

  Variant of $build-functions that works on references.
  */
  build-function-refs refs/List -> List:
    result := []
    refs.do: | ref/lsp.ToplevelRef |
      method := resolve-global ref
      if not include-method method: continue.do
      built := build-method method --ref=ref
      result.add built
    return result

  /**
  Builds the given $globals.

  The $globals must be a list of $lsp.Method. Contrary to $build-functions,
    this function use $build-global for each element.

  Filters the globals that should not be included (see $include-method).
  */
  build-globals globals/List -> List:
    result := []
    globals.do: | global/lsp.Method |
      if not include-method global: continue.do
      built := build-global global
      result.add built
    return result

  /**
  Builds the given $refs.

  Variant of $build-globals that works on references.
  */
  build-global-refs refs/List -> List:
    result := []
    refs.do: | ref/lsp.ToplevelRef |
      global := resolve-global ref
      if not include-method global: continue.do
      built := build-global global --ref=ref
      result.add built
    return result

  build-class klass/lsp.Class --ref/lsp.ToplevelRef?=null -> Class:
    built-fields := build-fields klass.fields
    built-methods := build-functions klass.methods
    if inherited := inheritance_.inherited.get klass:
      inherited-fields := []
      inherited-methods := []
      inherited.do: | member/inheritance.InheritedMember |
        if member.is-field:
          inherited-fields.add member.as-field
        else:
          inherited-methods.add member.as-method
      built-inherited-fields := build-fields inherited-fields
      built-inherited-fields.do: | field/Field | field.is-inherited = true
      built-fields.add-all built-inherited-fields

      built-inherited-methods := build-functions inherited-methods
      built-inherited-methods.do: | method/Function | method.is-inherited = true
      built-methods.add-all built-inherited-methods

    // According to the summary, interfaces also implement themselves. We
    // don't want that in the toitdoc.
    interfaces := klass.interfaces
    already-removed := false
    if klass.is-interface:
      interfaces = interfaces.filter: | ref/lsp.ToplevelRef |
        if already-removed: continue.filter true
        resolved := resolve-class ref
        if ref != klass: continue.filter true
        already-removed = true
        false

    structure := ClassStructure
        --statics=build-functions klass.statics
        --constructors=build-functions klass.constructors
        --factories=build-functions klass.factories
        --fields=built-fields
        --methods=built-methods

    return Class
      --name=klass.name
      --kind=klass.kind
      --is-abstract=klass.is-abstract
      --is-private=is-private klass.name
      --exported-from=build-exported-from ref
      --interfaces=build-toplevel-refs interfaces
      --mixins=build-toplevel-refs klass.mixins
      --extends=build-toplevel-ref klass.superclass
      --structure=structure
      --toitdoc=build-toitdoc klass.toitdoc

  build-exported-from ref/lsp.ToplevelRef? -> ToplevelRef?:
    if not ref: return null
    segments := module-path-segments ref.module-uri
    name := segments.last
    return build-toplevel-ref ref --name-override=name

  build-toplevel-ref ref/lsp.ToplevelRef? --name-override/string?=null -> ToplevelRef?:
    if not ref: return null

    target-module/lsp.Module := summaries[ref.module-uri]
    name := name-override or (target-module.toplevel-element-with-id ref.id).name
    if not include-element name: return null

    return ToplevelRef
        --name=name
        --path=module-path-segments ref.module-uri

  build-toplevel-refs refs/List -> List:
    result := []
    refs.do: | ref/lsp.ToplevelRef |
      built := build-toplevel-ref ref
      if built: result.add built
    return result

  build-global global/lsp.Method --ref/lsp.ToplevelRef?=null -> Global:
    return Global
        --name=global.name
        --is-private=is-private global.name
        --exported-from=build-exported-from ref
        --toitdoc=build-toitdoc global.toitdoc
        --type=build-type global.return-type

  build-method method/lsp.Method --ref/lsp.ToplevelRef?=null -> Function:
    return Function
        --name=method.name
        --is-private=is-private method.name
        --is-abstract=method.is-abstract
        --is-synthetic=method.is-synthetic
        --exported-from=build-exported-from ref
        --parameters=build-parameters method.parameters
        --return-type=build-type method.return-type
        --toitdoc=build-toitdoc method.toitdoc
        --shape=build-shape method

  build-fields fields/List -> List:
    result := []
    fields.do: | field/lsp.Field |
      if not include-element field.name: continue.do
      built := build-field field
      result.add built
    return result

  build-field field/lsp.Field -> Field:
    return Field
        --name=field.name
        --is-private=is-private field.name
        --type=build-type field.type
        --toitdoc=build-toitdoc field.toitdoc

  build-type type/lsp.Type -> Type:
    return Type
        --is-none=type.is-none
        --is-any=type.is-any
        --is-block=type.is-block
        --reference=build-toplevel-ref type.class-ref

  build-parameters parameters/List -> List:
    // Provide the parameters in the same order as the user wrote them.
    sorted := parameters.sort: | a/lsp.Parameter b/lsp.Parameter |
      a.original-index.compare-to b.original-index
    return sorted.map: | parameter/lsp.Parameter |
      build-parameter parameter

  build-parameter parameter/lsp.Parameter -> Parameter:
    return Parameter
        --name=parameter.name
        --is-block=parameter.is-block
        --is-named=parameter.is-named
        --is-required=parameter.is-required
        --default-value=parameter.default-value
        --type=build-type parameter.type

  build-shape method/lsp.Method -> Shape:
    arity := method.parameters.size
    total-block-count := 0
    named-block-count := 0
    non-block-names := []
    block-names := []

    method.parameters.do: | param/lsp.Parameter |
      is-block := param.is-block
      if is-block: total-block-count++
      if not param.is-named: continue.do
      if is-block:
        named-block-count++
        block-names.add param.name
      else:
        non-block-names.add param.name

    block-names.sort --in-place
    non-block-names.sort --in-place
    return Shape
        --arity=arity
        --total-block-count=total-block-count
        --named-block-count=named-block-count
        --names=non-block-names + block-names

  build-toitdoc doc/lsp.Contents? -> Toitdoc?:
    if not doc: return null
    return doc.accept this

  visit-doc node/lsp.Node -> any:
    return node.accept this

  visit-Contents doc/lsp.Contents -> Toitdoc:
    sections := doc.sections.map: visit-doc it
    return Toitdoc --sections=sections

  visit-Section section/lsp.Section -> DocSection:
    statements := section.statements.map: visit-doc it
    return DocSection --title=section.title --level=section.level --statements=statements

  visit-CodeSection code/lsp.CodeSection -> DocCodeSection:
    return DocCodeSection --text=code.text

  visit-Itemized itemized/lsp.Itemized -> DocItemized:
    items := itemized.items.map: visit-doc it
    return DocItemized --items=items

  visit-Item item/lsp.Item -> DocItem:
    statements := item.statements.map: visit-doc it
    return DocItem --statements=statements

  visit-Paragraph paragraph/lsp.Paragraph:
    expressions := paragraph.expressions.map: visit-doc it
    return DocParagraph --expressions=expressions

  visit-Text text/lsp.Text -> DocText:
    return DocText --text=text.text

  visit-Code code/lsp.Code -> DocCode:
    return DocCode --text=code.text

  visit-ToitdocRef ref/lsp.ToitdocRef -> DocToitdocRef:
    name := ref.name
    if ref.shape and ref.shape.is-setter:
      name = "$name="
    kind := convert-toitdoc-ref-kind ref.kind
    return DocToitdocRef
        --kind=kind
        --text=ref.text
        --path=module-path-segments ref.module-uri
        --holder=ref.holder
        --name=name
        --shape=build-doc-shape ref.shape

  visit-Link link/lsp.Link -> DocLink:
    return DocLink --text=link.text --url=link.url

  build-doc-shape shape/lsp.Shape? -> Shape?:
    if not shape: return null
    return Shape
        --arity=shape.arity
        --total-block-count=shape.total-block-count
        --named-block-count=shape.named-block-count
        --names=shape.names

  convert-toitdoc-ref-kind kind/int -> string:
    if kind == lsp.ToitdocRef.CLASS: return DocToitdocRef.KIND-CLASS
    if kind == lsp.ToitdocRef.GLOBAL: return DocToitdocRef.KIND-GLOBAL
    if kind == lsp.ToitdocRef.GLOBAL_METHOD: return DocToitdocRef.KIND-GLOBAL-METHOD
    if kind == lsp.ToitdocRef.STATIC_METHOD: return DocToitdocRef.KIND-STATIC-METHOD
    if kind == lsp.ToitdocRef.CONSTRUCTOR: return DocToitdocRef.KIND-CONSTRUCTOR
    if kind == lsp.ToitdocRef.FACTORY: return DocToitdocRef.KIND-FACTORY
    if kind == lsp.ToitdocRef.METHOD: return DocToitdocRef.KIND-METHOD
    if kind == lsp.ToitdocRef.FIELD: return DocToitdocRef.KIND-FIELD
    if kind == lsp.ToitdocRef.PARAMETER: return DocToitdocRef.KIND-PARAMETER
    if kind == lsp.ToitdocRef.OTHER: return DocToitdocRef.KIND-OTHER
    throw "Unknown kind: $kind"

  include-class klass/lsp.Class -> bool:
    return include-element klass.name

  include-method method/lsp.Method -> bool:
    return not method.is-synthetic and include-element method.name

  include-element name/string -> bool:
    return include-private or not is-private name

  is-private name/string -> bool:
    return name.ends-with "_" or name.ends-with "_="

  resolve-class klass/lsp.ToplevelRef -> lsp.Class:
    return resolve-class-ref klass --summaries=summaries

  resolve-global global/lsp.ToplevelRef -> lsp.Method:
    return resolve-global-ref global --summaries=summaries

  /**
  Returns the path segments of the URI, relative to the root path.
  */
  module-path-segments uri/string? --trim-extension/bool=false -> List?:
    if not uri: return null
    path := lsp.to-path uri
    inside-root-path := path.starts-with root-path
    if inside-root-path:
      path = path.trim --left root-path
    path = path.trim --left fs.SEPARATOR
    result := fs.split path
    if not inside-root-path:
      result = ["@"] + result
    if result.size > 0 and pkg-name and result.first == "src":
      result[0] = pkg-name
    if trim-extension:
      result[result.size - 1] = result.last.trim --right ".toit"
    result.map --in-place: kebabify it
    return result

/**
A compiled version of the Toitdocs.
*/
class Doc:
  sdk-version/string
  sdk-path/List
  version/string?
  pkg-name/string?
  packages-path/List?
  package-names/Map?
  libraries/Map

  constructor
      --.sdk-version
      --.sdk-path
      --.version
      --.pkg-name
      --.packages-path
      --.package-names
      --.libraries:

  to-json -> any:
    result := {
      "sdk_version": sdk-version,
      "sdk_path": sdk-path,
      "libraries": libraries.map: | _ library/Library | library.to-json,
    }

    if version: result["version"] = version
    if pkg-name: result["pkg_name"] = pkg-name
    if packages-path: result["packages_path"] = packages-path
    if package-names: result["package_names"] = package-names

    return result

class Library:
  static TYPE ::= "library"

  static CATEGORY-FUNDAMENTAL ::= "fundamental"
  static CATEGORY-JUST-THERE ::= "just_there"
  static CATEGORY-MISC ::= "misc"
  static CATEGORY-SUB ::= "sub"  // A category for libraries that aren't at the top-level.

  name/string
  path/List
  libraries/Map
  modules/Map
  category/string?

  constructor
      --.name
      --.path
      --.libraries
      --.modules
      --.category:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "path": path,
      "libraries": libraries.map: | _ library/Library | library.to-json,
      "modules": modules.map: | _ module/Module | module.to-json,
    }
    if category: result["category"] = category
    return result

class Module:
  static TYPE ::= "module"

  name/string
  is-private/bool
  classes/List
  interfaces/List
  mixins/List
  export-classes/List
  export-interfaces/List
  export-mixins/List
  functions/List
  export-functions/List
  globals/List
  export-globals/List
  toitdoc/Toitdoc?
  category/string?

  constructor
      --.name
      --.is-private
      --.classes
      --.interfaces
      --.mixins
      --.export-classes
      --.export-interfaces
      --.export-mixins
      --.functions
      --.export-functions
      --.globals
      --.export-globals
      --.toitdoc
      --.category:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "is_private": is-private,
      "classes": classes.map: it.to-json,
      "interfaces": interfaces.map: it.to-json,
      "mixins": mixins.map: it.to-json,
      "export_classes": export-classes.map: it.to-json,
      "export_interfaces": export-interfaces.map: it.to-json,
      "export_mixins": export-mixins.map: it.to-json,
      "functions": functions.map: it.to-json,
      "export_functions": export-functions.map: it.to-json,
      "globals": globals.map: it.to-json,
      "export_globals": export-globals.map: it.to-json,
    }
    if category: result["category"] = category
    if toitdoc: result["toitdoc"] = toitdoc.to-json
    return result

class ToplevelRef:
  static TYPE ::= "reference"

  name/string
  path/List

  constructor --.name --.path:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "name": name,
      "path": path,
    }

class Class:
  static TYPE ::= "class"

  name/string
  kind/string
  is-abstract/bool
  is-private/bool
  exported-from/ToplevelRef?
  interfaces/List  // Of ToplevelRef.
  mixins/List  // Of ToplevelRef.
  extends/ToplevelRef?
  structure/ClassStructure
  toitdoc/Toitdoc?

  constructor
      --.name
      --.kind
      --.is-abstract
      --.is-private
      --.exported-from
      --.interfaces
      --.mixins
      --.extends
      --.structure
      --.toitdoc:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "kind": kind,
      "is_abstract": is-abstract,
      "is_private": is-private,
      "interfaces": interfaces.map: it.to-json,
      "mixins": mixins.map: it.to-json,
      "structure": structure.to-json,
    }
    if exported-from: result["exported_from"] = exported-from.to-json
    if extends: result["extends"] = extends.to-json
    if toitdoc: result["toitdoc"] = toitdoc.to-json
    return result

class ClassStructure:
  statics/List // Of Function.
  constructors/List // Of Function.
  factories/List // Of Function.
  fields/List // Of Field.
  methods/List // Of Function.

  constructor
      --.statics
      --.constructors
      --.factories
      --.fields
      --.methods:

  to-json -> Map:
    return {
      "statics": statics.map: it.to-json,
      "constructors": constructors.map: it.to-json,
      "factories": factories.map: it.to-json,
      "fields": fields.map: it.to-json,
      "methods": methods.map: it.to-json,
    }

class Type:
  static TYPE ::= "type"

  is-none/bool
  is-any/bool
  is-block/bool
  reference/ToplevelRef?

  constructor --.is-none --.is-any --.is-block --.reference:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "is_none": is-none,
      "is_any": is-any,
      "is_block": is-block,
    }
    if reference: result["reference"] = reference.to-json
    return result

class Global:
  static TYPE ::= "global"

  name/string
  is-private/bool
  exported-from/ToplevelRef?
  type/Type
  toitdoc/Toitdoc?

  constructor --.name --.is-private --.exported-from --.type --.toitdoc:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "is_private": is-private,
      "type": type.to-json,
    }
    if exported-from: result["exported_from"] = exported-from.to-json
    if toitdoc: result["toitdoc"] = toitdoc.to-json
    return result

class Function:
  static TYPE ::= "function"

  name/string
  is-private/bool
  is-abstract/bool
  is-synthetic/bool
  exported-from/ToplevelRef?
  parameters/List // Of Parameter.
  return-type/Type
  shape/Shape
  is-inherited/bool := false
  toitdoc/Toitdoc?

  constructor
      --.name
      --.is-private
      --.is-abstract
      --.is-synthetic
      --.exported-from
      --.parameters
      --.return-type
      --.shape
      --.toitdoc:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "is_private": is-private,
      "is_abstract": is-abstract,
      "is_synthetic": is-synthetic,
      "parameters": parameters.map: it.to-json,
      "return_type": return-type.to-json,
      "shape": shape.to-json,
    }
    if exported-from: result["exported_from"] = exported-from.to-json
    if toitdoc: result["toitdoc"] = toitdoc.to-json
    return result

class Field:
  static TYPE ::= "field"

  name/string
  is-private/bool
  type/Type
  is-inherited/bool := false
  toitdoc/Toitdoc?

  constructor --.name --.is-private --.type --.toitdoc:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "is_private": is-private,
      "is_inherited": is-inherited,
      "type": type.to-json,
    }
    if toitdoc: result["toitdoc"] = toitdoc.to-json
    return result

class Parameter:
  static TYPE ::= "parameter"

  name/string
  is-block/bool
  is-named/bool
  is-required/bool
  type/Type
  default-value/string?

  constructor --.name --.is-block --.is-named --.is-required --.type --.default-value:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "name": name,
      "is_block": is-block,
      "is_named": is-named,
      "is_required": is-required,
      "type": type.to-json,
    }
    if default-value: result["default_value"] = default-value
    return result

class Shape:
  static TYPE ::= "shape"

  arity/int
  total-block-count/int
  named-block-count/int
  /**
  A list of names for the named parameters.
  The non-block parameters are first, in alphabetical order.
  Then the named block parameters, also in alphabetical order.
  */
  names/List

  constructor --.arity --.total-block-count --.named-block-count --.names:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "arity": arity,
      "total_block_count": total-block-count,
      "named_block_count": named-block-count,
      "names": names,
    }

class Toitdoc:
  sections/List // Of DocSection.

  constructor --.sections:

  to-json -> List:
    return sections.map: it.to-json

class DocSection:
  static TYPE ::= "section"
  title/string?
  level/int
  statements/List // Of DocStatement.

  constructor --.title --.level --.statements:

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "level": level,
      "statements": statements.map: it.to-json,
    }
    if title: result["title"] = title
    return result

abstract class DocStatement:
  abstract to-json -> Map

class DocCodeSection extends DocStatement:
  static TYPE ::= "statement_code_section"

  text/string

  constructor --.text:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "text": text,
    }

class DocItemized extends DocStatement:
  static TYPE ::= "statement_itemized"

  items/List // Of DocItem.

  constructor --.items:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "items": items.map: it.to-json,
    }

class DocItem:
  static TYPE ::= "statement_item"

  statements/List // Of DocStatement.

  constructor --.statements:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "statements": statements.map: it.to-json,
    }

class DocParagraph extends DocStatement:
  static TYPE ::= "statement_paragraph"

  expressions/List // Of DocExpression.

  constructor --.expressions:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "expressions": expressions.map: it.to-json,
    }

abstract class DocExpression:
  abstract to-json -> Map

class DocText extends DocExpression:
  static TYPE ::= "expression_text"

  text/string

  constructor --.text:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "text": text,
    }

class DocCode extends DocExpression:
  static TYPE ::= "expression_code"

  text/string

  constructor --.text:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "text": text,
    }

class DocLink extends DocExpression:
  static TYPE ::= "expression_link"

  text/string
  url/string

  constructor --.text --.url:

  to-json -> Map:
    return {
      "object_type": TYPE,
      "text": text,
      "url": url,
    }

class DocToitdocRef extends DocExpression:
  static TYPE ::= "toitdocref"

  static KIND-OTHER ::= "other"
  static KIND-CLASS ::= "class"
  static KIND-GLOBAL ::= "global"
  static KIND-GLOBAL-METHOD ::= "global-method"
  static KIND-STATIC-METHOD ::= "static-method"
  static KIND-CONSTRUCTOR ::= "constructor"
  static KIND-FACTORY ::= "factory"
  static KIND-METHOD ::= "method"
  static KIND-FIELD ::= "field"
  static KIND-PARAMETER ::= "parameter"

  kind/string
  text/string
  path/List?  // Of string.
  holder/string?
  name/string?
  shape/Shape?

  constructor
      --.kind
      --.text
      --.path
      --.holder
      --.name
      --.shape:
    // The KIND-OTHER currently includes references to parameters
    // which don't have a path.
    assert: path != null or kind == KIND-OTHER

  to-json -> Map:
    result := {
      "object_type": TYPE,
      "kind": kind,
      "text": text,
      "path": path,
      "name": name,
    }
    if holder: result["holder"] = holder
    if shape: result["shape"] = shape.to-json
    return result
