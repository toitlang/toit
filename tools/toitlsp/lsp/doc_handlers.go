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

func (s *Server) TextDocumentDidOpen(ctx context.Context, conn *jsonrpc2.Conn, req lsp.DidOpenTextDocumentParams) error {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	cCtx := s.GetContext(conn)
	if err := cCtx.Documents.Add(req.TextDocument.URI, &req.TextDocument.Text, cCtx.NextAnalysisRevision); err != nil {
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
	return cCtx.Documents.Close(req.TextDocument.URI)
}

func (s *Server) textDocumentDefinition(ctx context.Context, conn *jsonrpc2.Conn, req lsp.TextDocumentPositionParams) ([]lsp.Location, error) {
	req.TextDocument.URI = uri.Canonicalize(req.TextDocument.URI)
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return nil, err
	}
	cCtx := s.GetContext(conn)
	compiler := s.createCompiler(cCtx)
	res, err := compiler.GotoDefinition(ctx, req.TextDocument.URI, req.Position)
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
	compiler := s.createCompiler(cCtx)
	res, err := compiler.Complete(ctx, req.TextDocument.URI, req.Position)
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
	doc, ok := cCtx.Documents.Get(req.TextDocument.URI)
	if !ok || doc.Summary == nil {
		if err := s.analyze(ctx, conn, req.TextDocument.URI); err != nil {
			return nil, err
		}
		doc = cCtx.Documents.GetExisting(req.TextDocument.URI)
		if doc.Summary == nil {
			return nil, nil
		}
	}
	var content string
	if doc.Content != nil {
		content = *doc.Content
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
	compiler := s.createCompiler(cCtx)
	res, err := compiler.SemanticTokens(ctx, req.TextDocument.URI)
	if err != nil {
		return nil, s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: compiler,
		})
	}
	return res, nil
}

/**
  Analyzes the given $uris and sends diagnostics to the client.

  Transitively analyzes all newly discovered files.
*/
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
	s.logger.Debug("analyzing", zap.Any("uris", uris))
	defer s.logger.Debug("finished analyzing", zap.Any("uris", uris))
	if len(uris) == 0 {
		return nil
	}

	cCtx := s.GetContext(conn)
	c := s.createCompiler(cCtx)
	result, err := c.Analyze(ctx, uris...)
	if err != nil {
		err := s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: c,
		})
		if err != nil {
			s.logger.Error("failed to analyze uris", zap.Any("uris", err), zap.Error(err))
		}
		return err
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
			document, ok := cCtx.Documents.Get(uri)
			if probablyEntryProblem && ok {
				if document.IsOpen {
					// This should not happen.
					// TODO(jesper): report to client and log (potentially creating repro).
				} else {
					if err := cCtx.Documents.Delete(uri); err != nil {
						return err
					}
				}
			}
		}
		// Don't use the analysis result.
		return nil
	}

	// Documents for which the summary changed.
	changedSummaryDocuments := uri.Set{}
	// Documents for which we want to report diagnostics.
	reportDiagnosticsDocuments := uri.Set{}

	for _, uri := range uris {
		doc := cCtx.Documents.GetExisting(uri)
		if doc.AnalysisRevision < revision && doc.ContentRevision <= revision {
			reportDiagnosticsDocuments.Add(uri)
		}
	}

	for summaryURI, summary := range result.Summaries {
		updateResult, err := cCtx.Documents.UpdateAfterAnalysis(summaryURI, revision, summary)
		if err != nil {
			return err
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
		depDoc := cCtx.Documents.GetExisting(summaryURI)

		requestRevision := depDoc.AnalysisRequestedByRevision
		if requestRevision != -1 && requestRevision < revision {
			reportDiagnosticsDocuments.Add(summaryURI)
		}
	}

	// All reverse dependencies of changed documents need to have their diagnostics printed.
	for changedURI := range changedSummaryDocuments {
		doc := cCtx.Documents.GetExisting(changedURI)

		// Local lambda that transitively adds reverse dependencies.
		// We add all transitive dependencies, as it's hard to track implicit exports.
		// For example, the return type of a method, requires all users of the method
		//   to check whether a member call of the result is now allowed or not.
		// This can be happen multiple layers down. See #1513 for an example.
		// Note that we do this only if the summary of the initial file changes. As such, we
		//   usually don't analyze everything.
		var addReverseDeps func(lsp.DocumentURI) error
		addReverseDeps = func(revDepURI lsp.DocumentURI) error {
			if !reportDiagnosticsDocuments.Contains(revDepURI) {
				reportDiagnosticsDocuments.Add(revDepURI)
				revDepDoc := cCtx.Documents.GetExisting(revDepURI)
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
				return err
			}
		}
	}

	// Send the diagnostics we have to the client.
	for uri := range reportDiagnosticsDocuments {
		doc := cCtx.Documents.GetExisting(uri)
		requestRevision := doc.AnalysisRequestedByRevision
		_, wasAnalyzed := result.Summaries[uri]
		if wasAnalyzed {
			if err := publishDiagnostics(ctx, conn, lsp.PublishDiagnosticsParams{
				URI:         uri,
				Diagnostics: result.Diagnostics[uri],
			}); err != nil {
				return err
			}
			if requestRevision != -1 && requestRevision < revision {
				// Mark the request as done.
				cCtx.Documents.SetAnalysisRequestedByRevision(doc, -1)
			}
		} else if requestRevision < revision {
			cCtx.Documents.SetAnalysisRequestedByRevision(doc, revision)
		}
	}

	// See which documents need to be analyzed as a result of changes.
	documentsNeedsAnalysis := uri.Set{}
	for uri := range reportDiagnosticsDocuments {
		doc := cCtx.Documents.GetExisting(uri)
		upToDate := doc.AnalysisRevision >= revision
		willBeAnalysed := doc.ContentRevision > revision
		if !upToDate && !willBeAnalysed {
			documentsNeedsAnalysis.Add(uri)
		}
	}

	return s.analyzeWithRevision(ctx, conn, revision, documentsNeedsAnalysis.Values()...)
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
		RootURI:      cCtx.RootURI,
	})
}
