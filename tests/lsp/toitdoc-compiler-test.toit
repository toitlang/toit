// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import ...tools.lsp.server.summary
import ...tools.lsp.server.toitdoc-node
import .utils

import host.directory
import expect show *

main args:
  // We are reaching into the server, so we must not spawn the server as
  // a process.
  run-client-test args --no-spawn-process: test it
  // Since we didn't spawn any process, we need to exit.
  exit 0

FILE-TEMPLATE ::= """\
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
    method2 x --named-arg optional=3 [block] --optional-named=null:
    #Class.static-method1
    static static-method1:
    #Class.static-method2
    static static-method2 x --named-arg optional=3 [block] --optional-named=null:
    #Class.field
    field := null
    #Class.field2
    field2 ::= null
    #Class.setter=
    setter= val:
    #Class.static-field
    static static-field := null
    #Class.static-final-field
    static static-final-field ::= null
    #Class.STATIC-CONSTANT
    static STATIC-CONSTANT ::= 499
  #AbstractClass
  abstract class AbstractClass:
    #AbstractClass.abstract-method
    abstract abstract-method
    #AbstractClass.abstract-method2
    abstract abstract-method2 x --named-arg [block]
  #Interface
  class Interface:
    #Interface.interface-method
    interface-method
    #Interface.interface-method2
    interface-method2 x --named-arg [block]
    #Interface.static-method
    static static-method
    #Interface.static-method2
    static static-method2 x --named-arg  optional=3 [block] --optional-named=null:
  #global
  global := 499
  #final-global
  final-global ::= {:}
  #CONSTANT
  CONSTANT ::= 499
  #global-function
  global-function:
  #global-function2
  global-function2 x --named-arg  optional=3 [block] --optional-named=null:
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
    chunk-start := 0
    indentation := 0
    for i := 0; i < template.size; i++:
      if template[i] == '#':
        // Don't copy the indentation. It's nicer if the generator
        // is more uniform for each line it generates.
        chunks.add (template.copy chunk-start (i - indentation))
        start := i + 1
        while template[i] != '\n': i++
        chunk-start = i + 1  // Don't copy the '\n'
        key := template.copy start i
        expected-comment := generator.call (" " * indentation) key
        expected := expected-comment[0]
        comment := expected-comment[1]
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

    chunks.add (template.copy chunk-start)
    return chunks.join ""

  /// Checks that the given module has the expected toitdocs
  check module / Module:
    verified-count := 0
    verified-count += check-toitdoc (toitdocs.get "Module") module.toitdoc
    module.classes.do:   verified-count += check-class it
    module.functions.do: verified-count += check-method it
    module.globals.do:   verified-count += check-method it
    expect-equals toitdocs.size verified-count

  check-class klass/Class -> int:
    name := klass.name
    result := 0
    result += check-toitdoc (toitdocs.get name) klass.toitdoc
    klass.constructors.do: result += check-method it --prefix=name
    klass.factories.do:    result += check-method it --prefix=name
    klass.methods.do:      result += check-method it --prefix=name
    klass.statics.do:      result += check-method it --prefix=name
    klass.fields.do:       result += check-field it --prefix=name
    return result

  check-method method/Method --prefix/string?=null -> int:
    if method.is-synthetic: return 0
    map := null
    if prefix: map = prefixed.get prefix --if-absent=:{:}
    else:      map = toitdocs
    return check-toitdoc (map.get method.name) method.toitdoc

  check-field field/Field --prefix/string -> int:
    map := prefixed.get prefix --if-absent=:{:}
    return check-toitdoc (map.get field.name) field.toitdoc

  check-toitdoc expected-string/string? actual/Contents? -> int:
    if not expected-string:
      expect-null actual
      return 0

    lines := expected-string.split "\n"
    expect-equals 1 actual.sections.size
    section := actual.sections.first
    expect-null section.title
    expect-equals lines.size section.statements.size
    lines.size.repeat:
      expect-equals lines[it] section.statements[it].expressions[0].text
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


  FILE-URI ::= "untitled:/non_existent.toit"
  client.send-did-open --uri=FILE-URI --text=""

  generators.do:
    filler := TemplateFiller it
    filled := filler.fill FILE-TEMPLATE
    client.send-did-change --uri=FILE-URI filled
    project-uri := client.server.documents_.project-uri-for --uri=FILE-URI
    // Reaching into the private state of the server.
    analyzed-documents := client.server.documents_.analyzed-documents-for --project-uri=project-uri
    document := analyzed-documents.get-existing --uri=FILE-URI
    summary := document.summary
    filler.check summary
