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

import .project-uri
import .summary
import .uri-path-translator
import .utils

/**
Keeps track of unsaved files and their dependencies.
*/
class Documents:
  /**
  A map from document uri to opened document.
  During analysis, this map must be used to find the content of a document.
  */
  opened-documents_ /Map/*<string, OpenedDocument>*/ ::= {:}

  /**
  A map from a document URI to its project URI.

  The project URI is the root of the project where we can find the
    package lock file and the downloaded packages.

  From the user's point of view a document is only in one project. Diagnostics
    are only shown for this project.

  Internally, a document might be in more than one project, as local dependencies
    can lead to a document being referenced from multiple projects.
  */
  project-uris_ /Map/*<string, string>*/ ::= {:}

  /**
  A map from project-uri to a $AnalyzedDocuments object.
  Note that URIs might be in more than one project.
  */
  analyzed-documents_ /Map/*<string, AnalyzedDocuments>*/ ::= {:}

  translator_ /UriPathTranslator ::= ?
  error-reporter_ / Lambda ::= ?

  constructor .translator_ --error-reporter/Lambda=(:: /* do nothing */):
    error-reporter_ = error-reporter

  /**
  The project-uri the given document uri belongs to.

  If the document isn't known yet, computes its project-uri.
  If $recompute is true, then recomputes the project-uri even if it is already known.
  */
  project-uri-for --uri/string --recompute/bool=false -> string:
    project-uri := project-uris_.get uri
    if project-uri and not recompute: return project-uri
    computed := compute-project-uri --uri=uri --translator=translator_
    project-uris_[uri] = computed
    if not project-uri: return computed
    // Recompute the project-uri for all documents that are in the same project.
    // A user might have added or removed a package.{yaml|lock} file.
    project-uris_.map --in-place: | document-uri/string document-project-uri/string |
      if document-project-uri == project-uri:
        compute-project-uri --uri=document-uri --translator=translator_
    return computed

  /**
  Returns the $AnalyzedDocuments object for the given $project-uri.

  If the object doesn't exist yet, it is created.
  */
  analyzed-documents-for --project-uri/string -> AnalyzedDocuments:
    return analyzed-documents_.get project-uri --init=: (AnalyzedDocuments translator_ --error-reporter=error-reporter_)

  did-open --uri/string content/string? revision/int -> none:
    document/OpenedDocument? := opened-documents_.get uri
    if document:
      error-reporter_.call "Document $uri already open"
      // Treat it as an did-change.
      document.content = content
    if not document: document = OpenedDocument --uri=uri --content=content --revision=revision
    opened-documents_[uri] = document

  did-change --uri/string new-content/string revision/int-> none:
    document := get-opened-document_ --uri=uri
    document.content = new-content
    document.revision = revision

  did-save --uri/string -> none:
    opened-documents_.remove uri

  did-close --uri/string -> none:
    opened-documents_.remove uri

  delete --uri/string -> none:
    opened-documents_.remove uri
    analyzed-documents_.do: | _ documents/AnalyzedDocuments |
      documents.delete --uri=uri

  get-opened-document_ --uri/string -> OpenedDocument:
    return opened-documents_.get uri --init=:
      error-reporter_.call "Document $uri doesn't exist yet"
      OpenedDocument --uri=uri --revision=-1 --content=""

  get-opened --uri/string -> OpenedDocument?:
    return opened-documents_.get uri

  get-opened --path/string -> OpenedDocument?:
    return get-opened --uri=(translator_.to-uri path)

  do-opened [block] -> none:
    opened-documents_.do: |uri doc| block.call doc

  save-as-tar file-name:
    writer := file.Stream file-name file.CREAT | file.WRONLY 0x1ff
    try:
      write-as-tar writer
    finally:
      writer.close

  write-as-tar writer -> none:
    tar := Tar writer
    opened-documents_.do: |uri entry/OpenedDocument|
      tar.add (translator_.to-path entry.uri) entry.content
    tar.close --no-close-writer

  update-document-after-analysis -> int  // Returns a bitset.
      --project-uri/string
      --uri/string
      --analysis-revision/int
      --summary/Module:
    analyzed := analyzed-documents-for --project-uri=project-uri
    open-document := opened-documents_.get uri
    content-revision := open-document ? open-document.revision : -1
    return analyzed.update-document-after-analysis
        --uri=uri
        --analysis-revision=analysis-revision
        --summary=summary
        --content-revision=content-revision

/**
Keeps track of analyzed documents.
*/
class AnalyzedDocuments:
  // A map from a document URI to its project URI.
  project-uris_ /Map/*<string, string>*/ ::= {:}
  // For each project-uri a map from a document URI to its document.
  // Note that URIs might be in more than one project.
  documents_ /Map/*<Map<string, AnalyzedDocument>>*/ ::= {:}
  // For each project-uri a set of document URIs that are relevant
  // for the project.
  // Note that this information is redundant with the information in
  // `documents_`, but it is more efficient to keep it here.
  documents-in-project_ /Map/*<string, Set<string>>*/ ::= {:}

  translator_ /UriPathTranslator ::= ?
  error-reporter_ / Lambda ::= ?

  constructor .translator_ --error-reporter/Lambda:
    error-reporter_ = error-reporter

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

  delete --uri/string -> none:
    document := documents_.get uri
    if document:
      document.summary.dependencies.do:
        (get-existing --uri=it).reverse-deps.remove uri
    documents_.remove uri

  /**
  Updates the $summary for the given $uri.

  Updates reverse-dependencies.

  Returns a bitset, using $SUMMARY-CHANGED-EXTERNALLY-BIT and $FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT.
  The caller can use these to see whether reverse-dependencies need to be analyzed, or whether
    diagnostics of this analysis need to be reported.
  */
  update-document-after-analysis -> int  // Returns a bitset.
      --uri/string
      --analysis-revision/int
      --content-revision/int
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
        dep-doc := get-existing --uri=dep-uri
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
    if old-analysis-revision < content-revision and
        analysis-revision >= content-revision:
      result |= FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT
    if not (old-summary and old-summary.equals-external summary):
      result |= SUMMARY-CHANGED-EXTERNALLY-BIT

    return result

  get-dependency-document_ --uri/string -> AnalyzedDocument:
    return documents_.get uri --init=: AnalyzedDocument

  get-existing --uri/string -> AnalyzedDocument:
    result := documents_.get uri --init=:
      error-reporter_.call "Document $uri doesn't exist yet"
      AnalyzedDocument
    return result

  get --uri/string -> AnalyzedDocument?: return documents_.get uri
  get --path/string -> AnalyzedDocument?: return get --uri=(translator_.to-uri path)

/**
A document that is opened in the editor and thus has content that isn't
saved to disk.
*/
class OpenedDocument:
  uri     / string
  content / string := ?

  /**
  The revision of the $content.

  The revision of the content is synchronized with the analyzer revision.
  Any analysis result that is equal or greater than the content revision provides
    up-to-date results.
  */
  revision / int := ?

  constructor --.uri --.content --.revision:


class AnalyzedDocument:
  summary  / Module? := ?
  reverse-deps / Set := ?

  // The revision of the analysis that last ran on this document.
  // -1 if no analysis has been run yet.
  analysis-revision / int := -1

  // The revision of an analysis that requested to update the diagnostics of this document.
  // -1 if no request is pending.
  analysis-requested-by-revision / int := -1

  constructor
      --.summary=null
      --.reverse-deps={}:
