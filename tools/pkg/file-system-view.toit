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

