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
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"time"

	"github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

func (s *Server) ToitReportIdle(ctx context.Context, conn *jsonrpc2.Conn) error {
	s.OnIdle(conn, func(ctx context.Context, conn *jsonrpc2.Conn) {
		if err := notifyToitIdle(ctx, conn); err != nil {
			s.logger.Warn("failed to notify idle", zap.Error(err))
		}
	})
	return nil
}

type DidOpenManyParams struct {
	URIs []lsp.DocumentURI `json:"uris"`
}

func (s *Server) ToitDidOpenMany(ctx context.Context, conn *jsonrpc2.Conn, req DidOpenManyParams) error {
	cCtx := s.GetContext(conn)

	uris := req.URIs
	for i := range uris {
		uris[i] = uri.Canonicalize(uris[i])
	}

	for _, uri := range uris {
		if err := cCtx.Documents.Add(uri, nil, cCtx.NextAnalysisRevision); err != nil {
			return err
		}
	}

	err := s.analyze(ctx, conn, uris...)
	if err != nil {
		s.logger.Error("failed to analyze toit/DidOpenMany request", zap.Any("URIs", uris), zap.Error(err))
	} else {
		s.logger.Debug("successfully analyzed toit/DidOpenMany request", zap.Any("URIs", req.URIs))
	}
	return err
}

func (s *Server) ToitResetCrashRateLimit(ctx context.Context, conn *jsonrpc2.Conn) error {
	cCtx := s.GetContext(conn)
	cCtx.LastCrashReport = time.Time{}
	s.SetContext(conn, cCtx)
	return nil
}

type AnalyzeParams struct {
	URIs []lsp.DocumentURI `json:"uris"`
}

func lspRangeLess(aRange lsp.Range, bRange lsp.Range) bool {
	posCompare := func(aPos lsp.Position, bPos lsp.Position) int {
		if aPos.Line != bPos.Line {
			return aPos.Line - bPos.Line
		}
		return aPos.Character - bPos.Character
	}

	startComp := posCompare(aRange.Start, bRange.Start)
	if startComp != 0 {
		return startComp < 0
	}
	return posCompare(aRange.End, bRange.End) < 0
}

func printDiagnostic(path string, d lsp.Diagnostic) {
	prefix := ""
	switch d.Severity {
	case lsp.Error:
		prefix = "error: "
	case lsp.Warning:
		prefix = "warning: "
	case lsp.Information:
		prefix = "information: "
	case lsp.Hint:
		prefix = "hint: "
	default:
		prefix = ""
	}

	fmt.Printf("%s:%d:%d %s%s\n", path, d.Range.Start.Line+1, d.Range.Start.Character+1, prefix, d.Message)
}

// Analyze returns whether there were no errors.
func (s *Server) Analyze(ctx context.Context, conn *jsonrpc2.Conn, req AnalyzeParams) (bool, error) {
	uris := req.URIs

	for i := range uris {
		uris[i] = uri.Canonicalize(uris[i])
	}

	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return false, err
	}

	cCtx := s.GetContext(conn)
	c := s.createCompiler(cCtx)

	analyzeResult, err := c.Analyze(ctx, uris...)
	if err != nil {
		return false, err
	}

	noError := true

	for _, diagnostic := range analyzeResult.DiagnosticsWithoutPosition {
		noError = false
		fmt.Println(diagnostic)
	}

	diagnosticURIs := []lsp.DocumentURI{}
	for uri, _ := range analyzeResult.Diagnostics {
		diagnosticURIs = append(diagnosticURIs, uri)
	}
	sort.Slice(diagnosticURIs, func(i int, j int) bool {
		return diagnosticURIs[i] < diagnosticURIs[j]
	})

	for _, u := range diagnosticURIs {
		diagnostics := analyzeResult.Diagnostics[u]
		sort.Slice(diagnostics, func(i int, j int) bool {
			return lspRangeLess(diagnostics[i].Range, diagnostics[j].Range)
		})
		for _, diagnostic := range diagnostics {
			printDiagnostic(uri.URIToPath(u), diagnostic)
			if diagnostic.Severity == lsp.Error {
				noError = false
			}
		}
	}

	return noError, nil
}

type ArchiveParams struct {
	URIs       []lsp.DocumentURI `json:"uris"`
	URI        lsp.DocumentURI   `json:"uri"`
	IncludeSDK *bool             `json:"includeSdk"`
}

func (s *Server) ToitArchive(ctx context.Context, conn *jsonrpc2.Conn, req ArchiveParams) ([]byte, error) {
	var buffer bytes.Buffer
	if err := s.ToitArchiveWriter(ctx, conn, req, &buffer); err != nil {
		return nil, err
	}

	return buffer.Bytes(), nil
}

func (s *Server) ToitArchiveWriter(ctx context.Context, conn *jsonrpc2.Conn, req ArchiveParams, writer io.Writer) error {
	uris := req.URIs
	if len(uris) == 0 {
		uris = append(uris, req.URI)
	}

	for i := range uris {
		uris[i] = uri.Canonicalize(uris[i])
	}

	includeSDK := true
	if req.IncludeSDK != nil {
		includeSDK = *req.IncludeSDK
	}

	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return err
	}

	cCtx := s.GetContext(conn)
	c := s.createCompiler(cCtx)
	if err := c.Parse(ctx, uris...); err != nil {
		return s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: c,
		})
	}

	paths := []string{}
	for _, u := range uris {
		path := uri.URIToPath(u)
		paths = append(paths, path)
	}

	// The archive works as a input to the compiler so all paths written into it need to be converted using `ToCompilerPath`
	jsonPaths, err := json.Marshal(path.ToCompilerPaths(paths...))
	if err != nil {
		return err
	}
	compilerInput := string(jsonPaths)

	if err := c.Archive(ctx, compiler.ArchiveOptions{
		Writer:                 writer,
		Info:                   "toit/archive",
		IncludeSDK:             includeSDK,
		OverwriteCompilerInput: &compilerInput,
	}); err != nil {
		return err
	}

	return nil
}

type SnapshotBundleParams struct {
	URI lsp.DocumentURI `json:"uri"`
}

type SnapshotBundleResult struct {
	SnapshotBundle []byte `json:"snapshot_bundle"`
}

func (s *Server) ToitSnapshotBundle(ctx context.Context, conn *jsonrpc2.Conn, req SnapshotBundleParams) (*SnapshotBundleResult, error) {
	uri := uri.Canonicalize(req.URI)
	if err := s.WaitUntilReady(ctx, conn); err != nil {
		return nil, err
	}

	cCtx := s.GetContext(conn)
	c := s.createCompiler(cCtx)
	b, err := c.SnapshotBundle(ctx, uri)
	if err != nil {
		return nil, s.handleCompilerError(ctx, handleCompilerErrorOptions{
			Conn:     conn,
			Error:    err,
			Compiler: c,
		})
	}

	return &SnapshotBundleResult{
		SnapshotBundle: b,
	}, nil
}
