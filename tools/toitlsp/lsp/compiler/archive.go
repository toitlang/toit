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
	"archive/tar"
	"context"
	"encoding/json"
	"io"
	"path/filepath"
	"strings"

	"github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
)

const (
	ReproMetaFilePath          = "/<meta>"
	ReproSDKPathPath           = "/<sdk-path>"
	ReproPackageCachePathsPath = "/<package-cache-paths>"
	ReproCWDPathPath           = "/<cwd>"
	ReproCompilerFlagsPath     = "/<compiler-flags>"
	ReproCompilerInputPath     = "/<compiler-input>"
	ReproInfoPath              = "/<info>"
)

type ArchiveMeta struct {
	Files       map[string]ArchiveFile `json:"files"`
	Directories map[string][]string    `json:"directories"`
}

type ArchiveFile struct {
	Exists      bool `json:"exists"`
	IsRegular   bool `json:"is_regular"`
	IsDirectory bool `json:"is_directory"`
	HasContent  bool `json:"has_content"`
}

type WriteArchiveOptions struct {
	Writer             io.Writer
	CompilerFlags      []string
	CompilerInput      string
	Info               string
	CompilerFSProtocol *CompilerFSProtocol
	IncludeSDK         bool
	CWDPath            *string
}

// WriteArchive creates a tar file with all files that have been served.
func WriteArchive(ctx context.Context, options WriteArchiveOptions) error {
	meta := ArchiveMeta{
		Files:       map[string]ArchiveFile{},
		Directories: map[string][]string{},
	}

	sdkPath, hasSdkPath := options.CompilerFSProtocol.ServedSdkPath()
	if !strings.HasSuffix(sdkPath, string(filepath.Separator)) {
		sdkPath += string(filepath.Separator)
	}
	sdkPath = path.ToCompilerPath(sdkPath)

	packagePaths := options.CompilerFSProtocol.ServedPackageCachePaths()
	packagePaths = path.ToCompilerPaths(packagePaths...)

	w := tar.NewWriter(options.Writer)

	addFile := func(path string, content []byte) error {
		if err := w.WriteHeader(&tar.Header{
			Name:     path,
			Mode:     0664,
			Size:     int64(len(content)),
			Typeflag: tar.TypeReg,
			Format:   tar.FormatGNU,
		}); err != nil {
			return err
		}
		_, err := w.Write(content)
		return err
	}

	for p, file := range options.CompilerFSProtocol.ServedFiles() {
		path := path.ToCompilerPath(p)
		meta.Files[path] = ArchiveFile{
			Exists:      file.Exists,
			IsRegular:   file.IsRegular,
			IsDirectory: file.IsDirectory,
			HasContent:  file.Content != nil,
		}
		if file.Content != nil {
			if !options.IncludeSDK && hasSdkPath && filepath.HasPrefix(path, sdkPath) {
				continue
			}

			if err := addFile(path, file.Content); err != nil {
				return err
			}
		}
	}

	meta.Directories = options.CompilerFSProtocol.ServedDirectories()

	metaContent, err := json.Marshal(meta)
	if err != nil {
		return err
	}

	var cwdPath string
	if options.CWDPath != nil {
		cwdPath = path.ToCompilerPath(*options.CWDPath)
	}

	for _, err := range []error{
		addFile(ReproCompilerInputPath, []byte(options.CompilerInput)),
		addFile(ReproCompilerFlagsPath, []byte(strings.Join(options.CompilerFlags, "\n"))),
		addFile(ReproInfoPath, []byte(options.Info)),
		addFile(ReproMetaFilePath, metaContent),
		addFile(ReproSDKPathPath, []byte(sdkPath)),
		addFile(ReproPackageCachePathsPath, []byte(strings.Join(packagePaths, "\n"))),
		addFile(ReproCWDPathPath, []byte(cwdPath)),
	} {
		if err != nil {
			return err
		}
	}
	return w.Close()
}
