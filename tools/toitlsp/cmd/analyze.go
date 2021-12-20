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
	"context"
	"fmt"
	"io"
	"io/ioutil"
	"os"

	doclsp "github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
	"github.com/spf13/cobra"
	"github.com/toitware/toit.git/toitlsp/lsp"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// The command exits with exit-code 1, if the analysis fails.
func Analyze() *cobra.Command {
	analyzeCmd := &cobra.Command{
		Use:   "analyze <toit-file(s)>",
		Short: "Analyze toit files",
		RunE:  analyze,
		Args:  cobra.MinimumNArgs(1),
	}
	analyzeCmd.Flags().BoolP("verbose", "v", false, "")
	analyzeCmd.Flags().String("toitc", "", "the default toitc to use")
	analyzeCmd.Flags().String("sdk", "", "the default SDK path to use")

	return analyzeCmd
}

func analyze(cmd *cobra.Command, args []string) error {
	toitc, err := cmd.Flags().GetString("toitc")
	if err != nil {
		return err
	}
	sdk, err := computeSDKPath(cmd.Flags(), toitc)
	if err != nil {
		return err
	}

	verbose, err := cmd.Flags().GetBool("verbose")
	if err != nil {
		return err
	}

	var uris []doclsp.DocumentURI
	for _, arg := range args {
		if stat, err := os.Stat(arg); err == nil {
			if stat.IsDir() {
				return fmt.Errorf("the file: '%s' was a directory", arg)
			}
			uris = append(uris, pathToURI(arg))
		} else if os.IsNotExist(err) {
			return fmt.Errorf("the file: '%s' does not exist", arg)
		} else {
			return err
		}
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}

	logCfg := zap.NewDevelopmentConfig()
	logCfg.Level = zap.NewAtomicLevelAt(zapcore.InfoLevel)
	if verbose {
		logCfg.Level = zap.NewAtomicLevelAt(zapcore.DebugLevel)
	}

	logger, err := logCfg.Build()
	if err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server, err := lsp.NewServer(lsp.ServerOptions{
		Logger: logger,
		Settings: lsp.ServerSettings{
			Verbose:          verbose,
			DefaultToitcPath: toitc,
			DefaultSDKPath:   sdk,
		},
	})
	if err != nil {
		return err
	}

	ir, iw := io.Pipe()
	stream := jsonrpc2.NewBufferedStream(newStream(ir, ioutil.Discard), jsonrpc2.VSCodeObjectCodec{})
	conn := server.NewConn(ctx, stream)
	defer conn.Close()
	defer iw.Close()

	if _, err := server.Initialize(ctx, conn, doclsp.InitializeParams{
		RootURI: pathToURI(cwd),
	}); err != nil {
		return err
	}

	if err := server.Initialized(ctx, conn); err != nil {
		return err
	}

	noError, err := server.Analyze(ctx, conn, lsp.AnalyzeParams{
		URIs: uris,
	})
	if err != nil {
		return err
	}
	if !noError {
		os.Exit(1)
	}
	return nil
}
