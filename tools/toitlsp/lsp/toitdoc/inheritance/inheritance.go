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
	"sort"

	"github.com/sourcegraph/go-lsp"
	"github.com/toitware/toit.git/toitlsp/lsp/toit"
)

type InheritanceResult struct {
	// The toitdoc summaries.
	summaries Summaries

	// Keep track of whether a class is already done.
	done map[*toit.Class]struct{}

	// The map of each toit-member to its class.
	Holder map[ToitMember]*toit.Class

	// How deep in the hierarchy the class is located.
	// The Object class is at level 1.
	classDepth map[*toit.Class]int

	// For each class, the members that were Inherited.
	Inherited map[*toit.Class]InheritedMembers

	// For each method/field, the super members that were overridden/shadowed.
	// These entries are per class, as the same member could shadow different
	// super members depending on where it is in the hierarchy.
	// For example:
	// ```
	// class A:
	//    foo:
	// class B extends A:
	//    foo x=0:  // Overrides A.foo
	// class C extends B:
	//    foo:  // Overrides B.foo
	//    // Inherites B.foo, but B.foo doesn't shadow A.foo anymore, since
	//    // C.foo already does that.
	// ```
	// Shadowing can be full or partial. Currently there is no information on
	// the extend of the shadowing.
	Shadowed map[ShadowKey][]ToitMember
}

type ShadowKey struct {
	cls    *toit.Class
	member ToitMember
}

// computeInheritance.
// Computes the inheritance information for the toitdoc viewer.
// For each class computes the inherited members that are still accessible.
// For each method computes the super members that are shadowed.
func ComputeInheritance(summaries Summaries) *InheritanceResult {
	result := &InheritanceResult{
		summaries:  summaries,
		done:       map[*toit.Class]struct{}{},
		Holder:     map[ToitMember]*toit.Class{},
		classDepth: map[*toit.Class]int{},
		Inherited:  map[*toit.Class]InheritedMembers{},
		Shadowed:   map[ShadowKey][]ToitMember{},
	}
	result.doSummaries()
	// Sort the fields, so we have deterministic output.
	for _, inherited := range result.Inherited {
		result.sortInheritedMembers(inherited)
	}
	for _, superMembers := range result.Shadowed {
		result.sortMembers(superMembers)
	}
	return result
}

type Summaries map[lsp.DocumentURI]*toit.Module

// Either a toit.Method, a toit.Field.
type ToitMember interface {
	IsField() bool
}

// InheritedMember.
// A member that is visible in a subclass.
type InheritedMember struct {
	Member              *Member
	PartiallyShadowedBy []*Member
}

type MemberKind string

const (
	MemberKindField     MemberKind = "field"
	MemberKindMethod    MemberKind = "method"
	MemberKindInherited MemberKind = "inherited"
)

// Member.
// A member of a class. Can be either a Field, a Method, or an inherited member.
type Member struct {
	// Points to a toit.Method, toit.Field or InheritedMember
	target interface{}
	kind   MemberKind
}

func newMemberFromMethod(method *toit.Method) *Member {
	return &Member{
		target: method,
		kind:   MemberKindMethod,
	}
}

func newMemberFromField(field *toit.Field) *Member {
	return &Member{
		target: field,
		kind:   MemberKindField,
	}
}

func newMemberFromInherited(inherited *InheritedMember) *Member {
	return &Member{
		target: inherited,
		kind:   MemberKindInherited,
	}
}

func (m *Member) AsField() *toit.Field {
	return m.target.(*toit.Field)
}

func (m *Member) AsMethod() *toit.Method {
	return m.target.(*toit.Method)
}

func (m *Member) AsInherited() *InheritedMember {
	return m.target.(*InheritedMember)
}

func (m *Member) AsToitMember() ToitMember {
	if m.IsField() {
		return m.AsField()
	}
	if m.IsMethod() {
		return m.AsMethod()
	}
	return m.AsInherited().Member.AsToitMember()
}

func (m *Member) IsField() bool {
	return m.kind == MemberKindField
}

func (m *Member) IsMethod() bool {
	return m.kind == MemberKindMethod
}

func (m *Member) IsInherited() bool {
	return m.kind == MemberKindInherited
}

func (m *Member) GetName() string {
	if m.IsField() {
		return m.AsField().Name
	} else if m.IsMethod() {
		return m.AsMethod().Name
	}
	return m.AsInherited().GetName()
}

func (m *Member) ToString() string {
	if m.IsField() {
		return m.GetName()
	} else if m.IsMethod() {
		str := m.GetName()
		for _, param := range m.AsMethod().Parameters {
			pre := ""
			if param.IsNamed {
				pre = "--"
			}
			post := ""
			if param.Type.Kind == toit.TypeKindBlock {
				pre = "[" + pre
				post = "]"
			}
			if !param.IsRequired {
				post = "="
			}
			str += " " + pre + param.Name + post
		}
		return str
	} else {
		return "-" + m.AsInherited().Member.ToString()
	}
}

// toitMemberLess.
// A simple deterministic algorithm to sort members.
// The actual order isn't important, but we want to have a deterministic
// output.
func (ir *InheritanceResult) toitMemberLess(member1 ToitMember, member2 ToitMember) bool {
	holder1 := ir.Holder[member1]
	holder2 := ir.Holder[member2]
	holderDepth1 := ir.classDepth[holder1]
	holderDepth2 := ir.classDepth[holder2]
	if holderDepth1 != holderDepth2 {
		return holderDepth1 < holderDepth2
	}
	isField1 := member1.IsField()
	isField2 := member2.IsField()
	if isField1 != isField2 {
		// Methods are in front of fields.
		return !isField1
	}
	if isField1 {
		return member1.(*toit.Field).Name < member2.(*toit.Field).Name
	}
	method1 := member1.(*toit.Method)
	method2 := member2.(*toit.Method)
	if method1.Name != method2.Name {
		return method1.Name < method2.Name
	}
	shape1 := newMemberFromMethod(method1).makeShaped().shape
	shape2 := newMemberFromMethod(method2).makeShaped().shape
	if shape1.MinPositionalNonBlock != shape2.MinPositionalNonBlock {
		return shape1.MinPositionalNonBlock < shape2.MinPositionalNonBlock
	}
	if shape1.MaxPositionalNonBlock != shape2.MaxPositionalNonBlock {
		return shape1.MaxPositionalNonBlock < shape2.MaxPositionalNonBlock
	}
	if shape1.PositionalBlockCount != shape2.PositionalBlockCount {
		return shape1.PositionalBlockCount < shape2.PositionalBlockCount
	}
	if len(shape1.Named) != len(shape2.Named) {
		return len(shape1.Named) < len(shape2.Named)
	}
	for i := 0; i < len(shape1.Named); i++ {
		named1 := shape1.Named[i]
		named2 := shape2.Named[i]
		if named1.Name != named2.Name {
			return named1.Name < named2.Name
		}
		if named1.IsBlock != named2.IsBlock {
			return !named1.IsBlock
		}
		if named1.IsOptional != named2.IsOptional {
			return named1.IsOptional
		}
	}
	return false
}

func (ir *InheritanceResult) sortMembers(members []ToitMember) {
	sort.Slice(members, func(i int, j int) bool {
		member1 := members[i]
		member2 := members[j]
		return ir.toitMemberLess(member1, member2)
	})
}

func (ir *InheritanceResult) sortInheritedMembers(inherited InheritedMembers) {
	sort.Slice(inherited, func(i int, j int) bool {
		member1 := inherited[i].Member.AsToitMember()
		member2 := inherited[j].Member.AsToitMember()
		return ir.toitMemberLess(member1, member2)
	})
}

func newInheritedMember(member *Member, partiallyShadowedBy []*Member) *InheritedMember {
	if member.IsInherited() {
		panic("inherited member should not wrap another inherited member.")
	}
	return &InheritedMember{
		Member:              member,
		PartiallyShadowedBy: partiallyShadowedBy,
	}
}

func (im *InheritedMember) IsField() bool {
	return im.Member.IsField()
}

func (im *InheritedMember) IsMethod() bool {
	return im.Member.IsMethod()
}

func (im *InheritedMember) GetName() string {
	return im.Member.GetName()
}

type InheritedMembers []*InheritedMember

func (ir *InheritanceResult) markOverriding(cls *toit.Class, superMember *shapedMember, overriddenByList []*Member) {
	overridden := superMember.member.AsToitMember()
	for _, overriddenBy := range overriddenByList {
		clsToitMember := overriddenBy.AsToitMember()
		key := ShadowKey{
			cls:    cls,
			member: clsToitMember,
		}
		ir.Shadowed[key] = append(ir.Shadowed[key], overridden)
	}
}

func (ir *InheritanceResult) doSummaries() {
	for uri, module := range ir.summaries {
		ir.doModule(uri, module)
	}
}

func (ir *InheritanceResult) doModule(uri lsp.DocumentURI, module *toit.Module) {
	for _, cls := range module.Classes {
		ir.doClass(cls)
	}
}

func (ir *InheritanceResult) doClass(cls *toit.Class) {
	if ir.isDone(cls) {
		return
	}
	ir.done[cls] = struct{}{}

	for _, method := range cls.Methods {
		ir.Holder[method] = cls
	}
	for _, field := range cls.Fields {
		ir.Holder[field] = cls
	}

	if cls.SuperClass == nil {
		// No superclass.
		ir.classDepth[cls] = 1
		ir.Inherited[cls] = InheritedMembers{}
		return
	}

	superClass := ir.resolveClassRef(cls.SuperClass)
	// Do the superclass first, so we can use its inherited members and don't
	// need to recursively hunt for all members.
	ir.doClass(superClass)
	ir.classDepth[cls] = ir.classDepth[superClass] + 1

	// Build the shapedMembers of the super class.
	superShaped := map[string][]*shapedMember{}
	for _, method := range superClass.Methods {
		shaped := newMemberFromMethod(method).makeShaped()
		superShaped[shaped.name] = append(superShaped[shaped.name], shaped)
	}
	for _, field := range superClass.Fields {
		shaped := newMemberFromField(field).makeShaped()
		superShaped[shaped.name] = append(superShaped[shaped.name], shaped)
	}
	for _, inherited := range ir.Inherited[superClass] {
		shaped := newMemberFromInherited(inherited).makeShaped()
		superShaped[shaped.name] = append(superShaped[shaped.name], shaped)
	}

	clsShaped := map[string][]*shapedMember{}
	for _, method := range cls.Methods {
		shaped := newMemberFromMethod(method).makeShaped()
		clsShaped[shaped.name] = append(clsShaped[shaped.name], shaped)
	}
	for _, field := range cls.Fields {
		shaped := newMemberFromField(field).makeShaped()
		clsShaped[shaped.name] = append(clsShaped[shaped.name], shaped)
	}

	inherited := InheritedMembers{}
	for name, superMembers := range superShaped {
		clsMembers := clsShaped[name]
		if len(clsMembers) == 0 {
			// All superMembers are inherited.
			for _, superMember := range superMembers {
				if superMember.member.IsInherited() {
					inherited = append(inherited, superMember.member.AsInherited())
				} else {
					inherited =
						append(inherited, newInheritedMember(superMember.member, []*Member{}))
				}
			}
			continue
		}
		for _, superMember := range superMembers {
			partialOverriders := []*Member{}
			if superMember.member.IsInherited() {
				partialOverriders =
					superMember.member.AsInherited().PartiallyShadowedBy
				superMember = superMember.member.AsInherited().Member.makeShaped()
			}
			// This map will be filled by the `computeOverride` function.
			overriddenBy := overriddenByMap{}
			fullyOverridden := ir.computeOverride(superMember, partialOverriders, clsMembers, overriddenBy)
			overriddenByList := overriddenBy.toList()
			if !fullyOverridden {
				inherited = append(inherited, newInheritedMember(superMember.member, overriddenByList))
			}
			ir.markOverriding(cls, superMember, overriddenByList)
		}
	}
	ir.Inherited[cls] = inherited
}

func (ir *InheritanceResult) resolveClassRef(ref *toit.TopLevelReference) *toit.Class {
	targetSummary := ir.summaries[ref.Module]
	return targetSummary.TopLevelElementByID(ref.ID).(*toit.Class)
}

func (ir *InheritanceResult) isDone(cls *toit.Class) bool {
	_, ok := ir.done[cls]
	return ok
}
