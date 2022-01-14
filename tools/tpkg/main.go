// Copyright (C) 2022 Toitware ApS.
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

package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/toitlang/tpkg/commands"
	"github.com/toitlang/tpkg/config"
	"github.com/toitlang/tpkg/config/store"
	"github.com/toitlang/tpkg/pkg/tracking"
)

func getTrimmedEnv(key string) string {
	return strings.TrimSpace(os.Getenv(key))
}

// Should be set with '-X' flag when linking.
var sdkVersion = ""

func copyAsDeprecated(cmd *cobra.Command) *cobra.Command {
	result := &cobra.Command{
		Deprecated: "Use without the 'pkg' prefix",
		Use:        cmd.Use,
		Short:      cmd.Short,
		Long:       cmd.Long,
		Run:        cmd.Run,
		RunE:       cmd.RunE,
		Args:       cmd.Args,
		Aliases:    cmd.Aliases,
		Hidden:     cmd.Hidden,
		Example:    cmd.Example,
	}
	if cmd.HasLocalFlags() {
		cmd.Flags().VisitAll(func(flag *pflag.Flag) {
			result.Flags().AddFlag(flag)
		})
	}
	for _, c := range cmd.Commands() {
		result.AddCommand(copyAsDeprecated(c))
	}
	return result
}

func main() {
	cfgFile := getTrimmedEnv("TOIT_CONFIG_FILE")

	track := func(ctx context.Context, te *tracking.Event) error {
		// TODO(florian): implement tracking.
		return nil
	}

	configStore := store.NewViper("", sdkVersion, false, false)
	cobra.OnInitialize(func() {
		if cfgFile == "" {
			cfgFile, _ = config.UserConfigFile()
		}
		configStore.Init(cfgFile)
	})

	pkgCmd, err := commands.Pkg(commands.DefaultRunWrapper, track, configStore, nil)
	if err != nil {
		e, ok := err.(commands.WithSilent)
		if !ok {
			fmt.Fprintln(os.Stderr, e)
		}
	}
	deprecatedPkg := copyAsDeprecated(pkgCmd)

	pkgCmd.Use = "toit.pkg"
	pkgCmd.Short = "The Toit package manager"
	pkgCmd.AddCommand(deprecatedPkg)
	pkgCmd.AddCommand(&cobra.Command{
		Use:   "version",
		Short: "Prints the version of the package manager",
		Args:  cobra.NoArgs,
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Println(sdkVersion)
		},
	})
	pkgCmd.Execute()
}
