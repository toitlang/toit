// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..rpc

class Position extends MapWrapper:
  /**
  Line position i a document (zero-based).
  */
  line -> int:
    return at_ "line"

  /**
  Character offset on a line in a document (zero-based). Assuming that the line is
    represented as a string, the `character` value represents the gap between the
    `character` and `character + 1`.

  If the character value is greater than the line size it defaults back to the
    line size.
  */
  character -> int:
    return at_ "character"

  constructor line character:
    map_["line"]      = line
    map_["character"] = character

  constructor.from_map map/Map: super map

/**
A range in a text document expressed as (zero-based) start and end positions.

A range is comparable to a selection in an editor. Therefore the end position
  is exclusive. If you want to specify a range that contains a line including
  the line ending character(s) then use an end position denoting the start of
  the next line
*/
class Range extends MapWrapper:
  constructor.from_map map/Map: super map

  constructor start/Position end/Position:
    map_["start"] = start.map_
    map_["end"] = end.map_

  constructor.single line character:
    position := Position line character
    return Range position position

  /**
  The range's start position
  */
  start -> Position:
    return at_ "start": Position.from_map it

  /**
  The range's end position.
  */
  end -> Position:
    return at_ "end": Position.from_map it

/**
A location inside a resource, such as a line inside a text file.
*/
class Location extends MapWrapper:
  constructor.from_map json_map/Map: super json_map

  constructor
      --uri   /string   // A DocumentUri
      --range /Range:
    map_["uri"]   = uri
    map_["range"] = range.map_

  uri -> string:
    return at_ "uri"

  range -> Range:
    return at_ "range": Range.from_map it

/**
A link between a source and a target location.
*/
class LocationLink:
  /**
  Span of the origin of this link.

  Used as the underlined span for mouse interaction. Defaults to the word range at
    the mouse position.
  */
  origin_selection_range /Range? ::= null

  /**
  The target resource identifier of this link.
  */
  target_uri /string ::= ?

  /**
  The full target range of this link. If the target for example is a symbol then target range is the
    range enclosing this symbol not including leading/trailing whitespace but everything else
    like comments. This information is typically used to highlight the range in the editor.
  */
  target_range /Range ::= ?

  /**
  The range that should be selected and revealed when this link is being followed, e.g the name of a
    function.

  Must be contained by the the `targetRange`. See also [DocumentSymbol.range]
  */
  target_selection_range /Range ::= ?

  constructor .origin_selection_range .target_uri .target_range .target_selection_range:
  constructor .target_uri .target_range .target_selection_range:

class TextDocumentIdentifier extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The text document's URI.
  */
  // TODO(florian): the returned string is a DocumentUri.
  uri -> string:
    return at_ "uri"

class VersionedTextDocumentIdentifier extends TextDocumentIdentifier:
  constructor json_map/Map: super json_map

  /**
  The version number of this document.

  If a versioned text document identifier is sent from the server to the client
    and the file is not open in the editor (the server has not received an open
    notification before) the server can send `null` to indicate that the version
    is known and the content on disk is the truth (as speced with document content
    ownership).

  The version number of a document increases after each change, including
    undo/redo. The number doesn't need to be consecutive.
  */
  version -> int?:
    return lookup_ "version"

class TextDocumentItem extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The text document's URI.
  */
  // TODO(florian): the returned string is a DocumentUri.
  uri -> string:
    return at_ "uri"

  /**
  The text document's language identifier.
  */
  language_id -> string:
    return at_ "languageId"

  /**
  The version number of this document (it increases after each change, including undo/redo).
  */
  version -> int:
    return at_ "version"

  /**
  The content of the opened text document.
  */
  text -> string:
    return at_ "text"

class TextDocumentPositionParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The text document.
  */
  text_document -> TextDocumentIdentifier:
    return at_ "textDocument": TextDocumentIdentifier it

  /**
  The position inside the text document.
  */
  position -> Position:
    return at_ "position": Position.from_map it
