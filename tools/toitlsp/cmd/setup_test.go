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

	"github.com/jstroem/tedi"
)

type toitcPath string

func fixToitcPath(t *tedi.T) (toitcPath, error) {
	path, ok := os.LookupEnv("TOITC_PATH")
	if ok {
		return toitcPath(path), nil
	}

	path, err := exec.LookPath("toit.compile")
	if err != nil {
		return "", err
	}

	return toitcPath(path), nil
}

type toitlspPath string

func fixToitlspPath(t *tedi.T) (toitlspPath, error) {
	path, ok := os.LookupEnv("TOITLSP_PATH")
	if ok {
		return toitlspPath(path), nil
	}

	path, err := exec.LookPath("toitlsp")
	if err != nil {
		return "", err
	}

	return toitlspPath(path), nil
}

type cwdPath string

func fixCWDPath(t *tedi.T) (cwdPath, error) {
	dir, err := os.Getwd()
	return cwdPath(dir), err
}
