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
	"io"
	"sync"

	"go.uber.org/zap"
)

type PipeFileServer struct {
	l           sync.Mutex // Covers r and w.
	r           io.ReadCloser
	w           io.WriteCloser
	close_error error

	cp *CompilerFSProtocol
}

func NewPipeFileServer(fs FileSystem, logger *zap.Logger, SDKPath string) *PipeFileServer {
	return &PipeFileServer{
		cp: NewCompilerFSProtocol(fs, logger, SDKPath),
	}
}

func (s *PipeFileServer) Run(reader io.ReadCloser, writer io.WriteCloser) error {
	s.l.Lock()
	s.r = reader
	s.w = writer
	s.l.Unlock()

	go s.handleConn(reader, writer)
	return nil
}

func (s *PipeFileServer) handleConn(reader io.ReadCloser, writer io.WriteCloser) {
	defer s.Stop()
	s.cp.HandleConn(reader, writer)
}

func (s *PipeFileServer) ConfigLine() string {
	return "-2"
}

func (s *PipeFileServer) Protocol() *CompilerFSProtocol {
	return s.cp
}

func (s *PipeFileServer) Stop() error {
	s.l.Lock()
	defer s.l.Unlock()

	if s.r != nil {
		s.close_error = s.r.Close()
	}
	if s.w != nil {
		w_error := s.w.Close()
		if s.close_error == nil {
			s.close_error = w_error
		}
	}

	return s.close_error
}

func (s *PipeFileServer) IsReady() bool {
	s.l.Lock()
	defer s.l.Unlock()
	return s.r != nil
}
