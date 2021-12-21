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
	"io"
	"os"
	"runtime"
	"runtime/pprof"
	"sync"

	"github.com/sourcegraph/jsonrpc2"
	"github.com/spf13/cobra"
	"github.com/toitware/toit.git/toitlsp/lsp"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

func ToitLSP(version, date string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "toitlsp",
		Short: "start the lsp server",
		RunE:  runToitLSP,
	}
	cmd.Flags().BoolP("verbose", "v", false, "")
	cmd.Flags().String("toitc", "", "the default toitc to use")
	cmd.Flags().String("sdk", "", "the default SDK path to use")
	cmd.Flags().String("cpuprofile", "", "write cpu profile to `file`")
	cmd.Flags().String("memprofile", "", "write mem profile to `file`")

	cmd.AddCommand(Version(version, date))
	cmd.AddCommand(Toitdoc(version))
	cmd.AddCommand(Repro())
	cmd.AddCommand(Archive())
	cmd.AddCommand(Analyze())

	return cmd
}

func runToitLSP(cmd *cobra.Command, args []string) (err error) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	verbose, err := cmd.Flags().GetBool("verbose")
	if err != nil {
		return err
	}

	toitc, err := cmd.Flags().GetString("toitc")
	if err != nil {
		return err
	}

	sdk, err := computeSDKPath(cmd.Flags(), toitc)
	if err != nil {
		return err
	}

	if cmd.Flags().Changed("cpuprofile") {
		cpuprofile, err := cmd.Flags().GetString("cpuprofile")
		if err != nil {
			return err
		}
		f, err := os.Create(cpuprofile)
		if err != nil {
			return err
		}
		defer f.Close()
		if err := pprof.StartCPUProfile(f); err != nil {
			return err
		}
		defer pprof.StopCPUProfile()
	}

	if cmd.Flags().Changed("memprofile") {
		memprofile, err := cmd.Flags().GetString("memprofile")
		if err != nil {
			return err
		}

		f, err := os.Create(memprofile)
		if err != nil {
			return err
		}
		defer f.Close()
		defer func() {
			runtime.GC() // get up-to-date statistics
			if e := pprof.WriteHeapProfile(f); err == nil {
				err = e
			}
		}()
	}

	ioStream := newStream(os.Stdin, os.Stdout)
	stream := jsonrpc2.NewBufferedStream(ioStream, jsonrpc2.VSCodeObjectCodec{})

	logCfg := zap.NewDevelopmentConfig()
	logCfg.Level = zap.NewAtomicLevelAt(zapcore.InfoLevel)
	if verbose {
		logCfg.Level = zap.NewAtomicLevelAt(zapcore.DebugLevel)
	}

	logger, err := logCfg.Build()
	if err != nil {
		return err
	}

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
	conn := server.NewConn(ctx, stream)
	defer conn.Close()
	select {
	case <-conn.DisconnectNotify():
	case <-ioStream.ClosedNotify():
	}
	return nil
}

type stream struct {
	r         io.Reader
	w         io.Writer
	closed    chan struct{}
	closeOnce sync.Once
}

func newStream(r io.Reader, w io.Writer) *stream {
	return &stream{
		r:      r,
		w:      w,
		closed: make(chan struct{}),
	}
}

var _ io.ReadWriteCloser = (*stream)(nil)

func (s *stream) Read(p []byte) (n int, err error) {
	return s.r.Read(p)
}

func (s *stream) Write(p []byte) (n int, err error) {
	return s.w.Write(p)
}

func (s *stream) ClosedNotify() <-chan struct{} {
	return s.closed
}

func (s *stream) Close() error {
	var rErr, wErr error
	if closer, ok := s.r.(io.Closer); ok {
		rErr = closer.Close()
	}
	if closer, ok := s.w.(io.Closer); ok {
		wErr = closer.Close()
	}
	s.closeOnce.Do(func() {
		close(s.closed)
	})
	if rErr != nil {
		return rErr
	}
	return wErr
}
