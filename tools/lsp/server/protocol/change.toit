// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..rpc
import .document

class DidOpenTextDocumentParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /** The document that was opened. */
  text_document -> TextDocumentItem:
    return at_ "textDocument": TextDocumentItem it

class DidCloseTextDocumentParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /** The document that was closed. */
  text_document -> TextDocumentIdentifier:
    return at_ "textDocument": TextDocumentIdentifier it

/**
The document save notification is sent from the client to the server when
  the document was saved in the client.
*/
class DidSaveTextDocumentParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /** The document that was saved. */
  text_document -> TextDocumentIdentifier:
    return at_ "textDocument": TextDocumentIdentifier it

  /**
  Optional the content when saved. Depends on the include_text value
    when the save notification was requested.
  */
  text -> string?:
    return lookup_ "text"

class DidChangeTextDocumentParams extends MapWrapper:
  constructor json_map/Map: super json_map
  /**
  The document that did change.

  The version number points to the version after all provided content changes have
    been applied.
  */
  text_document -> VersionedTextDocumentIdentifier:
    return at_ "textDocument": VersionedTextDocumentIdentifier it

  /**
  The actual content changes.

  The content changes describe single state changes to the document. So if there are
    two content changes c1 and c2 for a document in state S then c1 move the document
    to S' and c2 to S''.
  */
  content_changes -> List/*<TextDocumentContentChangeEvent>*/:
    return at_ "contentChanges":
      for i := 0; i < it.size; i++:
        it[i] = TextDocumentContentChangeEvent it[i]
      it

/**
An event describing a change to a text document.

If range and rangeLength are omitted the new text is considered to be the full content
  of the document.
*/
class TextDocumentContentChangeEvent extends MapWrapper:
  constructor json_map/Map: super json_map

  /** The range of the document that changed. */
  range -> Range?:
    return lookup_ "range": Range.from_map it

  /** The size of the range that got replaced. */
  range_size -> int?:
    return lookup_ "rangeLength"

  /** The new text of the range/document. */
  text -> string:
    return at_ "text"
