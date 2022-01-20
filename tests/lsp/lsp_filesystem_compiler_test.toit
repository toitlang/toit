// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .lsp_client show LspClient run_client_test

import ...tools.lsp.server.uri_path_translator
import ...tools.lsp.server.documents
import ...tools.lsp.server.file_server

main args:
  run_client_test --use_rpc_filesystem args: test it
  // Also check, that the rpc filesystem works without process.
  run_client_test --use_rpc_filesystem --no-spawn_process args: test it

  run_client_test --use_rpc_filesystem args: test2 it
  // Also check, that the rpc filesystem works without process.
  run_client_test --use_rpc_filesystem --no-spawn_process args: test2 it
  exit 0

PATH_PREFIX ::= "/non_existent/some path with spaces and :/toit_test"

PATH1 ::= "$PATH_PREFIX/p1.toit"
PATH2 ::= "$PATH_PREFIX/p2.toit"
PATH3 ::= "$PATH_PREFIX/p3.toit"
PATH4 ::= "$PATH_PREFIX/p4.toit"

PATH1_CONTENT ::= """
  import .p2

  from_p1:
    from_p2 1
  """

PATH2_CONTENT ::= """
  from_p2 x: return x
  """

PATH3_CONTENT ::= """
  from_p3: unresolved
  """

PATH4_CONTENT ::= """
  import RETURN_NON_EXISTENT
  main:
  """

SPECIAL_FILES1 ::= {
  PATH1: PATH1_CONTENT,
  PATH2: PATH2_CONTENT,
  PATH3: PATH3_CONTENT,
}

PACKAGE_CACHE ::= "$PATH_PREFIX/package_cache"
PATH5 ::= "$PATH_PREFIX/p5.toit"
PATH6A ::= "$PACKAGE_CACHE/pkg_foo"
PATH6B ::= "$PACKAGE_CACHE/pkg_foo/1.0.0"
PATH6C ::= "$PACKAGE_CACHE/pkg_foo/1.0.0/src"
PATH6D ::= "$PACKAGE_CACHE/pkg_foo/1.0.0/src/foo.toit"
PATH7 ::= "$PATH_PREFIX/package.lock"

PATH5_CONTENT ::= """
  import pkg.foo as foo
  main:
    foo.say_hi
  """

PATH6_CONTENT ::= """
  say_hi: return "hello"
  """

PATH7_CONTENT ::= """
prefixes:
  pkg: pkg-foo

packages:
  pkg-foo:
    url: pkg_foo
    version: 1.0.0
"""

SPECIAL_FILES2 ::= {
  PATH5: PATH5_CONTENT,
  PATH6A: true,
  PATH6B: true,
  PATH6C: true,
  PATH6D: PATH6_CONTENT,
  PATH7: PATH7_CONTENT,
}


create_file_response local/FilesystemLocal special_files/Map param:
  path := param["path"]
  file := null
  if special_files.contains path:
    entry := special_files[path]
    if entry is bool:
      file = File path true true true null
    else:
      file = File path true true false entry.to_byte_array
  else if path.contains "RETURN_NON_EXISTENT":
    file = File path false false false null
  else if path == PATH_PREFIX or path == "$PATH_PREFIX/":
    file = File path true false true null
  else:
    file = local.create_file_entry path
  content_string := file.content == null
      ? null
      : file.content.to_string
  return {
    "path": file.path,
    "exists": file.exists,
    "is_regular": file.is_regular,
    "is_directory": file.is_directory,
    "content": content_string,
  }

basename path -> string:
  return (path.split "/").last

create_list_response local/FilesystemLocal special_files/Map param:
  path := param["path"]
  if path == PATH_PREFIX or path == "$PATH_PREFIX/":
    return special_files.keys.map: basename it
  return local.directory_entries path

test client/LspClient:
  translator := UriPathTranslator
  documents := Documents translator
  sdk_path := sdk_path_from_compiler client.toitc
  local := FilesystemLocal sdk_path
  client.install_handler "toit/sdk_path":: local.sdk_path
  client.install_handler "toit/file":: create_file_response local SPECIAL_FILES1 it
  client.install_handler "toit/list":: create_list_response local SPECIAL_FILES1 it

  path := "$PATH_PREFIX/entry.toit"
  client.send_did_open --path=path --text="import .p1"
  diagnostics := client.diagnostics_for --path=path
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=PATH1
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=PATH2
  expect_equals 0 diagnostics.size

  client.send_did_change --path=path "import .p3"
  diagnostics = client.diagnostics_for --path=path
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=PATH3
  expect_equals 1 diagnostics.size

  client.send_did_change --path=path "import "
  responses := client.send_completion_request --path=path 0 7
  expect responses is List
  expect (responses.any: it["label"] == "core")

  client.send_did_change --path=path "import core."
  responses = client.send_completion_request --path=path 0 12
  expect responses is List
  expect (responses.any: it["label"] == "collections")

  client.send_did_change --path=path "import ."
  responses = client.send_completion_request --path=path 0 8
  expect responses is List
  expect (responses.any: it["label"] == "p1")
  expect (responses.any: it["label"] == "p2")
  expect (responses.any: it["label"] == "p3")

  path = PATH4
  client.send_did_open --path=path --text=PATH4_CONTENT
  diagnostics = client.diagnostics_for --path=path
  expect_equals 1 diagnostics.size

test2 client/LspClient:
  path := PATH5
  sdk_path := sdk_path_from_compiler client.toitc
  local := FilesystemLocal sdk_path
  client.install_handler "toit/sdk_path":: local.sdk_path
  client.install_handler "toit/file":: create_file_response local SPECIAL_FILES2 it
  client.install_handler "toit/list":: create_list_response local SPECIAL_FILES2 it
  client.install_handler "toit/package_cache_paths":: [PACKAGE_CACHE]

  client.send_did_open --path=path --text=PATH5_CONTENT
  diagnostics := client.diagnostics_for --path=path
  diagnostics.do: print it
  expect_equals 0 diagnostics.size
