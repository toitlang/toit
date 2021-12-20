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
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/pflag"
)

func computeSDKPath(flags *pflag.FlagSet, toitc string) (string, error) {
	sdk := ""
	var err error
	if flags != nil {
		sdk, err = flags.GetString("sdk")

		if err != nil {
			return "", err
		}
	}
	if sdk == "" {
		toitc, err = filepath.EvalSymlinks(toitc)
		if err != nil {
			return "", err
		}
		sdk = filepath.Dir(toitc)
		libDir := filepath.Join(sdk, "lib")
		if _, err := os.Stat(libDir); err != nil {
			// Try ../lib.
			sdk = filepath.Join(sdk, "..")
			libDir = filepath.Join(sdk, "lib")
			if _, err := os.Stat(libDir); err != nil {
				return "", fmt.Errorf("SDK's 'lib' directory not found")
			}
		}
	}
	if sdk, err = filepath.Abs(sdk); err != nil {
		return "", err
	}
	if sdk, err = filepath.EvalSymlinks(sdk); err != nil {
		return "", err
	}
	return sdk, nil
}
