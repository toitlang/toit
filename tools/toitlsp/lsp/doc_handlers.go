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
	"context"
	"fmt"
	"io/ioutil"
	"os"
	"strings"
	"time"

	"github.com/sourcegraph/go-langserver/langserver/util"
	golsp "github.com/sourcegraph/go-langserver/pkg/lsp"
	"github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

const (
	crashReportRateLimit = 30 * time.Second
)

func isInsideDotPackages(uri lsp.DocumentURI) bool {
	return strings.Contains(string(uri), "/.packages/") ||
		strings.Contains(string(uri), "%2F.packages%2F")
}

func (s *Server) TextDocumentDidOpen(ctx context.Context, conn *jsonrpc2.Conn, req lsp.DidOpenTextDocumentParams) error {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	cCtx := s.GetContext(conn)
	if err := cCtx.Documents.Open(req.TextDocument.URI, req.TextDocument.Text, cCtx.NextAnalysisRevision); err != nil {
		return err
	}

	err := s.analyze(ctx, conn, req.TextDocument.URI)
	if err != nil {
		s.logger.Error("failed to analyze textDocument/didOpen request", zap.String("URI", string(req.TextDocument.URI)), zap.Error(err))
	} else {
		s.logger.Debug("successfully analyzed textDocument/didOpen request", zap.String("URI", string(req.TextDocument.URI)))
	}
	return err
}

func (s *Server) TextDocumentDidChange(ctx context.Context, conn *jsonrpc2.Conn, req lsp.DidChangeTextDocumentParams) error {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	cCtx := s.GetContext(conn)
	for _, change := range req.ContentChanges {
		if change.Range != nil {
			return fmt.Errorf("only full-file update is supported")
		}
		// We only support full-file updates for now.
		// We are calling `analyze` just after updating the document.
		// The next analysis-revision is thus the one where the new content has been
		// taken into account.
		if err := cCtx.Documents.Update(req.TextDocument.URI, change.Text, cCtx.NextAnalysisRevision); err != nil {
			return err
		}
	}
	err := s.analyze(ctx, conn, req.TextDocument.URI)
	if err != nil {
		s.logger.Error("failed to analyze textDocument/didChange request", zap.String("URI", string(req.TextDocument.URI)), zap.Error(err))
	} else {
		s.logger.Debug("successfully analyzed textDocument/didChange request", zap.String("URI", string(req.TextDocument.URI)))
	}
	return err
}

func (s *Server) TextDocumentDidSave(ctx context.Context, conn *jsonrpc2.Conn, req lsp.DidSaveTextDocumentParams) error {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	cCtx := s.GetContext(conn)
	// No need to validate, since we should have gotten a `did_change` before
	//   any save (if the document was dirty).
	return cCtx.Documents.Clear(req.TextDocument.URI)
}

func (s *Server) TextDocumentDidClose(ctx context.Context, conn *jsonrpc2.Conn, req lsp.DidCloseTextDocumentParams) error {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	cCtx := s.GetContext(conn)
	err := cCtx.Documents.Close(req.TextDocument.URI)
	if err != nil {
		return err
	}
	reportPackageDiagnostics := cCtx.Settings.ShouldReportPackageDiagnostics
	if !reportPackageDiagnostics && isInsideDotPackages(req.TextDocument.URI) {
		// Emit an empty diagnostics for this file, in case it had diagnostics before.
		// We are not going to update the diagnostics for this file anymore.
		return publishDiagnostics(ctx, conn, lsp.PublishDiagnosticsParams{
			URI:         req.TextDocument.URI,
			Diagnostics: []lsp.Diagnostic{},
		})
	}
	return nil
}

func (s *Server) textDocumentDefinition(ctx context.Context, conn *jsonrpc2.Conn, req lsp.TextDocumentPositionParams) ([]lsp.Location, error) {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return nil, err
	}
	cCtx := s.GetContext(conn)
	projectURI, err := cCtx.Documents.ProjectURIFor(req.TextDocument.URI, true)
	if err != nil {
		return nil, err
	}
	compiler := s.createCompiler(cCtx)
	res, err := compiler.GotoDefinition(ctx, projectURI, req.TextDocument.URI, req.Position)
	if err != nil {
		return nil, s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: compiler,
		})
	}
	return res, nil
}

func (s *Server) textDocumentCompletion(ctx context.Context, conn *jsonrpc2.Conn, req lsp.CompletionParams) ([]lsp.CompletionItem, error) {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return nil, err
	}
	cCtx := s.GetContext(conn)
	projectURI, err := cCtx.Documents.ProjectURIFor(req.TextDocument.URI, true)
	if err != nil {
		return nil, err
	}
	compiler := s.createCompiler(cCtx)
	res, err := compiler.Complete(ctx, projectURI, req.TextDocument.URI, req.Position)
	if err != nil {
		return nil, s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: compiler,
		})
	}
	return res, nil
}

func (s *Server) textDocumentSymbol(ctx context.Context, conn *jsonrpc2.Conn, req lsp.DocumentSymbolParams) ([]lsp.DocumentSymbol, error) {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return nil, err
	}
	cCtx := s.GetContext(conn)
	projectURI, err := cCtx.Documents.ProjectURIFor(req.TextDocument.URI, true)
	if err != nil {
		return nil, err
	}
	analyzedDocuments := cCtx.Documents.AnalyzedDocumentsFor(projectURI)
	doc, ok := analyzedDocuments.Get(req.TextDocument.URI)
	if !ok || doc.Summary == nil {
		if err := s.analyze(ctx, conn, req.TextDocument.URI); err != nil {
			return nil, err
		}
		doc = analyzedDocuments.GetExisting(req.TextDocument.URI)
		if doc.Summary == nil {
			return nil, nil
		}
	}
	content := ""
	openedDoc, ok := cCtx.Documents.GetOpenedDocument(req.TextDocument.URI)
	if ok && openedDoc.Content != nil {
		content = *openedDoc.Content
	} else {
		path := uri.URIToPath(req.TextDocument.URI)
		f, err := s.localFileSystem.Read(path)
		if err != nil {
			return nil, err
		}
		content = string(f.Content)
	}

	if len(content) == 0 {
		return nil, nil
	}
	return doc.Summary.LSPDocumentSymbols(content), nil
}

func (s *Server) textDocumentSemanticTokensFull(ctx context.Context, conn *jsonrpc2.Conn, req lsp.SemanticTokensParams) (*lsp.SemanticTokens, error) {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return nil, err
	}
	cCtx := s.GetContext(conn)
	projectURI, err := cCtx.Documents.ProjectURIFor(req.TextDocument.URI, true)
	if err != nil {
		return nil, err
	}
	compiler := s.createCompiler(cCtx)
	res, err := compiler.SemanticTokens(ctx, projectURI, req.TextDocument.URI)
	if err != nil {
		return nil, s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: compiler,
		})
	}
	return res, nil
}

// Analyzes the given $uris and sends diagnostics to the client.
// Transitively analyzes all newly discovered files.
func (s *Server) analyze(ctx context.Context, conn *jsonrpc2.Conn, uris ...lsp.DocumentURI) error {
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return err
	}

	cCtx := s.GetContext(conn)
	revision := cCtx.NextAnalysisRevision
	cCtx.NextAnalysisRevision++
	s.SetContext(conn, cCtx)
	return s.analyzeWithRevision(ctx, conn, revision, uris...)
}

func (s *Server) analyzeWithRevision(ctx context.Context, conn *jsonrpc2.Conn, revision int, uris ...lsp.DocumentURI) error {
	if len(uris) == 0 {
		return nil
	}

	// Map from project URI to a list of documents that need to be analyzed.
	projectURIs := map[lsp.DocumentURI][]lsp.DocumentURI{}
	for _, docUri := range uris {
		projectURI, err := s.GetContext(conn).Documents.ProjectURIFor(docUri, true)
		if err != nil {
			return err
		}
		projectURIs[projectURI] = append(projectURIs[projectURI], docUri)
	}

	changedSummaryDocuments := uri.Set{}
	for {
		documents := s.GetContext(conn).Documents
		oldChangedSize := len(changedSummaryDocuments)
		for projectURI, uris := range projectURIs {
			changedInProject, err := s.analyzeWithProjectURIAndRevision(ctx, conn, projectURI, revision, uris...)
			if err != nil {
				return err
			}
			changedSummaryDocuments.AddAll(changedInProject)
		}
		if oldChangedSize == len(changedSummaryDocuments) {
			break
		}
		// Do another run for changed summaries in other projects.
		projectURIs = map[lsp.DocumentURI][]lsp.DocumentURI{}
		for uri := range changedSummaryDocuments {
			projectUrisForUri := documents.ProjectUrisContaining(uri)
			for _, projectURI := range projectUrisForUri {
				// No need to analyze if that already happened.
				analyzedDocuments := documents.AnalyzedDocumentsFor(projectURI)
				doc := analyzedDocuments.GetExisting(uri)
				if doc.AnalysisRevision < revision {
					projectURIs[projectURI] = append(projectURIs[projectURI], uri)
				}
			}
		}
	}
	return nil
}

func (s *Server) analyzeWithProjectURIAndRevision(ctx context.Context, conn *jsonrpc2.Conn, projectURI lsp.DocumentURI, revision int, uris ...lsp.DocumentURI) (uri.Set, error) {
	s.logger.Debug("analyzing", zap.Any("uris", uris))
	defer s.logger.Debug("finished analyzing", zap.Any("uris", uris))
	if len(uris) == 0 {
		return uri.Set{}, nil
	}

	cCtx := s.GetContext(conn)
	analyzedDocuments := cCtx.Documents.AnalyzedDocumentsFor(projectURI)

	c := s.createCompiler(cCtx)
	result, err := c.Analyze(ctx, projectURI, uris...)
	if err != nil {
		err := s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: c,
		})
		if err != nil {
			s.logger.Error("failed to analyze uris", zap.Any("uris", err), zap.Error(err))
		}
		return nil, err
	}

	if len(result.DiagnosticsWithoutPosition) != 0 {
		// Print all non-position errors on stderr.
		// This makes them visible in the LSP output, but doesn't interfere with
		// normal operation of the LSP protocol.
		for _, diagnostic := range result.DiagnosticsWithoutPosition {
			os.Stderr.WriteString(diagnostic + "\n")
		}
	}

	if len(result.Summaries) == 0 {
		// If the diagnostics without position isn't empty, and contains something for a uri, we
		// assume that there was a problem reading the file.
		for _, uri := range uris {
			entryPath := util.UriToRealPath(golsp.DocumentURI(uri))
			probablyEntryProblem := len(result.Diagnostics) == 0 && stringsContainsAny(result.DiagnosticsWithoutPosition, entryPath)
			if probablyEntryProblem {
				_, ok := cCtx.Documents.GetOpenedDocument(uri)
				if ok {
					// This should not happen.
					// TODO(floitsch): report to client and log (potentially creating repro).
					s.logger.Info("LSP server error. Document not opened.", zap.String("URI", string(uri)))
				}
				// In any case: delete the entry, if there is one.
				if err := cCtx.Documents.Delete(uri); err != nil {
					return nil, err
				}
			}
		}
		// Don't use the analysis result.
		return uri.Set{}, nil
	}

	// Documents for which the summary changed.
	changedSummaryDocuments := uri.Set{}
	// Documents for which we want to report diagnostics.
	reportDiagnosticsDocuments := uri.Set{}

	for _, uri := range uris {
		doc := analyzedDocuments.GetOrCreate(uri)
		contentRevision := -1
		if openedDoc, ok := cCtx.Documents.GetOpenedDocument(uri); ok {
			contentRevision = openedDoc.Revision
		}
		if doc.AnalysisRevision < revision && contentRevision <= revision {
			reportDiagnosticsDocuments.Add(uri)
		}
	}

	for summaryURI, summary := range result.Summaries {
		contentRevision := -1
		if openedDoc, ok := cCtx.Documents.GetOpenedDocument(summaryURI); ok {
			contentRevision = openedDoc.Revision
		}
		updateResult, err := analyzedDocuments.UpdateAfterAnalysis(summaryURI, revision, summary, contentRevision)
		if err != nil {
			return nil, err
		}
		hasChangedSummary := (updateResult & SUMMARY_CHANGED_EXTERNALLY_BIT) != 0
		firstAnalysisAfterContentChange := (updateResult & FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT) != 0

		// If the summary has changed, it either means that:
		//  - this was one of the $uris that was analyzed
		//  - the $summary_uri depends on one of the $uris (but was also reachable from them)
		//  - the $summary_uri (or one of its dependencies) was changed. This could be because
		//    of a change on disk, or because of a `did_change` call. In the latter case,
		//    there would still be another analysis running, but this one completed earlier.
		if hasChangedSummary {
			changedSummaryDocuments.Add(summaryURI)
		}
		if hasChangedSummary || firstAnalysisAfterContentChange {
			reportDiagnosticsDocuments.Add(summaryURI)
		}
		depDoc := analyzedDocuments.GetExisting(summaryURI)

		requestRevision := depDoc.AnalysisRequestedByRevision
		if requestRevision != -1 && requestRevision < revision {
			reportDiagnosticsDocuments.Add(summaryURI)
		}
	}

	// All reverse dependencies of changed documents need to have their diagnostics printed.
	for changedURI := range changedSummaryDocuments {
		doc := analyzedDocuments.GetExisting(changedURI)

		// Local lambda that transitively adds reverse dependencies.
		// We add all transitive dependencies, as it's hard to track implicit exports.
		// For example, the return type of a method, requires all users of the method
		//   to check whether a member call of the result is now allowed or not.
		//   Say class 'A' in lib1 has a method 'foo' that is changed to take an additional parameter.
		//   Say lib2 imports lib1 and return an 'A' from its 'bar' method.
		//   Say lib3 imports lib2 and calls `bar.foo`. This call needs a diagnostic change, since
		//     the 'foo' method now requires an additional parameter.
		//
		// Note that we do this only if the summary of the initial file changes. As such, we
		//   usually don't analyze everything.
		//
		// We will also remove files that are in a different project-root. During the
		//   reverse dependency creation we add them (so we don't end up in an infinite
		//   recursion), but they will be removed just afterwards.
		var addReverseDeps func(lsp.DocumentURI) error
		addReverseDeps = func(revDepURI lsp.DocumentURI) error {
			if !reportDiagnosticsDocuments.Contains(revDepURI) {
				reportDiagnosticsDocuments.Add(revDepURI)
				revDepDoc := analyzedDocuments.GetExisting(revDepURI)
				for depDepURI := range revDepDoc.ReverseDependencies {
					if err := addReverseDeps(depDepURI); err != nil {
						return err
					}
				}
			}
			return nil
		}

		for revDepURI := range doc.ReverseDependencies {
			if err := addReverseDeps(revDepURI); err != nil {
				return nil, err
			}
		}
	}

	reportPackageDiagnostics := cCtx.Settings.ShouldReportPackageDiagnostics
	// Remove the documents that are not in the same project-root, or that are
	// in .packages.
	filtered := uri.Set{}
	for uri := range reportDiagnosticsDocuments {
		docProjectURI, err := cCtx.Documents.ProjectURIFor(uri, true)
		if err != nil {
			return nil, err
		}
		if docProjectURI != projectURI {
			continue
		}
		if !reportPackageDiagnostics && isInsideDotPackages(uri) {
			// Only report diagnostics for package files if they are open.
			_, ok := cCtx.Documents.GetOpenedDocument(uri)
			if !ok {
				continue
			}
		}

		filtered.Add(uri)
	}
	reportDiagnosticsDocuments = filtered

	// Send the diagnostics we have to the client.
	for uri := range reportDiagnosticsDocuments {
		doc := analyzedDocuments.GetExisting(uri)
		requestRevision := doc.AnalysisRequestedByRevision
		_, wasAnalyzed := result.Summaries[uri]
		if wasAnalyzed {
			if err := publishDiagnostics(ctx, conn, lsp.PublishDiagnosticsParams{
				URI:         uri,
				Diagnostics: result.Diagnostics[uri],
			}); err != nil {
				return nil, err
			}
			if requestRevision != -1 && requestRevision < revision {
				// Mark the request as done.
				analyzedDocuments.SetAnalysisRequestedByRevision(uri, doc, -1)
			}
		} else if requestRevision < revision {
			analyzedDocuments.SetAnalysisRequestedByRevision(uri, doc, revision)
		}
	}

	// See which documents need to be analyzed as a result of changes.
	documentsNeedsAnalysis := uri.Set{}
	for uri := range reportDiagnosticsDocuments {
		doc := analyzedDocuments.GetExisting(uri)
		documentRevision := -1
		if openedDoc, ok := cCtx.Documents.GetOpenedDocument(uri); ok {
			documentRevision = openedDoc.Revision
		}
		upToDate := doc.AnalysisRevision >= revision
		willBeAnalysed := documentRevision > revision
		if !upToDate && !willBeAnalysed {
			documentsNeedsAnalysis.Add(uri)
		}
	}

	if len(documentsNeedsAnalysis) != 0 {
		// It's highly unlikely that a reverse dependency changes its summary as a result
		// of a change in a dependency. However, this can easily change with language
		// extensions. As such, we just add the result of the recursive call to our result.
		revDepResults, err := s.analyzeWithProjectURIAndRevision(ctx, conn, projectURI, revision, documentsNeedsAnalysis.Values()...)
		if err != nil {
			return nil, err
		}
		changedSummaryDocuments.AddAll(revDepResults)
	}

	return changedSummaryDocuments, nil
}

type handleCompilerErrorOptions struct {
	Conn     *jsonrpc2.Conn
	Error    error
	Compiler *compiler.Compiler
}

func (s *Server) handleCompilerError(ctx context.Context, options handleCompilerErrorOptions) error {
	err := options.Error
	if err == nil {
		return nil
	}

	cCtx := s.GetContext(options.Conn)

	if s.settings.ReturnCompilerErrors {
		return err
	}

	if compiler.IsCompilerError(err) {
		s.logger.Info("compiler error", zap.Error(err))
		if cCtx.Settings.ShouldWriteReproOnCrash {
			return showMessage(ctx, options.Conn, lsp.ShowMessageParams{
				Type:    lsp.Info,
				Message: err.Error(),
			})
		}

		return logMessage(ctx, options.Conn, lsp.LogMessageParams{
			Type:    lsp.Log,
			Message: err.Error(),
		})
	}
	if compiler.IsCrashError(err) {
		cCtx = s.GetContext(options.Conn)
		if time.Since(cCtx.LastCrashReport) < crashReportRateLimit {
			s.logger.Debug("compiler crash was rate limited", zap.Error(err))
			return nil
		}
		cCtx.LastCrashReport = time.Now()
		s.SetContext(options.Conn, cCtx)

		if cCtx.Settings.ShouldWriteReproOnCrash {
			reproFile, err := ioutil.TempFile(cCtx.Settings.ReproDirectory, "repro-*.tar")
			if err != nil {
				s.logger.Info("failed to create temp file for repro", zap.Error(err))
				return err
			}
			err = options.Compiler.Archive(ctx, compiler.ArchiveOptions{
				Writer:     reproFile,
				IncludeSDK: true,
			})
			reproFile.Close()
			if err != nil {
				s.logger.Info("failed to write repro", zap.Error(err))
				return err
			}

			return showMessage(ctx, options.Conn, lsp.ShowMessageParams{
				Type:    lsp.MTError,
				Message: fmt.Sprintf("Compiler crashed. Repro created: %s", reproFile.Name()),
			})
		}
		return logMessage(ctx, options.Conn, lsp.LogMessageParams{
			Type:    lsp.Log,
			Message: err.Error(),
		})
	}
	return err
}

func stringsContainsAny(arr []string, needle string) bool {
	for _, s := range arr {
		if strings.ContainsAny(s, needle) {
			return true
		}
	}
	return false
}

func (s *Server) createCompiler(cCtx ConnContext) *compiler.Compiler {
	fs := MultiFileSystem{NewDocsCacheFileSystem(cCtx.Documents), s.localFileSystem}
	return compiler.New(fs, s.logger.Named("Compiler"), compiler.Settings{
		SDKPath:      cCtx.Settings.SDKPath,
		CompilerPath: cCtx.Settings.ToitcPath,
		Timeout:      cCtx.Settings.Timeout,
	})
}
