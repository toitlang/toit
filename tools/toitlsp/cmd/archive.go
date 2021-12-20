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
	"encoding/base64"
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

func Archive() *cobra.Command {
	archiveCmd := &cobra.Command{
		Use:   "archive <toit-file(s)>",
		Short: "archive a set of entrypoints into a toit archive file",
		RunE:  createArchive,
		Args:  cobra.MinimumNArgs(1),
	}
	archiveCmd.Flags().BoolP("verbose", "v", false, "")
	archiveCmd.Flags().String("toitc", "", "the default toitc to use")
	archiveCmd.Flags().String("sdk", "", "the default SDK path to use")
	archiveCmd.Flags().String("out", "archive.tar", "the output file. Use: '-' for stdout")
	archiveCmd.Flags().Bool("include-sdk", false, "if set, will include the used SDK files in the archive file")

	return archiveCmd
}

func createArchive(cmd *cobra.Command, args []string) error {
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

	out, err := cmd.Flags().GetString("out")
	if err != nil {
		return err
	}

	includeSDK, err := cmd.Flags().GetBool("include-sdk")
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
			return fmt.Errorf("the file: '%s' did not exist", arg)
		} else {
			return err
		}
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

	var w io.WriteCloser
	var f *os.File
	if out != "-" {
		f, err = os.Create(out)
		if err != nil {
			return err
		}
		w = f
	} else {
		w = base64.NewEncoder(base64.StdEncoding, os.Stdout)
	}
	defer w.Close()

	if err := archiveFiles(ctx, archiveFilesOptions{
		Writer:     w,
		Toitc:      toitc,
		SDK:        sdk,
		IncludeSDK: includeSDK,
		URIs:       uris,
		Logger:     logger,
		Verbose:    verbose,
	}); err != nil {
		if f != nil {
			f.Close()
			os.Remove(f.Name())
		}
		return err
	}
	return nil
}

type archiveFilesOptions struct {
	Writer     io.Writer
	Toitc      string
	SDK        string
	IncludeSDK bool
	URIs       []doclsp.DocumentURI
	Parallel   uint
	Logger     *zap.Logger
	Verbose    bool
}

func archiveFiles(ctx context.Context, options archiveFilesOptions) error {
	server, err := lsp.NewServer(lsp.ServerOptions{
		Logger: options.Logger,
		Settings: lsp.ServerSettings{
			Verbose:          options.Verbose,
			DefaultToitcPath: options.Toitc,
			DefaultSDKPath:   options.SDK,
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

	if _, err := server.Initialize(ctx, conn, doclsp.InitializeParams{}); err != nil {
		return err
	}

	if err := server.Initialized(ctx, conn); err != nil {
		return err
	}

	return server.ToitArchiveWriter(ctx, conn, lsp.ArchiveParams{
		URIs:       options.URIs,
		IncludeSDK: &options.IncludeSDK,
	}, options.Writer)
}
