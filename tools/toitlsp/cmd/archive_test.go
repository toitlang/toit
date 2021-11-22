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
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/jstroem/tedi"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func testArchive(t *tedi.T, toitlsp toitlspPath, toitc toitcPath, cwd cwdPath) {
	helloFile := filepath.Join(string(cwd), "assets", "hello.toit")
	archiveFile := "archive.tar"
	snapshotFile := "hello.snap"
	cmd := exec.Command(string(toitlsp), "archive", "--out", archiveFile, "--toitc", string(toitc), helloFile)
	cmd.Stderr = os.Stderr
	cmd.Stdout = os.Stdout
	defer os.Remove(archiveFile)
	require.NoError(t, cmd.Run())

	stat, err := os.Stat(archiveFile)
	require.NoError(t, err)
	assert.True(t, stat.Size() > 100)

	// TODO(jesper): building snapshot on windows throws unimplemented (#4069)
	if runtime.GOOS != "windows" {
		// Try and write a snapshot using the archive to see if it works
		cmd = exec.Command(string(toitc), "-Xno_fork", "-w", snapshotFile, archiveFile)
		cmd.Stderr = os.Stderr
		cmd.Stdout = os.Stdout
		defer os.Remove(snapshotFile)
		require.NoError(t, cmd.Run())
	}
}
