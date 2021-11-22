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
	"io/ioutil"
	"os"
	"path/filepath"

	"github.com/toitware/toit.git/toitlsp/lsp/compiler"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
)

const (
	EnvPackageCachePaths = "TOIT_PACKAGE_CACHE_PATHS"
)

type LocalFileSystem struct {
	packageCachePaths []string
}

func NewLocalFileSystem() *LocalFileSystem {
	return &LocalFileSystem{}
}

var _ compiler.FileSystem = (*LocalFileSystem)(nil)

func (fs *LocalFileSystem) Read(path string) (compiler.File, error) {
	stat, err := os.Stat(path)
	if os.IsNotExist(err) {
		return compiler.File{Path: path, Exists: false}, nil
	}
	if err != nil {
		return compiler.File{}, err
	}

	res := compiler.File{
		Path:        path,
		Exists:      true,
		IsDirectory: stat.Mode().IsDir(),
		IsRegular:   stat.Mode().IsRegular(),
	}
	if res.IsRegular {
		if res.Content, err = ioutil.ReadFile(path); err != nil {
			return compiler.File{}, err
		}
	}
	return res, nil
}

func (fs *LocalFileSystem) ListDirectory(path string) ([]string, error) {
	files, err := ioutil.ReadDir(path)
	if err != nil {
		return nil, err
	}

	var res []string
	for _, f := range files {
		res = append(res, filepath.Base(f.Name()))
	}
	return res, nil
}

func (fs *LocalFileSystem) PackageCachePaths() ([]string, error) {
	if fs.packageCachePaths == nil {
		var err error
		if fs.packageCachePaths, err = getPackageCachePaths(); err != nil {
			return nil, err
		}
	}
	return fs.packageCachePaths, nil
}

func getPackageCachePaths() ([]string, error) {
	if env, ok := os.LookupEnv("TOIT_PACKAGE_CACHE_PATHS"); ok {
		paths := filepath.SplitList(env)
		for i, p := range paths {
			if !filepath.IsAbs(p) {
				var err error
				p, err = filepath.Abs(p)
				if err != nil {
					return nil, err
				}
			}
			paths[i] = path.ToCompilerPath(p)
		}
		return paths, nil
	}

	homedir, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return []string{path.ToCompilerPath(filepath.Join(homedir, ".cache", "toit", "tpkg"))}, nil
}

type DocsCacheFileSystem struct {
	docs *Documents
}

func NewDocsCacheFileSystem(docs *Documents) *DocsCacheFileSystem {
	return &DocsCacheFileSystem{
		docs: docs,
	}
}

func (fs *DocsCacheFileSystem) ListDirectory(path string) ([]string, error) {
	return nil, os.ErrNotExist
}

func (fs *DocsCacheFileSystem) PackageCachePaths() ([]string, error) {
	return nil, os.ErrNotExist
}

func (fs *DocsCacheFileSystem) Read(path string) (compiler.File, error) {
	uri := uri.PathToURI(path)
	doc, ok := fs.docs.Get(uri)
	if ok && doc.Content != nil {
		return compiler.File{
			Path:        path,
			Exists:      true,
			IsRegular:   true,
			IsDirectory: false,
			Content:     []byte(*doc.Content),
		}, nil
	}
	return compiler.File{}, os.ErrNotExist
}

type MultiFileSystem []compiler.FileSystem

func (ms MultiFileSystem) ListDirectory(path string) ([]string, error) {
	for _, m := range ms {
		res, err := m.ListDirectory(path)
		if !os.IsNotExist(err) {
			return res, nil
		}
	}
	return nil, os.ErrNotExist
}

func (ms MultiFileSystem) PackageCachePaths() ([]string, error) {
	for _, m := range ms {
		res, err := m.PackageCachePaths()
		if !os.IsNotExist(err) {
			return res, nil
		}
	}
	return nil, os.ErrNotExist
}

func (ms MultiFileSystem) Read(path string) (compiler.File, error) {
	for _, m := range ms {
		res, err := m.Read(path)
		if !os.IsNotExist(err) {
			return res, nil
		}
	}
	return compiler.File{}, os.ErrNotExist
}
