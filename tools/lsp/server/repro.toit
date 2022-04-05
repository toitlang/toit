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

import host.pipe show print_to_stdout
import host.directory
import host.file
import tar show Tar
import encoding.json as json
import .compiler
import .documents
import .file_server
import .uri_path_translator
import .server show DEFAULT_TIMEOUT_MS
import .tar_utils
import .utils

REPRO_META_FILE_PATH ::= "/<meta>"
REPRO_SDK_PATH_PATH  ::= "/<sdk-path>"
REPRO_PACKAGE_CACHE_PATHS_PATH  ::= "/<package-cache-paths>"
REPRO_CWD_PATH_PATH  ::= "/<cwd>"
REPRO_COMPILER_FLAGS_PATH ::= "/<compiler-flags>"
REPRO_COMPILER_INPUT_PATH ::= "/<compiler-input>"
REPRO_INFO_PATH ::= "/<info>"

class FilesystemRepro extends FilesystemBase:
  archive_ / string ::= ?
  file_meta_ / Map ::= ?
  directory_meta_ / Map ::= ?
  sdk_path_ / string ::= ?
  package_cache_paths_ / List ::= ?

  constructor .archive_:
    parsed := json.parse (tar_extract archive_ REPRO_META_FILE_PATH)
    file_meta_ = parsed["files"]
    directory_meta_ = parsed["directories"]
    sdk_path_ = tar_extract archive_ REPRO_SDK_PATH_PATH
    package_cache_paths_ = (tar_extract archive_ REPRO_PACKAGE_CACHE_PATHS_PATH).split "\n"

  exists path/string -> bool:
    return file_meta_.get path
        --if_present=: it["exists"]
        --if_absent=: false

  is_regular_file path/string -> bool:
    return file_meta_.get path
        --if_present=: it["is_regular"]
        --if_absent=: false

  is_directory path/string -> bool:
    return file_meta_.get path
        --if_present=: it["is_directory"]
        --if_absent=: false

  sdk_path -> string: return sdk_path_
  package_cache_paths -> List: return package_cache_paths_

  read_content path/string -> ByteArray?:
    has_content := file_meta_.get path
        --if_present=: it["has_content"]
        --if_absent=: false
    if not has_content: return null
    return tar_extract --binary archive_ path

  directory_entries path/string -> List:
    return directory_meta_.get path

/**
Creates a tar file with all files that have been served.
*/
write_repro
    --repro_path     /string
    --compiler_flags /List
    --compiler_input /string
    --info           /string
    --protocol       /FileServerProtocol
    --cwd_path       /string?
    --include_sdk    /bool:
  writer := file.Stream.for_write repro_path
  write_repro --writer=writer \
      --compiler_flags=compiler_flags --compiler_input=compiler_input --info=info \
      --protocol=protocol --cwd_path=cwd_path --include_sdk=include_sdk
  writer.close

write_repro
    --writer
    --compiler_flags /List
    --compiler_input /string
    --info           /string
    --protocol       /FileServerProtocol
    --cwd_path       /string?
    --include_sdk    /bool:
  meta := {
    "files": {:},
    "directories": {:}
  }
  // If the sdk-path wasn't used then it's null. We can pick any value at that point. (We choose "").
  sdk_path := protocol.served_sdk_path or ""
  if not sdk_path.ends_with "/": sdk_path += "/"
  // If the package-cache paths wasn't used then it's null. We can pick any value at that point.
  // We choose [].
  package_cache_paths := protocol.served_package_cache_paths or []

  tar := Tar writer
  protocol.served_files.do: |path file|
    if not include_sdk and path.starts_with sdk_path: continue.do

    meta["files"][path] = {
      "exists": file.exists,
      "is_regular": file.is_regular,
      "is_directory": file.is_directory,
      "has_content": file.content != null
    }
    content := file.content
    if content: tar.add path content
  protocol.served_directories.do: |path entries|
    meta["directories"][path] = entries
  tar.add REPRO_COMPILER_FLAGS_PATH (compiler_flags.join "\n")
  tar.add REPRO_COMPILER_INPUT_PATH compiler_input
  tar.add REPRO_INFO_PATH info
  tar.add REPRO_META_FILE_PATH (json.stringify meta)
  tar.add REPRO_SDK_PATH_PATH sdk_path
  tar.add REPRO_PACKAGE_CACHE_PATHS_PATH (package_cache_paths.join "\n")
  tar.add REPRO_CWD_PATH_PATH (cwd_path or "/")
  // There is ambiguity on whether we need to call `close_write` or `close`.
  // As a consequence we don't close using the `tar`, but simply call close afterwards.
  tar.close --no-close_writer

create_archive project_path/string? compiler_path/string entry_path/string out_path/string:
  cwd := directory.cwd
  if not entry_path.starts_with "/": entry_path = "$cwd/$entry_path"
  translator := UriPathTranslator
  documents := Documents translator
  sdk_path := sdk_path_from_compiler compiler_path
  protocol := FileServerProtocol.local compiler_path sdk_path documents
  compiler := Compiler compiler_path translator DEFAULT_TIMEOUT_MS
      --protocol=protocol
      --project_path=project_path
  entry_uri := translator.to_uri entry_path
  compiler.analyze [entry_uri]

  write_repro
      --repro_path=out_path
      --compiler_flags=compiler.build_run_flags
      --compiler_input="ANALYZE\n1\n$entry_path\n"
      --info="from repro tool"
      --protocol=protocol
      --cwd_path=cwd
      --include_sdk
