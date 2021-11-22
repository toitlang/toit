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

	"github.com/spf13/cobra"
)

type versionCmd struct {
	date    string
	version string
}

func Version(version, date string) *cobra.Command {
	v := versionCmd{
		date:    date,
		version: version,
	}
	return &cobra.Command{
		Use:  "version",
		RunE: v.run,
	}
}

func (v *versionCmd) run(cmd *cobra.Command, args []string) (err error) {
	fmt.Println(string(v.version))
	return nil
}
