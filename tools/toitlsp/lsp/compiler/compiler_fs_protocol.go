// Copyright (C) 2022 Toitware ApS.
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
	"io"
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

type CompilerFSProtocol struct {
	// l handles the fields listener and closeCh
	l sync.Mutex

	fileCache      *fileCache
	directoryCache *directoryCache
	logger         *zap.Logger
	sdkPath        string
	fs             FileSystem

	servedSdkPath           *string
	servedPackageCachePaths []string
}

func NewCompilerFSProtocol(fs FileSystem, logger *zap.Logger, SDKPath string) *CompilerFSProtocol {
	return &CompilerFSProtocol{
		fileCache:      newFileCache(fs),
		directoryCache: newDirectoryCache(fs),
		logger:         logger.Named("compiler_protocol"),
		sdkPath:        SDKPath,
		fs:             fs,
	}
}

func (cp *CompilerFSProtocol) HandleConn(conn io.ReadWriter) {
	scanner := bufio.NewScanner(conn)
	w := bufio.NewWriter(conn)
	for scanner.Scan() {
		line := scanner.Text()
		switch line {
		case "SDK PATH":
			cp.l.Lock()
			if cp.servedSdkPath == nil {
				cp.servedSdkPath = &cp.sdkPath
			}
			cp.l.Unlock()
			//s.logger.Info("SDK Path requested")
			w.WriteString(cpath.ToCompilerPath(cp.sdkPath) + "\n")
		case "PACKAGE CACHE PATHS":
			cp.l.Lock()
			if cp.servedPackageCachePaths == nil {
				var err error
				if cp.servedPackageCachePaths, err = cp.fs.PackageCachePaths(); err != nil {
					cp.logger.Error("failed to get package cache paths", zap.Error(err))
				}
			}
			cp.l.Unlock()

			//s.logger.Info("PACKAGE CACHE PATHS requested")
			w.WriteString(fmt.Sprintf("%d\n", len(cp.servedPackageCachePaths)))
			for _, path := range cp.servedPackageCachePaths {
				w.WriteString(cpath.ToCompilerPath(path) + "\n")
			}
		case "LIST DIRECTORY":
			if !scanner.Scan() {
				break
			}
			path := cpath.FromCompilerPath(scanner.Text())
			//s.logger.Info("LIST DIRECTORY requested", zap.String("path", path))
			entries, err := cp.directoryCache.Get(path)
			if err != nil {
				cp.logger.Error("failed to directory entries", zap.Error(err))
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

			f, err := cp.fileCache.Get(path)
			if err != nil {
				cp.logger.Error("failed to get file", zap.Error(err))
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
			cp.logger.Error("unhandled line", zap.String("line", line))
			return
		}
		w.Flush()
	}
	if err := scanner.Err(); err != nil {
		cp.logger.Error("read failed", zap.Error(err))
	}
	return
}

func (cp *CompilerFSProtocol) ServedPackageCachePaths() []string {
	cp.l.Lock()
	defer cp.l.Unlock()
	return cp.servedPackageCachePaths
}

func (cp *CompilerFSProtocol) ServedSdkPath() (string, bool) {
	cp.l.Lock()
	defer cp.l.Unlock()
	if cp.servedSdkPath == nil {
		return "", false
	}
	return *cp.servedSdkPath, true
}

func (cp *CompilerFSProtocol) ServedFiles() map[string]File {
	return cp.fileCache.Snapshot()
}

func (cp *CompilerFSProtocol) ServedDirectories() map[string][]string {
	return cp.directoryCache.Snapshot()
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
