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

package toitdoc

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
	"github.com/toitware/toit.git/toitlsp/lsp/toitdoc/inheritance"
	"github.com/toitware/toit.git/toitlsp/lsp/uri"
)

type ObjectType string

const (
	ObjectTypeSection              ObjectType = "section"
	ObjectTypeStatementCodeSection ObjectType = "statement_code_section"
	ObjectTypeStatementItemized    ObjectType = "statement_itemized"
	ObjectTypeStatementItem        ObjectType = "statement_item"
	ObjectTypeStatementParagraph   ObjectType = "statement_paragraph"
	ObjectTypeExpressionCode       ObjectType = "expression_code"
	ObjectTypeExpressionText       ObjectType = "expression_text"
	ObjectTypeShape                ObjectType = "shape"
	ObjectTypeToitdocref           ObjectType = "toitdocref"
	ObjectTypeFunction             ObjectType = "function"
	ObjectTypeParameter            ObjectType = "parameter"
	ObjectTypeField                ObjectType = "field"
	ObjectTypeClass                ObjectType = "class"
	ObjectTypeModule               ObjectType = "module"
	ObjectTypeGlobal               ObjectType = "global"
	ObjectTypeLibrary              ObjectType = "library"
	ObjectTypeType                 ObjectType = "type"
	ObjectTypeReference            ObjectType = "reference"
)

type Category string

const (
	CategoryFundamental Category = "fundamental"
	CategoryJustThere   Category = "just_there"
	CategoryMisc        Category = "misc"
	// CategorySub: a category for libraries that aren't at the top level.
	CategorySub Category = "sub"
)

func categoryForLibrary(segments []string) Category {
	if len(segments) == 1 {
		// Not really a sub category, but currently we have this
		// 'lib' segment/library that shouldn't be there.
		return CategorySub
	}
	// Segments start with "lib".
	first := segments[1]
	switch first {
	case
		"core",
		"crypto",
		"log",
		"math",
		"monitor":
		return CategoryFundamental
	case
		"binary",
		"bytes",
		"expect",
		"device",
		"gpio",
		"i2c",
		"metrics",
		"pubsub",
		"serial",
		"reader",
		"writer":
		return CategoryJustThere
	default:
		return CategoryMisc
	}
}

func isLibraryHidden(segments []string) bool {
	// Segments start with "lib".
	first := segments[1]
	switch first {
	case
		"coap",
		"cron",
		"debug",
		"experimental",
		"protogen",
		"rpc",
		"service_registry",
		"services",
		"words":
		return true
	case
		"encoding":
		if len(segments) == 3 && segments[2] == "tpack" {
			return true
		}
	}
	return false
}

type Doc struct {
	SDKVersion string    `json:"sdk_version"`
	Version    string    `json:"version"`
	Libraries  Libraries `json:"libraries"`
}

type Summaries map[lsp.DocumentURI]*toit.Module

type BuildOptions struct {
	RootPath       string
	Version        string
	SDKVersion     string
	Summaries      Summaries
	IncludePrivate bool
	ExcludeSDK     bool
	SDKURI         lsp.DocumentURI
}

func Build(o BuildOptions) *Doc {
	return newBuilder(o).build()
}

type builder struct {
	summaries   Summaries
	inheritance *inheritance.InheritanceResult
	rootPath    string
	sdkURI      lsp.DocumentURI

	sdkVersion     string
	version        string
	includePrivate bool
	excludeSDK     bool
}

func newBuilder(o BuildOptions) *builder {
	return &builder{
		summaries:      o.Summaries,
		rootPath:       o.RootPath,
		version:        o.Version,
		sdkVersion:     o.SDKVersion,
		includePrivate: o.IncludePrivate,
		excludeSDK:     o.ExcludeSDK,
		sdkURI:         o.SDKURI,
	}
}

func (b *builder) modulePathSegments(docuri lsp.DocumentURI) []string {
	if docuri == "" {
		return nil
	}
	p := uri.URIToPath(docuri)
	p = strings.TrimPrefix(p, b.rootPath)
	p = strings.TrimPrefix(p, string(os.PathSeparator))
	return strings.Split(p, string(os.PathSeparator))
}

func (b *builder) build() *Doc {
	b.inheritance = inheritance.ComputeInheritance(inheritance.Summaries(b.summaries))

	res := Doc{
		SDKVersion: b.sdkVersion,
		Version:    b.version,
		Libraries:  Libraries{},
	}

	for u, m := range b.summaries {
		if b.excludeSDK && strings.HasPrefix(string(u), string(b.sdkURI)) {
			continue
		}

		segments := b.modulePathSegments(u)
		moduleName := strings.TrimSuffix(segments[len(segments)-1], ".toit")
		segments = segments[:len(segments)-1]

		if isLibraryHidden(append(segments, moduleName)) {
			continue
		}

		sublibraries := res.Libraries
		var library Library

		for i, name := range segments {
			var ok bool
			library, ok = sublibraries[name]
			if !ok {
				library = Library{
					ObjectType: ObjectTypeLibrary,
					Name:       name,
					Path:       segments[:i],
					Libraries:  Libraries{},
					Modules:    Modules{},
					Category:   categoryForLibrary(segments[:i+1]),
				}
				sublibraries[name] = library
			}
			sublibraries = library.Libraries
		}

		if !b.includeElementWithName(moduleName) {
			continue
		}

		exports := computeModuleExports(u, b.summaries)
		classes, interfaces := b.classesAndInterfaces(m.Classes)
		exportClasses, exportInterfaces := b.refsToClassesAndInterfaces(exports.Classes)
		library.Modules[moduleName] = Module{
			ObjectType:       ObjectTypeModule,
			Name:             moduleName,
			IsPrivate:        IsPrivate(moduleName),
			Classes:          classes,
			Interfaces:       interfaces,
			ExportClasses:    exportClasses,
			ExportInterfaces: exportInterfaces,
			Functions:        b.functions(m.Functions),
			ExportFunctions:  b.refsToFunctions(exports.Functions),
			Globals:          b.globals(m.Globals),
			ExportGlobals:    b.refsToGlobals(exports.Globals),
			Toitdoc:          b.toitdoc(m.Toitdoc),
			Category:         categoryForLibrary(append(segments, moduleName)),
		}

	}

	return &res
}

func (b *builder) includeElementWithName(name string) bool {
	return b.includePrivate || !IsPrivate(name)
}

type Libraries map[string]Library

type Modules map[string]Module

type Path []string

type Library struct {
	ObjectType ObjectType `json:"object_type"`
	Name       string     `json:"name"`
	Path       Path       `json:"path"`
	Libraries  Libraries  `json:"libraries"`
	Modules    Modules    `json:"modules"`
	Category   Category   `json:"category"`
}

type Module struct {
	ObjectType       ObjectType  `json:"object_type"`
	Name             string      `json:"name"`
	IsPrivate        bool        `json:"is_private"`
	Classes          Classes     `json:"classes"`
	Interfaces       Classes     `json:"interfaces"`
	ExportClasses    Classes     `json:"export_classes"`
	ExportInterfaces Classes     `json:"export_interfaces"`
	Functions        Functions   `json:"functions"`
	ExportFunctions  Functions   `json:"export_functions"`
	Globals          Globals     `json:"globals"`
	ExportGlobals    Globals     `json:"export_globals"`
	Toitdoc          DocContents `json:"toitdoc"`
	Category         Category    `json:"category"`
}

type Classes []Class

func (b *builder) classesAndInterfaces(classes []*toit.Class) (Classes, Classes) {
	resClasses := Classes{}
	resInterfaces := Classes{}
	for _, class := range classes {
		if !b.includeClass(class) {
			continue
		}
		if class.IsInterface {
			resInterfaces = append(resInterfaces, b.class(class, nil))
		} else {
			resClasses = append(resClasses, b.class(class, nil))
		}
	}
	return resClasses, resInterfaces
}

func (b *builder) refsToClassesAndInterfaces(refs []*toit.TopLevelReference) (Classes, Classes) {
	resClasses := Classes{}
	resInterfaces := Classes{}
	for i := range refs {
		ref := refs[i]
		class := b.summaries[ref.Module].TopLevelElementByID(ref.ID).(*toit.Class)
		if !b.includeClass(class) {
			continue
		}
		if class.IsInterface {
			resInterfaces = append(resInterfaces, b.class(class, ref))
		} else {
			resClasses = append(resClasses, b.class(class, ref))
		}
	}
	return resClasses, resInterfaces
}

func (b *builder) includeClass(class *toit.Class) bool {
	return b.includeElementWithName(class.Name)
}

type Class struct {
	ObjectType   ObjectType         `json:"object_type"`
	Name         string             `json:"name"`
	IsAbstract   bool               `json:"is_abstract"`
	IsInterface  bool               `json:"is_interface"`
	IsPrivate    bool               `json:"is_private"`
	ExportedFrom *TopLevelReference `json:"exported_from"`
	Toitdoc      DocContents        `json:"toitdoc"`
	Interfaces   TopLevelReferences `json:"interfaces"`
	Extends      *TopLevelReference `json:"extends"`
	Structure    ClassStructure     `json:"structure"`
}

func (b *builder) class(class *toit.Class, exportRef *toit.TopLevelReference) Class {
	fields := b.fields(class.Fields)
	methods := b.methods(class.Methods)
	if inherited, ok := b.inheritance.Inherited[class]; ok {
		inheritedFields := []*toit.Field{}
		inheritedMethods := []*toit.Method{}
		for _, member := range inherited {
			if member.IsField() {
				inheritedFields = append(inheritedFields, member.Member.AsField())
			} else {
				inheritedMethods = append(inheritedMethods, member.Member.AsMethod())
			}
		}
		convertedFields := b.fields(inheritedFields)
		for i := 0; i < len(convertedFields); i++ {
			convertedFields[i].IsInherited = true
		}
		fields = append(fields, convertedFields...)
		convertedMethods := b.methods(inheritedMethods)
		for i := 0; i < len(convertedMethods); i++ {
			convertedMethods[i].IsInherited = true
		}
		methods = append(methods, convertedMethods...)
	}

	// According to the summary interfaces also implement themselves.
	// We don't want that in the toitdoc, so we remove them here.
	interfaces := class.Interfaces
	if class.IsInterface {
		filteredInterfaces := []*toit.TopLevelReference{}
		alreadyRemoved := false
		for _, inter := range interfaces {
			if !alreadyRemoved {
				targetSummary := b.summaries[inter.Module]
				targetClass := targetSummary.TopLevelElementByID(inter.ID)
				if targetClass == class {
					alreadyRemoved = true
					continue
				}
			}
			filteredInterfaces = append(filteredInterfaces, inter)
		}
		interfaces = filteredInterfaces
	}
	return Class{
		ObjectType:   ObjectTypeClass,
		Name:         class.Name,
		IsAbstract:   class.IsAbstract,
		IsInterface:  class.IsInterface,
		IsPrivate:    IsPrivate(class.Name),
		ExportedFrom: b.exportedFrom(exportRef),
		Toitdoc:      b.toitdoc(class.Toitdoc),
		Interfaces:   b.topLevelReferences(interfaces),
		Extends:      b.topLevelReference(class.SuperClass, nil),
		Structure: ClassStructure{
			Statics:      b.methods(class.Statics),
			Constructors: b.methods(class.Constructors),
			Factories:    b.methods(class.Factories),
			Fields:       fields,
			Methods:      methods,
		},
	}
}

type ClassStructure struct {
	Statics      Functions `json:"statics"`
	Constructors Functions `json:"constructors"`
	Factories    Functions `json:"factories"`
	Fields       Fields    `json:"fields"`
	Methods      Functions `json:"methods"`
}

type Functions []Function

func (b *builder) functions(functions []*toit.TopLevelFunction) Functions {
	res := Functions{}
	for _, f := range functions {
		if !b.includeMethod(f.Method) {
			continue
		}
		res = append(res, b.function(f, nil))
	}
	return res
}

func (b *builder) refsToFunctions(refs []*toit.TopLevelReference) Functions {
	res := Functions{}
	for i := range refs {
		ref := refs[i]
		fn := b.summaries[ref.Module].TopLevelElementByID(ref.ID).(*toit.TopLevelFunction)
		if !b.includeMethod(fn.Method) {
			continue
		}
		res = append(res, b.function(fn, ref))
	}
	return res
}

func (b *builder) methods(methods []*toit.Method) Functions {
	res := Functions{}
	for _, f := range methods {
		if !b.includeMethod(f) {
			continue
		}
		res = append(res, b.method(f, nil))
	}
	return res
}

func (b *builder) includeMethod(method *toit.Method) bool {
	return !method.IsSynthetic && b.includeElementWithName(method.Name)
}

type Function struct {
	ObjectType   ObjectType         `json:"object_type"`
	Name         string             `json:"name"`
	IsPrivate    bool               `json:"is_private"`
	IsAbstract   bool               `json:"is_abstract"`
	IsSynthetic  bool               `json:"synthetic"`
	ExportedFrom *TopLevelReference `json:"exported_from"`
	Parameters   Parameters         `json:"parameters"`
	ReturnType   *Type              `json:"return_type"`
	Toitdoc      DocContents        `json:"toitdoc"`
	Shape        Shape              `json:"shape"`
	IsInherited  bool               `json:"is_inherited"`
}

func (b *builder) function(fn *toit.TopLevelFunction, exportRef *toit.TopLevelReference) Function {
	return b.method(fn.Method, exportRef)
}

func (b *builder) method(m *toit.Method, exportRef *toit.TopLevelReference) Function {
	return Function{
		ObjectType:   ObjectTypeFunction,
		Name:         m.Name,
		IsPrivate:    IsPrivate(m.Name),
		IsAbstract:   m.IsAbstract,
		IsSynthetic:  m.IsSynthetic,
		ExportedFrom: b.exportedFrom(exportRef),
		Parameters:   b.parameters(m.Parameters),
		ReturnType:   b.typ(m.ReturnType),
		Toitdoc:      b.toitdoc(m.Toitdoc),
		Shape:        b.shape(m),
	}
}

// Shape.
// A shape to identify methods.
// At this stage optional parameters aren't needed anymore. The shape thus
// treats all parameters as if they were required. This uniquely identifies
// a method (given the module, holder, and name).
//
// For simplicity this shape is used here, and in the toitdoc references. This
// way it's easier to match them up.
type Shape struct {
	ObjectType      ObjectType `json:"object_type"`
	Arity           int        `json:"arity"`
	TotalBlockCount int        `json:"total_block_count"`
	NamedBlockCount int        `json:"named_block_count"`
	// TODO(florian): this field should be deleted.
	// The setter is now part of the name.
	IsSetter bool `json:"is_setter"`
	// Names.
	// Non-block first, in alphabetical order.
	// Then block parameters, also in alphabetical order.
	Names []string `json:"names"`
}

func (b *builder) shape(fun *toit.Method) Shape {
	arity := len(fun.Parameters)
	totalBlockCount := 0
	namedBlockCount := 0
	nonBlockNames := []string{}
	blockNames := []string{}
	for _, param := range fun.Parameters {
		isBlock := param.Type == toit.TypeBlock
		if isBlock {
			totalBlockCount++
		}
		if !param.IsNamed {
			continue
		}
		if isBlock {
			namedBlockCount++
			blockNames = append(blockNames, param.Name)
		} else {
			nonBlockNames = append(nonBlockNames, param.Name)
		}
	}
	sort.Strings(blockNames)
	sort.Strings(nonBlockNames)
	return Shape{
		ObjectType:      ObjectTypeShape,
		Arity:           arity,
		TotalBlockCount: totalBlockCount,
		NamedBlockCount: namedBlockCount,
		IsSetter:        false,
		Names:           append(nonBlockNames, blockNames...),
	}
}

type Globals []Global

func (b *builder) globals(globals []*toit.TopLevelFunction) Globals {
	res := Globals{}
	for _, g := range globals {
		if !b.includeMethod(g.Method) {
			continue
		}
		res = append(res, b.global(g, nil))
	}
	return res
}

func (b *builder) refsToGlobals(refs []*toit.TopLevelReference) Globals {
	res := Globals{}
	for i := range refs {
		ref := refs[i]
		fn := b.summaries[ref.Module].TopLevelElementByID(ref.ID).(*toit.TopLevelFunction)
		if !b.includeMethod(fn.Method) {
			continue
		}
		res = append(res, b.global(fn, ref))
	}
	return res
}

type Global struct {
	ObjectType   ObjectType         `json:"object_type"`
	Name         string             `json:"name"`
	IsPrivate    bool               `json:"is_private"`
	ExportedFrom *TopLevelReference `json:"exported_from"`
	Toitdoc      DocContents        `json:"toitdoc"`
	Type         *Type              `json:"type"`
}

func (b *builder) global(m *toit.TopLevelFunction, exportRef *toit.TopLevelReference) Global {
	return Global{
		ObjectType:   ObjectTypeGlobal,
		Name:         m.Name,
		IsPrivate:    IsPrivate(m.Name),
		ExportedFrom: b.exportedFrom(exportRef),
		Toitdoc:      b.toitdoc(m.Toitdoc),
		Type:         b.typ(m.ReturnType),
	}
}

type Fields []Field

func (b *builder) fields(fields []*toit.Field) Fields {
	res := Fields{}
	for _, f := range fields {
		if !b.includeField(f) {
			continue
		}
		res = append(res, b.field(f))
	}
	return res
}

func (b *builder) includeField(field *toit.Field) bool {
	return b.includeElementWithName(field.Name)
}

type Field struct {
	ObjectType  ObjectType  `json:"object_type"`
	Name        string      `json:"name"`
	IsPrivate   bool        `json:"is_private"`
	Type        *Type       `json:"type"`
	Toitdoc     DocContents `json:"toitdoc"`
	IsInherited bool        `json:"is_inherited"`
}

func (b *builder) field(f *toit.Field) Field {
	return Field{
		ObjectType: ObjectTypeField,
		Name:       f.Name,
		IsPrivate:  IsPrivate(f.Name),
		Type:       b.typ(f.Type),
		Toitdoc:    b.toitdoc(f.Toitdoc),
	}
}

type TopLevelReferences []TopLevelReference

func (b *builder) topLevelReferences(refs []*toit.TopLevelReference) TopLevelReferences {
	res := TopLevelReferences{}
	for _, ref := range refs {
		r := b.topLevelReference(ref, nil)
		if r != nil {
			res = append(res, *r)
		}
	}
	return res
}

type TopLevelReference struct {
	ObjectType ObjectType `json:"object_type"`
	Name       string     `json:"name"`
	Path       Path       `json:"path"`
}

func (b *builder) topLevelReference(ref *toit.TopLevelReference, nameOverride *string) *TopLevelReference {
	if ref == nil {
		return nil
	}

	targetSummary := b.summaries[ref.Module]
	var name string
	if nameOverride != nil {
		name = *nameOverride
	} else {
		name = targetSummary.TopLevelElementByID(ref.ID).GetName()
	}

	if !b.includeElementWithName(name) {
		return nil
	}

	return &TopLevelReference{
		ObjectType: ObjectTypeReference,
		Name:       name,
		Path:       b.modulePathSegments(ref.Module),
	}
}

func (b *builder) exportedFrom(ref *toit.TopLevelReference) *TopLevelReference {
	if ref == nil {
		return nil
	}

	segments := b.modulePathSegments(ref.Module)
	name := segments[len(segments)-1]
	return b.topLevelReference(ref, &name)
}

type Type struct {
	ObjectType ObjectType         `json:"object_type"`
	IsNone     bool               `json:"is_none"`
	IsAny      bool               `json:"is_any"`
	IsBlock    bool               `json:"is_block"`
	Reference  *TopLevelReference `json:"reference"`
}

func (b *builder) typ(t *toit.Type) *Type {
	if t == nil {
		return nil
	}

	return &Type{
		ObjectType: ObjectTypeType,
		IsNone:     t == toit.TypeNone,
		IsAny:      t == toit.TypeAny,
		IsBlock:    t == toit.TypeBlock,
		Reference:  b.topLevelReference(t.ClassRef, nil),
	}
}

type Parameters []Parameter

func (b *builder) parameters(params []*toit.Parameter) Parameters {
	// Provide the parameters in the same order as the user wrote them.
	sorted := append([]*toit.Parameter{}, params...)
	sort.SliceStable(sorted, func(i int, j int) bool {
		return sorted[i].OriginalIndex < sorted[j].OriginalIndex
	})
	res := Parameters{}
	for _, param := range sorted {
		res = append(res, b.parameter(param))
	}
	return res
}

type Parameter struct {
	ObjectType ObjectType `json:"object_type"`
	Name       string     `json:"name"`
	IsBlock    bool       `json:"is_block"`
	IsNamed    bool       `json:"is_named"`
	IsRequired bool       `json:"is_required"`
	Type       *Type      `json:"type"`
}

func (b *builder) parameter(param *toit.Parameter) Parameter {
	return Parameter{
		ObjectType: ObjectTypeParameter,
		Name:       param.Name,
		IsBlock:    param.Type == toit.TypeBlock,
		IsNamed:    param.IsNamed,
		IsRequired: param.IsRequired,
		Type:       b.typ(param.Type),
	}
}

type DocContents []DocSection

func (b *builder) toitdoc(doc *toit.DocContents) DocContents {
	if doc == nil {
		return nil
	}

	var res DocContents
	for _, s := range doc.Sections {
		res = append(res, b.docSection(s))
	}

	return res
}

type DocSection struct {
	ObjectType ObjectType    `json:"object_type"`
	Title      string        `json:"title"`
	Statements DocStatements `json:"statements"`
}

func (b *builder) docSection(section *toit.DocSection) DocSection {
	return DocSection{
		ObjectType: ObjectTypeSection,
		Title:      section.Title,
		Statements: b.docStatements(section.Statements),
	}
}

type DocStatements []DocStatement

func (b *builder) docStatements(statements []toit.DocStatement) DocStatements {
	res := DocStatements{}
	for _, stmt := range statements {
		res = append(res, b.docStatement(stmt))
	}
	return res
}

type DocStatement interface {
	docStatement()
}

func (b *builder) docStatement(statement toit.DocStatement) DocStatement {
	switch t := statement.(type) {
	case *toit.DocCodeSection:
		return b.docCodeSection(t)
	case *toit.DocItemized:
		return b.docItemized(t)
	case *toit.DocParagraph:
		return b.docParagraph(t)
	default:
		panic(fmt.Sprintf("unhandled statement type: '%T'", statement))
	}
}

type DocCodeSection struct {
	ObjectType ObjectType `json:"object_type"`
	Text       string     `json:"text"`
}

func (DocCodeSection) docStatement() {}

func (b *builder) docCodeSection(codeSection *toit.DocCodeSection) DocCodeSection {
	return DocCodeSection{
		ObjectType: ObjectTypeStatementCodeSection,
		Text:       codeSection.Text,
	}
}

type DocItemized struct {
	ObjectType ObjectType `json:"object_type"`
	Items      DocItems   `json:"items"`
}

func (DocItemized) docStatement() {}

func (b *builder) docItemized(i *toit.DocItemized) DocItemized {
	return DocItemized{
		ObjectType: ObjectTypeStatementItemized,
		Items:      b.docItems(i.Items),
	}
}

type DocItems []DocItem

func (b *builder) docItems(items []*toit.DocItem) DocItems {
	res := DocItems{}
	for _, item := range items {
		res = append(res, b.docItem(item))
	}
	return res
}

type DocItem struct {
	ObjectType ObjectType    `json:"object_type"`
	Statements DocStatements `json:"statements"`
}

func (b *builder) docItem(item *toit.DocItem) DocItem {
	return DocItem{
		ObjectType: ObjectTypeStatementItem,
		Statements: b.docStatements(item.Statements),
	}
}

type DocParagraph struct {
	ObjectType  ObjectType     `json:"object_type"`
	Expressions DocExpressions `json:"expressions"`
}

func (DocParagraph) docStatement() {}

func (b *builder) docParagraph(p *toit.DocParagraph) DocParagraph {
	return DocParagraph{
		ObjectType:  ObjectTypeStatementParagraph,
		Expressions: b.docExpressions(p.Expressions),
	}
}

type DocExpressions []DocExpression

func (b *builder) docExpressions(expressions []toit.DocExpression) DocExpressions {
	res := DocExpressions{}
	for _, expr := range expressions {
		res = append(res, b.docExpression(expr))
	}
	return res
}

type DocExpression interface {
	docExpression()
}

func (b *builder) docExpression(expression toit.DocExpression) DocExpression {
	switch t := expression.(type) {
	case *toit.DocCode:
		return b.docCode(t)
	case *toit.DocText:
		return b.docText(t)
	case *toit.ToitDocReference:
		return b.toitDocReference(t)
	default:
		panic(fmt.Sprintf("unhandled expression type: '%T'", expression))
	}
}

type DocCode struct {
	ObjectType ObjectType `json:"object_type"`
	Text       string     `json:"text"`
}

func (DocCode) docExpression() {}

func (b *builder) docCode(code *toit.DocCode) DocCode {
	return DocCode{
		ObjectType: ObjectTypeExpressionCode,
		Text:       code.Text,
	}
}

type DocText struct {
	ObjectType ObjectType `json:"object_type"`
	Text       string     `json:"text"`
}

func (DocText) docExpression() {}

func (b *builder) docText(code *toit.DocText) DocCode {
	return DocCode{
		ObjectType: ObjectTypeExpressionText,
		Text:       code.Text,
	}
}

func (b *builder) docShape(shape *toit.DocShape) *Shape {
	if shape == nil {
		return nil
	}
	return &Shape{
		ObjectType:      ObjectTypeShape,
		Arity:           shape.Arity,
		TotalBlockCount: shape.TotalBlockCount,
		NamedBlockCount: shape.NamedBlockCount,
		// TODO(florian): The setter is already included in the name.
		// This field should be deleted.
		IsSetter: false,
		Names:    shape.Names,
	}
}

type ToitDocReferenceKind string

const (
	ToitDocReferenceKindOther        ToitDocReferenceKind = "other"
	ToitDocReferenceKindClass        ToitDocReferenceKind = "class"
	ToitDocReferenceKindGlobal       ToitDocReferenceKind = "global"
	ToitDocReferenceKindGlobalMethod ToitDocReferenceKind = "global-method"
	ToitDocReferenceKindStaticMethod ToitDocReferenceKind = "static-method"
	ToitDocReferenceKindConstructor  ToitDocReferenceKind = "constructor"
	ToitDocReferenceKindFactory      ToitDocReferenceKind = "factory"
	ToitDocReferenceKindMethod       ToitDocReferenceKind = "method"
	ToitDocReferenceKindField        ToitDocReferenceKind = "field"
	// Should never happen and yield an error in the viewer.
	ToitDocReferenceKindUnknown ToitDocReferenceKind = ""
)

type ToitDocReference struct {
	ObjectType ObjectType           `json:"object_type"`
	Kind       ToitDocReferenceKind `json:"kind"`
	Text       string               `json:"text"`
	Path       Path                 `json:"path"`
	Holder     *string              `json:"holder"`
	Name       string               `json:"name"`
	Shape      *Shape               `json:"shape"`
}

func (ToitDocReference) docExpression() {}

func (b *builder) toitDocReferenceKind(kind toit.ToitDocReferenceKind) ToitDocReferenceKind {
	switch kind {
	case toit.ToitDocReferenceKindOther:
		return ToitDocReferenceKindOther
	case toit.ToitDocReferenceKindClass:
		return ToitDocReferenceKindClass
	case toit.ToitDocReferenceKindGlobal:
		return ToitDocReferenceKindGlobal
	case toit.ToitDocReferenceKindGlobalMethod:
		return ToitDocReferenceKindGlobalMethod
	case toit.ToitDocReferenceKindStaticMethod:
		return ToitDocReferenceKindStaticMethod
	case toit.ToitDocReferenceKindConstructor:
		return ToitDocReferenceKindConstructor
	case toit.ToitDocReferenceKindFactory:
		return ToitDocReferenceKindFactory
	case toit.ToitDocReferenceKindMethod:
		return ToitDocReferenceKindMethod
	case toit.ToitDocReferenceKindField:
		return ToitDocReferenceKindField
	default:
		return ToitDocReferenceKindUnknown
	}
}

func (b *builder) toitDocReference(ref *toit.ToitDocReference) ToitDocReference {
	name := ref.Name
	if ref.Shape != nil && ref.Shape.IsSetter {
		name += "="
	}
	return ToitDocReference{
		ObjectType: ObjectTypeToitdocref,
		Kind:       b.toitDocReferenceKind(ref.Kind),
		Text:       ref.Text,
		Path:       b.modulePathSegments(ref.ModuleURI),
		Holder:     ref.Holder,
		Name:       name,
		Shape:      b.docShape(ref.Shape),
	}
}
