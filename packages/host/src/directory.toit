// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

// Manipulation of directories on a filesystem.  Currently not available on
// embedded targets.  Names work best when imported with "show *".

import .file as file

/** Removes an empty directory. */
rmdir path/string -> none:
  #primitive.file.rmdir

/**
Removes the directory and all its content.
*/
rmdir --recursive/bool path/string -> none:
  if not recursive:
    rmdir path
    return
  stream := DirectoryStream path
  while entry := stream.next:
    child := "$path/$entry"
    if file.is_directory child: rmdir --recursive child
    else: file.delete child
  stream.close
  rmdir path

/**
Creates an empty directory.

The given permissions are masked with the current umask to get
  the permissions of the new directory.
*/
mkdir path/string mode/int=0x1ff -> none:
  #primitive.file.mkdir

/**
Creates an empty directory, creating the parent directories if needed.

The given permissions are masked with the current umask to get
  the permissions of the new directory.
*/
mkdir --recursive/bool path/string mode/int=0x1ff -> none:
  if not recursive:
    mkdir path mode
    return

  built_path := ""
  parts := path.split "/"
  parts.size.repeat:
    part := parts[it]
    built_path += "$part/"
    if not file.is_directory built_path:
      mkdir built_path mode

/**
Creates a fresh directory with the given prefix.

The system adds random characters to make the name unique and creates a fresh
  directory with the new name.
Returns the name of the created directory.

# Examples
```
test_dir := mkdtemp "/tmp/test-"
print test_dir  // => "/tmp/test-1v42wp"  (for example).
```
*/
mkdtemp prefix/string="" -> string:
  return (mkdtemp_ prefix).to_string

mkdtemp_ prefix/string -> ByteArray:
  #primitive.file.mkdtemp

// Change the current directory.  Only changes the current directory for one
// Toit process, even if the Unix process contains more than one Toit process.
chdir name:
  #primitive.file.chdir

// An open directory, used to iterate over the named entries in a directory.
class DirectoryStream:
  fd_ := ?

  constructor name:
    fd_ = opendir_ name

  /**
  Returns a string with the next name from the directory.
  The '.' and '..' entries are skipped and never returned.
  Returns null when no entry is left.
  */
  next -> string?:
    while true:
      byte_array := readdir_ fd_
      if not byte_array: return null
      str := byte_array.to_string
      if str == "." or str == "..": continue
      return str

  close -> none:
    fd := fd_
    closedir_ fd

opendir_ name:
  #primitive.file.opendir

readdir_ dir -> ByteArray:
  #primitive.file.readdir

closedir_ dir:
  #primitive.file.closedir

same_entry_ a b:
  if a[file.ST_INO] != b[file.ST_INO]: return false
  return a[file.ST_DEV] == b[file.ST_DEV]

// Get the canonical version of a file path, removing . and .. and resolving
// symbolic links.  Returns null if the path does not exist, but may throw on
// other errors such as symlink loops.
realpath path:
  if path is not string: throw "WRONG_TYPE"
  if path == "": throw "NO_SUCH_FILE"
  // Relative paths must be prepended with the current directory, and we can't
  // let the C realpath routine do that for us, because it doesn't understand
  // what our current directory is.
  if not path.starts_with "/": path = "$cwd/$path"
  #primitive.file.realpath

// Get the current working directory.  Like the 'pwd' command, this works by
// iterating up through the filesystem tree using the ".." links, until it
// finds the root.
cwd:
  #primitive.file.cwd:
    // The primitive is only implemented for Macos, so ending up here is normal.
    dir := ""
    pos := ""
    while true:
      dot := file.stat "$(pos)."
      dot_dot := file.stat "$(pos).."
      if same_entry_ dot dot_dot:
        return dir == "" ? "/" : dir
      found := false
      above := DirectoryStream "$(pos).."
      while name := above.next:
        name_stat := file.stat "$(pos)../$name" --follow_links=false
        if name_stat:
          if same_entry_ name_stat dot:
            dir = "/$name$dir"
            found = true
            break
      above.close
      pos = "../$pos"
      if not found:
        throw "CURRENT_DIRECTORY_UNLINKED"  // The current directory is not present in the file system any more.
