// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc_node
import .utils

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run_client_test args --no-spawn_process: test it
  // Since we didn't spawn any process, we need to exit.
  exit 0

FILE_TEMPLATE ::= """\
  #Module

  #Class
  class Class:
    #Class.constructor
    constructor:
    #Class.named
    constructor.named:
    #Class.factory
    constructor.factory: return Class
    #Class.method1
    method1:
    #Class.method2
    method2 x --named_arg optional=3 [block] --optional_named=null:
    #Class.static_method1
    static static_method1:
    #Class.static_method2
    static static_method2 x --named_arg optional=3 [block] --optional_named=null:
    #Class.field
    field := null
    #Class.field2
    field2 ::= null
    #Class.setter=
    setter= val:
    #Class.static_field
    static static_field := null
    #Class.static_final_field
    static static_final_field ::= null
    #Class.STATIC_CONSTANT
    static STATIC_CONSTANT ::= 499
  #AbstractClass
  abstract class AbstractClass:
    #AbstractClass.abstract_method
    abstract abstract_method
    #AbstractClass.abstract_method2
    abstract abstract_method2 x --named_arg [block]
  #Interface
  class Interface:
    #Interface.interface_method
    interface_method
    #Interface.interface_method2
    interface_method2 x --named_arg [block]
    #Interface.static_method
    static static_method
    #Interface.static_method2
    static static_method2 x --named_arg  optional=3 [block] --optional_named=null:
  #global
  global := 499
  #final_global
  final_global ::= {:}
  #CONSTANT
  CONSTANT ::= 499
  #global_function
  global_function:
  #global_function2
  global_function2 x --named_arg  optional=3 [block] --optional_named=null:
  """

class TemplateFiller:
  toitdocs ::= {:}
  /// A subset of toitdocs.
  /// The toitdocs map above has keys of the form `Class.member`.
  /// These are split into `{"Class": {"member": val}}` here.
  prefixed ::= {:}

  generator / Lambda ::= ?

  constructor .generator:

  fill template/string -> string:
    chunks := []
    chunk_start := 0
    indentation := 0
    for i := 0; i < template.size; i++:
      if template[i] == '#':
        // Don't copy the indentation. It's nicer if the generator
        // is more uniform for each line it generates.
        chunks.add (template.copy chunk_start (i - indentation))
        start := i + 1
        while template[i] != '\n': i++
        chunk_start = i + 1  // Don't copy the '\n'
        key := template.copy start i
        expected_comment := generator.call (" " * indentation) key
        expected := expected_comment[0]
        comment := expected_comment[1]
        toitdocs[key] = expected
        chunks.add comment
      if template[i] == '\n':
        indentation = 0
      else:
        indentation++

    toitdocs.do: |key val|
      if key.contains ".":
        parts := key.split "."
        assert: parts.size == 2
        (prefixed.get parts[0] --init=(: {:}))[parts[1]] = val

    chunks.add (template.copy chunk_start)
    return chunks.join ""

  /// Checks that the given module has the expected toitdocs
  check module / Module:
    verified_count := 0
    verified_count += check_toitdoc (toitdocs.get "Module") module.toitdoc
    module.classes.do:   verified_count += check_class it
    module.functions.do: verified_count += check_method it
    module.globals.do:   verified_count += check_method it
    expect_equals toitdocs.size verified_count

  check_class klass/Class -> int:
    name := klass.name
    result := 0
    result += check_toitdoc (toitdocs.get name) klass.toitdoc
    klass.constructors.do: result += check_method it --prefix=name
    klass.factories.do:    result += check_method it --prefix=name
    klass.methods.do:      result += check_method it --prefix=name
    klass.statics.do:      result += check_method it --prefix=name
    klass.fields.do:       result += check_field it --prefix=name
    return result

  check_method method/Method --prefix/string?=null -> int:
    if method.is_synthetic: return 0
    map := null
    if prefix: map = prefixed.get prefix --if_absent=:{:}
    else:      map = toitdocs
    return check_toitdoc (map.get method.name) method.toitdoc

  check_field field/Field --prefix/string -> int:
    map := prefixed.get prefix --if_absent=:{:}
    return check_toitdoc (map.get field.name) field.toitdoc

  check_toitdoc expected_string/string? actual/Contents? -> int:
    if not expected_string:
      expect_null actual
      return 0

    lines := expected_string.split "\n"
    expect_equals 1 actual.sections.size
    section := actual.sections.first
    expect_null section.title
    expect_equals lines.size section.statements.size
    lines.size.repeat:
      expect_equals lines[it] section.statements[it].expressions[0].text
    return 1

test client/LspClient:
  generators ::= [];

  generators.add
    :: |indentation key|
      kind := "multiline on one line"
      expected := "$kind $key"
      comment := "/** $kind $key */\n"
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "singleline"
      expected := "$kind $key"
      comment := "/// $kind $key\n"
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "multiline"
      expected := "$kind $key"
      comment := """
        $indentation/**
        $indentation$kind $key
        $indentation*/
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "2 lines, one indented, multiline"
      expected := "$kind $key 1 $key 2"
      comment := """
        $indentation/**
        $indentation$kind $key 1
        $indentation  $key 2
        $indentation*/
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "4 lines, every second indented, multiline"
      expected := "$kind $key 1 $key 2\n$kind 2 $key 3"
      comment := """
        $indentation/**
        $indentation$kind $key 1
        $indentation  $key 2
        $indentation$kind 2
        $indentation  $key 3
        $indentation*/
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "4 lines, every second indented, multiline, indented empty line"
      expected := "$kind $key 1 $key 2\n$kind 2 $key 3"
      comment := """
        $indentation/**
        $indentation$kind $key 1
        $indentation  $key 2
        $indentation
        $indentation$kind 2
        $indentation  $key 3
        $indentation*/
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "4 lines, every second indented, multiline, empty line"
      expected := "$kind $key 1 $key 2\n$kind 2 $key 3"
      comment := """
        $indentation/**
        $indentation$kind $key 1
        $indentation  $key 2

        $indentation$kind 2
        $indentation  $key 3
        $indentation*/
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "4 lines, every second indented, singleline"
      expected := "$kind $key 1 $key 2\n$kind 2 $key 3"
      comment := """
        $indentation/// $kind $key 1
        $indentation///   $key 2
        $indentation///
        $indentation/// $kind 2
        $indentation///   $key 3
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "2 lines, one indented, singleline"
      expected := "$kind $key 1 $key 2"
      comment := """
        $indentation/// $kind $key 1
        $indentation///   $key 2
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "2 lines, singleline, followed by normal comments"
      expected := "$kind $key 1\n$key 2"
      comment := """
        $indentation/// $kind $key 1
        $indentation/// $key 2
        $indentation// Some comments
        $indentation// Some comments
        $indentation// Some comments
        $indentation// Some comments
        """
      [expected, comment]

  generators.add
    :: |indentation key|
      kind := "2 lines, multiline, followed by normal comments"
      expected := "$kind $key 1\n$key 2"
      comment := """
        $indentation/**
        $indentation$kind $key 1
        $indentation$key 2
        $indentation*/
        $indentation// Some comments.
        $indentation// Some comments.
        $indentation// Some comments.
        $indentation// Some comments.
        $indentation// Some comments.
        """
      [expected, comment]

  // Normal comments in front of the declaration don't hurt:
  generators.add
    :: |indentation key|
      kind := "1 lines, multiline, followed by normal comments"
      expected := "$kind $key"
      comment := """
        $indentation/** $kind $key */
        $indentation// Some comments
        $indentation// Some comments
        $indentation// Some comments
        $indentation// Some comments
        """
      [expected, comment]

  // Empty leading "///" comment is correctly handled.
  generators.add
    :: |indentation key|
      kind := "2 lines, singleline, first empty"
      expected := "$kind $key"
      comment := """
        $indentation///
        $indentation/// $kind $key
        """
      [expected, comment]

  // Empty trailing "///" comment is correctly handled.
  generators.add
    :: |indentation key|
      kind := "2 lines, singleline, second empty"
      expected := "$kind $key"
      comment := """
        $indentation/// $kind $key
        $indentation///
        """
      [expected, comment]

  // Not recommended, but we do support when the comment is not respecting the
  // indentation.
  generators.add
    :: |indentation key|
      kind := "3 lines, multiline, bad indentation"
      expected := "$kind $key 1\n$key 2 $key 3"
      comment := """
        $indentation/**
        $indentation$kind $key 1
        $key 2
        $indentation  $key 3
        $indentation*/
        """
      [expected, comment]


  FILE_URI ::= "untitled:/non_existent.toit"
  client.send_did_open --uri=FILE_URI --text=""

  generators.do:
    filler := TemplateFiller it
    filled := filler.fill FILE_TEMPLATE
    client.send_did_change --uri=FILE_URI filled
    // Reaching into the private state of the server.
    document := client.server.documents_.get_existing_document --uri=FILE_URI
    summary := document.summary
    filler.check summary
