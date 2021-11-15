// Copyright (C) 2018 Toitware ApS.
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

import reader show Reader

// Manipulation of files on a filesystem.  Currently not available on embedded
// targets.  Names work best when imported without "show *".

// Flags for file.Stream second constructor argument.  Analogous to the
// second argument to the open() system call.
RDONLY ::= 1
WRONLY ::= 2
RDWR ::= 3
APPEND ::= 4
CREAT ::= 8
TRUNC ::= 0x10

// Indices for the array returned by file.stat.
ST_DEV ::= 0
ST_INO ::= 1
ST_MODE ::= 2
ST_TYPE ::= 3
ST_NLINK ::= 4
ST_UID ::= 5
ST_GID ::= 6
ST_SIZE ::= 7
ST_ATIME ::= 8
ST_MTIME ::= 9
ST_CTIME ::= 10

// Filesystem entry types for the ST_TYPE field of file.stat.
FIFO ::= 0
CHARACTER_DEVICE ::= 1
DIRECTORY ::= 2
BLOCK_DEVICE ::= 3
REGULAR_FILE ::= 4
SYMBOLIC_LINK ::= 5
SOCKET ::= 6

// An open file with a current position.  Corresponds in many ways to a file
// descriptor in Posix.
class Stream implements Reader:
  fd_ := ?

  constructor.internal_ .fd_:

  // Open a file for reading.
  constructor.for_read path:
    return Stream path RDONLY 0

  // Open a file for writing, removing whatever was there before.  Uses 0666
  // permission, modified by the current umask.
  constructor.for_write path:
    return Stream path (WRONLY | TRUNC | CREAT) (6 << 6) | (6 << 3) | 6

  constructor name flags:
    if (flags & CREAT) != 0:
      // Two argument version with no permissions can't create new files.
      throw "INVALID_ARGUMENT"
    return Stream name flags 0

  // Returns an open file.  Only for use on actual files, not pipes, devices, etc.
  constructor name flags permissions:
    fd := open_ name flags permissions
    return Stream.internal_ fd

  // Reads some data from the file, returning a byte array.  Returns null on
  // end-of-file.
  read -> ByteArray?:
    return read_ fd_

  // Writes part of the string or ByteArray to the open file descriptor.
  write data from = 0 to = data.size:
    return write_ fd_ data from to

  close:
    close_ fd_

// Returns a file descriptor.  Only for use on actual files, not pipes,
// devices, etc.
open_ name flags permissions:
  #primitive.file.open

// Returns an array describing the given named entry in the filesystem, see the
// index names ST_DEV, etc.
stat name/string --follow_links/bool=true -> List?:
  #primitive.file.stat

// Takes an open file descriptor and determines if it represents a file
// as opposed to a socket or a pipe.
is_open_file_ fd:
  #primitive.file.is_open_file

// Path exists and is a file.
is_file name:
  stat := stat name
  if not stat: return false
  return stat[ST_TYPE] == REGULAR_FILE

// Path exists and is a directory.
is_directory name:
  stat := stat name
  if not stat: return false
  return stat[ST_TYPE] == DIRECTORY

// Return file size in bytes or null for no such file.
size name:
  stat := stat name
  if not stat: return null
  if stat[ST_TYPE] != REGULAR_FILE: throw "INVALID_ARGUMENT"
  return stat[ST_SIZE]

// Reads some data from the file, returning a byte array.  Returns null on
// end-of-file.
read_ descriptor:
  #primitive.file.read

// Writes part of the string or ByteArray to the open file descriptor.
write_ descriptor data from to:
  #primitive.file.write

// Close open file
close_ descriptor:
  #primitive.file.close

// Delete a file, given its name.  Like 'rm' and the 'unlink()' system call,
// this only removes one hard link to a file. The file may still exist if there
// were other hard links.
delete name:
  #primitive.file.unlink

// Rename a file or directory. Only works if the new name is on the same
// filesystem.
rename from to:
  #primitive.file.rename

/// Deprecated. Use $read_content instead.
read_contents name:
  return read_content name

/**
Reads the content of a file.
The file must not change while it is read into memory.

# Advanced
The content is stored in an off-heap ByteArray.
On small devices with a flash filesystem, simply gets a view
  of the underlying bytes. (Not implemented yet)
*/
read_content file_name -> ByteArray:
  length := size file_name
  if length == 0: return ByteArray 0
  file := Stream.for_read file_name
  try:
    byte_array := file.read
    if not byte_array: throw "CHANGED_SIZE"
    if byte_array.size == length: return byte_array
    proxy := create_off_heap_byte_array length
    for pos := 0; pos < length; null:
      proxy.replace pos byte_array 0 byte_array.size
      pos += byte_array.size
      if pos == length: return proxy
      byte_array = file.read
      if not byte_array: throw "CHANGED_SIZE"
    return proxy
  finally:
    file.close
