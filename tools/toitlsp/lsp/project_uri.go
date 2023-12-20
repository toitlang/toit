// Copyright (C) 2023 Toitware ApS.
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
	"os"
	"path/filepath"
	"strings"

	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
)

func computeProjectURI(documentUri lsp.DocumentURI) (lsp.DocumentURI, error) {
	path := uri.URIToPath(documentUri)
	segments := strings.Split(filepath.ToSlash(path), "/")
	// Find the last '.packages' segment. We assume that the project root is
	// the parent of this segment.
	for i := len(segments) - 1; i >= 0; i-- {
		if segments[i] == ".packages" {
			// We don't even check whether there is a package.yaml|lock file.
			// We just assume that this is the project uri.
			segments = segments[:i]
			resultSlashPath := strings.Join(segments, "/")
			resultPath := filepath.FromSlash(resultSlashPath)
			return uri.PathToURI(resultPath), nil
		}
	}

	// Walk up the path until we find a package.yaml|lock file.
	for {
		if hasPackageFile(path) {
			return uri.PathToURI(path), nil
		}
		parent := filepath.Dir(path)
		if parent == path {
			return uri.PathToURI(path), nil
		}
		path = parent
	}
}

func hasPackageFile(path string) bool {
	_, err := os.Stat(filepath.Join(path, "package.yaml"))
	if err == nil {
		return true
	}
	_, err = os.Stat(filepath.Join(path, "package.lock"))
	return err == nil
}
