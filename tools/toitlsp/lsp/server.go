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
	"time"

	"github.com/sourcegraph/jsonrpc2"
	"github.com/toitware/toit.git/toitlsp/errors"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

const (
	CodeRequestCancelled = -32800
)

type Server struct {
	logger          *zap.Logger
	handlers        methodHandlers
	manager         *connManager
	cancelManager   *cancelManager
	settings        ServerSettings
	localFileSystem compiler.FileSystem
}

type ServerSettings struct {
	Verbose              bool
	DefaultToitcPath     string
	DefaultSDKPath       string
	Timeout              time.Duration
	ReturnCompilerErrors bool
}

type ServerOptions struct {
	Logger *zap.Logger

	Settings ServerSettings
}

type handleFunc func(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) (interface{}, error)

type methodHandlers map[string]handleFunc

func (h methodHandlers) Handle(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) (interface{}, error) {
	mh, ok := h[req.Method]
	if !ok {
		return nil, &jsonrpc2.Error{
			Code:    jsonrpc2.CodeMethodNotFound,
			Message: fmt.Sprintf("unsupported method: %s", req.Method),
		}
	}

	return mh(ctx, conn, req)
}

type handleMiddlewareFunc func(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request, next handleFunc) (interface{}, error)

type handleMiddlewares []handleMiddlewareFunc

func (h handleMiddlewares) Handle(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) (interface{}, error) {
	if len(h) == 0 {
		return nil, nil
	}

	return h[0](ctx, conn, req, h[1:].Handle)
}

func (h handleMiddlewares) WithHandler(handler handleFunc) handleFunc {
	return func(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) (interface{}, error) {
		if len(h) == 0 {
			return handler(ctx, conn, req)
		}

		return h[0](ctx, conn, req, h[1:].WithHandler(handler))
	}
}

func NewServer(options ServerOptions) (*Server, error) {
	s := &Server{
		logger:          options.Logger,
		handlers:        methodHandlers{},
		settings:        options.Settings,
		manager:         newConnManager(options.Settings, options.Logger),
		cancelManager:   newCancelManager(),
		localFileSystem: NewLocalFileSystem(),
	}

	if err := s.bind(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Server) bind() error {
	return errors.FirstError(
		s.addHandler("initialize", s.Initialize),
		s.addHandler("initialized", s.Initialized),
		s.addHandler("shutdown", s.Shutdown),
		s.addHandler("exit", s.Exit),
		s.addHandler("$/cancelRequest", s.Cancel),
		s.addHandler("textDocument/didOpen", s.TextDocumentDidOpen),
		s.addHandler("textDocument/didChange", s.TextDocumentDidChange),
		s.addHandler("textDocument/didSave", s.TextDocumentDidSave),
		s.addHandler("textDocument/didClose", s.TextDocumentDidClose),
		s.addHandler("textDocument/completion", s.textDocumentCompletion),
		s.addHandler("textDocument/definition", s.textDocumentDefinition),
		s.addHandler("textDocument/documentSymbol", s.textDocumentSymbol),
		s.addHandler("textDocument/semanticTokens/full", s.textDocumentSemanticTokensFull),
		s.addHandler("toit/report_idle", s.ToitReportIdle),
		s.addHandler("toit/archive", s.ToitArchive),
		s.addHandler("toit/didOpenMany", s.ToitDidOpenMany),
		s.addHandler("toit/snapshot_bundle", s.ToitSnapshotBundle),
		s.addHandler("toit/reset_crash_rate_limit", s.ToitResetCrashRateLimit),
	)
}

func (s *Server) addHandler(name string, fn interface{}) error {
	h, ok := fn.(handleFunc)
	if !ok {
		var err error
		if h, err = reflectHandler(fn); err != nil {
			return err
		}
	}
	s.handlers[name] = h
	return nil
}

type logWrapper struct {
	level  zapcore.Level
	logger *zap.Logger
}

func newLogWrapper(logger *zap.Logger, level zapcore.Level) *logWrapper {
	return &logWrapper{
		level:  level,
		logger: logger,
	}
}

func (l *logWrapper) Printf(msg string, args ...interface{}) {
	l.logger.Check(l.level, fmt.Sprintf(msg, args...)).Write()
}

func (s *Server) NewConn(ctx context.Context, stream jsonrpc2.ObjectStream, options ...jsonrpc2.ConnOpt) *jsonrpc2.Conn {
	options = append(options, jsonrpc2.LogMessages(newLogWrapper(s.logger, zapcore.DebugLevel)))
	waitChan := make(chan struct{})
	conn := jsonrpc2.NewConn(ctx, stream, s.createHandler(waitChan), options...)
	s.manager.NewConn(conn)
	close(waitChan)
	return conn
}

func (s *Server) createHandler(waitChan <-chan struct{}) jsonrpc2.Handler {
	middlewares := handleMiddlewares{
		waitOnMiddleware(waitChan), convertErrorMiddleware, s.processCountMiddleware,
	}
	var h jsonrpc2.Handler = jsonrpc2.HandlerWithError(middlewares.WithHandler(s.handlers.Handle))
	h = AsyncHandler(s, h)
	return h
}

func waitOnMiddleware(waitChan <-chan struct{}) handleMiddlewareFunc {
	return func(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request, next handleFunc) (interface{}, error) {
		<-waitChan
		return next(ctx, conn, req)
	}
}

func convertErrorMiddleware(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request, next handleFunc) (interface{}, error) {
	res, err := next(ctx, conn, req)
	if err == context.Canceled {
		return res, &jsonrpc2.Error{
			Code:    CodeRequestCancelled,
			Message: err.Error(),
		}
	}
	return res, err
}

func (s *Server) processCountMiddleware(ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request, next handleFunc) (interface{}, error) {
	s.manager.processCount(conn, 1)
	defer s.manager.processCount(conn, -1)
	return next(ctx, conn, req)
}

func (s *Server) Go(conn *jsonrpc2.Conn, fn func()) {
	ready := make(chan struct{})
	go func() {
		s.manager.processCount(conn, 1)
		defer s.manager.processCount(conn, -1)

		close(ready)
		fn()
	}()
	<-ready
}

func (s *Server) OnIdle(conn *jsonrpc2.Conn, cb callbackFunc) {
	s.manager.onIdle(conn, cb)
}

func (s *Server) GetContext(conn *jsonrpc2.Conn) ConnContext {
	return s.manager.GetContext(conn)
}

func (s *Server) SetContext(conn *jsonrpc2.Conn, ctx ConnContext) {
	s.manager.SetContext(conn, ctx)
}

func (s *Server) GetConn(conn *jsonrpc2.Conn) *connection {
	return s.manager.getConn(conn)
}

func (s *Server) WaitUntilReady(ctx context.Context, conn *jsonrpc2.Conn) error {
	cCtx := s.manager.GetContext(conn)
	select {
	case <-cCtx.ReadySignal:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
