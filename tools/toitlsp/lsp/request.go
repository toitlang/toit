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

package lsp

import (
	"context"
	"encoding/json"
	"time"

	"github.com/sourcegraph/go-lsp"
	"github.com/sourcegraph/jsonrpc2"
)

const (
	// TODO(jesper): Move this to user temp directory
	defaultReproDir = "/tmp/lsp_repro"
	defaultTimeout  = 5 * time.Second
)

type WorkspaceSettings struct {
	// TODO(jesper): each connection should have its on logger changed on the verbose.
	Verbose                 bool          `json:"verbose"`
	ShouldWriteReproOnCrash bool          `json:"shouldWriteReproOnCrash"`
	Timeout                 time.Duration `json:"timeout"`
	SDKPath                 string        `json:"sdkPath"`
	ToitcPath               string        `json:"toitcPath"`
	ReproDirectory          string        `json:"reproDir"`
}

type parseWorkspaceSettings struct {
	Verbose                 bool   `json:"verbose"`
	ShouldWriteReproOnCrash bool   `json:"shouldWriteReproOnCrash"`
	TimeoutMs               *int   `json:"timeoutMs"`
	SDKPath                 string `json:"sdkPath"`
	ToitcPath               string `json:"toitcPath"`
	ReproDirectory          string `json:"reproDir"`
}

func (s parseWorkspaceSettings) WorkspaceSettings() *WorkspaceSettings {
	res := &WorkspaceSettings{
		Verbose:                 s.Verbose,
		ShouldWriteReproOnCrash: s.ShouldWriteReproOnCrash,
		Timeout:                 defaultTimeout,
		SDKPath:                 s.SDKPath,
		ToitcPath:               s.ToitcPath,
		ReproDirectory:          defaultReproDir,
	}

	if s.TimeoutMs != nil {
		res.Timeout = time.Duration(*s.TimeoutMs) * time.Millisecond
	}
	if s.ReproDirectory != "" {
		res.ReproDirectory = s.ReproDirectory
	}

	return res
}

func fetchWorkspaceSettings(ctx context.Context, conn *jsonrpc2.Conn) (*WorkspaceSettings, error) {
	var res []json.RawMessage
	req := lsp.ConfigurationParams{
		Items: []lsp.ConfigurationItem{{Section: "toitLanguageServer"}},
	}
	if err := conn.Call(ctx, "workspace/configuration", req, &res); err != nil {
		return nil, err
	}
	var s parseWorkspaceSettings
	if err := json.Unmarshal(res[0], &s); err != nil {
		return nil, err
	}
	return s.WorkspaceSettings(), nil
}

func notifyToitIdle(ctx context.Context, conn *jsonrpc2.Conn) error {
	return conn.Notify(ctx, "toit/idle", nil)
}

func publishDiagnostics(ctx context.Context, conn *jsonrpc2.Conn, params lsp.PublishDiagnosticsParams) error {
	if params.Diagnostics == nil {
		params.Diagnostics = []lsp.Diagnostic{}
	}
	return conn.Notify(ctx, "textDocument/publishDiagnostics", params)
}

func logMessage(ctx context.Context, conn *jsonrpc2.Conn, params lsp.LogMessageParams) error {
	return conn.Notify(ctx, "window/logMessage", params)
}

func showMessage(ctx context.Context, conn *jsonrpc2.Conn, params lsp.ShowMessageParams) error {
	return conn.Notify(ctx, "window/showMessage", params)
}
