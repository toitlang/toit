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

package cmd

import (
	"os/exec"
	"path/filepath"

	"github.com/jstroem/tedi"
	"github.com/stretchr/testify/require"
)

func testAnalyze(t *tedi.T, toitlsp toitlspPath, toitc toitcPath, cwd cwdPath) {
	helloFile := filepath.Join(string(cwd), "assets", "hello.toit")
	cmd := exec.Command(string(toitlsp), "analyze", "--toitc", string(toitc), helloFile)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err)
	require.Empty(t, out)

	bugFile := filepath.Join(string(cwd), "assets", "bug.toit")
	cmd = exec.Command(string(toitlsp), "analyze", "--toitc", string(toitc), bugFile)
	out, err = cmd.CombinedOutput()
	require.Error(t, err)
	require.NotEmpty(t, out)
}
