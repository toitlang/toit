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
	"sync"
	"sync/atomic"
	"time"

	"github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
	"go.uber.org/zap"
)

const (
	callbackTimeout = 10 * time.Second
)

type connManager struct {
	l        sync.Mutex
	settings ServerSettings
	logger   *zap.Logger
	conns    map[*jsonrpc2.Conn]*connection
}

func newConnManager(settings ServerSettings, logger *zap.Logger) *connManager {
	return &connManager{
		settings: settings,
		logger:   logger,
		conns:    map[*jsonrpc2.Conn]*connection{},
	}
}

type connection struct {
	// Put 'processCount' first to ensure that it's 64-bit aligned.
	processCount int64
	l            sync.Mutex

	*jsonrpc2.Conn
	context ConnContext
	logger  *zap.Logger

	onIdleCallbacks []callbackFunc
}

type callbackFunc func(ctx context.Context, conn *jsonrpc2.Conn)

type ConnContext struct {
	SupportsConfiguration bool
	LastCrashReport       time.Time
	RootURI               lsp.DocumentURI
	Verbose               bool
	Settings              *WorkspaceSettings
	Documents             *Documents
	ReadySignal           chan struct{}

	NextAnalysisRevision int
}

func (m *connManager) NewConn(conn *jsonrpc2.Conn) {
	m.l.Lock()
	defer m.l.Unlock()

	m.conns[conn] = &connection{
		Conn: conn,
		context: ConnContext{
			Verbose:              m.settings.Verbose,
			Documents:            NewDocuments(m.logger),
			ReadySignal:          make(chan struct{}),
			NextAnalysisRevision: 1,
		},
		logger: m.logger,
	}
	go func() {
		<-conn.DisconnectNotify()
		m.onIdle(conn, func(ctx context.Context, conn *jsonrpc2.Conn) {
			m.onDisconnect(conn)
		})
	}()
}

func (m *connManager) onDisconnect(conn *jsonrpc2.Conn) {
	m.l.Lock()
	defer m.l.Unlock()
	delete(m.conns, conn)
}

func (m *connManager) getConn(c *jsonrpc2.Conn) *connection {
	m.l.Lock()
	defer m.l.Unlock()
	return m.conns[c]
}

func (m *connManager) processCount(c *jsonrpc2.Conn, delta int64) {
	conn := m.getConn(c)
	if conn == nil {
		return
	}

	new := atomic.AddInt64(&conn.processCount, delta)
	if new > 0 {
		return
	}
	m.evaluateCallbacks(c)
}

func (m *connManager) evaluateCallbacks(c *jsonrpc2.Conn) {
	conn := m.conns[c]

	callbacks := conn.onIdleCallbacks
	conn.onIdleCallbacks = nil
	ctx, cancel := context.WithTimeout(context.Background(), callbackTimeout)
	wg := sync.WaitGroup{}
	for _, cb := range callbacks {
		wg.Add(1)
		go func(cb callbackFunc) {
			defer wg.Done()
			cb(ctx, c)
		}(cb)
	}

	go func() {
		wg.Wait()
		cancel()
	}()
}

func (m *connManager) onIdle(c *jsonrpc2.Conn, cb callbackFunc) {
	conn := m.getConn(c)
	conn.l.Lock()
	defer conn.l.Unlock()
	conn.onIdleCallbacks = append(conn.onIdleCallbacks, cb)
	if atomic.LoadInt64(&conn.processCount) == 0 {
		m.evaluateCallbacks(c)
	}
}

func (m *connManager) GetContext(c *jsonrpc2.Conn) ConnContext {
	conn := m.getConn(c)
	return conn.context
}

func (m *connManager) SetContext(c *jsonrpc2.Conn, ctx ConnContext) {
	conn := m.getConn(c)
	conn.context = ctx
}
