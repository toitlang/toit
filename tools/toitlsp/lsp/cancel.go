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

	"github.com/sourcegraph/jsonrpc2"
)

type cancelManager struct {
	l     sync.Mutex
	conns map[*jsonrpc2.Conn]map[jsonrpc2.ID]context.CancelFunc
}

func newCancelManager() *cancelManager {
	return &cancelManager{
		conns: map[*jsonrpc2.Conn]map[jsonrpc2.ID]context.CancelFunc{},
	}
}

func (c *cancelManager) WithCancel(ctx context.Context, conn *jsonrpc2.Conn, id jsonrpc2.ID) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(ctx)
	c.l.Lock()
	reqs, ok := c.conns[conn]
	if !ok {
		reqs = map[jsonrpc2.ID]context.CancelFunc{}
		c.conns[conn] = reqs
	}
	reqs[id] = cancel
	c.l.Unlock()

	return ctx, func() {
		c.Cancel(conn, id)
	}
}

func (c *cancelManager) Cancel(conn *jsonrpc2.Conn, id jsonrpc2.ID) {
	c.l.Lock()
	reqs, ok := c.conns[conn]
	if !ok {
		c.l.Unlock()
		return
	}
	cancel, ok := reqs[id]
	delete(reqs, id)
	if len(reqs) == 0 {
		delete(c.conns, conn)
	}
	c.l.Unlock()

	if ok {
		cancel()
	}
}
