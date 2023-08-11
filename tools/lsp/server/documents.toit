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

import host.file
import tar show *
import .summary

import .uri-path-translator
import .utils

/**
Keeps track of unsaved files.
*/
class Documents:
  documents_ /Map/*<string, Document>*/ ::= {:}
  translator_ /UriPathTranslator ::= ?
  error-reporter_ / Lambda ::= ?

  constructor .translator_ --.error-reporter_=(:: /* do nothing */):

  did-open --uri/string content/string? revision/int -> none:
    document := documents_.get uri
    if document: error-reporter_.call "Document $uri already open"
    if not document: document = Document --uri=uri
    document.content = content
    document.content-revision = revision
    document.is-open = true
    documents_[uri] = document

  did-change --uri/string new-content/string revision/int-> none:
    document := get-existing-document --uri=uri --is-open
    document.content = new-content
    document.content-revision = revision

  did-save --uri/string -> none:
    document := get-existing-document --uri=uri --is-open
    document.content = null
    // Keep the content-version number, as it could be useful for `update_document_after_analysis`.

  did-close --uri/string -> none:
    // We keep the entry, as the LSP client might still show errors, even if the file isn't open anymore.
    document := get-existing-document --uri=uri --is-open
    document.content = null
    document.is-open = false

  delete --uri/string -> none:
    document := documents_.get uri
    if document:
      document.summary.dependencies.do:
        (get-existing-document --uri=it).reverse-deps.remove uri
    documents_.remove uri

  /**
  This bit is set, if the summary changed externally.
  If the summary only changed in a way that doesn't affect modules that
    import this summary, then the bit is not set. For example, changes to
    the documentation, or to code inside a method will not set this bit.
  */
  static SUMMARY-CHANGED-EXTERNALLY-BIT ::= 1
  /**
  This bit is set, if this analysis was the first to provide a fresh
  analysis for new content.
  */
  static FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT ::= 2

  /**
  Updates the $summary for the given $uri.

  Updates reverse-dependencies.

  Returns a bitset, using $SUMMARY-CHANGED-EXTERNALLY-BIT and $FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT.
  The caller can use these to see whether reverse-dependencies need to be analyzed, or whether
    diagnostics of this analysis need to be reported.
  */
  update-document-after-analysis --uri/string -> int  // Returns a bitset.
      --analysis-revision/int
      --summary/Module:
    document := get-dependency-document_ --uri=uri

    // If there was already a newer analysis we can completely ignore this update.
    if document.analysis-revision >= analysis-revision: return 0

    old-deps := {}
    if document.summary:
      old-deps.add-all document.summary.dependencies
    new-deps := {}
    new-deps.add-all summary.dependencies

    // Delete all obsolete reverse dependencies.
    old-deps.do: |dep-uri|
      if not new-deps.contains dep-uri:
        dep-doc := get-existing-document --uri=dep-uri
        dep-doc.reverse-deps.remove uri --if-absent=:
          error-reporter_.call "Couldn't delete reverse dependency for $dep-uri (not dep of $uri anymore)"
    // Set up the new reverse dependencies.
    new-deps.do: |dep-uri|
      if not old-deps.contains dep-uri:
        dep-doc := get-dependency-document_ --uri=dep-uri
        dep-doc.reverse-deps.add uri

    old-summary := document.summary
    old-analysis-revision := document.analysis-revision

    document.summary = summary
    document.analysis-revision = analysis-revision

    result := 0
    if old-analysis-revision < document.content-revision and
        analysis-revision >= document.content-revision:
      result |= FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT
    if not (old-summary and old-summary.equals-external summary):
      result |= SUMMARY-CHANGED-EXTERNALLY-BIT

    return result

  /**
  Returns the document for $uri.

  The document must exist.
  If $is-open, then also checks that the document is currently open.
  */
  get-existing-document --uri/string --is-open/bool=false -> Document:
    result := documents_.get uri --init=:
      error-reporter_.call "Document $uri doesn't exist yet"
      Document --uri=uri --is-open=is-open
    if is-open and not result.is-open:
      error-reporter_.call "Document $uri isn't open as expected"
    return result
  get-existing-document --path/string --is-open/bool=false -> Document:
    return get-existing-document --uri=(translator_.to-uri path) --is-open=is-open

  get-dependency-document_ --uri/string -> Document:
    return documents_.get uri --init=: Document --uri=uri

  save-as-tar file-name:
    writer := file.Stream file-name file.CREAT | file.WRONLY 0x1ff
    try:
      write-as-tar writer
    finally:
      writer.close

  write-as-tar writer -> none:
    tar := Tar writer
    documents_.do: |uri entry|
      if entry.content: tar.add (translator_.to-path entry.uri) entry.content
    tar.close --no-close-writer

  get --uri/string -> Document?: return documents_.get uri
  get --path/string -> Document?: return get --uri=(translator_.to-uri path)

  do [block] -> none:
    documents_.do: |uri doc| block.call doc


class Document:
  uri      / string ::= ?
  is-open  / bool    := ?
  content  / string? := ?
  summary  / Module? := ?
  reverse-deps / Set := ?

  /**
  The revision of the $content.

  The revision of the content is synchronized with the analyzer revision.
  Any analysis result that is equal or greater than the content revision provides
    up-to-date results.
  */
  content-revision / int := ?

  /**
  Whether the summary is correct. That is, whether the summary could be used instead
    of the content to analyze other files.
  */
  is-summary-up-to-date -> bool:
    return summary and analysis-revision >= content-revision

  // The revision of the analysis that last ran on this document.
  // -1 if no analysis has been run yet.
  analysis-revision / int := -1

  // The revision of an analysis that requested to update the diagnostics of this document.
  // -1 if no request is pending.
  analysis-requested-by-revision / int := -1

  constructor --.uri
      --.is-open=false
      --.content=null
      --.content-revision=-1
      --.summary=null
      --.reverse-deps={}:
