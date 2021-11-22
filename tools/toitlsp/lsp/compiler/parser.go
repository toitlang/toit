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
	"fmt"
	"io"
	"io/ioutil"
	"strconv"
	"strings"

	"github.com/sourcegraph/go-lsp"
	cpath "github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
	"github.com/toitware/toit.git/toitlsp/lsp/toit/text"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

type parser struct {
	logger *zap.Logger
}

func newParser(logger *zap.Logger) *parser {
	return &parser{
		logger: logger,
	}
}

func (p *parser) AnalyzeOutput(r io.Reader) (*AnalyzeResult, error) {
	reader := bufio.NewReader(r)

	res := &AnalyzeResult{
		Diagnostics: map[lsp.DocumentURI][]lsp.Diagnostic{},
	}

	var inGroup bool
	var groupURI lsp.DocumentURI
	var groupDiagnostics *lsp.Diagnostic
	for {
		line, err := p.readLine(reader)
		if err == io.EOF {
			break
		}
		if err != nil {
			p.logger.Error("Read line err", zap.Error(err), zap.String("line", line))
			return nil, err
		}
		switch line {
		case "":
			continue
		case "SUMMARY":
			if res.Summaries != nil {
				return nil, fmt.Errorf("summary already filled")
			}
			summaries, err := text.ParseSummary(reader, p.logger)
			if err != nil {
				return nil, err
			}
			res.Summaries = summaries
		case "START GROUP":
			if inGroup {
				return nil, fmt.Errorf("got 'START GROUP' but was already in a group")
			}
			if groupDiagnostics != nil {
				return nil, fmt.Errorf("group diagnostics was already filled")
			}
			inGroup = true
		case "END GROUP":
			if groupDiagnostics != nil {
				res.Diagnostics[groupURI] = append(res.Diagnostics[groupURI], *groupDiagnostics)
			}
			inGroup = false
			groupURI = ""
			groupDiagnostics = nil
		case "WITH POSITION", "NO POSITION":
			withPosition := line == "WITH POSITION"
			severity, err := p.readLine(reader)
			if err != nil {
				return nil, err
			}
			diagnosticsSeverity := lsp.Warning
			if severity == "error" {
				diagnosticsSeverity = lsp.Error
			} else if severity == "information" {
				diagnosticsSeverity = lsp.Information
			}

			var errorURI lsp.DocumentURI
			var rng *lsp.Range
			if withPosition {
				if errorURI, err = p.readURI(reader); err != nil {
					return nil, err
				}
				if rng, err = p.readRange(reader); err != nil {
					return nil, err
				}
			}

			var msg string
			for {
				line, err := p.readLine(reader)
				if err != nil {
					return nil, err
				}
				if line == "*******************" {
					break
				}
				msg += line
			}

			if !withPosition {
				p.logger.Debug("diagnostics without position", zap.String("message", msg))
				res.DiagnosticsWithoutPosition = append(res.DiagnosticsWithoutPosition, msg)
			} else if !inGroup {
				p.logger.Debug("diagnostics for group", zap.String("error_uri", string(errorURI)), zap.String("message", msg))
				res.Diagnostics[errorURI] = append(res.Diagnostics[errorURI], lsp.Diagnostic{
					Range:    *rng,
					Severity: lsp.DiagnosticSeverity(diagnosticsSeverity),
					Message:  msg,
				})
			} else if groupURI == "" {
				p.logger.Debug("starting group diagnostics", zap.String("error_uri", string(errorURI)), zap.String("message", msg))
				groupURI = errorURI
				groupDiagnostics = &lsp.Diagnostic{
					Range:    *rng,
					Message:  msg,
					Severity: diagnosticsSeverity,
				}
			} else {
				groupDiagnostics.RelatedInformation = append(groupDiagnostics.RelatedInformation, lsp.DiagnosticRelatedInformation{
					Location: lsp.Location{URI: errorURI, Range: *rng},
					Message:  msg,
				})
			}
		default:
			return nil, CompilerErrorf("LSP Server: unexpected line from compiler: %s", line)
		}
	}

	return res, nil
}

func (p *parser) GotoDefinitionOutput(r io.Reader) ([]lsp.Location, error) {
	reader := bufio.NewReader(r)

	res := []lsp.Location{}

	for {
		uri, err := p.readURI(reader)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		rng, err := p.readRange(reader)
		if err != nil {
			return nil, err
		}
		res = append(res, lsp.Location{
			URI:   uri,
			Range: *rng,
		})
	}

	return res, nil
}

func (p *parser) CompleteOutput(r io.Reader) ([]lsp.CompletionItem, error) {
	reader := bufio.NewReader(r)

	res := []lsp.CompletionItem{}

	for {
		label, err := p.readLine(reader)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		kind, err := p.readInt(reader)
		if err != nil {
			return nil, err
		}
		res = append(res, lsp.CompletionItem{
			Label: label,
			Kind:  lsp.CompletionItemKind(kind),
		})
	}

	return res, nil
}

func (p *parser) SnapshotBundleOutput(r io.Reader) ([]byte, error) {
	reader := bufio.NewReader(r)

	status, err := p.readLine(reader)
	if err != nil {
		return nil, err
	}
	if status != "OK" {
		return nil, fmt.Errorf("failed to generate snapshot, status: %s", status)
	}

	size, err := p.readInt(reader)
	if err != nil {
		return nil, err
	}

	res, err := ioutil.ReadAll(reader)
	if err != nil {
		return nil, err
	}

	if len(res) != size {
		return nil, fmt.Errorf("snapshot bundle was corrupted. read %d but was estimated as %d", len(res), size)
	}

	return res, nil
}

func (p *parser) SemanticTokensOutput(r io.Reader) ([]uint, error) {
	reader := bufio.NewReader(r)
	cnt, err := p.readInt(reader)
	if err != nil {
		return nil, err
	}

	res := make([]uint, cnt)
	for i := range res {
		v, err := p.readInt(reader)
		if err != nil {
			return nil, err
		}
		res[i] = uint(v)
	}
	return res, nil
}

func (p *parser) readLine(reader *bufio.Reader) (string, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(line, "\n"), nil
}

func (p *parser) readURI(reader *bufio.Reader) (lsp.DocumentURI, error) {
	path, err := p.readLine(reader)
	if err != nil {
		return "", err
	}
	path = cpath.FromCompilerPath(path)
	return uri.PathToURI(path), nil
}

func (p *parser) readInt(reader *bufio.Reader) (int, error) {
	line, err := p.readLine(reader)
	if err != nil {
		return -1, err
	}
	res, err := strconv.Atoi(line)
	if err != nil {
		p.logger.Error("failed to parse integer", zap.Error(err))
		return -1, err
	}
	return res, nil
}

func (p *parser) readRange(reader *bufio.Reader) (*lsp.Range, error) {
	fromLine, err := p.readInt(reader)
	if err != nil {
		return nil, err
	}
	fromChar, err := p.readInt(reader)
	if err != nil {
		return nil, err
	}
	toLine, err := p.readInt(reader)
	if err != nil {
		return nil, err
	}
	toChar, err := p.readInt(reader)
	if err != nil {
		return nil, err
	}
	return &lsp.Range{
		Start: lsp.Position{Line: fromLine, Character: fromChar},
		End:   lsp.Position{Line: toLine, Character: toChar},
	}, nil
}
