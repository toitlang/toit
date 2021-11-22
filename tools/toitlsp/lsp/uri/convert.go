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

package uri

import (
	"encoding/hex"
	"strings"

	"github.com/sourcegraph/go-langserver/langserver/util"
	golsp "github.com/sourcegraph/go-langserver/pkg/lsp"
	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
)

const (
	virtualFileMarker = "///"
)

func PathToURI(path string) lsp.DocumentURI {
	if strings.HasPrefix(path, virtualFileMarker) {
		return lsp.DocumentURI(strings.TrimPrefix(path, virtualFileMarker))
	}
	path = Encode(path)
	return lsp.DocumentURI(util.PathToURI(path))
}

func Encode(path string) string {
	var res []byte
	var hexBytes [3]byte
	var tmp [1]byte
	hexBytes[0] = '%'

	for _, b := range []byte(path) {
		if b == '/' || b == '.' ||
			('a' <= b && b <= 'z') ||
			('A' <= b && b <= 'Z') ||
			('0' <= b && b <= '9') {
			res = append(res, b)
			continue
		}
		tmp[0] = b
		hex.Encode(hexBytes[1:], tmp[:])
		res = append(res, hexBytes[:]...)
	}
	return string(res)
}

func URIToPath(uri lsp.DocumentURI) string {
	if strings.HasPrefix(string(uri), "file://") {
		return util.UriToRealPath(golsp.DocumentURI(uri))
	}
	return virtualFileMarker + string(uri)
}

func URIToCompilerPath(uri lsp.DocumentURI) string {
	if strings.HasPrefix(string(uri), "file://") {
		return path.ToCompilerPath(util.UriToRealPath(golsp.DocumentURI(uri)))
	}
	return path.ToCompilerPath(virtualFileMarker + string(uri))
}

func Canonicalize(uri lsp.DocumentURI) lsp.DocumentURI {
	return PathToURI(URIToPath(uri))
}
