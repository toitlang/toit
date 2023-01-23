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

import .tcp as tcp
import reader show BufferedReader Reader CloseableReader
import writer show Writer
import host.pipe show OpenPipe
import host.file
import host.directory
import monitor

import .documents
import .rpc
import .utils
import .verbose

sdk_path_from_compiler compiler_path/string -> string:
  is_absolute/bool := ?
  if platform == PLATFORM_WINDOWS:
    compiler_path = compiler_path.replace "\\" "/"
    if compiler_path.starts_with "/":
      is_absolute = true
    else if compiler_path.size >= 3 and compiler_path[1] == ':' and compiler_path[2] == '/':
      is_absolute = true
    else:
      is_absolute = false
  else:
    is_absolute = compiler_path.starts_with "/"

  index := compiler_path.index_of --last "/"
  if index < 0: throw "Couldn't determine SDK path"
  result := compiler_path.copy 0 index
  if not is_absolute:
    // Make it absolute.
    result = "$directory.cwd/$result"
  return result


class File:
  path / string ::= ?
  exists / bool ::= ?
  is_regular / bool ::= ?
  is_directory / bool ::= ?
  content / ByteArray? ::= ?

  constructor .path .exists .is_regular .is_directory .content:


class FileServerProtocol:
  filesystem / Filesystem ::= ?
  documents_  / Documents  ::= ?

  file_cache_ / Map ::= {:}
  directory_cache_ / Map ::= {:}
  sdk_path_ / string? := null
  package_cache_paths_ / List? := null

  constructor .documents_ .filesystem:

  constructor.local compiler_path/string sdk_path/string .documents_:
    filesystem = FilesystemLocal sdk_path

  handle reader/BufferedReader writer/Writer:
      while true:
        line := reader.read_line
        if line == null: break
        if line == "SDK PATH":
          if not sdk_path_: sdk_path_ = filesystem.sdk_path
          writer.write "$sdk_path_\n"
        else if line == "PACKAGE CACHE PATHS":
          if not package_cache_paths_: package_cache_paths_ = filesystem.package_cache_paths
          writer.write "$package_cache_paths_.size\n"
          package_cache_paths_.do: writer.write "$it\n"
        else if line == "LIST DIRECTORY":
          path := reader.read_line
          entries := directory_cache_.get path --init=: filesystem.directory_entries path
          writer.write "$entries.size\n"
          entries.do: writer.write "$it\n"
        else:
          assert: line == "INFO"
          path := reader.read_line

          file := get_file path
          encoded_size := file.content == null ? -1 : file.content.size
          encoded_content := file.content == null ? "" : file.content
          writer.write "$file.exists\n$file.is_regular\n$file.is_directory\n$encoded_size\n"
          writer.write encoded_content

  get_file path /string -> File:
    return file_cache_.get path --init=: create_file_entry_ path

  create_file_entry_ path / string -> File:
    exists := false
    is_regular := false
    is_directory := false
    content := null
    document := documents_.get --path=path
    // Just having a document is not enough, as we might still have entries for
    // deleted files.
    if document and document.content:
      exists = true
      is_regular = true
      is_directory = false
      content = document.content.to_byte_array
      return File path exists is_regular is_directory content
    return filesystem.create_file_entry path

  served_files -> Map: return file_cache_
  served_directories -> Map: return directory_cache_
  served_sdk_path -> string?: return sdk_path_
  served_package_cache_paths -> List?: return package_cache_paths_

interface FileServer:
  // Starts the file server and returns the line that should be given
  // to the compiler to be able to contact it.
  run -> string
  close
  protocol -> FileServerProtocol

class PipeFileServer implements FileServer:
  protocol / FileServerProtocol
  to_compiler_   / OpenPipe
  from_compiler_ / CloseableReader

  constructor .protocol .to_compiler_ .from_compiler_:

  /**
  Starts the pipe file server in a new task.
  Returns "-2".
  */
  run -> string:
    task::
      catch --trace:
        reader := BufferedReader from_compiler_
        writer := Writer to_compiler_
        protocol.handle reader writer
    return "-2"

  close:
    from_compiler_.close
    to_compiler_.close


class TcpFileServer implements FileServer:
  server_   / tcp.TcpServerSocket? := null
  semaphore_ ::= monitor.Semaphore
  protocol / FileServerProtocol

  constructor .protocol:

  /**
  Binds the server and listens for one connection.

  If a $port is given, binds to that port.
  Otherwise binds to an arbitrary port.

  Returns the port at which the server can be reached.
  */
  run --port=0 -> string:
    server_ = tcp.TcpServerSocket
    server_.listen "" port
    port = server_.local_address.port
    task:: catch --trace: accept_
    return "$port"

  close:
    server_.close
    semaphore_.up

  accept_:
    socket := server_.accept
    try:
      socket.no_delay = true
      reader := BufferedReader socket
      writer := Writer socket
      protocol.handle reader writer
    finally:
      socket.close
      close

  wait_for_done -> none:
    semaphore_.down


interface Filesystem:
  /** The path to the SDK. */
  sdk_path -> string

  /**
  The directories in which to look for packages.
  */
  package_cache_paths -> List

  /**
  Creates a $File entry for the $path.

  The content should be null if the file isn't regular.
  */
  create_file_entry path/string -> File

  /**
  Returns a list of entries in the given $path directory.
  */
  directory_entries path/string -> List


abstract class FilesystemBase implements Filesystem:
  create_file_entry path/string -> File:
    does_exist := exists path
    is_reg := does_exist and is_regular_file path
    is_dir := does_exist and not is_reg and is_directory path
    content := is_reg ? read_content path : null
    return File path does_exist is_reg is_dir content

  abstract sdk_path -> string
  abstract package_cache_paths -> List

  abstract exists path/string -> bool
  /// Whether the file (or the file a symlink is pointing to) is regular.
  abstract is_regular_file path/string -> bool
  abstract is_directory path/string -> bool
  abstract read_content path/string -> ByteArray
  abstract directory_entries path/string -> List


class FilesystemLocal extends FilesystemBase:
  sdk_path_ / string  ::= ?
  package_cache_paths_ / List? := null

  constructor .sdk_path_:

  exists path/string -> bool:
    return (file.stat path) != null

  is_regular_file path/string -> bool:
    return file.is_file path

  is_directory path/string -> bool:
    return file.is_directory path

  sdk_path -> string: return sdk_path_
  package_cache_paths -> List:
    if not package_cache_paths_:
      package_cache_paths_ = find_package_cache_paths
    return package_cache_paths_

  read_content path/string -> ByteArray: return file.read_content path

  directory_entries path/string -> List:
    entries := []
    stream := directory.DirectoryStream path
    while entry := stream.next:
      entries.add entry
    stream.close
    return entries
