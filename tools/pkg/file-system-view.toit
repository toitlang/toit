
/**
Represents a hierarchical structure as if it where a directory tree. Intermediate nodes represents
  directories and leaf nodes represents files.
*/
interface FileSystemView:
  /**
  Gets the content of the file at $path, by recursively traversing the view.
    For leaf nodes, return the content of the node, for intermediate nodes return a $FileSystemView.
  */
  get --path/List -> any

  /**
  Get the value of the entry denoted by $key in this FileSystemView. If the
    value is a leaf node return the content of that file, otherwise
    return the a $FileSystemView rooted at $key
  */
  get key/string -> any

  /**
  Returns a $Map of the children of this intermediate node. The keys in the $Map are the names of the
    children.
    If the child in an intermediate node the value is a $FileSystemView.
    If the child represents a file, the value is a string equal to key
  */
  list -> Map

