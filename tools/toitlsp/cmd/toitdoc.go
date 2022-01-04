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
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"

	doclsp "github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
	"github.com/spf13/cobra"
	"github.com/toitware/toit.git/toitlsp/lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
	"github.com/toitware/toit.git/toitlsp/lsp/toitdoc"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

func Toitdoc(sdkVersion string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "toitdoc <paths...>",
		Short: "Generates a toitdoc json file",
		RunE:  runToitdoc(sdkVersion),
		Args:  cobra.MinimumNArgs(1),
	}
	cmd.Flags().BoolP("verbose", "v", false, "")
	cmd.Flags().String("version", "", "version of the package to build toitdoc for")
	cwd, _ := os.Getwd()
	cmd.Flags().String("root-path", cwd, "root path to build paths from")
	cmd.Flags().String("toitc", "", "the toit compiler to use")
	cmd.Flags().String("sdk", "", "the SDK path to use")
	cmd.Flags().String("out", "toitdoc.json", "the output file")
	cmd.Flags().Bool("exclude-sdk", false, "if set, will remove the sdk libraries from the toitdoc")
	cmd.Flags().Bool("include-private", false, "if set, will include private toitdoc for private elements")
	cmd.Flags().UintP("parallel", "p", 1, "parallelism")
	return cmd
}

func runToitdoc(sdkVersion string) func(cmd *cobra.Command, args []string) error {
	return func(cmd *cobra.Command, args []string) (err error) {
		toitc, err := cmd.Flags().GetString("toitc")
		if err != nil {
			return err
		}
		if toitc == "" {
			return fmt.Errorf("missing --toitc")
		}

		verbose, err := cmd.Flags().GetBool("verbose")
		if err != nil {
			return err
		}

		version, err := cmd.Flags().GetString("version")
		if err != nil {
			return err
		}

		rootPath, err := cmd.Flags().GetString("root-path")
		if err != nil {
			return err
		}

		includePrivate, err := cmd.Flags().GetBool("include-private")
		if err != nil {
			return err
		}

		excludeSDK, err := cmd.Flags().GetBool("exclude-sdk")
		if err != nil {
			return err
		}

		if !filepath.IsAbs(rootPath) {
			if p, err := filepath.Abs(rootPath); err == nil {
				rootPath = p
			}
		}

		sdk, err := computeSDKPath(cmd.Flags(), toitc)
		if err != nil {
			return err
		}

		out, err := cmd.Flags().GetString("out")
		if err != nil {
			return err
		}

		parallel, err := cmd.Flags().GetUint("parallel")
		if err != nil {
			return err
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

		var uris uri.Set
		for _, arg := range args {
			if stat, err := os.Stat(arg); err == nil {
				if stat.IsDir() {
					if err := filepath.Walk(arg, func(p string, info os.FileInfo, err error) error {
						if err != nil {
							return err
						}
						if !info.IsDir() && path.Ext(p) == ".toit" {
							uris.Add(pathToURI(p))
						}
						return nil
					}); err != nil {
						return err
					}
				} else {
					uris.Add(pathToURI(arg))
				}
			}
		}

		sdkURI := pathToURI(sdk)
		if !strings.HasSuffix(string(sdkURI), "/") {
			sdkURI += "/"
		}
		if excludeSDK {
			for u := range uris {
				if strings.HasPrefix(string(u), string(sdkURI)) {
					uris.Remove(u)
				}
			}
		}

		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		summaries, err := extractSummaries(ctx, extractSummariesOptions{
			Toitc:    toitc,
			SDK:      sdk,
			URIs:     uris,
			RootURI:  pathToURI(cwd),
			Parallel: parallel,
			Logger:   logger,
			Verbose:  verbose,
		})
		if err != nil {
			return err
		}

		f, err := os.Create(out)
		if err != nil {
			return err
		}
		defer f.Close()

		return exportSummaries(ctx, exportSummariesOptions{
			Summaries:      summaries,
			Writer:         f,
			Version:        version,
			SDKVersion:     sdkVersion,
			RootPath:       rootPath,
			IncludePrivate: includePrivate,
			excludeSDK:     excludeSDK,
			sdkURI:         sdkURI,
		})
	}
}

type extractSummariesOptions struct {
	Toitc    string
	SDK      string
	URIs     uri.Set
	RootURI  doclsp.DocumentURI
	Parallel uint
	Logger   *zap.Logger
	Verbose  bool
}

func extractSummaries(ctx context.Context, options extractSummariesOptions) (map[doclsp.DocumentURI]*toit.Module, error) {
	server, err := lsp.NewServer(lsp.ServerOptions{
		Logger: options.Logger,
		Settings: lsp.ServerSettings{
			Verbose:              options.Verbose,
			DefaultToitcPath:     options.Toitc,
			DefaultSDKPath:       options.SDK,
			ReturnCompilerErrors: true,
		},
	})
	if err != nil {
		return nil, err
	}

	ir, iw := io.Pipe()
	stream := jsonrpc2.NewBufferedStream(newStream(ir, ioutil.Discard), jsonrpc2.VSCodeObjectCodec{})
	conn := server.NewConn(ctx, stream)
	defer conn.Close()
	defer iw.Close()

	if _, err := server.Initialize(ctx, conn, doclsp.InitializeParams{
		RootURI: options.RootURI,
	}); err != nil {
		return nil, err
	}

	if err := server.Initialized(ctx, conn); err != nil {
		return nil, err
	}

	uris := options.URIs.Values()

	var wg sync.WaitGroup
	chunkSize := len(uris) / int(options.Parallel)

	var subErr error
	for i := 0; i < int(options.Parallel); i++ {
		start := i * chunkSize
		end := (i + 1) * chunkSize
		if i == int(options.Parallel)-1 {
			end = len(uris)
		}
		wg.Add(1)
		go func(uris []doclsp.DocumentURI) {
			defer wg.Done()
			if err := server.ToitDidOpenMany(ctx, conn, lsp.DidOpenManyParams{
				URIs: uris,
			}); err != nil && subErr == nil {
				subErr = err
			}
		}(uris[start:end])
	}

	wg.Wait()
	if subErr != nil {
		return nil, subErr
	}

	return server.GetContext(conn).Documents.Summaries(), nil
}

func pathToURI(path string) doclsp.DocumentURI {
	p, err := filepath.Abs(path)
	if err != nil {
		p = path
	}
	return uri.PathToURI(p)
}

type exportSummariesOptions struct {
	Summaries      map[doclsp.DocumentURI]*toit.Module
	Writer         io.Writer
	Version        string
	SDKVersion     string
	RootPath       string
	IncludePrivate bool
	excludeSDK     bool
	sdkURI         doclsp.DocumentURI
}

func exportSummaries(ctx context.Context, options exportSummariesOptions) error {
	doc := toitdoc.Build(toitdoc.BuildOptions{
		Summaries:      options.Summaries,
		RootPath:       options.RootPath,
		Version:        options.Version,
		SDKVersion:     options.SDKVersion,
		IncludePrivate: options.IncludePrivate,
		ExcludeSDK:     options.excludeSDK,
		SDKURI:         options.sdkURI,
	})
	return json.NewEncoder(options.Writer).Encode(doc)
}
