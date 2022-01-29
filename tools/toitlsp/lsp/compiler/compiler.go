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

package compiler

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

var (
	ErrCompilerCrashed = fmt.Errorf("Compiler crashed")
)

type CompilerError string

func CompilerErrorf(format string, args ...interface{}) error {
	return CompilerError(fmt.Sprintf(format, args...))
}

func (e CompilerError) Error() string {
	return string(e)
}

func IsCompilerError(err error) bool {
	_, ok := err.(CompilerError)
	return ok
}

type CrashError syscall.Signal

func newCrashError(signal syscall.Signal) error {
	return CrashError(signal)
}

func (e CrashError) Error() string {
	if int(e) == -1 {
		return "Compiler crashed"
	}
	return fmt.Sprintf("Compiler crashed with signal: %s", e.Signal().String())
}

func (e CrashError) Signal() syscall.Signal {
	return syscall.Signal(e)
}

func IsCrashError(err error) bool {
	_, ok := err.(CrashError)
	return ok
}

type Compiler struct {
	settings    Settings
	logger      *zap.Logger
	fs          FileSystem
	fs_protocol *CompilerFSProtocol
	parser      *parser

	lastCompilerFlags []string
	lastCompilerInput string
}

type Settings struct {
	SDKPath      string
	CompilerPath string
	Timeout      time.Duration
	RootURI      lsp.DocumentURI
}

func New(fs FileSystem, logger *zap.Logger, settings Settings) *Compiler {
	return &Compiler{
		settings: settings,
		logger:   logger,
		fs:       fs,
		parser:   newParser(logger),
	}
}

type AnalyzeResult struct {
	Diagnostics                map[lsp.DocumentURI][]lsp.Diagnostic
	DiagnosticsWithoutPosition []string
	Summaries                  map[lsp.DocumentURI]*toit.Module
}

func (c *Compiler) ctx(ctx context.Context) (context.Context, context.CancelFunc) {
	if c.settings.Timeout > 0 {
		return context.WithTimeout(ctx, c.settings.Timeout)
	}
	return context.WithCancel(ctx)
}

func (c *Compiler) Analyze(ctx context.Context, uris ...lsp.DocumentURI) (*AnalyzeResult, error) {
	ctx, cancel := c.ctx(ctx)
	defer cancel()

	paths := make([]string, len(uris))
	for i, u := range uris {
		paths[i] = uri.URIToCompilerPath(u)
	}

	var res struct {
		err    error
		result *AnalyzeResult
	}

	err := c.run(ctx, fmt.Sprintf("ANALYZE\n%d\n%s\n", len(paths), strings.Join(paths, "\n")), func(ctx context.Context, stdout io.Reader) {
		res.result, res.err = c.parser.AnalyzeOutput(stdout)
	})
	if err != nil {
		return nil, err
	}

	return res.result, res.err
}

func (c *Compiler) GotoDefinition(ctx context.Context, docURI lsp.DocumentURI, position lsp.Position) ([]lsp.Location, error) {
	ctx, cancel := c.ctx(ctx)
	defer cancel()

	path := uri.URIToCompilerPath(docURI)

	var res struct {
		err    error
		result []lsp.Location
	}

	err := c.run(ctx, fmt.Sprintf("GOTO DEFINITION\n%s\n%d\n%d\n", path, position.Line, position.Character), func(ctx context.Context, stdout io.Reader) {
		res.result, res.err = c.parser.GotoDefinitionOutput(stdout)
	})
	if err != nil {
		return nil, err
	}

	return res.result, res.err
}

func (c *Compiler) Complete(ctx context.Context, docURI lsp.DocumentURI, position lsp.Position) ([]lsp.CompletionItem, error) {
	ctx, cancel := c.ctx(ctx)
	defer cancel()

	path := uri.URIToCompilerPath(docURI)

	var res struct {
		err    error
		result []lsp.CompletionItem
	}

	err := c.run(ctx, fmt.Sprintf("COMPLETE\n%s\n%d\n%d\n", path, position.Line, position.Character), func(ctx context.Context, stdout io.Reader) {
		res.result, res.err = c.parser.CompleteOutput(stdout)
	})
	if err != nil {
		return nil, err
	}

	return res.result, res.err
}

func (c *Compiler) SemanticTokens(ctx context.Context, docURI lsp.DocumentURI) (*lsp.SemanticTokens, error) {
	ctx, cancel := c.ctx(ctx)
	defer cancel()

	path := uri.URIToCompilerPath(docURI)

	var res struct {
		err    error
		result []uint
	}

	err := c.run(ctx, fmt.Sprintf("SEMANTIC TOKENS\n%s\n", path), func(ctx context.Context, stdout io.Reader) {
		res.result, res.err = c.parser.SemanticTokensOutput(stdout)
	})
	if err != nil {
		return nil, err
	}

	if res.err != nil {
		return nil, res.err
	}

	return &lsp.SemanticTokens{
		Data: res.result,
	}, nil
}

func (c *Compiler) Parse(ctx context.Context, uris ...lsp.DocumentURI) error {
	ctx, cancel := c.ctx(ctx)
	defer cancel()

	paths := make([]string, len(uris))
	for i, u := range uris {
		paths[i] = uri.URIToCompilerPath(u)
	}

	var resErr error
	err := c.run(ctx, fmt.Sprintf("PARSE\n%d\n%s\n", len(paths), strings.Join(paths, "\n")), func(ctx context.Context, stdout io.Reader) {
		_, resErr = ioutil.ReadAll(stdout)
	})
	if err != nil {
		return err
	}

	return resErr
}

func (c *Compiler) SnapshotBundle(ctx context.Context, docUri lsp.DocumentURI) ([]byte, error) {
	ctx, cancel := c.ctx(ctx)
	defer cancel()

	path := uri.URIToCompilerPath(docUri)

	var res struct {
		res []byte
		err error
	}
	err := c.run(ctx, fmt.Sprintf("SNAPSHOT BUNDLE\n%s\n", path), func(ctx context.Context, stdout io.Reader) {
		res.res, res.err = c.parser.SnapshotBundleOutput(stdout)
	})
	if err != nil {
		return nil, err
	}

	return res.res, res.err
}

type ArchiveOptions struct {
	Writer                 io.Writer
	OverwriteCompilerInput *string
	Info                   string
	IncludeSDK             bool
}

func (c *Compiler) Archive(ctx context.Context, options ArchiveOptions) error {
	compilerInput := c.lastCompilerInput
	if options.OverwriteCompilerInput != nil {
		compilerInput = *options.OverwriteCompilerInput
	}

	compilerFlags := c.lastCompilerFlags

	var cwdPath *string
	if c.settings.RootURI != "" {
		rootPath := uri.URIToPath(c.settings.RootURI)
		cwdPath = &rootPath
	}

	return WriteArchive(ctx, WriteArchiveOptions{
		Writer:             options.Writer,
		CompilerFlags:      compilerFlags,
		CompilerInput:      compilerInput,
		Info:               options.Info,
		CompilerFSProtocol: c.fs_protocol,
		IncludeSDK:         options.IncludeSDK,
		CWDPath:            cwdPath,
	})
}

type logWriter struct {
	level  zapcore.Level
	logger *zap.Logger
}

func newLogWriter(logger *zap.Logger, level zapcore.Level) io.Writer {
	return &logWriter{
		level:  level,
		logger: logger.WithOptions(zap.AddStacktrace(zap.ErrorLevel)),
	}
}

func (w *logWriter) Write(b []byte) (n int, err error) {
	w.logger.Check(w.level, string(b)).Write()
	return len(b), nil
}

type parserFn func(context.Context, io.Reader)

func (c *Compiler) run(ctx context.Context, input string, parserFunc parserFn) error {
	multi := newMultiplexConn(c.logger)
	fileServer := NewPipeFileServer(c.fs, c.logger, c.settings.SDKPath)
	c.fs_protocol = fileServer.Protocol()
	go fileServer.Run(multi.CompilerToFS.r, multi.FSToCompiler.w)
	defer fileServer.Stop()

	cmd := c.cmd(ctx, input, fileServer)
	input = fmt.Sprintf("%s\n%s", fileServer.ConfigLine(), input)

	c.logger.Debug("running compiler", zap.String("input", input), zap.Stringer("cmd", cmd))

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	w := bufio.NewWriter(stdin)
	w.WriteString(input)
	w.Flush()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	multi.setFromCompiler(stdout)
	multi.setToCompiler(stdin)

	wg := sync.WaitGroup{}
	wg.Add(1)
	go func() {
		defer wg.Done()
		parserFunc(ctx, multi.CompilerToParser.r)
		fileServer.Stop()
		multi.Close()
		stdout.Close()
	}()

	if err := cmd.Start(); err != nil {
		return err
	}

	wg.Wait()

	if err := cmd.Wait(); err != nil {
		c.logger.Debug("compiler finished with error", zap.Error(err))
		if exitErr, ok := err.(*exec.ExitError); ok {
			if exitErr.ExitCode() < 0 {
				select {
				case <-ctx.Done():
					if ctx.Err() == context.Canceled {
						return ctx.Err()
					}
				default:
				}

				status, ok := exitErr.ProcessState.Sys().(syscall.WaitStatus)
				if !ok {
					return newCrashError(-1)
				}
				return newCrashError(status.Signal())
			}
		}
	}

	return nil
}

func (c *Compiler) cmd(ctx context.Context, input string, fileServer FileServer) *exec.Cmd {
	args := []string{"--lsp"}
	if c.settings.RootURI != "" {
		project_root := uri.URIToPath(c.settings.RootURI)
		lock_file := filepath.Join(project_root, "package.lock")
		if stat, err := os.Stat(lock_file); err == nil && !stat.IsDir() {
			args = append(args, "--project-root", uri.URIToCompilerPath(c.settings.RootURI))
		}
	}
	cmd := exec.CommandContext(ctx, c.settings.CompilerPath, args...)
	for !fileServer.IsReady() {
		runtime.Gosched()
	}

	c.lastCompilerFlags = args
	c.lastCompilerInput = input
	cmd.Stderr = newLogWriter(c.logger.Named("toitc"), zapcore.WarnLevel)
	return cmd
}
