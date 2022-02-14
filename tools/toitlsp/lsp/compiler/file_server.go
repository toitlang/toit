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

package compiler

import (
	"fmt"
	"net"
	"strconv"
	"sync"

	"go.uber.org/zap"
)

type FileServer interface {
	IsReady() bool
	/// ConfigLine is the line that is sent to the compiler to be able to
	/// communicate with the file server.
	ConfigLine() string
	Stop() error
	Protocol() *CompilerFSProtocol
}

type PortFileServer struct {
	address  string
	l        sync.Mutex
	listener net.Listener
	closeCh  chan struct{}

	cp *CompilerFSProtocol
}

func NewPortFileServer(fs FileSystem, logger *zap.Logger, SDKPath string, address string) *PortFileServer {
	return &PortFileServer{
		address: address,
		cp:      NewCompilerFSProtocol(fs, logger, SDKPath),
	}
}

func (s *PortFileServer) Run() error {
	ocl, closeCh, err := s.setup(s.address)
	if err != nil {
		return err
	}

	defer s.clear()
	return s.serve(ocl, closeCh)
}

func (s *PortFileServer) ConfigLine() string {
	return strconv.Itoa(s.Port())
}

func (s *PortFileServer) Protocol() *CompilerFSProtocol {
	return s.cp
}

func (s *PortFileServer) setup(address string) (*onceCloseListener, chan struct{}, error) {
	s.l.Lock()
	defer s.l.Unlock()
	if s.listener != nil {
		return nil, nil, fmt.Errorf("server already running")
	}

	l, err := net.Listen("tcp", address)
	if err != nil {
		return nil, nil, err
	}

	ocl := &onceCloseListener{Listener: l}
	closeCh := make(chan struct{})

	s.listener = ocl
	s.closeCh = closeCh
	return ocl, closeCh, nil
}

func (s *PortFileServer) clear() {
	s.l.Lock()
	defer s.l.Unlock()
	s.closeCh = nil
	s.listener = nil
}

func (s *PortFileServer) serve(l net.Listener, closeCh chan struct{}) error {
	defer close(closeCh)
	for {
		conn, err := l.Accept()
		if err != nil {
			return err
		}

		go s.handleConn(conn)
	}
}

func (s *PortFileServer) handleConn(conn net.Conn) {
	defer conn.Close()
	s.cp.HandleConn(conn, conn)
}

func (s *PortFileServer) Stop() error {
	s.l.Lock()
	listener := s.listener
	closeCh := s.closeCh
	s.l.Unlock()

	if listener == nil || closeCh == nil {
		return fmt.Errorf("server already closed")
	}

	err := listener.Close()
	select {
	case <-closeCh:
	}
	return err
}

func (s *PortFileServer) StopWait() <-chan struct{} {
	s.l.Lock()
	closeCh := s.closeCh
	s.l.Unlock()
	return closeCh
}

func (s *PortFileServer) IsReady() bool {
	s.l.Lock()
	defer s.l.Unlock()
	return s.listener != nil
}

func (s *PortFileServer) Port() int {
	s.l.Lock()
	defer s.l.Unlock()
	return s.listener.Addr().(*net.TCPAddr).Port
}

type onceCloseListener struct {
	net.Listener
	once     sync.Once
	closeErr error
}

func (oc *onceCloseListener) Close() error {
	oc.once.Do(oc.close)
	return oc.closeErr
}

func (oc *onceCloseListener) close() { oc.closeErr = oc.Listener.Close() }
