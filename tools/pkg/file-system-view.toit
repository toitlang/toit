// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.


/**
A hierarchical structure as if it where a directory tree.
Intermediate nodes represent directories and leaf nodes represent files.
*/
interface FileSystemView:
  /**
  Gets the content of the file at $path, by recursively traversing the view.

  Returns the content of the file, if the $path resolves to a leaf node.
  Returns a $FileSystemView, if the $path resolves to an intermediate node.
  */
  get --path/List -> any

  /**
  Gets the value of the entry denoted by $key in this FileSystemView.

  Returns the content of the file, if the $key resolves to a leaf node.
  Returns a $FileSystemView, if the $key resolves to an intermediate node.
  */
  get key/string -> any

  /**
  Returns a $Map of the children of this intermediate node.
  The keys in the $Map are the names of the children.
  If the child is an intermediate node then its value is a $FileSystemView.
  If the child represents a file, then the value is a string equal to the key.
  */
  list -> Map

