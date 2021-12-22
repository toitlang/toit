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

package path

import (
	"path/filepath"
	"runtime"
	"strings"
)

const (
	virtualFileMarker = "///"
)

func isVirtualPath(path string) bool {
	return strings.HasPrefix(path, virtualFileMarker)
}

func ToCompilerPath(path string) string {
	return toCompilerPath(path, runtime.GOOS == "windows")
}

func ToCompilerPaths(paths ...string) []string {
	for i, path := range paths {
		paths[i] = ToCompilerPath(path)
	}
	return paths
}

func toCompilerPath(path string, windows bool) string {
	if !windows || isVirtualPath(path) {
		return path
	}
	if filepath.IsAbs(path) {
		path = "/" + path
	}
	return filepath.ToSlash(path)
}

func FromCompilerPath(path string) string {
	return fromCompilerPath(path, runtime.GOOS == "windows")
}

func fromCompilerPath(path string, onWindows bool) string {
	if !onWindows || isVirtualPath(path) {
		return path
	}

	if strings.HasPrefix(path, "/") {
		path = strings.TrimPrefix(path, "/")
	}
	return filepath.FromSlash(path)
}
