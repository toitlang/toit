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
	"testing"

	"github.com/stretchr/testify/assert"
)

func Test_Path(t *testing.T) {
	tests := []string{
		"C:/foo/bar",
		"///iamvirtual",
		"/some/wierd/string",
		"\\some\\wierd\\string",
	}
	for _, test := range tests {
		t.Run(test, func(t *testing.T) {
			assert.Equal(t, test, fromCompilerPath(toCompilerPath(test, true), true))
		})
	}
}
