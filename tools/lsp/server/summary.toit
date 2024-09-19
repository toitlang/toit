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

import io
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
  uri / string
  external-hash / ByteArray
  dependencies / List?/*<string>*/

  /**
  The summary bytes.

  If this field is set, then the module hasn't been parsed yet.
  It needs to go through the $SummaryReader first.
  */
  summary-bytes_ / ByteArray? := ?
  toplevel-offset_ / int := ?
  module-toplevel-offsets_ / List := ?
  module-uris_ / List := ?

  exported-modules_ / List?/*<string>*/ := null
  is-deprecated_ / bool? := null
  exports_      / List? := null
  classes_      / List? := null
  functions_    / List? := null
  globals_      / List?/*<Method>*/ := null
  toitdoc_      / Contents? := null

  constructor
      --.uri
      --.external-hash
      --.dependencies
      --summary-bytes/ByteArray
      --toplevel-offset/int
      --module-toplevel-offsets/List
      --module-uris/List:
    summary-bytes_ = summary-bytes
    toplevel-offset_ = toplevel-offset
    module-toplevel-offsets_ = module-toplevel-offsets
    module-uris_ = module-uris

  constructor
      --.uri
      --.external-hash
      --.dependencies
      --exports/List
      --exported-modules/List
      --classes/List
      --functions/List
      --globals/List
      --toitdoc/Contents?:
    summary-bytes_ = null
    toplevel-offset_ = -1
    module-toplevel-offsets_ = []
    module-uris_ = []
    exported-modules_ = exported-modules
    exports_ = exports
    classes_ = classes
    functions_ = functions
    globals_ = globals
    toitdoc_ = toitdoc

  is-deprecated -> bool:
    if summary-bytes_: parse_
    return is-deprecated_

  exported-modules -> List/*<string>*/:
    if summary-bytes_: parse_
    return exported-modules_

  exports -> List:
    if summary-bytes_: parse_
    return exports_

  classes -> List/*<Class>*/:
    if summary-bytes_: parse_
    return classes_

  functions -> List/*<Method>*/:
    if summary-bytes_: parse_
    return functions_

  globals -> List/*<Method>*/:
    if summary-bytes_: parse_
    return globals_

  toitdoc -> Contents?:
    if summary-bytes_: parse_
    return toitdoc_

  equals-external other/Module -> bool:
    return external-hash == other.external-hash

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
  toplevel-element-with-id id/int -> ToplevelElement:
    if id < classes.size: return classes[id]
    id -= classes.size
    if id < functions.size: return functions[id]
    id -= functions.size
    assert: id < globals.size
    return globals[id]

  parse_ -> none:
    reader := ModuleReader summary-bytes_
        --toplevel-offset=toplevel-offset_
        --module-toplevel-offsets=module-toplevel-offsets_
        --module-uris=module-uris_
    reader.fill-module this
    summary-bytes_ = null

class Export:
  static AMBIGUOUS ::= 0
  static NODES ::= 1

  hash-code / int ::= hash-code-counter_++

  name / string ::= ?
  kind / int ::= ?
  refs / List /* ToplevelRef */ ::= ?

  constructor .name .kind .refs:

class Range:
  start / int ::= -1
  end / int ::= -1

  constructor .start .end:

  to-lsp-range lines/Lines -> lsp.Range:
    return lsp.Range
        lines.lsp-position-for-offset start
        lines.lsp-position-for-offset end

  stringify -> string:
    return "$start-$end"

class ToplevelRef:
  module-uri / string ::= ?
  id / int ::= 0

  constructor .module-uri .id:
    assert: id >= 0

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

hash-code-counter_ := 0

interface ToplevelElement:
  hash-code -> int
  name -> string
  toplevel-id -> int

class Class implements ToplevelElement:
  static KIND-CLASS ::= "class"
  static KIND-INTERFACE ::= "interface"
  static KIND-MIXIN ::= "mixin"

  hash-code / int ::= hash-code-counter_++

  name  / string ::= ?
  range / Range  ::= ?
  outline-range / Range ::= ?
  toplevel-id   / int   ::= ?

  kind          / string ::= ?
  is-abstract   / bool ::= ?
  is-deprecated / bool ::= ?

  superclass   / ToplevelRef? ::= ?
  interfaces   / List ::= ?
  mixins       / List ::= ?

  statics      / List ::= ?
  constructors / List ::= ?  // Only unnamed constructors
  factories    / List ::= ?  // Only unnamed factories

  fields  / List ::= ?
  methods / List ::= ?

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.outline-range --.toplevel-id --.kind --.is-abstract
      --.is-deprecated --.superclass --.interfaces --.mixins
      --.statics --.constructors --.factories --.fields --.methods  --.toitdoc:

  is-class -> bool: return kind == KIND-CLASS
  is-interface -> bool: return kind == KIND-INTERFACE
  is-mixin -> bool: return kind == KIND-MIXIN

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
        --range=outline-range.to-lsp-range lines
        --selection-range=range.to-lsp-range lines
        --children=children

interface ClassMember:
  hash-code -> int
  name -> string

class Method implements ClassMember ToplevelElement:
  static INSTANCE-KIND ::= 0
  static GLOBAL-FUN-KIND ::= 1
  static GLOBAL-KIND ::= 2
  static CONSTRUCTOR-KIND ::= 3
  static FACTORY-KIND ::= 4

  hash-code / int ::= hash-code-counter_++

  name        / string ::= ?
  range       / Range  ::= ?
  outline-range / Range ::= ?
  toplevel-id   / int   ::= ?
  kind / int ::= 0
  parameters  / List  ::= ?
  return-type / Type? ::= ?

  is-abstract   / bool ::= ?
  is-synthetic  / bool ::= ?
  is-deprecated / bool ::= ?

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.outline-range --.toplevel-id --.kind --.parameters
      --.return-type --.is-abstract --.is-synthetic --.is-deprecated --.toitdoc:

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
        --range=outline-range.to-lsp-range lines
        --selection-range=range.to-lsp-range lines

class Field implements ClassMember:
  hash-code / int ::= hash-code-counter_++

  name / string ::= ?
  range / Range ::= ?
  outline-range / Range ::= ?
  is-final / bool ::= ?
  is-deprecated / bool ::= ?
  type / Type? ::= ?

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.outline-range --.is-final --.is-deprecated --.type --.toitdoc:

  to-lsp-document-symbol lines/Lines -> lsp.DocumentSymbol:
    return lsp.DocumentSymbol
        --name=safe-name_ name
        --kind=lsp.SymbolKind.FIELD
        --range=outline-range.to-lsp-range lines
        --selection-range=range.to-lsp-range lines

class Parameter:
  name / string ::= ?
  original-index / int ::= ?
  is-required / bool ::= ?
  is-named / bool ::= ?
  type / Type? ::= ?
  default-value / string? ::= ?

  constructor .name .original-index .type --.is-required --.is-named --.default-value:

  is-block -> bool: return type and type.is-block

class ReaderBase:
  reader_ / io.Reader

  constructor .reader_:

  read-line -> string:
    return reader_.read-line

  read-bytes count/int -> ByteArray:
    return reader_.read-bytes count

  read-int -> int:
    return int.parse read-line

  read-list [block] -> List:
    count := read-int
    // TODO(1268, florian): remove this work-around and use the commented code instead.
    // return List count block
    result := List count
    for i := 0; i < count; i++:
      result[i] = block.call i
    return result

class SummaryReader extends ReaderBase:
  module-uris_             / List ::= []
  module-toplevel-offsets_ / List ::= []
  current-module-id_ / int := 0

  constructor reader/io.Reader:
    super reader

  to-uri_ path / string -> string: return to-uri path --from-compiler

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
    module-offset := module-toplevel-offsets_[current-module-id_]
    module-path := read-line
    module-uri := to-uri_ module-path
    assert: module-uri == module-uris_[current-module-id_]

    dependencies := read-list: to-uri_ read-line

    hash := read-bytes 20
    module-bytes-size := read-int
    module-bytes := read-bytes module-bytes-size

    return Module
        --uri=module-uri
        --dependencies=dependencies
        --external-hash=hash
        --summary-bytes=module-bytes
        --toplevel-offset=module-offset
        --module-toplevel-offsets=module-toplevel-offsets_
        --module-uris=module-uris_

class ModuleReader extends ReaderBase:
  current-toplevel-id_ / int := 0
  toplevel-offset_ / int
  module-toplevel-offsets_ / List
  module-uris_ / List

  constructor bytes/ByteArray
      --toplevel-offset/int
      --module-toplevel-offsets/List
      --module-uris/List:
    toplevel-offset_ = toplevel-offset
    module-toplevel-offsets_ = module-toplevel-offsets
    module-uris_ = module-uris
    super (io.Reader bytes)

  to-uri_ path / string -> string: return to-uri path --from-compiler

  fill-module module/Module -> none:
    is-deprecated := read-line == "deprecated"
    exported-modules := read-list: to-uri_ read-line
    exported := read-list: read-export
    // The order also defines the toplevel-ids.
    // Classes go before toplevel functions, before globals.
    classes := read-list: read-class
    functions := read-list: read-method
    globals := read-list: read-method
    toitdoc := read-toitdoc
    module.is-deprecated_ = is-deprecated
    module.exported-modules_ = exported-modules
    module.exports_ = exported
    module.classes_ = classes
    module.functions_ = functions
    module.globals_ = globals
    module.toitdoc_ = toitdoc

  read-export -> Export:
    name := read-line
    kind := read-line == "AMBIGUOUS" ? Export.AMBIGUOUS : Export.NODES
    refs := read-list: read-toplevel-ref
    return Export name kind refs

  read-class -> Class:
    toplevel-id := current-toplevel-id_++
    name := read-line
    range := read-range
    outline-range := read-range
    global-id := read-int
    assert: global-id == toplevel-id + toplevel-offset_
    kind := read-line
    assert: kind == Class.KIND-CLASS or kind == Class.KIND-INTERFACE or kind == Class.KIND-MIXIN
    is-abstract := read-line == "abstract"
    is-deprecated := read-line == "deprecated"
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
        --outline-range=outline-range
        --toplevel-id=toplevel-id
        --kind=kind
        --is-abstract=is-abstract
        --is-deprecated=is-deprecated
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
    outline-range := read-range
    global-id := read-int  // Might be -1
    toplevel-id := (global-id == -1) ? -1 : global-id - toplevel-offset_
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
    is-deprecated := read-line == "deprecated"
    parameters := read-list: read-parameter
    return-type := read-type
    toitdoc := read-toitdoc
    return Method
        --name=name
        --range=range
        --outline-range=outline-range
        --toplevel-id=toplevel-id
        --kind=kind
        --parameters=parameters
        --return-type=return-type
        --is-abstract=is-abstract
        --is-synthetic=is-synthetic
        --is-deprecated=is-deprecated
        --toitdoc=toitdoc

  read-parameter -> Parameter:
    name := read-line
    original-index := read-int
    kind := read-line
    is-required := kind == "required" or kind == "required named"
    is-named := kind == "required named" or kind == "optional named"
    default-value-length := read-int
    default-value-string := default-value-length > 0
        ? reader_.read-string default-value-length
        : null
    type := read-type
    is-block := type.is-block
    return Parameter name original-index type
        --is-required=is-required
        --is-named=is-named
        --default-value=default-value-string

  read-field -> Field:
    name := read-line
    range := read-range
    outline-range := read-range
    is-final := read-line == "final"
    is-deprecated := read-line == "deprecated"
    type := read-type
    toitdoc := read-toitdoc
    return Field
        --name=name
        --range=range
        --outline-range=outline-range
        --is-deprecated=is-deprecated
        --is-final=is-final
        --type=type
        --toitdoc=toitdoc

  read-toitdoc -> Contents?:
    sections := read-list: read-section
    if sections.is-empty: return null
    return Contents sections

  read-section -> Section:
    title/string? := read-toitdoc-symbol
    if title == "": title = null
    level := read-int
    return Section
      title
      level
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
    if kind == "LINK": return read-link
    if kind == "REF": return read-toitdoc-ref
    throw "Unknown kind $kind"

  read-link -> Link:
    text := read-toitdoc-symbol
    uri := read-toitdoc-symbol
    return Link text uri

  read-toitdoc-ref -> ToitdocRef:
    text := read-toitdoc-symbol
    kind := read-int
    if kind < 0 or kind == ToitdocRef.OTHER:
      // Either bad reference, or not yet supported.
      return ToitdocRef.other text

    if kind == ToitdocRef.PARAMETER:
      return ToitdocRef.parameter text

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

class Lines:
  offsets_ ::= []
  last-hit_ := 0

  constructor text/string:
    offsets_.add 0
    text.size.repeat:
      c := text.at it --raw
      if c == '\n': offsets_.add (it + 1)
    offsets_.add text.size

  lsp-position-for-offset offset/int -> lsp.Position:
    if offsets_.is-empty: return lsp.Position 0 0

    if offset == -1 or offset > offsets_.last:
      // No position given or file has changed in size.
      return lsp.Position 0 0

    last-hit_ = interval-binary-search offsets_ offset --try-first=last-hit_
    return lsp.Position last-hit_ (offset - offsets_[last-hit_])
