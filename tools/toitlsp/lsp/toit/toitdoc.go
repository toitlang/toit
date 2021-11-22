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

import "github.com/sourcegraph/go-lsp"

type DocContents struct {
	Sections []*DocSection
}

type DocSection struct {
	Title      string
	Statements []DocStatement
}

type DocStatement interface {
	doc_statement()
}

type DocCodeSection struct {
	Text string
}

func (*DocCodeSection) doc_statement() {}

type DocItemized struct {
	Items []*DocItem
}

func (*DocItemized) doc_statement() {}

type DocItem struct {
	Statements []DocStatement
}

type DocParagraph struct {
	Expressions []DocExpression
}

func (*DocParagraph) doc_statement() {}

type DocExpression interface {
	doc_expression()
}

type DocText struct {
	Text string
}

func (*DocText) doc_expression() {}

type DocCode struct {
	Text string
}

func (*DocCode) doc_expression() {}

// DocShape.
// A shape to identify methods.
// At this stage optional parameters aren't needed anymore. The shape thus
// treats all parameters as if they were required. This uniquely identifies
// a method (given the module, holder, and name).
type DocShape struct {
	Arity           int
	TotalBlockCount int
	NamedBlockCount int
	IsSetter        bool
	// Names.
	// Non-block first, in alphabetical order.
	// Then block parameters, also in alphabetical order.
	Names []string
}

type ToitDocReferenceKind int

func (kind ToitDocReferenceKind) IsMethodReference() bool {
	return ToitDocReferenceKindGlobalMethod <= kind && kind <= ToitDocReferenceKindMethod
}

func (kind ToitDocReferenceKind) HasHolder() bool {
	return kind >= ToitDocReferenceKindStaticMethod
}

const (
	ToitDocReferenceKindOther        ToitDocReferenceKind = 0
	ToitDocReferenceKindClass        ToitDocReferenceKind = 1
	ToitDocReferenceKindGlobal       ToitDocReferenceKind = 2
	ToitDocReferenceKindGlobalMethod ToitDocReferenceKind = 3
	ToitDocReferenceKindStaticMethod ToitDocReferenceKind = 4
	ToitDocReferenceKindConstructor  ToitDocReferenceKind = 5
	ToitDocReferenceKindFactory      ToitDocReferenceKind = 6
	ToitDocReferenceKindMethod       ToitDocReferenceKind = 7
	ToitDocReferenceKindField        ToitDocReferenceKind = 8
)

type ToitDocReference struct {
	Text      string
	Kind      ToitDocReferenceKind
	ModuleURI lsp.DocumentURI
	Holder    *string
	Name      string
	Shape     *DocShape
}

func (*ToitDocReference) doc_expression() {}
