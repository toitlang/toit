// Copyright (C) 2019 Toitware ApS.
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

import reader show BufferedReader
import .uri-path-translator
import .protocol.document-symbol as lsp
import .protocol.document as lsp
import .toitdoc-node
import .utils show interval-binary-search

ERROR-NAME ::= "<Error>"
safe-name_ name/string -> string:
  if name == "": return ERROR-NAME
  return name

/** A summary of a module. */
class Module:
  uri / string ::= ?
  dependencies / List/*<string>*/ ::= ?
  exported-modules / List/*<string>*/ ::= ?
  exports      / List ::= ?
  classes      / List ::= ?
  functions    / List ::= ?
  globals      / List/*<Method>*/ ::= ?
  toitdoc      / Contents? ::= ?

  constructor
      --.uri
      --.dependencies
      --.exports
      --.exported-modules
      --.classes
      --.functions
      --.globals
      --.toitdoc:

  equals-external other/Module -> bool:
    return other and
        uri == other.uri and
        // The dependencies only have an external impact if `export_all` is true. However, we
        //    conservatively just return require that they are the same.
        dependencies == other.dependencies and
        exported-modules == other.exported-modules and
        (exports.equals other.exports --element-equals=: |a b| a.equals-external b) and
        (classes.equals other.classes --element-equals=: |a b| a.equals-external b) and
        (functions.equals other.functions --element-equals=: |a b| a.equals-external b) and
        (globals.equals other.globals --element-equals=: |a b| a.equals-external b)

  to-lsp-document-symbol content/string -> List/*<DocumentSymbol>*/:
    lines := Lines content
    result := []
    classes.do: result.add (it.to-lsp-document-symbol lines)
    functions.do: result.add (it.to-lsp-document-symbol lines)
    globals.do: result.add (it.to-lsp-document-symbol lines)
    return result

  /**
  Finds the toplevel element with the given $id.
  Returns either a class or a method.
  */
  toplevel-element-with-id id/int -> any:
    if id < classes.size: return classes[id]
    id -= classes.size
    if id < functions.size: return functions[id]
    id -= functions.size
    assert: id < globals.size
    return globals[id]

class Export:
  static AMBIGUOUS ::= 0
  static NODES ::= 1

  name / string ::= ?
  kind / int ::= ?
  refs / List /* ToplevelRef */ ::= ?

  constructor .name .kind .refs:

  equals-external other/Export -> bool:
    return other and
        name == other.name and
        kind == other.kind and
        refs.equals other.refs --element-equals=: |a b| a.equals-external b

class Range:
  start / int ::= -1
  end / int ::= -1

  constructor .start .end:

  to-lsp-range lines/Lines -> lsp.Range:
    return lsp.Range
        lines.lsp-position-for-offset start
        lines.lsp-position-for-offset end

class ToplevelRef:
  module-uri / string ::= ?
  id / int ::= 0

  constructor .module-uri .id:
    assert: id >= 0

  equals-external other/ToplevelRef -> bool:
    return other and module-uri == other.module-uri and id == other.id

class Type:
  static ANY-KIND ::= -1
  static NONE-KIND ::= -2
  static BLOCK-KIND ::= -3
  static CLASS-KIND ::= 0

  static ANY / Type ::= Type.internal_ ANY-KIND null
  static NONE / Type ::= Type.internal_ NONE-KIND null
  static BLOCK / Type ::= Type.internal_ BLOCK-KIND null

  kind / int ::= 0
  class-ref / ToplevelRef? ::= ?

  constructor .class-ref: kind = 0
  constructor.internal_ .kind .class-ref:

  is-block -> bool: return kind == BLOCK-KIND
  is-any -> bool: return kind == ANY-KIND
  is-none -> bool: return kind == NONE-KIND

  equals-external other/Type -> bool:
    return other and kind == other.kind and class-ref.equals-external other.class-ref

hash-code-counter_ := 0

class Class:
  static KIND_CLASS ::= "class"
  static KIND_INTERFACE ::= "interface"
  static KIND_MIXIN ::= "mixin"

  name  / string ::= ?
  range / Range  ::= ?
  toplevel-id / int ::= ?

  kind         / string ::= ?
  is_abstract  / bool ::= false

  superclass   / ToplevelRef? ::= ?
  interfaces   / List ::= ?
  mixins       / List ::= ?

  statics      / List ::= ?
  constructors / List ::= ?  // Only unnamed constructors
  factories    / List ::= ?  // Only unnamed factories

  fields  / List ::= ?
  methods / List ::= ?

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.toplevel-id --.kind --.is-abstract
      --.superclass --.interfaces --.mixins
      --.statics --.constructors --.factories --.fields --.methods  --.toitdoc:

  equals-external other/Class -> bool:
    return other and
        name == other.name and
        kind == other.kind and
        is-abstract == other.is-abstract and
        (superclass == other.superclass or (superclass and superclass.equals-external other.superclass)) and
        (interfaces.equals other.interfaces --element-equals=: |a b| a.equals-external b) and
        (mixins.equals other.mixins --element_equals=: |a b| a.equals-external b) and
        (statics.equals other.statics --element-equals=: |a b| a.equals-external b) and
        (constructors.equals other.constructors --element-equals=: |a b| a.equals-external b) and
        (factories.equals other.factories --element-equals=: |a b| a.equals-external b) and
        (fields.equals other.fields --element-equals=: |a b| a.equals-external b) and
        (methods.equals other.methods --element-equals=: |a b| a.equals-external b)

  to-lsp-document-symbol lines/Lines -> lsp.DocumentSymbol:
    children := []

    add-method-symbol := :
      if not it.is-synthetic:
        children.add (it.to-lsp-document-symbol lines)

    statics.do      add-method-symbol
    constructors.do add-method-symbol
    factories.do    add-method-symbol
    methods.do      add-method-symbol
    fields.do: children.add (it.to-lsp-document-symbol lines)
    return lsp.DocumentSymbol
        --name=safe-name_ name
        --kind= kind == KIND-INTERFACE ? lsp.SymbolKind.INTERFACE : lsp.SymbolKind.CLASS  // Mixins count as class.
        --range=range.to-lsp-range lines
        --selection-range=range.to-lsp-range lines
        --children=children

class Method:
  static INSTANCE-KIND ::= 0
  static GLOBAL-FUN-KIND ::= 1
  static GLOBAL-KIND ::= 2
  static CONSTRUCTOR-KIND ::= 3
  static FACTORY-KIND ::= 4

  hash-code / int ::= hash-code-counter_++

  name        / string ::= ?
  range       / Range  ::= ?
  toplevel-id / int    ::= ?
  kind / int ::= 0
  parameters  / List  ::= ?
  return-type / Type? ::= ?

  is-abstract  / bool ::= false
  is-synthetic / bool ::= false

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.toplevel-id --.kind --.parameters --.return-type --.is-abstract --.is-synthetic --.toitdoc:

  equals-external other/Method -> bool:
    return other and
        name == other.name and
        kind == other.kind and
        is-abstract == other.is-abstract and
        (parameters.equals other.parameters --element-equals=: |a b| a.equals-external b) and
        (return-type == other.return-type or (return-type and return-type.equals-external other.return-type))

  to-lsp-document-symbol lines/Lines -> lsp.DocumentSymbol:
    lsp-kind := -1
    if kind == INSTANCE-KIND:         lsp-kind = lsp.SymbolKind.METHOD
    else if kind == GLOBAL-FUN-KIND:  lsp-kind = lsp.SymbolKind.FUNCTION
    else if kind == GLOBAL-KIND:      lsp-kind = lsp.SymbolKind.VARIABLE
    else if kind == CONSTRUCTOR-KIND: lsp-kind = lsp.SymbolKind.CONSTRUCTOR
    else if kind == FACTORY-KIND:     lsp-kind = lsp.SymbolKind.CONSTRUCTOR
    else: throw "Unexpected method kind: $kind"

    details := ""
    if kind != GLOBAL-KIND:
      parameter-details := parameters.map:
        detail := it.name
        if it.is-named: detail = "--" + detail
        if not it.is-required: detail = detail + "="
        if it.type and it.type.is-block: detail = "[" + detail + "]"
        detail
      details = parameter-details.join " "

    return lsp.DocumentSymbol
        --name=safe-name_ name
        --detail=details
        --kind=lsp-kind
        --range=range.to-lsp-range lines
        --selection-range=range.to-lsp-range lines

class Field:
  name / string ::= ?
  range / Range ::= ?
  is-final / bool ::= false
  type / Type? ::= ?

  toitdoc / Contents? ::= ?

  constructor .name .range .is-final .type .toitdoc:

  equals-external other/Field -> bool:
    return other and
        name == other.name and
        is-final == other.is-final and
        (type == other.type or (type and type.equals-external other.type))

  to-lsp-document-symbol lines/Lines -> lsp.DocumentSymbol:
    return lsp.DocumentSymbol
        --name=safe-name_ name
        --kind=lsp.SymbolKind.FIELD
        --range=range.to-lsp-range lines
        --selection-range=range.to-lsp-range lines

class Parameter:
  name / string ::= ?
  original-index / int ::= ?
  is-required / bool ::= ?
  is-named / bool ::= ?
  type / Type? ::= ?

  constructor .name .original-index --.is-required --.is-named .type:

  is-block -> bool: return type and type.is-block

  equals-external other/Parameter -> bool:
    return other and
        name == other.name and
        is-required == other.is-required and
        is-named == other.is-named and
        (type == other.type or (type and type.equals-external other.type))

class SummaryReader:
  reader_ / BufferedReader ::= ?
  uri-path-translator_ / UriPathTranslator ::= ?

  module-uris_             / List ::= []
  module-toplevel-offsets_ / List ::= []
  current-module-id_ := 0
  current-toplevel-id_ := 0

  constructor .reader_ .uri-path-translator_:

  to-uri_ path / string -> string: return uri-path-translator_.to-uri path --from-compiler

  read-summary -> Map/*<uri, Module>*/:
    module-count := read-int
    module-offset := 0
    module-count.repeat:
      module-path := read-line
      module-uri := to-uri_ module-path
      module-uris_.add module-uri
      module-toplevel-offsets_.add module-offset
      toplevel-count := read-int
      module-offset += toplevel-count

    result := {:}
    assert: current-module-id_ == 0
    module-count.repeat:
      module := read-module
      result[module.uri] = module
      current-module-id_++
    return result

  read-module -> Module:
    current-toplevel-id_ = 0;
    module-offset := module-toplevel-offsets_[current-module-id_]
    module-path := read-line
    module-uri := to-uri_ module-path
    assert: module-uri == module-uris_[current-module-id_]

    dependencies := read-list: to-uri_ read-line
    exported-modules := read-list: to-uri_ read-line
    exported := read-list: read-export
    // The order also defines the toplevel-ids.
    // Classes go before toplevel functions, before globals.
    classes := read-list: read-class
    functions := read-list: read-method
    globals := read-list: read-method
    toitdoc := read-toitdoc
    return Module
        --uri=module-uri
        --dependencies=dependencies
        --exported-modules=exported-modules
        --exports=exported
        --classes=classes
        --functions=functions
        --globals=globals
        --toitdoc=toitdoc

  read-export -> Export:
    name := read-line
    kind := read-line == "AMBIGUOUS" ? Export.AMBIGUOUS : Export.NODES
    refs := read-list: read-toplevel-ref
    return Export name kind refs

  read-class -> Class:
    toplevel-id := current-toplevel-id_++
    name := read-line
    range := read-range
    global-id := read-int
    assert: global-id == toplevel-id + module-toplevel-offsets_[current-module-id_]
    kind := read-line
    assert: kind == Class.KIND-CLASS or kind == Class.KIND-INTERFACE or kind == Class.KIND-MIXIN
    is-abstract := read-line == "abstract"
    superclass := read-toplevel-ref
    interfaces := read-list: read-toplevel-ref
    mixins := read-list: read-toplevel-ref
    statics := read-list: read-method
    constructors := read-list: read-method
    factories := read-list: read-method
    fields := read-list: read-field
    methods := read-list: read-method
    toitdoc := read-toitdoc
    return Class
        --name=name
        --range=range
        --toplevel-id=toplevel-id
        --kind=kind
        --is-abstract=is-abstract
        --superclass=superclass
        --interfaces=interfaces
        --mixins=mixins
        --statics=statics
        --constructors=constructors
        --factories=factories
        --fields=fields
        --methods=methods
        --toitdoc=toitdoc

  read-method -> Method:
    name := read-line
    range := read-range
    global-id := read-int  // Might be -1
    toplevel-id := (global-id == -1) ? -1 : global-id - module-toplevel-offsets_[current-module-id_]
    kind-string := read-line
    kind := -1
    is-abstract := false
    is-synthetic := false
    if kind-string == "instance":
      kind = Method.INSTANCE-KIND
      assert: global-id == -1
    else if kind-string == "abstract":
      kind = Method.INSTANCE-KIND
      is-abstract = true
      assert: global-id == -1
    else if kind-string == "field stub":
      kind = Method.INSTANCE-KIND
      is-synthetic = true
      assert: global-id == -1
    else if kind-string == "global fun":
      kind = Method.GLOBAL-FUN-KIND
      if global-id != -1:
        // If the read id is -1, then it's just a class-static.
        assert: current-toplevel-id_ == toplevel-id
        current-toplevel-id_++
    else if kind-string == "global initializer":
      kind = Method.GLOBAL-KIND
      if global-id != -1:
        // If the read id is -1, then it's just a class-static.
        assert: current-toplevel-id_ == toplevel-id
        current-toplevel-id_++
    else if kind-string == "constructor":
      kind = Method.CONSTRUCTOR-KIND
      assert: global-id == -1
    else if kind-string == "default constructor":
      kind = Method.CONSTRUCTOR-KIND
      is-synthetic = true
      assert: global-id == -1
    else if kind-string == "factory":
      kind = Method.FACTORY-KIND
      assert: global-id == -1
    else:
      throw "Unknown kind"
    parameters := read-list: read-parameter
    return-type := read-type
    toitdoc := read-toitdoc
    return Method
        --name=name
        --range=range
        --toplevel-id=toplevel-id
        --kind=kind
        --parameters=parameters
        --return-type=return-type
        --is-abstract=is-abstract
        --is-synthetic=is-synthetic
        --toitdoc=toitdoc

  read-parameter -> Parameter:
    name := read-line
    original-index := read-int
    kind := read-line
    is-required := kind == "required" or kind == "required named"
    is-named := kind == "required named" or kind == "optional named"
    type := read-type
    is-block := type.is-block
    return Parameter name original-index --is-required=is-required --is-named=is-named type

  read-field -> Field:
    name := read-line
    range := read-range
    is-final := read-line == "final"
    type := read-type
    toitdoc := read-toitdoc
    return Field name range is-final type toitdoc

  read-toitdoc -> Contents?:
    sections := read-list: read-section
    if sections.is-empty: return null
    return Contents sections

  read-section -> Section:
    title := null
    title = read-toitdoc-symbol
    if title == "": title = null
    return Section
      title
      read-list: read-statement

  read-statement -> Statement:
    kind := read-line
    if kind == "CODE SECTION": return read-code-section
    if kind == "ITEMIZED": return read-itemized
    assert: kind == "PARAGRAPH"
    return read-paragraph

  read-code-section -> CodeSection:
    return CodeSection read-toitdoc-symbol

  read-itemized -> Itemized:
    return Itemized
        read-list: read-item

  read-item -> Item:
    kind := read-line
    assert: kind == "ITEM"
    return Item
        read-list: read-statement

  read-paragraph -> Paragraph:
    return Paragraph
        read-list: read-expression

  read-expression -> Expression:
    kind := read-line
    if kind == "TEXT": return Text read-toitdoc-symbol
    if kind == "CODE": return Code read-toitdoc-symbol
    assert: kind == "REF"
    return read-toitdoc-ref

  read-toitdoc-ref -> ToitdocRef:
    text := read-toitdoc-symbol
    kind := read-int
    if kind < 0 or kind == ToitdocRef.OTHER:
      // Either bad reference, or not yet supported.
      return ToitdocRef.other text

    assert: ToitdocRef.CLASS <= kind <= ToitdocRef.FIELD
    module-uri := to-uri_ read-line
    holder := null
    if kind >= ToitdocRef.STATIC-METHOD:
      holder = read-toitdoc-symbol
    name := read-toitdoc-symbol
    shape := null
    if ToitdocRef.GLOBAL-METHOD <= kind <= ToitdocRef.METHOD:
      shape = read-toitdoc-shape
    return ToitdocRef
        --text=text
        --kind=kind
        --module-uri=module-uri
        --holder=holder
        --name=name
        --shape=shape

  read-toitdoc-shape -> Shape:
    arity := read-int
    total-block-count := read-int
    name-count := read-int
    named-block-count := read-int
    is-setter := read-line == "setter"
    names := List name-count: read-toitdoc-symbol
    return Shape
        --arity=arity
        --total-block-count=total-block-count
        --named-block-count=named-block-count
        --is-setter=is-setter
        --names=names

  read-toitdoc-symbol -> string:
    size := read-int
    str := reader_.read-string size
    reader_.read-byte  // Read the '\n'
    return str

  toplevel-ref-from-global-id id/int -> ToplevelRef:
    assert: id >= 0
    module-id := interval-binary-search module-toplevel-offsets_ id
    toplevel-id := id - module-toplevel-offsets_[module-id]
    return ToplevelRef module-uris_[module-id] toplevel-id

  read-toplevel-ref -> ToplevelRef?:
    id := read-int
    if id < 0: return null;
    return toplevel-ref-from-global-id id

  read-type -> Type:
    line := read-line
    if line == "[block]": return Type.BLOCK

    id := int.parse line
    if id == -1: return Type.ANY
    if id == -2: return Type.NONE
    return Type (toplevel-ref-from-global-id id)

  read-range -> Range:
    return Range read-int read-int

  read-list [block] -> List:
    count := read-int
    // TODO(1268, florian): remove this work-around and use the commented code instead.
    // return List count block
    result := List count
    for i := 0; i < count; i++:
      result[i] = block.call i
    return result

  read-line -> string:
    return reader_.read-line

  read-int -> int:
    return int.parse read-line

class Lines:
  offsets_ ::= []
  size_ ::= 0
  last-hit_ := 0

  constructor text/string:
    offsets_.add 0
    text.size.repeat:
      c := text.at it --raw
      if c == '\n': offsets_.add (it + 1)
    offsets_.add text.size

  lsp-position-for-offset offset/int -> lsp.Position:
    if offset == -1 or offset >= offsets_.last:
      // No position given or file has changed in size.
      return lsp.Position 0 0

    last-hit_ = interval-binary-search offsets_ offset --try-first=last-hit_
    return lsp.Position last-hit_ (offset - offsets_[last-hit_])
