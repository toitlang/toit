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
	"bufio"
	"fmt"
	"net"
	"sync"

	cpath "github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
	"go.uber.org/zap"
)

type FileSystem interface {
	Read(path string) (File, error)
	ListDirectory(path string) ([]string, error)
	PackageCachePaths() ([]string, error)
}

type File struct {
	Path        string
	Exists      bool
	IsRegular   bool
	IsDirectory bool
	Content     []byte
}

type FileServer struct {
	// l handles the fields listener and closeCh
	l sync.Mutex

	fileCache      *fileCache
	directoryCache *directoryCache
	logger         *zap.Logger
	sdkPath        string
	fs             FileSystem

	listener net.Listener
	closeCh  chan struct{}

	servedSdkPath           *string
	servedPackageCachePaths []string
}

func NewFileServer(fs FileSystem, logger *zap.Logger, SDKPath string) *FileServer {
	return &FileServer{
		fileCache:      newFileCache(fs),
		directoryCache: newDirectoryCache(fs),
		logger:         logger.Named("fileserver"),
		sdkPath:        SDKPath,
		fs:             fs,
	}
}

func (s *FileServer) ListenAndServe(address string) error {
	ocl, closeCh, err := s.setup(address)
	if err != nil {
		return err
	}

	defer s.clear()
	return s.serve(ocl, closeCh)
}

func (s *FileServer) setup(address string) (*onceCloseListener, chan struct{}, error) {
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

func (s *FileServer) clear() {
	s.l.Lock()
	defer s.l.Unlock()
	s.closeCh = nil
	s.listener = nil
}

func (s *FileServer) serve(l net.Listener, closeCh chan struct{}) error {
	defer close(closeCh)
	for {
		conn, err := l.Accept()
		if err != nil {
			return err
		}

		go s.handleConn(conn)
	}
}

func (s *FileServer) handleConn(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	w := bufio.NewWriter(conn)
	for scanner.Scan() {
		line := scanner.Text()
		switch line {
		case "SDK PATH":
			s.l.Lock()
			if s.servedSdkPath == nil {
				s.servedSdkPath = &s.sdkPath
			}
			s.l.Unlock()
			//s.logger.Info("SDK Path requested")
			w.WriteString(cpath.ToCompilerPath(s.sdkPath) + "\n")
		case "PACKAGE CACHE PATHS":
			s.l.Lock()
			if s.servedPackageCachePaths == nil {
				var err error
				if s.servedPackageCachePaths, err = s.fs.PackageCachePaths(); err != nil {
					s.logger.Error("failed to get package cache paths", zap.Error(err))
				}
			}
			s.l.Unlock()

			//s.logger.Info("PACKAGE CACHE PATHS requested")
			w.WriteString(fmt.Sprintf("%d\n", len(s.servedPackageCachePaths)))
			for _, path := range s.servedPackageCachePaths {
				w.WriteString(cpath.ToCompilerPath(path) + "\n")
			}
		case "LIST DIRECTORY":
			if !scanner.Scan() {
				break
			}
			path := cpath.FromCompilerPath(scanner.Text())
			//s.logger.Info("LIST DIRECTORY requested", zap.String("path", path))
			entries, err := s.directoryCache.Get(path)
			if err != nil {
				s.logger.Error("failed to directory entries", zap.Error(err))
				return
			}
			w.WriteString(fmt.Sprintf("%d\n", len(entries)))
			for _, e := range entries {
				w.WriteString(cpath.ToCompilerPath(e) + "\n")
			}
		case "INFO":
			if !scanner.Scan() {
				break
			}
			path := cpath.FromCompilerPath(scanner.Text())

			f, err := s.fileCache.Get(path)
			if err != nil {
				s.logger.Error("failed to get file", zap.Error(err))
				return
			}
			contentLength := -1
			if f.Exists {
				contentLength = len(f.Content)
			}
			//s.logger.Info(fmt.Sprintf("Fetching file: %s - exists: %t - regular: %t - size: %d", path, f.Exists, f.IsRegular, contentLength))
			w.WriteString(fmt.Sprintf("%t\n%t\n%t\n%d\n", f.Exists, f.IsRegular, f.IsDirectory, contentLength))
			w.Write(f.Content)
		default:
			s.logger.Error("unhandled line", zap.String("line", line))
			return
		}
		w.Flush()
	}
	if err := scanner.Err(); err != nil {
		s.logger.Error("read failed", zap.Error(err))
	}
	return
}

func (s *FileServer) Stop() error {
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

func (s *FileServer) StopWait() <-chan struct{} {
	s.l.Lock()
	closeCh := s.closeCh
	s.l.Unlock()
	return closeCh
}

func (s *FileServer) IsReady() bool {
	s.l.Lock()
	defer s.l.Unlock()
	return s.listener != nil
}

func (s *FileServer) Port() int {
	s.l.Lock()
	defer s.l.Unlock()
	return s.listener.Addr().(*net.TCPAddr).Port
}

func (s *FileServer) ServedPackageCachePaths() []string {
	s.l.Lock()
	defer s.l.Unlock()
	return s.servedPackageCachePaths
}

func (s *FileServer) ServedSdkPath() (string, bool) {
	s.l.Lock()
	defer s.l.Unlock()
	if s.servedSdkPath == nil {
		return "", false
	}
	return *s.servedSdkPath, true
}

func (s *FileServer) ServedFiles() map[string]File {
	return s.fileCache.Snapshot()
}

func (s *FileServer) ServedDirectories() map[string][]string {
	return s.directoryCache.Snapshot()
}

type directoryCache struct {
	l sync.Mutex

	directories map[string][]string
	fs          FileSystem
}

func newDirectoryCache(fs FileSystem) *directoryCache {
	return &directoryCache{
		directories: map[string][]string{},
		fs:          fs,
	}
}

func (d *directoryCache) Get(path string) ([]string, error) {
	d.l.Lock()
	p, ok := d.directories[path]
	d.l.Unlock()

	if !ok {
		var err error
		if p, err = d.fs.ListDirectory(path); err != nil {
			return nil, err
		}
		d.l.Lock()
		d.directories[path] = p
		d.l.Unlock()
	}

	return p, nil
}

func (d *directoryCache) Snapshot() map[string][]string {
	d.l.Lock()
	defer d.l.Unlock()
	res := map[string][]string{}
	for k, v := range d.directories {
		res[k] = v
	}
	return res
}

type fileCache struct {
	l sync.Mutex

	files map[string]File
	fs    FileSystem
}

func newFileCache(fs FileSystem) *fileCache {
	return &fileCache{
		files: map[string]File{},
		fs:    fs,
	}
}

func (f *fileCache) Get(path string) (File, error) {
	f.l.Lock()
	defer f.l.Unlock()

	file, ok := f.files[path]
	if ok {
		return file, nil
	}

	var err error
	if file, err = f.fs.Read(path); err != nil {
		return File{}, err
	}
	f.files[path] = file
	return file, nil
}

func (f *fileCache) Snapshot() map[string]File {
	f.l.Lock()
	defer f.l.Unlock()
	res := map[string]File{}
	for k, v := range f.files {
		res[k] = v
	}
	return res
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
