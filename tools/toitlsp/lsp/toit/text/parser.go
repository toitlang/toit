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

package text

import (
	"bufio"
	"fmt"
	"strconv"
	"strings"

	"github.com/sourcegraph/go-lsp"
	cpath "github.com/toitware/toit.git/toitlsp/lsp/compiler/path"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
	"go.uber.org/zap"
)

type summaryReader struct {
	reader *bufio.Reader
	logger *zap.Logger

	moduleURIs            []lsp.DocumentURI
	moduleToplevelOffsets []int
	currModuleID          int
	currToplevelID        int
}

var ErrScannerEmpty = fmt.Errorf("scanner was empty")

func ParseSummary(reader *bufio.Reader, logger *zap.Logger) (map[lsp.DocumentURI]*toit.Module, error) {
	r := &summaryReader{
		reader: reader,
		logger: logger.Named("textParser"),
	}

	return r.Read()
}

func (r *summaryReader) init() {
	r.moduleURIs = nil
	r.moduleToplevelOffsets = nil
	r.currModuleID = 0
}

func (r *summaryReader) Read() (map[lsp.DocumentURI]*toit.Module, error) {
	r.init()

	moduleCnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	moduleOffset := 0
	for i := 0; i < moduleCnt; i++ {
		moduleURI, err := r.readURI()
		if err != nil {
			return nil, err
		}
		r.moduleURIs = append(r.moduleURIs, moduleURI)
		r.moduleToplevelOffsets = append(r.moduleToplevelOffsets, moduleOffset)
		toplevelCnt, err := r.readInt()
		if err != nil {
			return nil, err
		}
		moduleOffset += toplevelCnt
	}

	res := map[lsp.DocumentURI]*toit.Module{}
	for i := 0; i < moduleCnt; i++ {
		mod, err := r.readModule()
		if err != nil {
			return nil, err
		}
		res[mod.URI] = mod
		r.currModuleID++
	}

	return res, nil
}

func (r *summaryReader) readModule() (*toit.Module, error) {
	r.currToplevelID = 0
	moduleURI, err := r.readURI()
	if err != nil {
		return nil, err
	}
	if moduleURI != r.moduleURIs[r.currModuleID] {
		return nil, fmt.Errorf("module URI did not match header. Header: %s but was '%s' in body", r.moduleURIs[r.currModuleID], moduleURI)
	}

	res := &toit.Module{
		URI: moduleURI,
	}
	if res.Dependencies, err = r.readURIs(); err != nil {
		return nil, err
	}
	if res.ExportedModules, err = r.readURIs(); err != nil {
		return nil, err
	}
	if res.Exports, err = r.readExports(); err != nil {
		return nil, err
	}

	// The order also defines the toplevel-ids.
	// Classes go before toplevel functions, before globals.
	if res.Classes, err = r.readClasses(); err != nil {
		return nil, err
	}
	if res.Functions, err = r.readFunctions(); err != nil {
		return nil, err
	}
	if res.Globals, err = r.readFunctions(); err != nil {
		return nil, err
	}
	if res.Toitdoc, err = r.readToitdoc(); err != nil {
		return nil, err
	}

	return res, nil
}

func (r *summaryReader) readClasses() ([]*toit.Class, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.Class, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readClass(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readClass() (*toit.Class, error) {
	topLevelID := r.currToplevelID
	r.currToplevelID++
	var res toit.Class
	var err error
	if res.Name, err = r.readLine(); err != nil {
		return nil, err
	}

	if res.Range, err = r.readRange(); err != nil {
		return nil, err
	}

	globalID, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res.TopLevelID = toit.ID(topLevelID)

	if assertedGlobalID := topLevelID + r.moduleToplevelOffsets[r.currModuleID]; globalID != assertedGlobalID {
		return nil, fmt.Errorf("globalID did not match asserted ID. Was %d but should have been %d", globalID, assertedGlobalID)
	}

	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}
	res.IsInterface = kind == "interface"
	res.IsAbstract = kind == "abstract"
	if res.SuperClass, err = r.readTopLevelReference(); err != nil {
		return nil, err
	}

	if res.Interfaces, err = r.readTopLevelReferences(); err != nil {
		return nil, err
	}

	if res.Statics, err = r.readMethods(); err != nil {
		return nil, err
	}

	if res.Constructors, err = r.readMethods(); err != nil {
		return nil, err
	}

	if res.Factories, err = r.readMethods(); err != nil {
		return nil, err
	}

	if res.Fields, err = r.readFields(); err != nil {
		return nil, err
	}

	if res.Methods, err = r.readMethods(); err != nil {
		return nil, err
	}

	if res.Toitdoc, err = r.readToitdoc(); err != nil {
		return nil, err
	}

	return &res, nil
}

func (r *summaryReader) readFields() ([]*toit.Field, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.Field, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readField(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readField() (*toit.Field, error) {
	var res toit.Field
	var err error
	if res.Name, err = r.readLine(); err != nil {
		return nil, err
	}
	if res.Range, err = r.readRange(); err != nil {
		return nil, err
	}
	final, err := r.readLine()
	if err != nil {
		return nil, err
	}
	res.IsFinal = final == "final"
	if res.Type, err = r.readType(); err != nil {
		return nil, err
	}
	if res.Toitdoc, err = r.readToitdoc(); err != nil {
		return nil, err
	}

	return &res, nil
}

func (r *summaryReader) readFunctions() ([]*toit.TopLevelFunction, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.TopLevelFunction, cnt)
	for i := 0; i < cnt; i++ {
		m, err := r.readMethod()
		if err != nil {
			return nil, err
		}
		res[i] = &toit.TopLevelFunction{Method: m}
	}
	return res, nil
}

func (r *summaryReader) readMethods() ([]*toit.Method, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.Method, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readMethod(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readMethod() (*toit.Method, error) {
	var res toit.Method
	var err error
	if res.Name, err = r.readLine(); err != nil {
		return nil, err
	}
	if res.Range, err = r.readRange(); err != nil {
		return nil, err
	}

	globalID, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res.TopLevelID = toit.ID(globalID)
	if res.TopLevelID != -1 {
		res.TopLevelID -= toit.ID(r.moduleToplevelOffsets[r.currModuleID])
	}
	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}
	switch kind {
	case "instance":
	case "abstract":
		res.Kind = toit.MethodKindInstance
		if kind == "abstract" {
			res.IsAbstract = true
		}
		if globalID != -1 {
			return nil, fmt.Errorf("global ID for a instance method should be -1 but was %d", globalID)
		}
	case "field stub":
		res.Kind = toit.MethodKindInstance
		res.IsSynthetic = true
		if globalID != -1 {
			return nil, fmt.Errorf("global ID for a field stub method should be -1 but was %d", globalID)
		}
	case "global fun":
		res.Kind = toit.MethodKindGlobalFunction
		// If the read id is -1, then it's just a class-static.
		if globalID != -1 {
			if r.currToplevelID != int(res.TopLevelID) {
				return nil, fmt.Errorf("topLevelID for the global function did not match. Was %d should have been: %d", res.TopLevelID, r.currToplevelID)
			}
			r.currToplevelID++
		}
	case "global initializer":
		res.Kind = toit.MethodKindGlobal
		// If the read id is -1, then it's just a class-static.
		if globalID != -1 {
			if r.currToplevelID != int(res.TopLevelID) {
				return nil, fmt.Errorf("topLevelID for the global did not match. Was %d should have been: %d", res.TopLevelID, r.currToplevelID)
			}
			r.currToplevelID++
		}
	case "constructor":
		res.Kind = toit.MethodKindConstructor
		if globalID != -1 {
			return nil, fmt.Errorf("global ID for a constructor method should be -1 but was %d", globalID)
		}
	case "default constructor":
		res.Kind = toit.MethodKindConstructor
		res.IsSynthetic = true
		if globalID != -1 {
			return nil, fmt.Errorf("global ID for a constructor method should be -1 but was %d", globalID)
		}
	case "factory":
		res.Kind = toit.MethodKindFactory
		if globalID != -1 {
			return nil, fmt.Errorf("global ID for a factory method should be -1 but was %d", globalID)
		}
	default:
		return nil, fmt.Errorf("unknown method kind: %s", kind)
	}

	if res.Parameters, err = r.readParameters(); err != nil {
		return nil, err
	}
	if res.ReturnType, err = r.readType(); err != nil {
		return nil, err
	}
	if res.Toitdoc, err = r.readToitdoc(); err != nil {
		return nil, err
	}
	return &res, nil
}

func (r *summaryReader) readParameters() ([]*toit.Parameter, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.Parameter, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readParameter(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readParameter() (*toit.Parameter, error) {
	var res toit.Parameter
	var err error
	if res.Name, err = r.readLine(); err != nil {
		return nil, err
	}

	originalIndex, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res.OriginalIndex = originalIndex

	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}
	res.IsRequired = kind == "required" || kind == "required named"
	res.IsNamed = kind == "required named" || kind == "optional named"

	if res.Type, err = r.readType(); err != nil {
		return nil, err
	}
	return &res, nil
}

func (r *summaryReader) readType() (*toit.Type, error) {
	var res toit.Type
	var err error
	line, err := r.readLine()
	if err != nil {
		return nil, err
	}
	if line == "[block]" {
		return toit.TypeBlock, nil
	}
	id, err := strconv.Atoi(line)
	if err != nil {
		r.logger.Error("failed to parse integer", zap.Error(err))
		return nil, err
	}
	if id == -1 {
		return toit.TypeAny, nil
	}
	if id == -2 {
		return toit.TypeNone, nil
	}
	res.Kind = toit.TypeKindClass
	if res.ClassRef, err = r.topLevelReferenceFromGlobalID(id); err != nil {
		return nil, err
	}
	return &res, nil
}

func (r *summaryReader) readToitdoc() (*toit.DocContents, error) {
	var res toit.DocContents
	var err error
	if res.Sections, err = r.readDocSections(); err != nil {
		return nil, err
	}
	if len(res.Sections) == 0 {
		return nil, nil
	}
	return &res, nil
}

func (r *summaryReader) readDocSymbol() (string, error) {
	size, err := r.readInt()
	if err != nil {
		return "", err
	}

	var symbol string
	for len(symbol) < size {
		b, err := r.reader.Peek(size - len(symbol))
		if err != nil {
			return "", err
		}
		r.reader.Discard(len(b))
		symbol += string(b)
	}
	r.reader.ReadByte() // Read the '\n'
	if len(symbol) != size {
		return "", fmt.Errorf("symbol was larger than expected size: '%s' (size: '%d') should have been '%d'", symbol, len(symbol), size)
	}

	return symbol, nil
}

func (r *summaryReader) readDocSections() ([]*toit.DocSection, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.DocSection, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readDocSection(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readDocSection() (*toit.DocSection, error) {
	var res toit.DocSection
	var err error

	if res.Title, err = r.readDocSymbol(); err != nil {
		return nil, err
	}

	if res.Statements, err = r.readDocStatements(); err != nil {
		return nil, err
	}

	return &res, nil
}

func (r *summaryReader) readDocStatements() ([]toit.DocStatement, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]toit.DocStatement, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readDocStatement(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readDocStatement() (toit.DocStatement, error) {
	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}

	switch kind {
	case "CODE SECTION":
		return r.readDocCodeSection()
	case "ITEMIZED":
		return r.readDocItemized()
	case "PARAGRAPH":
		return r.readDocParagraph()
	default:
		return nil, fmt.Errorf("unknown statement kind: %s", kind)
	}
}

func (r *summaryReader) readDocCodeSection() (*toit.DocCodeSection, error) {
	var res toit.DocCodeSection
	var err error
	if res.Text, err = r.readDocSymbol(); err != nil {
		return nil, err
	}
	return &res, nil
}

func (r *summaryReader) readDocItemized() (*toit.DocItemized, error) {
	var res toit.DocItemized
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res.Items = make([]*toit.DocItem, cnt)
	for i := 0; i < cnt; i++ {
		if res.Items[i], err = r.readDocItem(); err != nil {
			return nil, err
		}
	}
	return &res, nil
}

func (r *summaryReader) readDocItem() (*toit.DocItem, error) {
	var res toit.DocItem
	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}
	switch kind {
	case "ITEM":
		if res.Statements, err = r.readDocStatements(); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("unknown item format: %s", kind)
	}
	return &res, nil
}

func (r *summaryReader) readDocParagraph() (*toit.DocParagraph, error) {
	var res toit.DocParagraph
	var err error
	if res.Expressions, err = r.readDocExpressions(); err != nil {
		return nil, err
	}
	return &res, nil
}

func (r *summaryReader) readDocExpressions() ([]toit.DocExpression, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]toit.DocExpression, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readDocExpression(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readDocExpression() (toit.DocExpression, error) {
	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}

	switch kind {
	case "TEXT":
		return r.readDocText()
	case "CODE":
		return r.readDocCode()
	case "REF":
		return r.readDocReference()
	default:
		return nil, fmt.Errorf("unknown expression kind: %s", kind)
	}
}

func (r *summaryReader) readDocText() (*toit.DocText, error) {
	text, err := r.readDocSymbol()
	if err != nil {
		return nil, err
	}
	return &toit.DocText{Text: text}, nil
}

func (r *summaryReader) readDocCode() (*toit.DocCode, error) {
	text, err := r.readDocSymbol()
	if err != nil {
		return nil, err
	}
	return &toit.DocCode{Text: text}, nil
}

func (r *summaryReader) readDocReference() (*toit.ToitDocReference, error) {
	var res toit.ToitDocReference
	var err error
	if res.Text, err = r.readDocSymbol(); err != nil {
		return nil, err
	}

	kindInt, err := r.readInt()
	if err != nil {
		return nil, err
	}

	res.Kind = toit.ToitDocReferenceKind(kindInt)

	if res.Kind < 0 || res.Kind == toit.ToitDocReferenceKindOther {
		res.Kind = toit.ToitDocReferenceKindOther
		return &res, nil
	}

	if res.Kind < toit.ToitDocReferenceKindClass || toit.ToitDocReferenceKindField < res.Kind {
		return nil, fmt.Errorf("invalid reference kind: %d", res.Kind)
	}

	if res.ModuleURI, err = r.readURI(); err != nil {
		return nil, err
	}
	if res.Kind.HasHolder() {
		holder, err := r.readDocSymbol()
		if err != nil {
			return nil, err
		}
		res.Holder = &holder
	}
	if res.Name, err = r.readDocSymbol(); err != nil {
		return nil, err
	}
	if res.Kind.IsMethodReference() {
		if res.Shape, err = r.readDocShape(); err != nil {
			return nil, err
		}
	}
	return &res, nil
}

func (r *summaryReader) readDocShape() (*toit.DocShape, error) {
	var res toit.DocShape
	var err error
	if res.Arity, err = r.readInt(); err != nil {
		return nil, err
	}
	if res.TotalBlockCount, err = r.readInt(); err != nil {
		return nil, err
	}
	namesCnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	if res.NamedBlockCount, err = r.readInt(); err != nil {
		return nil, err
	}
	setter, err := r.readLine()
	if err != nil {
		return nil, err
	}
	res.IsSetter = setter == "setter"

	res.Names = make([]string, namesCnt)
	for i := 0; i < namesCnt; i++ {
		if res.Names[i], err = r.readDocSymbol(); err != nil {
			return nil, err
		}
	}
	return &res, nil
}

func (r *summaryReader) readRange() (*toit.Range, error) {
	start, err := r.readInt()
	if err != nil {
		return nil, err
	}

	end, err := r.readInt()
	if err != nil {
		return nil, err
	}

	return &toit.Range{
		Start: start,
		End:   end,
	}, nil
}

func (r *summaryReader) readExports() ([]*toit.Export, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.Export, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readExport(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readExport() (*toit.Export, error) {
	var res toit.Export
	var err error
	if res.Name, err = r.readLine(); err != nil {
		return nil, err
	}
	kind, err := r.readLine()
	if err != nil {
		return nil, err
	}
	if kind == "AMBIGUOUS" {
		res.Kind = toit.ExportKindAmbiguous
	} else {
		res.Kind = toit.ExportKindNodes
	}
	if res.References, err = r.readTopLevelReferences(); err != nil {
		return nil, err
	}
	return &res, nil
}

func (r *summaryReader) readTopLevelReferences() ([]*toit.TopLevelReference, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]*toit.TopLevelReference, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readTopLevelReference(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) topLevelReferenceFromGlobalID(id int) (*toit.TopLevelReference, error) {
	if id < 0 {
		return nil, fmt.Errorf("global ID must be a positive integer. was: %d", id)
	}

	modID := toit.FindLastGreaterThanIdx(r.moduleToplevelOffsets, id)
	topLevelID := id - r.moduleToplevelOffsets[modID]
	return &toit.TopLevelReference{
		Module: r.moduleURIs[modID],
		ID:     toit.ID(topLevelID),
	}, nil
}

func (r *summaryReader) readTopLevelReference() (*toit.TopLevelReference, error) {
	id, err := r.readInt()
	if err != nil {
		return nil, err
	}
	if id < 0 {
		return nil, nil
	}
	return r.topLevelReferenceFromGlobalID(id)
}

func (r *summaryReader) readURIs() ([]lsp.DocumentURI, error) {
	cnt, err := r.readInt()
	if err != nil {
		return nil, err
	}
	res := make([]lsp.DocumentURI, cnt)
	for i := 0; i < cnt; i++ {
		if res[i], err = r.readURI(); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func (r *summaryReader) readURI() (lsp.DocumentURI, error) {
	path, err := r.readLine()
	if err != nil {
		return "", err
	}
	path = cpath.FromCompilerPath(path)
	return uri.PathToURI(path), nil
}

func (r *summaryReader) readLine() (string, error) {
	line, err := r.reader.ReadString('\n')
	if err != nil {
		r.logger.Error("Read line err", zap.Error(err), zap.String("line", line))
		return "", err
	}
	return strings.TrimSuffix(line, "\n"), nil
}

func (r *summaryReader) readInt() (int, error) {
	line, err := r.readLine()
	if err != nil {
		return -1, err
	}
	res, err := strconv.Atoi(line)
	if err != nil {
		r.logger.Error("failed to parse integer", zap.Error(err))
		return -1, err
	}
	return res, nil
}
