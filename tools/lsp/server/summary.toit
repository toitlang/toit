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
import .uri_path_translator
import .protocol.document_symbol as lsp
import .protocol.document as lsp
import .toitdoc_node
import .utils show interval_binary_search

ERROR_NAME ::= "<Error>"
safe_name_ name/string -> string:
  if name == "": return ERROR_NAME
  return name

/** A summary of a module. */
class Module:
  uri / string ::= ?
  dependencies / List/*<string>*/ ::= ?
  exported_modules / List/*<string>*/ ::= ?
  exports      / List ::= ?
  classes      / List ::= ?
  functions    / List ::= ?
  globals      / List/*<Method>*/ ::= ?
  toitdoc      / Contents? ::= ?

  constructor
      --.uri
      --.dependencies
      --.exports
      --.exported_modules
      --.classes
      --.functions
      --.globals
      --.toitdoc:

  equals_external other/Module -> bool:
    return other and
        uri == other.uri and
        // The dependencies only have an external impact if `export_all` is true. However, we
        //    conservatively just return require that they are the same.
        dependencies == other.dependencies and
        exported_modules == other.exported_modules and
        (exports.equals other.exports --element_equals=: |a b| a.equals_external b) and
        (classes.equals other.classes --element_equals=: |a b| a.equals_external b) and
        (functions.equals other.functions --element_equals=: |a b| a.equals_external b) and
        (globals.equals other.globals --element_equals=: |a b| a.equals_external b)

  to_lsp_document_symbol content/string -> List/*<DocumentSymbol>*/:
    lines := Lines content
    result := []
    classes.do: result.add (it.to_lsp_document_symbol lines)
    functions.do: result.add (it.to_lsp_document_symbol lines)
    globals.do: result.add (it.to_lsp_document_symbol lines)
    return result

  /**
  Finds the toplevel element with the given $id.
  Returns either a class or a method.
  */
  toplevel_element_with_id id/int -> any:
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

  equals_external other/Export -> bool:
    return other and
        name == other.name and
        kind == other.kind and
        refs.equals other.refs --element_equals=: |a b| a.equals_external b

class Range:
  start / int ::= -1
  end / int ::= -1

  constructor .start .end:

  to_lsp_range lines/Lines -> lsp.Range:
    return lsp.Range
        lines.lsp_position_for_offset start
        lines.lsp_position_for_offset end

class ToplevelRef:
  module_uri / string ::= ?
  id / int ::= 0

  constructor .module_uri .id:
    assert: id >= 0

  equals_external other/ToplevelRef -> bool:
    return other and module_uri == other.module_uri and id == other.id

class Type:
  static ANY_KIND ::= -1
  static NONE_KIND ::= -2
  static BLOCK_KIND ::= -3
  static CLASS_KIND ::= 0

  static ANY / Type ::= Type.internal_ ANY_KIND null
  static NONE / Type ::= Type.internal_ NONE_KIND null
  static BLOCK / Type ::= Type.internal_ BLOCK_KIND null

  kind / int ::= 0
  class_ref / ToplevelRef? ::= ?

  constructor .class_ref: kind = 0
  constructor.internal_ .kind .class_ref:

  is_block -> bool: return kind == BLOCK_KIND
  is_any -> bool: return kind == ANY_KIND
  is_none -> bool: return kind == NONE_KIND

  equals_external other/Type -> bool:
    return other and kind == other.kind and class_ref.equals_external other.class_ref

hash_code_counter_ := 0

class Class:
  name  / string ::= ?
  range / Range  ::= ?
  toplevel_id / int ::= ?

  is_abstract  / bool ::= false
  is_interface / bool ::= false
  superclass   / ToplevelRef? ::= ?
  interfaces   / List ::= ?

  statics      / List ::= ?
  constructors / List ::= ?  // Only unnamed constructors
  factories    / List ::= ?  // Only unnamed factories

  fields  / List ::= ?
  methods / List ::= ?

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.toplevel_id --.is_abstract --.is_interface --.superclass --.interfaces
      --.statics --.constructors --.factories --.fields --.methods  --.toitdoc:

  equals_external other/Class -> bool:
    return other and
        name == other.name and
        is_interface == other.is_interface and
        is_abstract == other.is_abstract and
        (superclass == other.superclass or (superclass and superclass.equals_external other.superclass)) and
        (interfaces.equals other.interfaces --element_equals=: |a b| a.equals_external b) and
        (statics.equals other.statics --element_equals=: |a b| a.equals_external b) and
        (constructors.equals other.constructors --element_equals=: |a b| a.equals_external b) and
        (factories.equals other.factories --element_equals=: |a b| a.equals_external b) and
        (fields.equals other.fields --element_equals=: |a b| a.equals_external b) and
        (methods.equals other.methods --element_equals=: |a b| a.equals_external b)

  to_lsp_document_symbol lines/Lines -> lsp.DocumentSymbol:
    children := []

    add_method_symbol := :
      if not it.is_synthetic:
        children.add (it.to_lsp_document_symbol lines)

    statics.do      add_method_symbol
    constructors.do add_method_symbol
    factories.do    add_method_symbol
    methods.do      add_method_symbol
    fields.do: children.add (it.to_lsp_document_symbol lines)
    return lsp.DocumentSymbol
        --name=safe_name_ name
        --kind= is_interface ? lsp.SymbolKind.INTERFACE : lsp.SymbolKind.CLASS
        --range=range.to_lsp_range lines
        --selection_range=range.to_lsp_range lines
        --children=children

class Method:
  static INSTANCE_KIND ::= 0
  static GLOBAL_FUN_KIND ::= 1
  static GLOBAL_KIND ::= 2
  static CONSTRUCTOR_KIND ::= 3
  static FACTORY_KIND ::= 4

  hash_code / int ::= hash_code_counter_++

  name        / string ::= ?
  range       / Range  ::= ?
  toplevel_id / int    ::= ?
  kind / int ::= 0
  parameters  / List  ::= ?
  return_type / Type? ::= ?

  is_abstract  / bool ::= false
  is_synthetic / bool ::= false

  toitdoc / Contents? ::= ?

  constructor --.name --.range --.toplevel_id --.kind --.parameters --.return_type --.is_abstract --.is_synthetic --.toitdoc:

  equals_external other/Method -> bool:
    return other and
        name == other.name and
        kind == other.kind and
        is_abstract == other.is_abstract and
        (parameters.equals other.parameters --element_equals=: |a b| a.equals_external b) and
        (return_type == other.return_type or (return_type and return_type.equals_external other.return_type))

  to_lsp_document_symbol lines/Lines -> lsp.DocumentSymbol:
    lsp_kind := -1
    if kind == INSTANCE_KIND:         lsp_kind = lsp.SymbolKind.METHOD
    else if kind == GLOBAL_FUN_KIND:  lsp_kind = lsp.SymbolKind.FUNCTION
    else if kind == GLOBAL_KIND:      lsp_kind = lsp.SymbolKind.VARIABLE
    else if kind == CONSTRUCTOR_KIND: lsp_kind = lsp.SymbolKind.CONSTRUCTOR
    else if kind == FACTORY_KIND:     lsp_kind = lsp.SymbolKind.CONSTRUCTOR
    else: throw "Unexpected method kind: $kind"

    details := ""
    if kind != GLOBAL_KIND:
      parameter_details := parameters.map:
        detail := it.name
        if it.is_named: detail = "--" + detail
        if not it.is_required: detail = detail + "="
        if it.type and it.type.is_block: detail = "[" + detail + "]"
        detail
      details = parameter_details.join " "

    return lsp.DocumentSymbol
        --name=safe_name_ name
        --detail=details
        --kind=lsp_kind
        --range=range.to_lsp_range lines
        --selection_range=range.to_lsp_range lines

class Field:
  name / string ::= ?
  range / Range ::= ?
  is_final / bool ::= false
  type / Type? ::= ?

  toitdoc / Contents? ::= ?

  constructor .name .range .is_final .type .toitdoc:

  equals_external other/Field -> bool:
    return other and
        name == other.name and
        is_final == other.is_final and
        (type == other.type or (type and type.equals_external other.type))

  to_lsp_document_symbol lines/Lines -> lsp.DocumentSymbol:
    return lsp.DocumentSymbol
        --name=safe_name_ name
        --kind=lsp.SymbolKind.FIELD
        --range=range.to_lsp_range lines
        --selection_range=range.to_lsp_range lines

class Parameter:
  name / string ::= ?
  original_index / int ::= ?
  is_required / bool ::= ?
  is_named / bool ::= ?
  type / Type? ::= ?

  constructor .name .original_index --.is_required --.is_named .type:

  is_block -> bool: return type and type.is_block

  equals_external other/Parameter -> bool:
    return other and
        name == other.name and
        is_required == other.is_required and
        is_named == other.is_named and
        (type == other.type or (type and type.equals_external other.type))

class SummaryReader:
  reader_ / BufferedReader ::= ?
  uri_path_translator_ / UriPathTranslator ::= ?

  module_uris_             / List ::= []
  module_toplevel_offsets_ / List ::= []
  current_module_id_ := 0
  current_toplevel_id_ := 0

  constructor .reader_ .uri_path_translator_:

  to_uri_ path / string -> string: return uri_path_translator_.to_uri path --from_compiler

  read_summary -> Map/*<uri, Module>*/:
    module_count := read_int
    module_offset := 0
    module_count.repeat:
      module_path := read_line
      module_uri := to_uri_ module_path
      module_uris_.add module_uri
      module_toplevel_offsets_.add module_offset
      toplevel_count := read_int
      module_offset += toplevel_count

    result := {:}
    assert: current_module_id_ == 0
    module_count.repeat:
      module := read_module
      result[module.uri] = module
      current_module_id_++
    return result

  read_module -> Module:
    current_toplevel_id_ = 0;
    module_offset := module_toplevel_offsets_[current_module_id_]
    module_path := read_line
    module_uri := to_uri_ module_path
    assert: module_uri == module_uris_[current_module_id_]

    dependencies := read_list: to_uri_ read_line
    exported_modules := read_list: to_uri_ read_line
    exported := read_list: read_export
    // The order also defines the toplevel-ids.
    // Classes go before toplevel functions, before globals.
    classes := read_list: read_class
    functions := read_list: read_method
    globals := read_list: read_method
    toitdoc := read_toitdoc
    return Module
        --uri=module_uri
        --dependencies=dependencies
        --exported_modules=exported_modules
        --exports=exported
        --classes=classes
        --functions=functions
        --globals=globals
        --toitdoc=toitdoc

  read_export -> Export:
    name := read_line
    kind := read_line == "AMBIGUOUS" ? Export.AMBIGUOUS : Export.NODES
    refs := read_list: read_toplevel_ref
    return Export name kind refs

  read_class -> Class:
    toplevel_id := current_toplevel_id_++
    name := read_line
    range := read_range
    global_id := read_int
    assert: global_id == toplevel_id + module_toplevel_offsets_[current_module_id_]
    kind := read_line
    is_interface := kind == "interface"
    is_abstract := kind == "abstract"
    superclass := read_toplevel_ref
    interfaces := read_list: read_toplevel_ref
    statics := read_list: read_method
    constructors := read_list: read_method
    factories := read_list: read_method
    fields := read_list: read_field
    methods := read_list: read_method
    toitdoc := read_toitdoc
    return Class
        --name=name
        --range=range
        --toplevel_id=toplevel_id
        --is_interface=is_interface
        --is_abstract=is_abstract
        --superclass=superclass
        --interfaces=interfaces
        --statics=statics
        --constructors=constructors
        --factories=factories
        --fields=fields
        --methods=methods
        --toitdoc=toitdoc

  read_method -> Method:
    name := read_line
    range := read_range
    global_id := read_int  // Might be -1
    toplevel_id := (global_id == -1) ? -1 : global_id - module_toplevel_offsets_[current_module_id_]
    kind_string := read_line
    kind := -1
    is_abstract := false
    is_synthetic := false
    if kind_string == "instance":
      kind = Method.INSTANCE_KIND
      assert: global_id == -1
    else if kind_string == "abstract":
      kind = Method.INSTANCE_KIND
      is_abstract = true
      assert: global_id == -1
    else if kind_string == "field stub":
      kind = Method.INSTANCE_KIND
      is_synthetic = true
      assert: global_id == -1
    else if kind_string == "global fun":
      kind = Method.GLOBAL_FUN_KIND
      if global_id != -1:
        // If the read id is -1, then it's just a class-static.
        assert: current_toplevel_id_ == toplevel_id
        current_toplevel_id_++
    else if kind_string == "global initializer":
      kind = Method.GLOBAL_KIND
      if global_id != -1:
        // If the read id is -1, then it's just a class-static.
        assert: current_toplevel_id_ == toplevel_id
        current_toplevel_id_++
    else if kind_string == "constructor":
      kind = Method.CONSTRUCTOR_KIND
      assert: global_id == -1
    else if kind_string == "default constructor":
      kind = Method.CONSTRUCTOR_KIND
      is_synthetic = true
      assert: global_id == -1
    else if kind_string == "factory":
      kind = Method.FACTORY_KIND
      assert: global_id == -1
    else:
      throw "Unknown kind"
    parameters := read_list: read_parameter
    return_type := read_type
    toitdoc := read_toitdoc
    return Method
        --name=name
        --range=range
        --toplevel_id=toplevel_id
        --kind=kind
        --parameters=parameters
        --return_type=return_type
        --is_abstract=is_abstract
        --is_synthetic=is_synthetic
        --toitdoc=toitdoc

  read_parameter -> Parameter:
    name := read_line
    original_index := read_int
    kind := read_line
    is_required := kind == "required" or kind == "required named"
    is_named := kind == "required named" or kind == "optional named"
    type := read_type
    is_block := type.is_block
    return Parameter name original_index --is_required=is_required --is_named=is_named type

  read_field -> Field:
    name := read_line
    range := read_range
    is_final := read_line == "final"
    type := read_type
    toitdoc := read_toitdoc
    return Field name range is_final type toitdoc

  read_toitdoc -> Contents?:
    sections := read_list: read_section
    if sections.is_empty: return null
    return Contents sections

  read_section -> Section:
    title := null
    title = read_toitdoc_symbol
    if title == "": title = null
    return Section
      title
      read_list: read_statement

  read_statement -> Statement:
    kind := read_line
    if kind == "CODE SECTION": return read_code_section
    if kind == "ITEMIZED": return read_itemized
    assert: kind == "PARAGRAPH"
    return read_paragraph

  read_code_section -> CodeSection:
    return CodeSection read_toitdoc_symbol

  read_itemized -> Itemized:
    return Itemized
        read_list: read_item

  read_item -> Item:
    kind := read_line
    assert: kind == "ITEM"
    return Item
        read_list: read_statement

  read_paragraph -> Paragraph:
    return Paragraph
        read_list: read_expression

  read_expression -> Expression:
    kind := read_line
    if kind == "TEXT": return Text read_toitdoc_symbol
    if kind == "CODE": return Code read_toitdoc_symbol
    assert: kind == "REF"
    return read_toitdoc_ref

  read_toitdoc_ref -> ToitdocRef:
    text := read_toitdoc_symbol
    kind := read_int
    if kind < 0 or kind == ToitdocRef.OTHER:
      // Either bad reference, or not yet supported.
      return ToitdocRef.other text

    assert: ToitdocRef.CLASS <= kind <= ToitdocRef.FIELD
    module_uri := to_uri_ read_line
    holder := null
    if kind >= ToitdocRef.STATIC_METHOD:
      holder = read_toitdoc_symbol
    name := read_toitdoc_symbol
    shape := null
    if ToitdocRef.GLOBAL_METHOD <= kind <= ToitdocRef.METHOD:
      shape = read_toitdoc_shape
    return ToitdocRef
        --text=text
        --kind=kind
        --module_uri=module_uri
        --holder=holder
        --name=name
        --shape=shape

  read_toitdoc_shape -> Shape:
    arity := read_int
    total_block_count := read_int
    name_count := read_int
    named_block_count := read_int
    is_setter := read_line == "setter"
    names := List name_count: read_toitdoc_symbol
    return Shape
        --arity=arity
        --total_block_count=total_block_count
        --named_block_count=named_block_count
        --is_setter=is_setter
        --names=names

  read_toitdoc_symbol -> string:
    size := read_int
    str := reader_.read_string size
    reader_.read_byte  // Read the '\n'
    return str

  toplevel_ref_from_global_id id/int -> ToplevelRef:
    assert: id >= 0
    module_id := interval_binary_search module_toplevel_offsets_ id
    toplevel_id := id - module_toplevel_offsets_[module_id]
    return ToplevelRef module_uris_[module_id] toplevel_id

  read_toplevel_ref -> ToplevelRef?:
    id := read_int
    if id < 0: return null;
    return toplevel_ref_from_global_id id

  read_type -> Type:
    line := read_line
    if line == "[block]": return Type.BLOCK

    id := int.parse line
    if id == -1: return Type.ANY
    if id == -2: return Type.NONE
    return Type (toplevel_ref_from_global_id id)

  read_range -> Range:
    return Range read_int read_int

  read_list [block] -> List:
    count := read_int
    // TODO(1268, florian): remove this work-around and use the commented code instead.
    // return List count block
    result := List count
    for i := 0; i < count; i++:
      result[i] = block.call i
    return result

  read_line -> string:
    return reader_.read_line

  read_int -> int:
    return int.parse read_line

class Lines:
  offsets_ ::= []
  size_ ::= 0
  last_hit_ := 0

  constructor text/string:
    offsets_.add 0
    previous := '\0'
    text.size.repeat:
      c := text.at it --raw
      if (c == '\r' and previous != '\r') or
          (c == '\n' and previous != '\r'):
        offsets_.add (it + 1)
      previous = c
    offsets_.add text.size

  lsp_position_for_offset offset/int -> lsp.Position:
    if offset == -1 or offset >= offsets_.last:
      // No position given or file has changed in size.
      return lsp.Position 0 0

    last_hit_ = interval_binary_search offsets_ offset --try_first=last_hit_
    return lsp.Position last_hit_ (offset - offsets_[last_hit_])
