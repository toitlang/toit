// Copyright (C) 2021 Toitware ApS.
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

package lsp

import (
	"sync"

	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

type Documents struct {
	l         sync.RWMutex
	logger    *zap.Logger
	documents map[lsp.DocumentURI]*Document
}

func NewDocuments(logger *zap.Logger) *Documents {
	return &Documents{
		logger:    logger,
		documents: map[lsp.DocumentURI]*Document{},
	}
}

func (d *Documents) Add(uri lsp.DocumentURI, content *string, revision int) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc, ok := d.documents[uri]
	if ok {
		d.logger.Debug("document already open", zap.String("uri", string(uri)))
	} else {
		doc = &Document{
			URI:                         uri,
			AnalysisRevision:            -1,
			AnalysisRequestedByRevision: -1,
		}
		d.documents[uri] = doc
	}
	doc.Content = content
	doc.ContentRevision = revision
	doc.IsOpen = true
	return nil
}

func (d *Documents) Update(uri lsp.DocumentURI, newContent string, revision int) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc := d.get(uri, true)
	doc.Content = &newContent
	doc.ContentRevision = revision
	return nil
}

func (d *Documents) Clear(uri lsp.DocumentURI) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc := d.get(uri, true)
	doc.Content = nil
	return nil
}

func (d *Documents) Close(uri lsp.DocumentURI) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc := d.get(uri, true)
	doc.IsOpen = false
	doc.Content = nil
	return nil
}

func (d *Documents) GetExisting(uri lsp.DocumentURI) Document {
	d.l.RLock()
	defer d.l.RUnlock()
	doc := d.get(uri, false)
	if doc == nil {
		d.logger.Info("failed to lookup document", zap.String("uri", string(uri)))
		return Document{}
	}
	return *doc
}

func (d *Documents) Get(uri lsp.DocumentURI) (Document, bool) {
	d.l.RLock()
	defer d.l.RUnlock()
	doc, ok := d.documents[uri]
	if !ok {
		return Document{}, ok
	}
	return *doc, ok
}

func (d *Documents) Summaries() map[lsp.DocumentURI]*toit.Module {
	res := map[lsp.DocumentURI]*toit.Module{}
	d.l.RLock()
	defer d.l.RUnlock()
	for url, doc := range d.documents {
		res[url] = doc.Summary
	}
	return res
}

func (d *Documents) get(uri lsp.DocumentURI, isOpen bool) *Document {
	doc, ok := d.documents[uri]
	if !ok {
		d.logger.Debug("Document doesn't exist yet", zap.String("uri", string(uri)))
		doc = &Document{
			URI:    uri,
			IsOpen: isOpen,
		}
		d.documents[uri] = doc
	}

	if isOpen && !doc.IsOpen {
		d.logger.Error("Document isn't open as expected", zap.String("uri", string(uri)))
	}

	return doc
}

func (d *Documents) Delete(uri lsp.DocumentURI) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc, ok := d.documents[uri]
	if ok {
		if doc.Summary != nil {
			for _, dep := range doc.Summary.Dependencies {
				doc := d.get(dep, false)
				doc.ReverseDependencies.Remove(uri)
			}
		}
	}
	delete(d.documents, uri)
	return nil
}

func (d *Documents) SetAnalysisRequestedByRevision(document Document, analysisRequestedByRevision int) {
	d.l.Lock()
	defer d.l.Unlock()
	doc, ok := d.documents[document.URI]
	if !ok {
		return
	}
	if doc.AnalysisRequestedByRevision == document.AnalysisRequestedByRevision {
		doc.AnalysisRequestedByRevision = analysisRequestedByRevision
	}
}

const (
	/**
	  This bit is set, if the summary changed externally.
	  If the summary only changed in a way that doesn't affect modules that
	    import this summary, then the bit is not set. For example, changes to
	    the documentation, or to code inside a method will not set this bit.
	*/
	SUMMARY_CHANGED_EXTERNALLY_BIT = 1
	/**
	  This bit is set, if this analysis was the first to provide a fresh
	  analysis for new content.
	*/
	FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT = 2
)

/**
  Updates the $summary for the given $uri.

  Updates reverse-dependencies.

  Returns a bitset, using $SUMMARY_CHANGED_EXTERNALLY_BIT and $FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT.
  The caller can use these to see whether reverse-dependencies need to be analyzed, or whether
    diagnostics of this analysis need to be reported.
*/

func (d *Documents) UpdateAfterAnalysis(docUri lsp.DocumentURI, analysisRevision int, summary *toit.Module) (int, error) {
	d.l.Lock()
	defer d.l.Unlock()
	doc := d.get(docUri, false)

	if doc.AnalysisRevision >= analysisRevision {
		return 0, nil
	}

	oldDeps := uri.Set{}
	oldSummary := doc.Summary
	if oldSummary != nil {
		oldDeps.Add(oldSummary.Dependencies...)
	}
	newDeps := uri.Set{}
	newDeps.Add(summary.Dependencies...)

	for oldDep := range oldDeps {
		if !newDeps.Contains(oldDep) {
			depDoc := d.get(oldDep, false)
			if !depDoc.ReverseDependencies.Contains(docUri) {
				d.logger.Error("couldn't delete reverse dependency (not dep anymore)", zap.String("uri", string(docUri)), zap.String("dep_uri", string(oldDep)))
			} else {
				depDoc.ReverseDependencies.Remove(docUri)
			}
		}
	}

	for newDep := range newDeps {
		if !oldDeps.Contains(newDep) {
			depDoc := d.get(newDep, false)
			depDoc.ReverseDependencies.Add(docUri)
		}
	}

	oldAnalysisRevision := doc.AnalysisRevision
	doc.Summary = summary
	doc.AnalysisRevision = analysisRevision

	res := 0
	if oldAnalysisRevision < doc.ContentRevision && analysisRevision >= doc.ContentRevision {
		res |= FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT
	}
	if oldSummary == nil || !oldSummary.EqualsExternal(summary) {
		res |= SUMMARY_CHANGED_EXTERNALLY_BIT
	}

	return res, nil
}

type Document struct {
	URI                 lsp.DocumentURI
	IsOpen              bool
	Content             *string
	Summary             *toit.Module
	ReverseDependencies uri.Set

	/**
	The revision of the $content.

	The revision of the content is synchronized with the analyzer revision.
	Any analysis result that is equal or greater than the content revision provides
		up-to-date results.
	*/
	ContentRevision int

	// AnalysisRevision, The revision of the analysis that last ran on this document.
	// -1 if no analysis has been run yet.
	AnalysisRevision int

	// The revision of an analysis that requested to update the diagnostics of this document.
	// -1 if no request is pending.
	AnalysisRequestedByRevision int
}
