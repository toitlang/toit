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

import system
import ...tools.toitdoc.lsp-exports as lsp

TEST-URI ::= "test-uri"

/**
Creates summaries for the given $source.

This parser only supports a very limited subset of the Toit language.
*/
create-summaries source/string -> Map:
  result := {:}
  result[TEST-URI] = parse-module source --uri=TEST-URI
  return result

parse-module source/string --uri/string -> lsp.Module:
  if system.platform == system.PLATFORM-WINDOWS:
    source = source.replace --all "\r\n" "\n"

  lines := source.split "\n"

  classes := []
  class-ids := {:}

  current-kind/string? := null  // See $lsp.Class.KIND_*.
  current-class-name/string? := null
  current-super-class/lsp.ToplevelRef? := null
  current-mixins := []
  current-methods := []

  finish-class := :
    if current-class-name:
      id := classes.size
      class-ids[current-class-name] = id
      new-class := lsp.Class
          --name=current-class-name
          --superclass=current-super-class
          --methods=current-methods
          --kind=current-kind
          --mixins=current-mixins
          --constructors=[]
          --factories=[]
          --fields=[]
          --interfaces=[]
          --statics=[]
          --is-abstract=false
          --range=lsp.Range 0 0
          --outline-range=lsp.Range 0 0
          --toitdoc=null
          --toplevel-id=id
          --is-deprecated=false
      classes.add new-class

    current-class-name = null
    current-super-class = null
    current-mixins = []
    current-methods = []

  lines.do: | line/string |
    line = line.trim
    line = line.trim --right ":"

    if line.starts-with "//" or line.is-empty: continue.do

    if line.starts-with "class " or line.starts-with "mixin":
      // Finish the started class.
      finish-class.call

    if not line.starts-with "class " and not line.starts-with "mixin ":
      current-methods.add (parse-method line)
      continue.do

    // Parse the class/mixin line.
    current-kind = line.starts-with "class "
        ? lsp.Class.KIND_CLASS
        : lsp.Class.KIND_MIXIN

    parts := line.split " "
    current-class-name = parts[1]
    if parts.size > 2:
      if parts[2] != "extends":
        throw "Syntax must be 'class <name> extends <name>'."
      if parts.size > 4 and (parts[4] != "with" or parts.size < 6):
        throw "Syntax must be 'class <name> extends <name> with <name> ...'."

      current-super-class = lsp.ToplevelRef uri class-ids[parts[3]]

      for i := 5; i < parts.size; i++:
        current-mixins.add (lsp.ToplevelRef uri class-ids[parts[i]])

  // Finish the last started class/mixin.
  finish-class.call

  return lsp.Module
      --uri=uri
      --classes=classes
      --external-hash=#[]
      --dependencies=[]
      --exported-modules=[]
      --exports=[]
      --functions=[]
      --globals=[]
      --toitdoc=null

parse-method str/string -> lsp.Method:
  parts := str.trim.split " "
  name := parts[0]
  params := []

  for i := 1; i < parts.size; i++:
    param-str := parts[i]
    is-named := false
    is-optional := false
    param-type := lsp.Type.ANY
    if param-str[0] == '[':
      param-type = lsp.Type.BLOCK
      param-str = param-str[1 .. param-str.size - 1]
    if param-str.ends-with "=":
      is-optional = true
      param-str = param-str[0 .. param-str.size - 1]
    if param-str.starts-with "--":
      is-named = true
      param-str = param-str[2..]
    // What's left is the name of the parameter.
    param-name := param-str
    parameter := lsp.Parameter param-name (i - 1) param-type
        --is-named=is-named
        --is-required=not is-optional
        --default-value=is-optional ? "null" : null
    params.add parameter

  return lsp.Method
      --name=name
      --parameters=params
      --is-abstract=false
      --is-synthetic=false
      --kind=lsp.Method.INSTANCE-KIND
      --range=lsp.Range 0 0
      --outline-range=lsp.Range 0 0
      --return-type=null
      --toitdoc=null
      --toplevel-id=-1
      --is-deprecated=false
