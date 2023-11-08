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

import net
import net.tcp
import reader show BufferedReader Reader CloseableReader
import writer show Writer
import host.pipe show OpenPipe
import host.file
import host.directory
import monitor
import system
import system show platform

import .documents
import .rpc
import .uri-path-translator
import .utils
import .verbose

sdk-path-from-compiler compiler-path/string -> string:
  is-absolute/bool := ?
  if platform == system.PLATFORM-WINDOWS:
    compiler-path = compiler-path.replace "\\" "/"
    if compiler-path.starts-with "/":
      is-absolute = true
    else if compiler-path.size >= 3 and compiler-path[1] == ':' and compiler-path[2] == '/':
      is-absolute = true
    else:
      is-absolute = false
  else:
    is-absolute = compiler-path.starts-with "/"

  index := compiler-path.index-of --last "/"
  if index < 0: throw "Couldn't determine SDK path"
  result := compiler-path.copy 0 index
  if not is-absolute:
    // Make it absolute.
    result = "$directory.cwd/$result"
  return result


class File:
  exists / bool ::= ?
  is-regular / bool ::= ?
  is-directory / bool ::= ?
  content / ByteArray? ::= ?

  constructor .exists .is-regular .is-directory .content:


class FileServerProtocol:
  filesystem / Filesystem ::= ?
  documents_  / Documents  ::= ?
  translator_ / UriPathTranslator ::= ?

  file-cache_ / Map ::= {:}
  directory-cache_ / Map ::= {:}
  sdk-path_ / string? := null
  package-cache-paths_ / List? := null

  constructor .documents_ .filesystem .translator_:

  constructor.local compiler-path/string sdk-path/string .documents_ .translator_:
    filesystem = FilesystemLocal sdk-path

  handle reader/BufferedReader writer/Writer:
      while true:
        line := reader.read-line
        if line == null: break
        if line == "SDK PATH":
          if not sdk-path_:
            sdk-path_ = translator_.local-path-to-compiler-path filesystem.sdk-path
          writer.write "$sdk-path_\n"
        else if line == "PACKAGE CACHE PATHS":
          if not package-cache-paths_: package-cache-paths_ = filesystem.package-cache-paths
          writer.write "$package-cache-paths_.size\n"
          package-cache-paths_.do: writer.write "$it\n"
        else if line == "LIST DIRECTORY":
          compiler-path := reader.read-line
          entries := directory-cache_.get compiler-path --init=:
            local-path := translator_.compiler-path-to-local-path compiler-path
            entries-for-path/List := []
            exception := catch:  // The path might not exist.
              entries-for-path = filesystem.directory-entries local-path
            if exception:
              verbose: "Couldn't list directory: $local-path"
            entries-for-path

          writer.write "$entries.size\n"
          entries.do: writer.write "$it\n"
        else:
          assert: line == "INFO"
          compiler-path := reader.read-line
          file := get-file compiler-path
          encoded-size := file.content == null ? -1 : file.content.size
          encoded-content := file.content == null ? "" : file.content
          writer.write "$file.exists\n$file.is-regular\n$file.is-directory\n$encoded-size\n"
          writer.write encoded-content

  get-file compiler-path/string -> File:
    return file-cache_.get compiler-path --init=: create-file-entry_ compiler-path

  create-file-entry_ compiler-path / string -> File:
    exists := false
    is-regular := false
    is-directory := false
    content := null
    document := documents_.get --uri=(translator_.to-uri compiler-path --from-compiler)
    // Just having a document is not enough, as we might still have entries for
    // deleted files.
    if document and document.content:
      exists = true
      is-regular = true
      is-directory = false
      content = document.content.to-byte-array
      return File exists is-regular is-directory content
    local-path := translator_.compiler-path-to-local-path compiler-path
    return filesystem.create-file-entry local-path

  served-files -> Map: return file-cache_
  served-directories -> Map: return directory-cache_
  served-sdk-path -> string?: return sdk-path_
  served-package-cache-paths -> List?: return package-cache-paths_

interface FileServer:
  // Starts the file server and returns the line that should be given
  // to the compiler to be able to contact it.
  run -> string
  close
  protocol -> FileServerProtocol

class PipeFileServer implements FileServer:
  protocol / FileServerProtocol
  to-compiler_   / OpenPipe
  from-compiler_ / CloseableReader

  constructor .protocol .to-compiler_ .from-compiler_:

  /**
  Starts the pipe file server in a new task.
  Returns "-2".
  */
  run -> string:
    task::
      catch --trace:
        reader := BufferedReader from-compiler_
        writer := Writer to-compiler_
        protocol.handle reader writer
    return "-2"

  close:
    from-compiler_.close
    to-compiler_.close


class TcpFileServer implements FileServer:
  server_   / tcp.ServerSocket? := null
  semaphore_ ::= monitor.Semaphore
  protocol / FileServerProtocol

  constructor .protocol:

  /**
  Binds the server and listens for one connection.

  If a $port is given, binds to that port.
  Otherwise binds to an arbitrary port.

  Returns the port at which the server can be reached as a string.
  */
  run --port=0 -> string:
    network := net.open
    server_ = network.tcp-listen port
    local-port := server_.local-address.port
    task:: catch --trace: accept_
    return "$local-port"

  close:
    server_.close
    semaphore_.up

  accept_:
    socket := server_.accept
    try:
      socket.no-delay = true
      reader := BufferedReader socket
      writer := Writer socket
      protocol.handle reader writer
    finally:
      socket.close
      close

  wait-for-done -> none:
    semaphore_.down


interface Filesystem:
  /** The path to the SDK. */
  sdk-path -> string

  /**
  The directories in which to look for packages.
  */
  package-cache-paths -> List

  /**
  Creates a $File entry for the $path.

  The content should be null if the file isn't regular.
  */
  create-file-entry path/string -> File

  /**
  Returns a list of entries in the given $path directory.
  */
  directory-entries path/string -> List


abstract class FilesystemBase implements Filesystem:
  create-file-entry path/string -> File:
    does-exist := exists path
    is-reg := does-exist and is-regular-file path
    is-dir := does-exist and not is-reg and is-directory path
    content := is-reg ? read-content path : null
    return File does-exist is-reg is-dir content

  abstract sdk-path -> string
  abstract package-cache-paths -> List

  abstract exists path/string -> bool
  /// Whether the file (or the file a symlink is pointing to) is regular.
  abstract is-regular-file path/string -> bool
  abstract is-directory path/string -> bool
  abstract read-content path/string -> ByteArray
  abstract directory-entries path/string -> List


class FilesystemLocal extends FilesystemBase:
  sdk-path_ / string  ::= ?
  package-cache-paths_ / List? := null

  constructor .sdk-path_:

  exists path/string -> bool:
    return (file.stat path) != null

  is-regular-file path/string -> bool:
    return file.is-file path

  is-directory path/string -> bool:
    return file.is-directory path

  sdk-path -> string: return sdk-path_
  package-cache-paths -> List:
    if not package-cache-paths_:
      package-cache-paths_ = find-package-cache-paths
    return package-cache-paths_

  read-content path/string -> ByteArray: return file.read-content path

  directory-entries path/string -> List:
    entries := []
    stream := directory.DirectoryStream path
    while entry := stream.next:
      entries.add entry
    stream.close
    return entries
