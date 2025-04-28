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

import fs
import net
import net.tcp
import host.pipe show OpenPipe
import host.file
import host.directory
import io
import monitor
import system
import system show platform

import .documents
import .rpc
import .uri-path-translator as translator
import .utils
import .verbose

sdk-path-from-compiler compiler-path/string -> string:
  compiler-path = fs.to-slash compiler-path
  index := compiler-path.index-of --last "/"
  if index < 0: throw "Couldn't determine SDK path"
  result := compiler-path.copy 0 index
  return fs.to-slash (fs.to-absolute result)

class File:
  exists / bool ::= ?
  is-regular / bool ::= ?
  is-directory / bool ::= ?
  content / ByteArray? ::= ?

  constructor .exists .is-regular .is-directory .content:


class FileServerProtocol:
  filesystem / Filesystem ::= ?
  documents_  / Documents  ::= ?

  file-cache_ / Map ::= {:}
  directory-cache_ / Map ::= {:}
  sdk-path_ / string? := null
  package-cache-paths_ / List? := null

  constructor .documents_ .filesystem:

  constructor.local compiler-path/string sdk-path/string .documents_:
    filesystem = FilesystemLocal sdk-path

  handle reader/io.Reader writer/io.Writer:
      while true:
        line := reader.read-line
        if line == null: break
        if line == "SDK PATH":
          if not sdk-path_:
            sdk-path_ = translator.local-path-to-compiler-path filesystem.sdk-path
          writer.write "$sdk-path_\n"
        else if line == "PACKAGE CACHE PATHS":
          if not package-cache-paths_:
            paths := filesystem.package-cache-paths
            package-cache-paths_ = paths.map: translator.local-path-to-compiler-path it
          writer.write "$package-cache-paths_.size\n"
          package-cache-paths_.do: writer.write "$it\n"
        else if line == "LIST DIRECTORY":
          compiler-path := reader.read-line
          entries := directory-cache_.get compiler-path --init=:
            local-path := translator.compiler-path-to-local-path compiler-path
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
    document := documents_.get-opened --uri=(translator.to-uri compiler-path --from-compiler)
    if document:
      exists = true
      is-regular = true
      is-directory = false
      content = document.content.to-byte-array
      return File exists is-regular is-directory content
    local-path := translator.compiler-path-to-local-path compiler-path
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
  from-compiler_ / io.CloseableReader

  constructor .protocol .to-compiler_ .from-compiler_:

  /**
  Starts the pipe file server in a new task.
  Returns "-2".
  */
  run -> string:
    task::
      catch --trace:
        reader := io.Reader.adapt from-compiler_
        writer := io.Writer.adapt to-compiler_
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
  run --port/int=0 -> string:
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
      protocol.handle socket.in socket.out
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
    content := is-reg ? read-contents path : null
    return File does-exist is-reg is-dir content

  abstract sdk-path -> string
  abstract package-cache-paths -> List

  abstract exists path/string -> bool
  /// Whether the file (or the file a symlink is pointing to) is regular.
  abstract is-regular-file path/string -> bool
  abstract is-directory path/string -> bool
  abstract read-contents path/string -> ByteArray
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

  read-contents path/string -> ByteArray: return file.read-contents path

  directory-entries path/string -> List:
    entries := []
    stream := directory.DirectoryStream path
    while entry := stream.next:
      entries.add entry
    stream.close
    return entries
