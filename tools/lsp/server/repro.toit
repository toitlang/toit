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

import host.pipe show print-to-stdout
import host.directory
import host.file
import tar show Tar
import encoding.json as json
import .compiler
import .documents
import .file-server
import .uri-path-translator
import .server show DEFAULT-TIMEOUT-MS
import .tar-utils
import .utils

REPRO-META-FILE-PATH ::= "/<meta>"
REPRO-SDK-PATH-PATH  ::= "/<sdk-path>"
REPRO-PACKAGE-CACHE-PATHS-PATH  ::= "/<package-cache-paths>"
REPRO-CWD-PATH-PATH  ::= "/<cwd>"
REPRO-COMPILER-FLAGS-PATH ::= "/<compiler-flags>"
REPRO-COMPILER-INPUT-PATH ::= "/<compiler-input>"
REPRO-INFO-PATH ::= "/<info>"

class FilesystemRepro extends FilesystemBase:
  archive_ / string ::= ?
  file-meta_ / Map ::= ?
  directory-meta_ / Map ::= ?
  sdk-path_ / string ::= ?
  package-cache-paths_ / List ::= ?

  constructor .archive_:
    parsed := json.parse (tar-extract archive_ REPRO-META-FILE-PATH)
    file-meta_ = parsed["files"]
    directory-meta_ = parsed["directories"]
    sdk-path_ = tar-extract archive_ REPRO-SDK-PATH-PATH
    package-cache-paths_ = (tar-extract archive_ REPRO-PACKAGE-CACHE-PATHS-PATH).split "\n"

  exists path/string -> bool:
    return file-meta_.get path
        --if-present=: it["exists"]
        --if-absent=: false

  is-regular-file path/string -> bool:
    return file-meta_.get path
        --if-present=: it["is_regular"]
        --if-absent=: false

  is-directory path/string -> bool:
    return file-meta_.get path
        --if-present=: it["is_directory"]
        --if-absent=: false

  sdk-path -> string: return sdk-path_
  package-cache-paths -> List: return package-cache-paths_

  read-content path/string -> ByteArray?:
    has-content := file-meta_.get path
        --if-present=: it["has_content"]
        --if-absent=: false
    if not has-content: return null
    return tar-extract --binary archive_ path

  directory-entries path/string -> List:
    return directory-meta_.get path

/**
Creates a tar file with all files that have been served.
*/
write-repro
    --repro-path     /string
    --compiler-flags /List
    --compiler-input /string
    --info           /string
    --protocol       /FileServerProtocol
    --cwd-path       /string?
    --include-sdk    /bool:
  writer := file.Stream.for-write repro-path
  write-repro --writer=writer \
      --compiler-flags=compiler-flags --compiler-input=compiler-input --info=info \
      --protocol=protocol --cwd-path=cwd-path --include-sdk=include-sdk
  writer.close

write-repro
    --writer
    --compiler-flags /List
    --compiler-input /string
    --info           /string
    --protocol       /FileServerProtocol
    --cwd-path       /string?
    --include-sdk    /bool:
  meta := {
    "files": {:},
    "directories": {:}
  }
  // If the sdk-path wasn't used then it's null. We can pick any value at that point. (We choose "").
  sdk-path := protocol.served-sdk-path or ""
  if not sdk-path.ends-with "/": sdk-path += "/"
  // If the package-cache paths wasn't used then it's null. We can pick any value at that point.
  // We choose [].
  package-cache-paths := protocol.served-package-cache-paths or []

  tar := Tar writer
  protocol.served-files.do: |path file|
    if not include-sdk and path.starts-with sdk-path: continue.do

    meta["files"][path] = {
      "exists": file.exists,
      "is_regular": file.is-regular,
      "is_directory": file.is-directory,
      "has_content": file.content != null
    }
    content := file.content
    if content: tar.add path content
  protocol.served-directories.do: |path entries|
    meta["directories"][path] = entries
  tar.add REPRO-COMPILER-FLAGS-PATH (compiler-flags.join "\n")
  tar.add REPRO-COMPILER-INPUT-PATH compiler-input
  tar.add REPRO-INFO-PATH info
  tar.add REPRO-META-FILE-PATH (json.stringify meta)
  tar.add REPRO-SDK-PATH-PATH sdk-path
  tar.add REPRO-PACKAGE-CACHE-PATHS-PATH (package-cache-paths.join "\n")
  tar.add REPRO-CWD-PATH-PATH (cwd-path or "/")
  // There is ambiguity on whether we need to call `close_write` or `close`.
  // As a consequence we don't close using the `tar`, but simply call close afterwards.
  tar.close --no-close-writer

create-archive project-uri/string? compiler-path/string entry-path/string out-path/string:
  cwd := directory.cwd
  if not entry-path.starts-with "/": entry-path = "$cwd/$entry-path"
  translator := UriPathTranslator
  documents := Documents translator
  sdk-path := sdk-path-from-compiler compiler-path
  protocol := FileServerProtocol.local compiler-path sdk-path documents translator
  compiler := Compiler compiler-path translator DEFAULT-TIMEOUT-MS
      --protocol=protocol
      --project-uri=project-uri
  entry-uri := translator.to-uri entry-path
  compiler.analyze [entry-uri]

  write-repro
      --repro-path=out-path
      --compiler-flags=compiler.build-run-flags
      --compiler-input="ANALYZE\n1\n$entry-path\n"
      --info="from repro tool"
      --protocol=protocol
      --cwd-path=cwd
      --include-sdk
