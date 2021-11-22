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

package inheritance

import (
	"log"
	"strings"
	"testing"

	"github.com/sourcegraph/go-lsp"
	"github.com/stretchr/testify/assert"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
)

func parseMethod(str string) *toit.Method {
	parts := strings.Split(strings.Trim(str, " "), " ")
	name := parts[0]
	params := []*toit.Parameter{}
	for _, paramStr := range parts[1:] {
		isNamed := false
		isOptional := false
		paramType := toit.TypeAny
		if paramStr[0] == '[' {
			paramType = toit.TypeBlock
			paramStr = paramStr[1 : len(paramStr)-1]
		}
		if strings.HasSuffix(paramStr, "=") {
			isOptional = true
			paramStr = paramStr[:len(paramStr)-1]
		}
		if strings.HasPrefix(paramStr, "--") {
			isNamed = true
			paramStr = paramStr[2:]
		}
		params = append(params, &toit.Parameter{
			Name:       paramStr,
			IsRequired: !isOptional,
			Type:       paramType,
			IsNamed:    isNamed,
		})
	}
	return &toit.Method{
		Name:       name,
		Parameters: params,
	}
}

func parseModule(uri lsp.DocumentURI, str string) *toit.Module {
	lines := strings.Split(str, "\n")
	classes := []*toit.Class{}

	classIDs := map[string]int{}

	currentClassName := ""
	var currentSuperClass *toit.TopLevelReference
	currentMethods := []*toit.Method{}

	finishClass := func() {
		if currentClassName != "" {
			classIDs[currentClassName] = len(classes)
			classes = append(classes, &toit.Class{
				Name:       currentClassName,
				SuperClass: currentSuperClass,
				Methods:    currentMethods,
			})
		}
		currentClassName = ""
		currentSuperClass = nil
		currentMethods = []*toit.Method{}
	}
	for _, line := range lines {
		line = strings.Trim(line, ":")
		if strings.HasPrefix(line, "//") || strings.Trim(line, " ") == "" {
			continue
		}
		if !strings.HasPrefix(line, "class ") {
			currentMethods = append(currentMethods, parseMethod(line))
			continue
		}
		finishClass()
		parts := strings.Split(line, " ")
		currentClassName = parts[1]
		if len(parts) > 2 {
			if parts[2] != "extends" {
				log.Fatal("Syntax must be 'class name extends name'")
			}
			currentSuperClass = &toit.TopLevelReference{
				Module: uri,
				ID:     toit.ID(classIDs[parts[3]]),
			}
		}
	}
	finishClass()
	return &toit.Module{
		Classes: classes,
	}
}

const (
	moduleURI lsp.DocumentURI = lsp.DocumentURI("URI")
)

func createSummaries(moduleContent string) map[lsp.DocumentURI]*toit.Module {
	result := map[lsp.DocumentURI]*toit.Module{}
	lspURI := moduleURI
	result[lspURI] = parseModule(lspURI, moduleContent)
	return result
}

func Test_Inheritance(t *testing.T) {
	t.Run("No Shadow - different name", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo:

class B extends A:
  bar:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		assert.Len(t, inheritedA, 0)
		assert.Len(t, inheritedB, 1)
		foo := inheritedB[0]
		assert.Equal(t, "foo", foo.Member.ToString())
		assert.True(t, foo.Member.IsMethod())
		assert.True(t, foo.IsMethod())
		assert.Equal(t, classA.Methods[0], foo.Member.target)
		assert.Empty(t, foo.PartiallyShadowedBy)
		assert.Empty(t, result.Shadowed)
	})

	t.Run("No Shadow - different named - deep", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo:

class B extends A:
class C extends B:
class D extends C:
class E extends D:

class F extends E:
  bar:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		classC := classes[2]
		classD := classes[3]
		classE := classes[4]
		classF := classes[5]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		inheritedC := result.Inherited[classC]
		inheritedD := result.Inherited[classD]
		inheritedE := result.Inherited[classE]
		inheritedF := result.Inherited[classF]
		assert.Len(t, inheritedA, 0)
		assert.Len(t, inheritedB, 1)
		assert.Len(t, inheritedC, 1)
		assert.Len(t, inheritedD, 1)
		assert.Len(t, inheritedE, 1)
		assert.Len(t, inheritedF, 1)
		for _, inherited := range []InheritedMembers{
			inheritedB,
			inheritedC,
			inheritedD,
			inheritedE,
			inheritedF,
		} {
			foo := inherited[0]
			assert.Equal(t, "foo", foo.Member.ToString())
			assert.True(t, foo.Member.IsMethod())
			assert.True(t, foo.IsMethod())
			assert.Equal(t, classA.Methods[0], foo.Member.target)
			assert.Empty(t, foo.PartiallyShadowedBy)
			assert.Empty(t, result.Shadowed)
		}
	})

	t.Run("No Shadow - same name", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo:

class B extends A:
  foo x:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		assert.Len(t, inheritedA, 0)
		assert.Len(t, inheritedB, 1)
		foo := inheritedB[0]
		assert.Equal(t, "foo", foo.Member.ToString())
		assert.True(t, foo.Member.IsMethod())
		assert.True(t, foo.IsMethod())
		assert.Equal(t, classA.Methods[0], foo.Member.target)
		assert.Empty(t, foo.PartiallyShadowedBy)
		assert.Empty(t, result.Shadowed)
	})
	t.Run("Full override", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo x:

class B extends A:
  foo x:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		assert.Empty(t, inheritedA)
		assert.Empty(t, inheritedB)
		fooA := classA.Methods[0]
		fooB := classB.Methods[0]
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		overridingFooB := result.Shadowed[ShadowKey{
			cls:    classB,
			member: fooB,
		}]
		assert.Empty(t, overridingFooA)
		assert.Len(t, overridingFooB, 1)

		assert.Equal(t, overridingFooB[0], fooA)
	})
	t.Run("Partial override", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo x y=:

class B extends A:
  foo x:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		fooA := classA.Methods[0]
		fooB := classB.Methods[0]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		assert.Empty(t, inheritedA)
		assert.Len(t, inheritedB, 1)
		foo := inheritedB[0]
		assert.Equal(t, fooA, foo.Member.target)
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		overridingFooB := result.Shadowed[ShadowKey{
			cls:    classB,
			member: fooB,
		}]
		assert.Empty(t, overridingFooA)
		assert.Len(t, overridingFooB, 1)
		assert.Equal(t, overridingFooB[0], fooA)
	})
	t.Run("Partial override - multiple", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo x y=:

class B extends A:
  foo x:

class C extends B:
  foo x:

class D extends B:
  foo x:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		classC := classes[2]
		classD := classes[3]
		fooA := classA.Methods[0]
		fooB := classB.Methods[0]
		fooC := classC.Methods[0]
		fooD := classD.Methods[0]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		inheritedC := result.Inherited[classC]
		inheritedD := result.Inherited[classD]
		assert.Empty(t, inheritedA)
		assert.Len(t, inheritedB, 1)
		assert.Len(t, inheritedC, 1)
		assert.Len(t, inheritedD, 1)
		inheritedFooB := inheritedB[0]
		inheritedFooC := inheritedC[0]
		inheritedFooD := inheritedD[0]
		assert.Equal(t, fooA, inheritedFooB.Member.target)
		assert.Equal(t, fooA, inheritedFooC.Member.target)
		assert.Equal(t, fooA, inheritedFooD.Member.target)
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		overridingFooB := result.Shadowed[ShadowKey{
			cls:    classB,
			member: fooB,
		}]
		overridingFooC := result.Shadowed[ShadowKey{
			cls:    classC,
			member: fooC,
		}]
		overridingFooD := result.Shadowed[ShadowKey{
			cls:    classD,
			member: fooD,
		}]
		assert.Empty(t, overridingFooA)
		assert.Len(t, overridingFooB, 1)
		assert.Equal(t, overridingFooB[0], fooA)
		assert.Len(t, overridingFooC, 2)
		assert.Equal(t, overridingFooC[0], fooA)
		assert.Equal(t, overridingFooC[1], fooB)
		assert.Len(t, overridingFooD, 2)
		assert.Equal(t, overridingFooD[0], fooA)
		assert.Equal(t, overridingFooD[1], fooC)
	})

	t.Run("Partial override - twice", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo x y=:

class B extends A:
  foo x --named=:

class C extends B:
  foo x:

class D extends C:
  foo x y= --named=:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		classC := classes[2]
		classD := classes[3]
		fooA := classA.Methods[0]
		fooB := classB.Methods[0]
		fooC := classC.Methods[0]
		fooD := classD.Methods[0]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		inheritedC := result.Inherited[classC]
		inheritedD := result.Inherited[classD]
		assert.Empty(t, inheritedA)
		assert.Len(t, inheritedB, 1)
		assert.Len(t, inheritedC, 2)
		assert.Len(t, inheritedD, 0)
		inheritedFooB := inheritedB[0]
		inheritedFooC1 := inheritedC[0]
		inheritedFooC2 := inheritedC[1]
		assert.Equal(t, fooA, inheritedFooB.Member.target)
		assert.Equal(t, fooA, inheritedFooC1.Member.target)
		assert.Equal(t, fooB, inheritedFooC2.Member.target)
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		overridingFooB := result.Shadowed[ShadowKey{
			cls:    classB,
			member: fooB,
		}]
		overridingFooC := result.Shadowed[ShadowKey{
			cls:    classC,
			member: fooC,
		}]
		overridingFooD := result.Shadowed[ShadowKey{
			cls:    classD,
			member: fooD,
		}]
		assert.Empty(t, overridingFooA)
		assert.Len(t, overridingFooB, 1)
		assert.Equal(t, overridingFooB[0], fooA)
		assert.Len(t, overridingFooC, 2)
		assert.Equal(t, overridingFooC[0], fooA)
		assert.Equal(t, overridingFooC[1], fooB)
		assert.Len(t, overridingFooD, 3)
		assert.Equal(t, overridingFooD[0], fooA)
		assert.Equal(t, overridingFooD[1], fooB)
		assert.Equal(t, overridingFooD[2], fooC)
	})

	t.Run("Named", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo --a= --b= --c=:

class B extends A:
  foo --a --b --c:
  foo --a --b:
  foo --a --c:
  foo --a:
  foo --b --c:
  foo --b:
  foo --c:

class C extends B:
  foo:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		classC := classes[2]
		fooA := classA.Methods[0]
		fooBs := classB.Methods
		fooC := classC.Methods[0]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		inheritedC := result.Inherited[classC]
		assert.Empty(t, inheritedA)
		assert.Len(t, inheritedB, 1)
		assert.Len(t, inheritedC, 7)
		inheritedFooB := inheritedB[0]
		assert.Equal(t, fooA, inheritedFooB.Member.target)
		// The inherited methods are sorted. So we can ensure that they are
		// the same.
		expectedInherited := []*toit.Method{
			fooBs[3], // foo --a
			fooBs[5], // foo --b
			fooBs[6], // foo --c
			fooBs[1], // foo --a --b
			fooBs[2], // foo --a --c
			fooBs[4], // foo --b --c
			fooBs[0], // foo --a --b --c
		}
		for i, expected := range expectedInherited {
			assert.Equal(t, expected, inheritedC[i].Member.target)

		}
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		assert.Empty(t, overridingFooA)
		for _, fooB := range fooBs {
			overridingFooB := result.Shadowed[ShadowKey{
				cls:    classB,
				member: fooB,
			}]
			assert.Len(t, overridingFooB, 1)
			assert.Equal(t, overridingFooB[0], fooA)
		}

		overridingFooC := result.Shadowed[ShadowKey{
			cls:    classC,
			member: fooC,
		}]
		assert.Len(t, overridingFooC, 1)
		assert.Equal(t, overridingFooC[0], fooA)
	})

	t.Run("Named", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo opt= --a= --b= --c=:

class B extends A:
  foo --a --b --c:
  foo --a --b:
  foo --a --c:
  foo --a:
  foo --b --c:
  foo --b:
  foo --c:

class C extends B:
  foo:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		classC := classes[2]
		fooA := classA.Methods[0]
		fooBs := classB.Methods
		fooC := classC.Methods[0]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		inheritedC := result.Inherited[classC]
		assert.Empty(t, inheritedA)
		assert.Len(t, inheritedB, 1)
		assert.Len(t, inheritedC, 8)
		inheritedFooB := inheritedB[0]
		assert.Equal(t, fooA, inheritedFooB.Member.target)
		// The inherited methods are sorted. So we can ensure that they are
		// the same.
		expectedInherited := []*toit.Method{
			fooA,
			fooBs[3], // foo --a
			fooBs[5], // foo --b
			fooBs[6], // foo --c
			fooBs[1], // foo --a --b
			fooBs[2], // foo --a --c
			fooBs[4], // foo --b --c
			fooBs[0], // foo --a --b --c
		}
		for i, expected := range expectedInherited {
			assert.Equal(t, expected, inheritedC[i].Member.target)

		}
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		assert.Empty(t, overridingFooA)
		for _, fooB := range fooBs {
			overridingFooB := result.Shadowed[ShadowKey{
				cls:    classB,
				member: fooB,
			}]
			assert.Len(t, overridingFooB, 1)
			assert.Equal(t, overridingFooB[0], fooA)
		}

		overridingFooC := result.Shadowed[ShadowKey{
			cls:    classC,
			member: fooC,
		}]
		assert.Len(t, overridingFooC, 1)
		assert.Equal(t, overridingFooC[0], fooA)
	})

	t.Run("Named skipping optional", func(t *testing.T) {
		summaries := createSummaries(`
class A:
  foo --a --b= --z:

class B extends A:
  foo --a --x= --y= --z:
`)
		result := ComputeInheritance(summaries)
		classes := summaries[moduleURI].Classes
		classA := classes[0]
		classB := classes[1]
		fooA := classA.Methods[0]
		fooB := classB.Methods[0]
		inheritedA := result.Inherited[classA]
		inheritedB := result.Inherited[classB]
		assert.Empty(t, inheritedA)
		assert.Len(t, inheritedB, 1)
		assert.Equal(t, fooA, inheritedB[0].Member.target)
		overridingFooA := result.Shadowed[ShadowKey{
			cls:    classA,
			member: fooA,
		}]
		assert.Empty(t, overridingFooA)
		overridingFooB := result.Shadowed[ShadowKey{
			cls:    classB,
			member: fooB,
		}]
		assert.Len(t, overridingFooB, 1)
		assert.Equal(t, overridingFooB[0], fooA)
	})
}
