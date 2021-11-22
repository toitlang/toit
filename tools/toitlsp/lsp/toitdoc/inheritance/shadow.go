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
	"sort"
	"strings"

	"github.com/toitware/toit.git/toitlsp/lsp/toit"
)

type overriddenByMap map[*Member]struct{}

func (m overriddenByMap) addAllShaped(shaped []shapedMember) {
	for _, shaped := range shaped {
		m[shaped.member] = struct{}{}
	}
}

func (m overriddenByMap) addAllIndexed(indexed []shapedMemberIterator) {
	for _, entry := range indexed {
		m[entry.shapedMember.member] = struct{}{}
	}
}

func (m overriddenByMap) addAll(members []*Member) {
	for _, member := range members {
		m[member] = struct{}{}
	}
}

func (m overriddenByMap) toList() []*Member {
	result := []*Member{}
	for overriddenBy := range m {
		result = append(result, overriddenBy)
	}
	return result
}

type namedParam struct {
	Name       string
	IsBlock    bool
	IsOptional bool
}

func (np namedParam) isValid() bool {
	return np.Name != ""
}

type shape struct {
	MinPositionalNonBlock int
	MaxPositionalNonBlock int
	PositionalBlockCount  int
	IsSetter              bool
	IsField               bool // If it's a field, then `IsSetter` is false.
	// Alphabetically sorted list of named parameters.
	Named []namedParam
}

type shapedMember struct {
	name   string
	member *Member
	shape  shape
}

func (m *Member) makeShaped() *shapedMember {
	if m.IsField() {
		return &shapedMember{
			name:   m.AsField().Name,
			member: m,
			shape: shape{
				MinPositionalNonBlock: 0,
				MaxPositionalNonBlock: 0,
				PositionalBlockCount:  0,
				IsSetter:              false,
				IsField:               true,
				Named:                 []namedParam{},
			},
		}
	}
	if m.IsMethod() {
		method := m.AsMethod()
		isSetter := strings.HasSuffix(method.Name, "=")
		name := method.Name
		if isSetter {
			name = strings.TrimSuffix(name, "=")
		}
		params := method.Parameters
		minPositional := 0
		maxPositional := 0
		positionalBlockCount := 0
		named := []namedParam{}
		for _, param := range params {
			isBlock := param.Type.Kind == toit.TypeKindBlock
			isOptional := !param.IsRequired
			if param.IsNamed {
				named = append(named, namedParam{
					Name:       param.Name,
					IsBlock:    isBlock,
					IsOptional: isOptional,
				})
				continue
			}
			if isBlock {
				positionalBlockCount++
				continue
			}
			maxPositional++
			if !isOptional {
				minPositional++
			}
		}
		sort.Slice(named, func(i1 int, i2 int) bool {
			return named[i1].Name < named[i2].Name
		})
		return &shapedMember{
			name:   name,
			member: m,
			shape: shape{
				MinPositionalNonBlock: minPositional,
				MaxPositionalNonBlock: maxPositional,
				PositionalBlockCount:  positionalBlockCount,
				IsSetter:              isSetter,
				IsField:               false,
				Named:                 named,
			},
		}
	}
	// The shape of the inherited is the same as the one of the member,
	result := m.AsInherited().Member.makeShaped()
	result.member = m
	return result
}

func isGetterShape(shape shape) bool {
	if shape.IsSetter {
		return false
	}
	if shape.IsField {
		return true
	}

	if shape.MinPositionalNonBlock != 0 || shape.PositionalBlockCount != 0 {
		return false
	}

	for _, named := range shape.Named {
		if !named.IsOptional {
			return false
		}
	}
	return true
}

func (shaped *shapedMember) iterator() shapedMemberIterator {
	return shapedMemberIterator{
		shapedMember: shaped,
		index:        0,
	}
}

// shapedMemberIterator.
// A shaped member with an index at which named parameter we are looking at.
// It is valid to read the shaped member out of the instance.
type shapedMemberIterator struct {
	shapedMember *shapedMember
	index        int
}

func (iter *shapedMemberIterator) current() namedParam {
	named := iter.shapedMember.shape.Named
	if iter.index < len(named) {
		return named[iter.index]
	}
	return namedParam{}
}

func (iter *shapedMemberIterator) advance() {
	named := iter.shapedMember.shape.Named
	if iter.index < len(named) {
		iter.index++
	}
}

func toIterators(members []*shapedMember) []shapedMemberIterator {
	result := []shapedMemberIterator{}
	for _, m := range members {
		result = append(result, m.iterator())
	}
	return result
}

// positionalPhaseComputeOverride.
// We know that all old overriders (partial shadowing the super member in a
// different superclass) and new overriders (from the class we are looking at)
// all override (at least partially) the super member.
// We just need to see "how much" they override the super member (complete or
// partial), and whether the old partial overriders are still relevant.
// Fills the overriddenBy map with all members (old and new) that shadow the
// super member.
// Returns whether the super member is fully shadowed. Note that this function
// is called for different branches of overlaps. The returned
// result is only true for the current branch.
func (ir *InheritanceResult) positionalPhaseComputeOverride(superIter shapedMemberIterator, oldIters []shapedMemberIterator, newIters []shapedMemberIterator, overriddenBy overriddenByMap) bool {
	// Note that the new overriders may have overlapping regions as they
	// don't need to be from the same class. However, the new overriders can't
	// overlap as that would make calls ambiguous. If they mistakenly overlap
	// the algorithm still terminates but might yield a bad result.
	// We also know that all functions here have at least some overlap with
	// the super member as we filtered at the beginning of the whole process.

	superMin := superIter.shapedMember.shape.MinPositionalNonBlock
	superMax := superIter.shapedMember.shape.MaxPositionalNonBlock

	// A list where we mark which arities are handled by the
	// overriding methods.
	// We use 1 for being overridden by a new overrider.
	// We use negative numbers when the arity is overridden by an old overrider.
	// -1 is for the Object class, and -2 for the next deeper class, etc.
	arities := make([]int, superMax-superMin+1)

	for _, new := range newIters {
		shape := new.shapedMember.shape
		overriddenBy[new.shapedMember.member] = struct{}{}
		from := max(shape.MinPositionalNonBlock, superMin) - superMin
		to := min(shape.MaxPositionalNonBlock, superMax) - superMin
		for i := from; i <= to; i++ {
			arities[i] = 1
		}
	}

	for _, old := range oldIters {
		addedAsOverrider := false
		shape := old.shapedMember.shape
		from := max(shape.MinPositionalNonBlock, superMin) - superMin
		to := min(shape.MaxPositionalNonBlock, superMax) - superMin
		for i := from; i <= to; i++ {
			if arities[i] <= 0 {
				// Either another old overrider, or not overridden yet.
				classDepth := -ir.classDepth[ir.Holder[old.shapedMember.member.AsToitMember()]]
				if classDepth < arities[i] {
					// This method shadows the previous one (if there was one)
					arities[i] = classDepth
					if !addedAsOverrider {
						overriddenBy[old.shapedMember.member] = struct{}{}
					}
					addedAsOverrider = true
				}
			}
		}
	}

	// Check if any of the arities isn't covered. If we have a hole then
	// the method is visible and should be shown as inherited.
	for _, marker := range arities {
		if marker == 0 {
			return false
		}
	}
	return true
}

// categorizeNamed.
// Splits the given indexed into three buckets:
// - the ones requiring the named parameter (with the given name),
// - the ones that have that parameter as optional one.
// - the ones that don't have it.
func categorizeNamed(name string, iterators []shapedMemberIterator) (required []shapedMemberIterator, optional []shapedMemberIterator, notExist []shapedMemberIterator) {
	required = []shapedMemberIterator{}
	optional = []shapedMemberIterator{}
	notExist = []shapedMemberIterator{}

	for _, entry := range iterators {
		// Advance the entry until it has the same name.
		for true {
			current := entry.current()
			if !current.isValid() || current.Name > name {
				notExist = append(notExist, entry)
				break
			}
			// Consume this name, independently if it's the name we
			// are looking for or not.
			entry.advance()
			if current.Name == name {
				if current.IsOptional {
					optional = append(optional, entry)
				} else {
					required = append(required, entry)
				}
				break
			}
		}
	}
	return required, optional, notExist
}

// namedPhaseComputeOverride.
// Checks all named arguments are overridden.
//
// We know that all old overriders (partial shadowing the super member in a
// different superclass) and new overriders (from the class we are looking at)
// all override (at least partially) the super member.
// We just need to see "how much" they override the super member (complete or
// partial), and whether the old partial overriders are still relevant.
// Fills the overriddenBy map with all members (old and new) that shadow the
// super member.
// Returns whether the super member is fully shadowed. Note that this function
// is called recursively for different branches of overlaps. The returned
// result is only true for the current branch.
//
// In this phase we look at named parameters.
// All parameters are iterators. Some named parameters may have already been
// handled.
// For optional parameters, the function splits recursively into two branches
// and verifies each branch. (It avoids the branching for easy cases).
func (ir *InheritanceResult) namedPhaseComputeOverride(superIter shapedMemberIterator, oldIters []shapedMemberIterator, newIters []shapedMemberIterator, overriddenBy overriddenByMap) bool {
	if len(newIters) == 0 && len(oldIters) == 0 {
		// This happens when called recursively and none of the potential overriders
		// handles one branch of an optional parameter.
		return false
	}

	for true {
		current := superIter.current()
		if !current.isValid() {
			break
		}
		superIter.advance()

		if !current.IsOptional {
			// Since we know that all parameters match, we know that
			// the old and the new overriders all have the
			// parameter.
			continue
		}

		// The named argument is optional. We need to check for both cases
		// (potential overrider has the named arg or not).
		// We continue recursively for the two cases (with, or without named arg).
		// When possible we also have a third branch "optional" to avoid
		// duplicating work.

		name := current.Name

		// We have three slices:
		// 1. members that have the named argument as required.
		// 2. members that have the named argument as optional.
		// 3. members that don't handle it.
		requiredNew, optionalNew, notExistNew := categorizeNamed(name, newIters)

		requiredOld, optionalOld, notExistOld := categorizeNamed(name, oldIters)

		if len(requiredNew) == 0 && len(requiredOld) == 0 &&
			len(notExistNew) == 0 && len(notExistOld) == 0 {
			// The old and new overriders all have optional arguments too.
			continue
		}

		if len(oldIters) != 0 {
			// We have to evaluate two branches: one with, and one without the
			// named argument.
			withNew := append(requiredNew, optionalNew...)
			withOld := append(requiredOld, optionalOld...)
			withFull := ir.namedPhaseComputeOverride(
				superIter, withOld, withNew, overriddenBy)

			withoutNew := append(optionalNew, notExistNew...)
			withoutOld := append(optionalOld, notExistOld...)
			withoutFull := ir.namedPhaseComputeOverride(
				superIter, withoutOld, withoutNew, overriddenBy)

			return withFull && withoutFull
		}

		// No old overriders, so we can concentrate on the new ones.
		// Assuming that calls are not ambiguous we know that neither the
		// required, nor the not-exist set can overlap with the optional
		// set. As such we can evaluate them separately, starting with the
		// optional set. If that one is fully overriding the super member
		// we don't even need to look at the other two.
		optionalFull := ir.namedPhaseComputeOverride(
			superIter, oldIters, optionalNew, overriddenBy)
		if optionalFull {
			return optionalFull
		}

		requiredFull := ir.namedPhaseComputeOverride(
			superIter, oldIters, requiredNew, overriddenBy)
		notExistFull := ir.namedPhaseComputeOverride(
			superIter, oldIters, notExistNew, overriddenBy)

		return requiredFull && notExistFull
	}

	// We have successfully finished the loop for names. Now check for positional
	// parameters.
	return ir.positionalPhaseComputeOverride(superIter, oldIters, newIters, overriddenBy)
}

// fieldPhaseComputeOverride.
// Handles the case where the superMember is a field.
// Otherwise dispatches to the later phases.
//
// We know that all old overriders (partial shadowing the super member in a
// different superclass) and new overriders (from the class we are looking at)
// all override (at least partially) the super member.
// Fills the overriddenBy map with all members (old and new) that shadow the
// superMember.
// Returns whether the superMember is fully shadowed.
func (ir *InheritanceResult) fieldPhaseComputeOverride(superMember *shapedMember, oldOverriders []*shapedMember, newOverriders []*shapedMember, overriddenBy overriddenByMap) bool {
	if !superMember.shape.IsField {
		superIter := shapedMemberIterator{
			shapedMember: superMember,
			index:        0,
		}
		oldIters := toIterators(oldOverriders)
		newIters := toIterators(newOverriders)
		return ir.namedPhaseComputeOverride(superIter, oldIters, newIters, overriddenBy)
	}

	if len(oldOverriders) > 1 {
		panic("A field can't have more than one partial override.")
	}

	var getterOverride *shapedMember = nil
	var setterOverride *shapedMember = nil
	for _, new := range newOverriders {
		if new.shape.IsField {
			// Fully shadows the super-member.
			overriddenBy[new.member] = struct{}{}
			return true
		} else if new.shape.IsSetter {
			setterOverride = new
		} else if isGetterShape(new.shape) {
			getterOverride = new
		}
		if getterOverride != nil && setterOverride != nil {
			overriddenBy[getterOverride.member] = struct{}{}
			overriddenBy[setterOverride.member] = struct{}{}
			return true
		}
	}

	for _, old := range oldOverriders {
		if setterOverride == nil && old.shape.IsSetter {
			setterOverride = old
		} else if getterOverride == nil && !old.shape.IsSetter {
			getterOverride = old
		}
	}

	// The two can't be the same, as this would be a field for which
	// we already returned.
	if getterOverride != nil {
		overriddenBy[getterOverride.member] = struct{}{}
	}
	if setterOverride != nil {
		overriddenBy[setterOverride.member] = struct{}{}
	}
	return getterOverride != nil && setterOverride != nil
}

// setterPhaseComputeOverride.
// Handles the case where the superMember is a setter.
// Otherwise dispatches to the later phases.
// We know that all old overriders (partial shadowing the super member in a
// different superclass) and new overriders (from the class we are looking at)
// all override (at least partially) the super member.
// Fills the overriddenBy map with all members (old and new) that shadow the
// superMember.
// Returns whether the superMember is fully shadowed.
func (ir *InheritanceResult) setterPhaseComputeOverride(superMember *shapedMember, oldOverriders []*shapedMember, newOverriders []*shapedMember, overriddenBy overriddenByMap) bool {
	if !superMember.shape.IsSetter {
		return ir.fieldPhaseComputeOverride(
			superMember, oldOverriders, newOverriders, overriddenBy)
	}

	if len(oldOverriders) != 0 {
		log.Fatal("A simple setter can't have a partial override.")
	}
	for _, new := range newOverriders {
		if new.shape.IsField || new.shape.IsSetter {
			// Fully shadows the super-member.
			overriddenBy[new.member] = struct{}{}
			return true
		}
	}
	return false
}

// filterOverriding
// Filters the given members and only returns the ones that have an
// overlap with the given superMember.
// The returned functions override, at least partially, the superMember.
func filterOverriding(superMember *shapedMember, members []*shapedMember) []*shapedMember {
	superShape := superMember.shape
	superIsField := superShape.IsField
	superIsSetter := superShape.IsSetter
	result := []*shapedMember{}
	for _, member := range members {
		if superIsField {
			if member.shape.IsSetter || isGetterShape(member.shape) {
				result = append(result, member)
			}
			continue
		}
		if superIsSetter {
			if member.shape.IsSetter || member.shape.IsField {
				result = append(result, member)
			}
			continue
		}
		shape := member.shape
		if shape.MinPositionalNonBlock > superShape.MaxPositionalNonBlock ||
			shape.MaxPositionalNonBlock < superShape.MinPositionalNonBlock ||
			shape.PositionalBlockCount != superShape.PositionalBlockCount {
			continue
		}

		superIter := superMember.iterator()
		memberIter := member.iterator()
		matches := true
		for matches {
			superNamedParam := superIter.current()
			if !superNamedParam.isValid() {
				break
			}
			superIter.advance()

			for true {
				namedParam := memberIter.current()
				// Don't advance immediately, as the member name might be needed
				// later.

				if !namedParam.isValid() || namedParam.Name > superNamedParam.Name {
					if !superNamedParam.IsOptional {
						// The member is missing a required named parameter of the
						// super member.
						matches = false
					}
					break
				}

				memberIter.advance()

				if namedParam.Name == superNamedParam.Name {
					if superNamedParam.IsBlock != namedParam.IsBlock {
						matches = false
					}
					// No need to check whether either is optional.
					break
				}

				if namedParam.Name < superNamedParam.Name {
					if !namedParam.IsOptional {
						// The member requires a named parameter the super
						// doesn't have.
						matches = false
						break
					}
				}
			}
		}
		for matches {
			current := memberIter.current()
			if !current.isValid() {
				break
			}
			memberIter.advance()
			if !current.IsOptional {
				// The member requires a named parameter the super
				// doesn't have.
				matches = false
				break
			}
		}
		if matches {
			result = append(result, member)
		}
	}
	return result
}

// computeOverride.
// Figures out if the superMember is still visible in the subclass.
// The result states whether the superMember is fully overridden.
//
// As a side-effect (but almost more imporantly) it also updates the
// overriddenBy map that is given as parameter.
// Any function (either old, or new) that overrides
// the superMember is added to the map. Note that old overriders (from
// another overriding superclass) are only added if they are still
// relevant. That is, if the new members don't shadow them (with respect
// to the superMember).
//
// The superMember must not be an inheritedMember anymore.
func (ir *InheritanceResult) computeOverride(superMember *shapedMember, oldOverriders []*Member, members []*shapedMember, overriddenBy overriddenByMap) bool {
	// Start by checking whether any of our members could even shadow the
	// superMember.
	members = filterOverriding(superMember, members)
	if len(members) == 0 {
		overriddenBy.addAll(oldOverriders)
		return false
	}

	oldShaped := []*shapedMember{}
	for _, overrider := range oldOverriders {
		oldShaped = append(oldShaped, overrider.makeShaped())
	}
	return ir.setterPhaseComputeOverride(
		superMember, oldShaped, members, overriddenBy)
}
