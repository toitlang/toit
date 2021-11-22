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
	"encoding/json"
	"fmt"
	"reflect"
	"sync"
	"time"

	"github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

var (
	semanticTokenTypes = []string{
		"namespace",
		"class",
		"interface",
		"parameter",
		"variable",
	}

	semanticTokenModifiers = []string{
		"definition",
		"readonly",
		"static",
		"abstract",
		"defaultLibrary",
	}
)

func (s *Server) Initialize(ctx context.Context, conn *jsonrpc2.Conn, req lsp.InitializeParams) (*lsp.InitializeResult, error) {
	cCtx := s.GetContext(conn)
	cCtx.SupportsConfiguration = req.Capabilities.Workspace.Configuration
	if req.RootURI != "" {
		cCtx.RootURI = uri.Canonicalize(req.RootURI)
	}
	s.SetContext(conn, cCtx)
	return &lsp.InitializeResult{
		Capabilities: lsp.ServerCapabilities{
			CompletionProvider: &lsp.CompletionOptions{
				ResolveProvider:   false,
				TriggerCharacters: []string{".", "-", "$"},
			},
			DefinitionProvider:     true,
			DocumentSymbolProvider: true,
			TextDocumentSync: &lsp.TextDocumentSyncOptionsOrKind{
				Options: &lsp.TextDocumentSyncOptions{
					OpenClose: true,
					Change:    lsp.TDSKFull,
					Save: &lsp.SaveOptions{
						IncludeText: false,
					},
				},
			},
			SemanticTokensProvider: &lsp.SemanticTokensOptions{
				Legend: lsp.SemanticTokensLegend{
					TokenTypes:     semanticTokenTypes,
					TokenModifiers: semanticTokenModifiers,
				},
				Range: false,
				Full:  lsp.STPFFull,
			},
		},
	}, nil
}

func (s *Server) Initialized(ctx context.Context, conn *jsonrpc2.Conn) error {
	cCtx := s.GetContext(conn)
	var settings WorkspaceSettings
	if cCtx.SupportsConfiguration {
		respSettings, err := fetchWorkspaceSettings(ctx, conn)
		if err != nil {
			s.logger.Error("failed to fetch workspace settings", zap.Error(err))
			return err
		}
		settings = *respSettings
	}

	cCtx = s.GetContext(conn)
	// Override with the server settings.
	if settings.ToitcPath == "" {
		settings.ToitcPath = s.settings.DefaultToitcPath
	}
	if settings.SDKPath == "" {
		settings.SDKPath = s.settings.DefaultSDKPath
	}
	if settings.Timeout == 0 {
		settings.Timeout = s.settings.Timeout
	}
	cCtx.Settings = &settings
	cCtx.Verbose = cCtx.Verbose || settings.Verbose || s.settings.Verbose
	s.SetContext(conn, cCtx)
	close(cCtx.ReadySignal)
	return nil
}

func (s *Server) Shutdown(ctx context.Context, conn *jsonrpc2.Conn) error {
	// noop for now.
	return nil
}

func (s *Server) Exit(ctx context.Context, conn *jsonrpc2.Conn) error {
	var once sync.Once
	s.OnIdle(conn, func(ctx context.Context, conn *jsonrpc2.Conn) {
		once.Do(func() {
			conn.Close()
		})
	})
	go func() {
		// Force an exit in case some request is not terminating.
		time.Sleep(time.Second)
		once.Do(func() {
			conn.Close()
		})
	}()
	return nil
}

func (s *Server) Cancel(ctx context.Context, conn *jsonrpc2.Conn, req lsp.CancelParams) error {
	s.cancelManager.Cancel(conn, jsonrpc2.ID(req.ID))
	return nil
}

// reflectHandler promotes a generic function into a handlerFunc.
// It assumes a function on the type:
//  func(ctx context.Context,conn *jsonrpc2.Conn, [param Any], [req *jsonrpc2.Request]) ([result Any],  errr error)
// if a specific type is used for param the req.Params will be json unmarshalled into the type of param.
func reflectHandler(fn interface{}) (handleFunc, error) {
	rv := reflect.ValueOf(fn)
	rt := rv.Type()
	if rt.NumIn() > 4 {
		return nil, fmt.Errorf("the handler cannot have more than 4 arguments")
	}

	if rt.NumOut() > 2 {
		return nil, fmt.Errorf("the handler must return at most two values")
	}

	return func(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) (interface{}, error) {
		args := []reflect.Value{reflect.ValueOf(ctx), reflect.ValueOf(conn), reflect.ValueOf(nil), reflect.ValueOf(req)}
		if rt.NumIn() >= 3 {
			rat := rt.In(2)
			a := reflect.New(rat).Interface()
			if req.Params != nil {
				if err := json.Unmarshal(*req.Params, a); err != nil {
					return nil, err
				}
			}
			args[2] = reflect.ValueOf(a).Elem()
		}

		out := rv.Call(args[:rt.NumIn()])
		var result interface{}
		rErr := out[0]
		if len(out) == 2 {
			result = out[0].Interface()
			rErr = out[1]
		}

		if rErr.IsNil() {
			return result, nil
		}
		return result, rErr.Interface().(error)
	}, nil
}

// AsyncHandler wraps a Handler such that each request is handled in its own
// goroutine. It is a convenience wrapper.
func AsyncHandler(server *Server, h jsonrpc2.Handler) jsonrpc2.Handler {
	return asyncHandler{Handler: h, server: server}
}

type asyncHandler struct {
	jsonrpc2.Handler
	server *Server
}

func (h asyncHandler) Handle(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) {
	var cancel context.CancelFunc = func() {}
	if !req.Notif {
		ctx, cancel = h.server.cancelManager.WithCancel(ctx, conn, req.ID)
	}
	h.server.Go(conn, func() {
		defer cancel()
		h.Handler.Handle(ctx, conn, req)
	})
}
