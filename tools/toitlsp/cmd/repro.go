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
	"archive/tar"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/toitware/toit.git/toitlsp/lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/compiler"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

func Repro() *cobra.Command {
	reproCmd := &cobra.Command{
		Use:  "repro <toitc> <toit-file> <out>",
		RunE: createRepro,
		Args: cobra.ExactArgs(3),
	}
	reproCmd.Flags().String("sdk-path", "", "override the sdk path to use")
	reproCmd.Flags().Duration("timeout", 5*time.Second, "timeout to use")

	serveCmd := &cobra.Command{
		Use:  "serve <repro>",
		RunE: serveRepro,
		Args: cobra.ExactArgs(1),
	}
	serveCmd.Flags().Bool("json", false, "output format as json")
	serveCmd.Flags().Int("port", 0, "port to use for file-server")
	reproCmd.AddCommand(serveCmd)

	return reproCmd
}

func createRepro(cmd *cobra.Command, args []string) error {
	toitcPath := args[0]
	entryPath := args[1]
	outPath := args[2]

	sdkPath, err := cmd.Flags().GetString("sdk-path")
	if err != nil {
		return err
	}

	timeout, err := cmd.Flags().GetDuration("timeout")
	if err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	if !cmd.Flags().Changed("sdk-path") {
		sdkPath, err = filepath.Abs(filepath.Dir(toitcPath))
		if err != nil {
			return err
		}
	}

	if entryPath, err = filepath.Abs(entryPath); err != nil {
		return err
	}

	logger := zap.NewNop()
	documents := lsp.NewDocuments(logger)

	fs := lsp.MultiFileSystem{lsp.NewDocsCacheFileSystem(documents), lsp.NewLocalFileSystem()}
	c := compiler.New(fs, logger.Named("Compiler"), compiler.Settings{
		SDKPath:      sdkPath,
		CompilerPath: toitcPath,
		Timeout:      timeout,
		RootURI:      uri.PathToURI(cwd),
	})

	if _, err := c.Analyze(ctx, uri.PathToURI(entryPath)); err != nil {
		return err
	}
	out, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer out.Close()

	fmt.Println("Creating archive")
	return c.Archive(ctx, compiler.ArchiveOptions{
		Writer:     out,
		Info:       "from repro tool",
		IncludeSDK: true,
	})
}

func serveRepro(cmd *cobra.Command, args []string) error {
	archive := args[0]

	outputJSON, err := cmd.Flags().GetBool("json")
	if err != nil {
		return err
	}

	port, err := cmd.Flags().GetInt("port")
	if err != nil {
		return err
	}

	logger := zap.NewNop()
	reproFS, err := NewReproFileSystem(archive)
	if err != nil {
		return err
	}
	documents := lsp.NewDocuments(logger)
	fs := lsp.MultiFileSystem{lsp.NewDocsCacheFileSystem(documents), reproFS}

	fileServer := compiler.NewFileServer(fs, logger, reproFS.sdkPath)
	go fileServer.ListenAndServe(fmt.Sprintf(":%d", port))
	defer fileServer.Stop()

	for !fileServer.IsReady() {
		runtime.Gosched()
	}

	if outputJSON {
		json.NewEncoder(os.Stdout).Encode(map[string]interface{}{
			"port":          fileServer.Port(),
			"compilerInput": reproFS.compilerInput,
		})
	} else {
		fmt.Println("Server started at", fileServer.Port())
		fmt.Println("Run the compiler with:")
		if len(reproFS.compilerFlags) == 0 {
			fmt.Println("  toitc -Xno_fork --lsp")
		} else {
			fmt.Println("  toitc -Xno_fork", strings.Join(reproFS.compilerFlags, " "))
		}
		fmt.Println("Stdin for the compiler:")
		fmt.Println(fileServer.Port())
		fmt.Println(reproFS.compilerInput)
	}

	<-fileServer.StopWait()
	return nil
}

type ReproFileSystem struct {
	archive           map[string][]byte
	meta              compiler.ArchiveMeta
	sdkPath           string
	packageCachePaths []string
	compilerFlags     []string
	compilerInput     string
}

func NewReproFileSystem(filepath string) (*ReproFileSystem, error) {
	res := &ReproFileSystem{
		archive: map[string][]byte{},
	}
	f, err := os.Open(filepath)
	if err != nil {
		return nil, err
	}
	r := tar.NewReader(f)
	for {
		h, err := r.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}

		if h.Typeflag == tar.TypeReg {
			b, err := ioutil.ReadAll(r)
			if err != nil {
				return nil, err
			}
			res.archive[h.Name] = b
		}
	}

	if err := json.Unmarshal(res.archive[compiler.ReproMetaFilePath], &res.meta); err != nil {
		return nil, err
	}
	delete(res.archive, compiler.ReproMetaFilePath)

	res.compilerFlags = strings.Split(string(res.archive[compiler.ReproCompilerFlagsPath]), "\n")
	delete(res.archive, compiler.ReproCompilerFlagsPath)

	res.compilerInput = string(res.archive[compiler.ReproCompilerInputPath])
	delete(res.archive, compiler.ReproCompilerInputPath)

	res.packageCachePaths = strings.Split(string(res.archive[compiler.ReproPackageCachePathsPath]), "\n")
	delete(res.archive, compiler.ReproPackageCachePathsPath)

	res.sdkPath = string(res.archive[compiler.ReproSDKPathPath])
	delete(res.archive, compiler.ReproSDKPathPath)

	delete(res.archive, compiler.ReproInfoPath)
	delete(res.archive, compiler.ReproCWDPathPath)
	return res, nil
}

func (fs *ReproFileSystem) Read(path string) (compiler.File, error) {
	f, ok := fs.meta.Files[path]
	if !ok {
		return compiler.File{}, os.ErrNotExist
	}
	res := compiler.File{
		Path:        path,
		Exists:      f.Exists,
		IsRegular:   f.IsRegular,
		IsDirectory: f.IsDirectory,
	}
	if f.HasContent {
		res.Content = fs.archive[path]
	}
	return res, nil
}

func (fs *ReproFileSystem) ListDirectory(path string) ([]string, error) {
	entries, ok := fs.meta.Directories[path]
	if !ok {
		return nil, os.ErrNotExist
	}
	return entries, nil
}
func (fs *ReproFileSystem) PackageCachePaths() ([]string, error) {
	return fs.packageCachePaths, nil
}
