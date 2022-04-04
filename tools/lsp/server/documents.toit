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

import .uri_path_translator
import .utils

/**
Keeps track of unsaved files.
*/
class Documents:
  documents_ /Map/*<string, Document>*/ ::= {:}
  translator_ /UriPathTranslator ::= ?
  error_reporter_ / Lambda ::= ?

  constructor .translator_ --.error_reporter_=(:: /* do nothing */):

  did_open --uri/string content/string? revision/int -> none:
    document := documents_.get uri
    if document: error_reporter_.call "Document $uri already open"
    if not document: document = Document --uri=uri
    document.content = content
    document.content_revision = revision
    document.is_open = true
    documents_[uri] = document

  did_change --uri/string new_content/string revision/int-> none:
    document := get_existing_document --uri=uri --is_open
    document.content = new_content
    document.content_revision = revision

  did_save --uri/string -> none:
    document := get_existing_document --uri=uri --is_open
    document.content = null
    // Keep the content-version number, as it could be useful for `update_document_after_analysis`.

  did_close --uri/string -> none:
    // We keep the entry, as the LSP client might still show errors, even if the file isn't open anymore.
    document := get_existing_document --uri=uri --is_open
    document.content = null
    document.is_open = false

  delete --uri/string -> none:
    document := documents_.get uri
    if document:
      document.summary.dependencies.do:
        (get_existing_document --uri=it).reverse_deps.remove uri
    documents_.remove uri

  /**
  This bit is set, if the summary changed externally.
  If the summary only changed in a way that doesn't affect modules that
    import this summary, then the bit is not set. For example, changes to
    the documentation, or to code inside a method will not set this bit.
  */
  static SUMMARY_CHANGED_EXTERNALLY_BIT ::= 1
  /**
  This bit is set, if this analysis was the first to provide a fresh
  analysis for new content.
  */
  static FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT ::= 2

  /**
  Updates the $summary for the given $uri.

  Updates reverse-dependencies.

  Returns a bitset, using $SUMMARY_CHANGED_EXTERNALLY_BIT and $FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT.
  The caller can use these to see whether reverse-dependencies need to be analyzed, or whether
    diagnostics of this analysis need to be reported.
  */
  update_document_after_analysis --uri/string -> int  // Returns a bitset.
      --analysis_revision/int
      --summary/Module:
    document := get_dependency_document_ --uri=uri

    // If there was already a newer analysis we can completely ignore this update.
    if document.analysis_revision >= analysis_revision: return 0

    old_deps := {}
    if document.summary:
      old_deps.add_all document.summary.dependencies
    new_deps := {}
    new_deps.add_all summary.dependencies

    // Delete all obsolete reverse dependencies.
    old_deps.do: |dep_uri|
      if not new_deps.contains dep_uri:
        dep_doc := get_existing_document --uri=dep_uri
        dep_doc.reverse_deps.remove uri --if_absent=:
          error_reporter_.call "Couldn't delete reverse dependency for $dep_uri (not dep of $uri anymore)"
    // Set up the new reverse dependencies.
    new_deps.do: |dep_uri|
      if not old_deps.contains dep_uri:
        dep_doc := get_dependency_document_ --uri=dep_uri
        dep_doc.reverse_deps.add uri

    old_summary := document.summary
    old_analysis_revision := document.analysis_revision

    document.summary = summary
    document.analysis_revision = analysis_revision

    result := 0
    if old_analysis_revision < document.content_revision and
        analysis_revision >= document.content_revision:
      result |= FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT
    if not (old_summary and old_summary.equals_external summary):
      result |= SUMMARY_CHANGED_EXTERNALLY_BIT

    return result

  /**
  Returns the document for $uri.

  The document must exist.
  If $is_open, then also checks that the document is currently open.
  */
  get_existing_document --uri/string --is_open/bool=false -> Document:
    result := documents_.get uri --init=:
      error_reporter_.call "Document $uri doesn't exist yet"
      Document --uri=uri --is_open=is_open
    if is_open and not result.is_open:
      error_reporter_.call "Document $uri isn't open as expected"
    return result
  get_existing_document --path/string --is_open/bool=false -> Document:
    return get_existing_document --uri=(translator_.to_uri path) --is_open=is_open

  get_dependency_document_ --uri/string -> Document:
    return documents_.get uri --init=: Document --uri=uri

  save_as_tar file_name:
    writer := file.Stream file_name file.CREAT | file.WRONLY 0x1ff
    try:
      write_as_tar writer
    finally:
      writer.close

  write_as_tar writer -> none:
    tar := Tar writer
    documents_.do: |uri entry|
      if entry.content: tar.add (translator_.to_path entry.uri) entry.content
    tar.close --no-close_writer

  get --uri/string -> Document?: return documents_.get uri
  get --path/string -> Document?: return get --uri=(translator_.to_uri path)

  do [block] -> none:
    documents_.do: |uri doc| block.call doc


class Document:
  uri      / string ::= ?
  is_open  / bool    := ?
  content  / string? := ?
  summary  / Module? := ?
  reverse_deps / Set := ?

  /**
  The revision of the $content.

  The revision of the content is synchronized with the analyzer revision.
  Any analysis result that is equal or greater than the content revision provides
    up-to-date results.
  */
  content_revision / int := ?

  /**
  Whether the summary is correct. That is, whether the summary could be used instead
    of the content to analyze other files.
  */
  is_summary_up_to_date -> bool:
    return summary and analysis_revision >= content_revision

  // The revision of the analysis that last ran on this document.
  // -1 if no analysis has been run yet.
  analysis_revision / int := -1

  // The revision of an analysis that requested to update the diagnostics of this document.
  // -1 if no request is pending.
  analysis_requested_by_revision / int := -1

  constructor --.uri
      --.is_open=false
      --.content=null
      --.content_revision=-1
      --.summary=null
      --.reverse_deps={}:
