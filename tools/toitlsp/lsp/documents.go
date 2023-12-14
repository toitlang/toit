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
	l      sync.RWMutex
	logger *zap.Logger

	// A map from document URI to opened document.
	// During analysis, this map must be used to find the content of a document.
	openedDocuments map[lsp.DocumentURI]*OpenedDocument

	// A map from a document URI to its project URI.
	//
	// The project URI is the root of the projcet where we can find the
	// package lock file and the downloaded packages.
	//
	// From the user's point of view a document is only in one project. Diagnostics
	// are only shown for this project.
	//
	// Internally, a document might be in more than one project, as local dependencies
	// can lead to a document being referenced from multiple projects.
	projectURIs map[lsp.DocumentURI]lsp.DocumentURI

	// A map from document URI to analyzed documents for the specific uri..
	analyzedDocuments map[lsp.DocumentURI]*AnalyzedDocuments
}

func NewDocuments(logger *zap.Logger) *Documents {
	return &Documents{
		logger:            logger,
		openedDocuments:   map[lsp.DocumentURI]*OpenedDocument{},
		projectURIs:       map[lsp.DocumentURI]lsp.DocumentURI{},
		analyzedDocuments: map[lsp.DocumentURI]*AnalyzedDocuments{},
	}
}

func (d *Documents) AnalyzedDocumentsFor(projectURI lsp.DocumentURI) *AnalyzedDocuments {
	d.l.Lock()
	defer d.l.Unlock()
	ad, ok := d.analyzedDocuments[projectURI]
	if !ok {
		ad = newAnalyzedDocuments(d.logger)
		d.analyzedDocuments[projectURI] = ad
	}
	return ad
}

func (d *Documents) AllProjectURIs() []lsp.DocumentURI {
	d.l.RLock()
	defer d.l.RUnlock()
	res := make([]lsp.DocumentURI, 0, len(d.projectURIs))
	for _, uri := range d.projectURIs {
		res = append(res, uri)
	}
	return res
}

func (d *Documents) ProjectURIFor(uri lsp.DocumentURI, recompute bool) (lsp.DocumentURI, error) {
	d.l.Lock()
	defer d.l.Unlock()
	projectURI, ok := d.projectURIs[uri]
	if ok && !recompute {
		return projectURI, nil
	}
	computed, err := computeProjectURI(uri)
	if err != nil {
		return "", err
	}
	d.projectURIs[uri] = computed
	if !ok {
		return computed, nil
	}
	// Recompute the project-uri for all documents that are in the same project.
	// A user might have added or removed a package.{yaml|lock} file.
	for otherURI, otherProjectURI := range d.projectURIs {
		if otherProjectURI == projectURI {
			newURI, err := computeProjectURI(otherURI)
			if err != nil {
				return "", err
			}
			d.projectURIs[otherURI] = newURI
		}
	}
	return computed, nil
}

func (d *Documents) ProjectUrisContaining(uri lsp.DocumentURI) []lsp.DocumentURI {
	result := []lsp.DocumentURI{}
	d.l.RLock()
	defer d.l.RUnlock()
	for projectURI, analyzedDocument := range d.analyzedDocuments {
		if _, ok := analyzedDocument.Get(uri); ok {
			result = append(result, projectURI)
		}
	}
	return result
}

func (d *Documents) Open(uri lsp.DocumentURI, content string, revision int) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc, ok := d.openedDocuments[uri]
	if ok {
		d.logger.Debug("document already open", zap.String("uri", string(uri)))
		// Treat it as if it was an update.
		doc.Content = &content
		doc.Revision = revision
	} else {
		doc = newOpenedDocument(uri, content, revision)
		d.openedDocuments[uri] = doc
	}
	return nil
}

func (d *Documents) Update(uri lsp.DocumentURI, newContent string, revision int) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc := d.getExistingOpenedDocument(uri)
	doc.Content = &newContent
	doc.Revision = revision
	return nil
}

// Used when the document has been saved.
func (d *Documents) Clear(uri lsp.DocumentURI) error {
	d.l.Lock()
	defer d.l.Unlock()
	doc := d.getExistingOpenedDocument(uri)
	doc.Content = nil
	return nil
}

func (d *Documents) Close(uri lsp.DocumentURI) error {
	d.l.Lock()
	defer d.l.Unlock()
	delete(d.openedDocuments, uri)
	return nil
}

func (d *Documents) getExistingOpenedDocument(uri lsp.DocumentURI) *OpenedDocument {
	doc, ok := d.openedDocuments[uri]
	if !ok {
		d.logger.Error("couldn't get existing opened document", zap.String("uri", string(uri)))
		doc = newOpenedDocument(uri, "", -1)
		d.openedDocuments[uri] = doc
	}
	return doc
}

func (d *Documents) GetOpenedDocument(uri lsp.DocumentURI) (*OpenedDocument, bool) {
	d.l.RLock()
	defer d.l.RUnlock()
	doc, ok := d.openedDocuments[uri]
	if !ok {
		return nil, false
	}

	return doc, true
}

func (d *Documents) Delete(uri lsp.DocumentURI) error {
	d.l.Lock()
	defer d.l.Unlock()

	delete(d.openedDocuments, uri)

	for _, ad := range d.analyzedDocuments {
		ad.Delete(uri)
	}
	return nil
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

type AnalyzedDocuments struct {
	l      sync.RWMutex
	logger *zap.Logger
	// For this instance of analyzed documents a map from a document URI to its document.
	// Note that URIs might be in more than one project and thus AnalyzedDocuments object.
	documents map[lsp.DocumentURI]*AnalyzedDocument
}

func newAnalyzedDocuments(logger *zap.Logger) *AnalyzedDocuments {
	return &AnalyzedDocuments{
		logger:    logger,
		documents: map[lsp.DocumentURI]*AnalyzedDocument{},
	}
}

func (ad *AnalyzedDocuments) Delete(uri lsp.DocumentURI) error {
	ad.l.Lock()
	defer ad.l.Unlock()
	doc, ok := ad.documents[uri]
	if ok {
		if doc.Summary != nil {
			for _, dep := range doc.Summary.Dependencies {
				doc := ad.get(dep)
				doc.ReverseDependencies.Remove(uri)
			}
		}
	}
	delete(ad.documents, uri)
	return nil
}

/**
  Updates the $summary for the given $uri.

  Updates reverse-dependencies.

  Returns a bitset, using $SUMMARY_CHANGED_EXTERNALLY_BIT and $FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT.
  The caller can use these to see whether reverse-dependencies need to be analyzed, or whether
    diagnostics of this analysis need to be reported.
*/

func (ad *AnalyzedDocuments) UpdateAfterAnalysis(docUri lsp.DocumentURI, analysisRevision int, summary *toit.Module, contentRevision int) (int, error) {
	ad.l.Lock()
	defer ad.l.Unlock()
	doc := ad.getOrCreate(docUri)

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
			depDoc := ad.getExisting(oldDep)
			if !depDoc.ReverseDependencies.Contains(docUri) {
				ad.logger.Error("couldn't delete reverse dependency (not dep anymore)", zap.String("uri", string(docUri)), zap.String("dep_uri", string(oldDep)))
			} else {
				depDoc.ReverseDependencies.Remove(docUri)
			}
		}
	}

	for newDep := range newDeps {
		if !oldDeps.Contains(newDep) {
			depDoc := ad.getOrCreate(newDep)
			depDoc.ReverseDependencies.Add(docUri)
		}
	}

	oldAnalysisRevision := doc.AnalysisRevision
	doc.Summary = summary
	doc.AnalysisRevision = analysisRevision

	res := 0
	if oldAnalysisRevision < contentRevision && analysisRevision >= contentRevision {
		res |= FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT
	}
	if oldSummary == nil || !oldSummary.EqualsExternal(summary) {
		res |= SUMMARY_CHANGED_EXTERNALLY_BIT
	}

	return res, nil
}

func (ad *AnalyzedDocuments) SetAnalysisRequestedByRevision(uri lsp.DocumentURI, document *AnalyzedDocument, analysisRequestedByRevision int) {
	ad.l.Lock()
	defer ad.l.Unlock()
	doc, ok := ad.documents[uri]
	if !ok {
		return
	}
	if doc.AnalysisRequestedByRevision == document.AnalysisRequestedByRevision {
		doc.AnalysisRequestedByRevision = analysisRequestedByRevision
	}
}

func (ad *AnalyzedDocuments) Get(docUri lsp.DocumentURI) (*AnalyzedDocument, bool) {
	ad.l.RLock()
	defer ad.l.RUnlock()
	doc, ok := ad.documents[docUri]
	if !ok {
		return nil, false
	}
	return doc, true
}

func (ad *AnalyzedDocuments) GetOrCreate(docUri lsp.DocumentURI) *AnalyzedDocument {
	ad.l.Lock()
	defer ad.l.Unlock()
	return ad.getOrCreate(docUri)
}

func (ad *AnalyzedDocuments) getOrCreate(docUri lsp.DocumentURI) *AnalyzedDocument {
	doc, ok := ad.documents[docUri]
	if !ok {
		doc = newAnalyzedDocument()
		ad.documents[docUri] = doc
	}
	return doc
}

func (ad *AnalyzedDocuments) GetExisting(docUri lsp.DocumentURI) *AnalyzedDocument {
	ad.l.Lock()
	defer ad.l.Unlock()
	return ad.getExisting(docUri)
}

func (ad *AnalyzedDocuments) getExisting(docUri lsp.DocumentURI) *AnalyzedDocument {
	doc, ok := ad.documents[docUri]
	if !ok {
		ad.logger.Error("couldn't get existing document", zap.String("uri", string(docUri)))
		return ad.getOrCreate(docUri)
	}
	return doc
}

func (ad *AnalyzedDocuments) get(docUri lsp.DocumentURI) *AnalyzedDocument {
	doc, ok := ad.documents[docUri]
	if !ok {
		return nil
	}
	return doc
}

func (ad *AnalyzedDocuments) Summaries() map[lsp.DocumentURI]*toit.Module {
	res := map[lsp.DocumentURI]*toit.Module{}
	ad.l.RLock()
	defer ad.l.RUnlock()
	for url, doc := range ad.documents {
		res[url] = doc.Summary
	}
	return res
}

type OpenedDocument struct {
	URI     lsp.DocumentURI
	Content *string
	/**
	The revision of the $content.

	The revision of the content is synchronized with the analyzer revision.
	Any analysis result that is equal or greater than the content revision provides
		up-to-date results.
	*/
	Revision int
}

func newOpenedDocument(uri lsp.DocumentURI, content string, revision int) *OpenedDocument {
	return &OpenedDocument{
		URI:      uri,
		Content:  &content,
		Revision: revision,
	}
}

type AnalyzedDocument struct {
	Summary             *toit.Module
	ReverseDependencies uri.Set

	// AnalysisRevision, The revision of the analysis that last ran on this document.
	// -1 if no analysis has been run yet.
	AnalysisRevision int

	// The revision of an analysis that requested to update the diagnostics of this document.
	// -1 if no request is pending.
	AnalysisRequestedByRevision int
}

func newAnalyzedDocument() *AnalyzedDocument {
	return &AnalyzedDocument{
		AnalysisRevision:            -1,
		AnalysisRequestedByRevision: -1,
	}
}
