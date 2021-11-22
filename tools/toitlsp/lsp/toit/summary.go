// Copyright (C) 2020 Toitware ApS.
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

package toit

import (
	"sort"
	"strings"

	"github.com/sourcegraph/go-lsp"
)

type Module struct {
	URI             lsp.DocumentURI
	Dependencies    []lsp.DocumentURI
	ExportedModules []lsp.DocumentURI
	Exports         []*Export
	Classes         []*Class
	Functions       []*TopLevelFunction
	Globals         []*TopLevelFunction
	Toitdoc         *DocContents
}

func (m *Module) TopLevelElementByID(id ID) TopLevelElement {
	i := int(id)
	if i < len(m.Classes) {
		return m.Classes[i]
	}
	i -= len(m.Classes)
	if i < len(m.Functions) {
		return m.Functions[i]
	}
	i -= len(m.Functions)
	if i < len(m.Globals) {
		return m.Globals[i]
	}
	panic("ID was out of range of all elements")
}

func equalDocumentURIs(a, b []lsp.DocumentURI) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func equalsExports(a, b []*Export) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func equalClasses(a, b []*Class) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func equalTopLevelFunctions(a, b []*TopLevelFunction) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func equalMethods(a, b []*Method) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func equalFields(a, b []*Field) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func equalParameters(a, b []*Parameter) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func equalTopLevelReferences(a, b []*TopLevelReference) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].EqualsExternal(b[i]) {
			return false
		}
	}
	return true
}

func (m *Module) EqualsExternal(other *Module) bool {
	if m == nil {
		return other == nil
	}

	return other != nil &&
		m.URI == other.URI &&
		equalDocumentURIs(m.Dependencies, other.Dependencies) &&
		equalDocumentURIs(m.ExportedModules, other.ExportedModules) &&
		equalsExports(m.Exports, other.Exports) &&
		equalClasses(m.Classes, other.Classes) &&
		equalTopLevelFunctions(m.Functions, other.Functions) &&
		equalTopLevelFunctions(m.Globals, other.Globals)
}

func (m *Module) LSPDocumentSymbols(content string) []lsp.DocumentSymbol {
	lines := parseLines(content)
	var res []lsp.DocumentSymbol
	for _, c := range m.Classes {
		res = append(res, c.lspDocumentSymbol(lines))
	}
	for _, f := range m.Functions {
		res = append(res, f.lspDocumentSymbol(lines))
	}
	for _, g := range m.Globals {
		res = append(res, g.lspDocumentSymbol(lines))
	}
	return res
}

type ID int

type ExportKind int

const (
	ExportKindAmbiguous ExportKind = 0
	ExportKindNodes     ExportKind = 1
)

type Export struct {
	Name       string
	Kind       ExportKind
	References []*TopLevelReference
}

func (e *Export) EqualsExternal(other *Export) bool {
	if e == nil {
		return other == nil
	}

	return other != nil &&
		e.Name == other.Name &&
		e.Kind == other.Kind &&
		equalTopLevelReferences(e.References, other.References)
}

type Range struct {
	Start int
	End   int
}

func (r *Range) lspRange(lines Lines) lsp.Range {
	return lsp.Range{
		Start: lines.LSPPosition(r.Start),
		End:   lines.LSPPosition(r.End),
	}
}

type TopLevelReference struct {
	Module lsp.DocumentURI
	ID     ID
}

func (r *TopLevelReference) EqualsExternal(other *TopLevelReference) bool {
	if r == nil {
		return other == nil
	}

	return other != nil &&
		r.Module == other.Module &&
		r.ID == other.ID
}

type TypeKind int

const (
	TypeKindAny   = -1
	TypeKindNone  = -2
	TypeKindBlock = -3
	TypeKindClass = 0
)

var (
	TypeBlock = &Type{Kind: TypeKindBlock}
	TypeAny   = &Type{Kind: TypeKindAny}
	TypeNone  = &Type{Kind: TypeKindNone}
)

type Type struct {
	Kind     TypeKind
	ClassRef *TopLevelReference
}

func (t *Type) EqualsExternal(other *Type) bool {
	if t == nil {
		return other == nil
	}

	return other != nil &&
		t.Kind == other.Kind &&
		t.ClassRef.EqualsExternal(other.ClassRef)
}

type TopLevelElement interface {
	toplevelElement()
	GetName() string
	GetID() ID
}

type Class struct {
	Name         string
	Range        *Range
	TopLevelID   ID
	IsInterface  bool
	IsAbstract   bool
	SuperClass   *TopLevelReference
	Interfaces   []*TopLevelReference
	Statics      []*Method
	Constructors []*Method
	Factories    []*Method
	Fields       []*Field
	Methods      []*Method

	Toitdoc *DocContents
}

var _ TopLevelElement = (*Class)(nil)

func (c *Class) toplevelElement() {}
func (c *Class) GetName() string {
	return c.Name
}
func (c *Class) GetID() ID {
	return c.TopLevelID
}

func (c *Class) EqualsExternal(other *Class) bool {
	if c == nil {
		return other == nil
	}

	return other != nil &&
		c.Name == other.Name &&
		c.IsInterface == other.IsInterface &&
		c.IsAbstract == other.IsAbstract &&
		c.SuperClass.EqualsExternal(other.SuperClass) &&
		equalTopLevelReferences(c.Interfaces, other.Interfaces) &&
		equalMethods(c.Statics, other.Statics) &&
		equalMethods(c.Constructors, other.Constructors) &&
		equalMethods(c.Factories, other.Factories) &&
		equalFields(c.Fields, other.Fields) &&
		equalMethods(c.Methods, other.Methods)
}

func lspName(name string) string {
	if name != "" {
		return name
	}
	return "<Error>"
}

func (c *Class) lspDocumentSymbol(lines Lines) lsp.DocumentSymbol {
	var children []lsp.DocumentSymbol
	for _, ms := range [][]*Method{c.Statics, c.Constructors, c.Factories, c.Methods} {
		for _, m := range ms {
			if !m.IsSynthetic {
				children = append(children, m.lspDocumentSymbol(lines))
			}
		}
	}
	for _, f := range c.Fields {
		children = append(children, f.lspDocumentSymbol(lines))
	}

	var kind lsp.SymbolKind
	if c.IsInterface {
		kind = lsp.SKInterface
	} else {
		kind = lsp.SKClass
	}

	return lsp.DocumentSymbol{
		Name:           lspName(c.Name),
		Kind:           kind,
		Range:          c.Range.lspRange(lines),
		SelectionRange: c.Range.lspRange(lines),
		Children:       children,
	}
}

type MethodKind int

const (
	MethodKindInstance       MethodKind = 0
	MethodKindGlobalFunction MethodKind = 1
	MethodKindGlobal         MethodKind = 2
	MethodKindConstructor    MethodKind = 3
	MethodKindFactory        MethodKind = 4
)

func (k MethodKind) lspKind() lsp.SymbolKind {
	switch k {
	case MethodKindInstance:
		return lsp.SKMethod
	case MethodKindGlobalFunction:
		return lsp.SKFunction
	case MethodKindGlobal:
		return lsp.SKVariable
	case MethodKindFactory, MethodKindConstructor:
		return lsp.SKConstructor
	default:
		return lsp.SKMethod
	}
}

type Method struct {
	Name       string
	Range      *Range
	TopLevelID ID
	Kind       MethodKind
	Parameters []*Parameter
	ReturnType *Type

	IsSynthetic bool
	IsAbstract  bool
	Toitdoc     *DocContents
}

func (m *Method) EqualsExternal(other *Method) bool {
	if m == nil {
		return other == nil
	}
	return other != nil &&
		m.Name == other.Name &&
		m.Kind == other.Kind &&
		m.IsAbstract == other.IsAbstract &&
		equalParameters(m.Parameters, other.Parameters) &&
		m.ReturnType.EqualsExternal(other.ReturnType)
}

func (m *Method) lspDocumentSymbol(lines Lines) lsp.DocumentSymbol {
	var params []string
	for _, p := range m.Parameters {
		param := p.Name
		if p.IsNamed {
			param = "--" + param
		}
		if !p.IsRequired {
			param += "="
		}
		if p.Type == TypeBlock {
			param = "[" + param + "]"
		}
		params = append(params, param)
	}
	return lsp.DocumentSymbol{
		Name:           lspName(m.Name),
		Detail:         strings.Join(params, " "),
		Kind:           m.Kind.lspKind(),
		Range:          m.Range.lspRange(lines),
		SelectionRange: m.Range.lspRange(lines),
	}
}

func (m *Method) IsField() bool {
	return false
}

type TopLevelFunction struct {
	*Method
}

var _ TopLevelElement = (*TopLevelFunction)(nil)

func (f *TopLevelFunction) toplevelElement() {}
func (f *TopLevelFunction) EqualsExternal(other *TopLevelFunction) bool {
	return f.Method.EqualsExternal(other.Method)
}

func (f *TopLevelFunction) GetName() string {
	return f.Name
}
func (f *TopLevelFunction) GetID() ID {
	return f.TopLevelID
}

type Field struct {
	Name    string
	Range   *Range
	IsFinal bool
	Type    *Type
	Toitdoc *DocContents
}

func (f *Field) EqualsExternal(other *Field) bool {
	if f == nil {
		return other == nil
	}

	return other != nil &&
		f.Name == other.Name &&
		f.IsFinal == other.IsFinal &&
		f.Type.EqualsExternal(other.Type)
}

func (f *Field) lspDocumentSymbol(lines Lines) lsp.DocumentSymbol {
	return lsp.DocumentSymbol{
		Name:           lspName(f.Name),
		Kind:           lsp.SKField,
		Range:          f.Range.lspRange(lines),
		SelectionRange: f.Range.lspRange(lines),
	}
}

func (m *Field) IsField() bool {
	return true
}

type Parameter struct {
	Name          string
	OriginalIndex int
	IsRequired    bool
	IsNamed       bool
	Type          *Type
}

func (p *Parameter) EqualsExternal(other *Parameter) bool {
	if p == nil {
		return other == nil
	}

	return other != nil &&
		p.Name == other.Name &&
		p.IsRequired == other.IsRequired &&
		p.IsNamed == other.IsNamed &&
		p.Type.EqualsExternal(other.Type)
}

type Lines struct {
	Offsets []int
	lastHit int
}

func parseLines(content string) Lines {
	lines := Lines{}
	lines.Offsets = append(lines.Offsets, 0)
	i := 0
	for _, c := range content {
		i++
		if c == '\n' {
			lines.Offsets = append(lines.Offsets, i)
		}
	}
	lines.Offsets = append(lines.Offsets, len(content))
	return lines
}

func (l *Lines) LSPPosition(offset int) lsp.Position {
	if offset == -1 || offset >= l.Offsets[len(l.Offsets)-1] {
		return lsp.Position{}
	}

	search := l.Offsets[:]
	idx := 0
	if l.Offsets[l.lastHit] <= offset {
		search = l.Offsets[l.lastHit:]
		idx = l.lastHit
	}

	idx += FindLastGreaterThanIdx(search, offset)
	l.lastHit = idx
	return lsp.Position{
		Line:      idx,
		Character: offset - l.Offsets[idx],
	}
}

// FindLastGreaterThanIdx, returns the greatest index such that element at that slot is less than or equal to $needle.
func FindLastGreaterThanIdx(arr []int, needle int) int {
	idx := -1
	if len(arr) > 0 {
		if arr[0] == needle {
			idx = 0
		}
	}
	if idx < 0 {
		idx = sort.SearchInts(arr, needle)
		if idx == len(arr) || arr[idx] != needle {
			return idx - 1
		}
	}

	for next := idx; next < len(arr) && arr[next] == needle; next++ {
		idx = next
	}
	return idx
}
