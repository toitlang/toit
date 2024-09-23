// Copyright (C) 2024 Toitware ApS.
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

import .inheritance

class NamedIterator:
  member/Member
  index/int := 0
  named_/List

  constructor .member:
    named_ = member.shape.named

  constructor.copy_ .member .index .named_:

  /**
  Returns the current named parameter, or null if there are no more.

  It is valid to read $index, which is the index of the current named parameter.
  */
  current -> NamedParameter?:
    if index >= named_.size: return null
    return named_[index]

  advance -> none:
    if index < named_.size: index++

  copy -> NamedIterator:
    return NamedIterator.copy_ member index named_

/**
Computes if the given $super-member is still visible in the subclass.

Returns true if the $super-member is fully overridden.

The $class-members argument must be a list of $Member.

As a side-effect, updates the given $overridden-by set. Any function
  (either old or new) that overrides the $super-member is added to the set.
  Note that overriders from another overriding superclass are only added
  if the are still relevant. That is, if the new members don't shadow them
  with respect to the $super-member.

The $super-member must not be an $InheritedMember.
*/
compute-and-fill-override super-member/Member -> bool
    --old-overriders/List
    --class-members/List
    --overridden-by/Set:
  if super-member is InheritedMember:
    throw "super-member must not be an InheritedMember"

  // Start by checking whether any of our members could even shadow the
  // super-member.
  members := filter-overriding super-member class-members
  if members.is-empty:
    overridden-by.add-all old-overriders
    return false

  return compute-override-phase-setter super-member
      --old-overriders=old-overriders
      --new-overriders=members
      --overridden-by=overridden-by

/**
Filters the given $class-members and only returns the ones that have an
  overlap with the given $super-member.

The returned members override, at least partially, the $super-member.
*/
filter-overriding super-member/Member class-members/List -> List:
  super-shape := super-member.shape
  super-is-field := super-shape.is-field
  super-is-setter := super-shape.is-setter

  result := []
  class-members.do: | member/Member |
    shape := member.shape
    if super-is-field:
      if shape.is-setter or shape.has-getter-shape:
        result.add member
      continue.do

    if super-is-setter:
      if shape.is-setter or shape.is-field:
        result.add member
      continue.do

    if shape.min-positional-non-block > super-shape.max-positional-non-block or
        shape.max-positional-non-block < super-shape.min-positional-non-block or
        shape.positional-block-count != super-shape.positional-block-count:
      continue.do

    super-iter := NamedIterator super-member
    member-iter := NamedIterator member
    matches := true
    while matches:
      super-named-param := super-iter.current
      if not super-named-param: break
      super-iter.advance

      while true:
        named-param := member-iter.current
        // Don't advance immediately, as the member name might be needed later.

        if not named-param or named-param.name > super-named-param.name:
          if not super-named-param.is-optional:
            // The member is missing a required named parameter of the super member.
            matches = false
          break

        member-iter.advance

        if named-param.name == super-named-param.name:
          if super-named-param.is-block != named-param.is-block:
            // The member has a different block-ness for the named parameter.
            matches = false
          // Always break out. No need to check whether either is optional.
          break

        if named-param.name < super-named-param.name:
          if not named-param.is-optional:
            // The member requires a named parameter the super doesn't have.
            matches = false
            break

    // Check that all remaining member named are optional.
    while matches:
      current := member-iter.current
      if not current: break
      member-iter.advance

      if not current.is-optional:
        matches = false
        break

    if matches: result.add member

  return result

/**
Computes if the given $super-member is still visible in the subclass.

Handles the case where the $super-member is a setter.
Otherwise dispatches to the later phases.

We know that all old overriders (partially shadowing the $super-member in a
  different superclass) and new overriders (from the class we are looking at)
  all override (at least partially) the $super-member.

Fills the $overridden-by set with all members (old and new) that shadow the
  $super-member.

Returns whether the $super-member is fully shadowed.
*/
compute-override-phase-setter super-member/Member -> bool
    --old-overriders/List
    --new-overriders/List
    --overridden-by/Set:
  if not super-member.shape.is-setter:
    return compute-override-phase-field super-member
        --old-overriders=old-overriders
        --new-overriders=new-overriders
        --overridden-by=overridden-by

  if not old-overriders.is-empty:
    throw "A simple setter can't have a partial override"

  new-overriders.do: | new/Member |
    if new.shape.is-field or new.shape.is-setter:
      // Fully shadows the super-member.
      overridden-by.add new
      return true

  return false

/**
Computes if the given $super-member is still visible in the subclass.

Handles the case where the $super-member is a field.
Otherwise dispatches to the later phases.

Also see $compute-override-phase-setter.
*/
compute-override-phase-field super-member/Member -> bool
    --old-overriders/List
    --new-overriders/List
    --overridden-by/Set:
  if not super-member.shape.is-field:
    super-iter := NamedIterator super-member
    old-iters := old-overriders.map: NamedIterator it
    new-iters := new-overriders.map: NamedIterator it
    return compute-override-phase-named super-iter
        --old-iterators=old-iters
        --new-iterators=new-iters
        --overridden-by=overridden-by

  if old-overriders.size > 1:
    throw "A field can't have more than partial override"

  getter-override/Member? := null
  setter-override/Member? := null

  new-overriders.do: | new/Member |
    if new.shape.is-field:
      // Fully shadows the super-member.
      overridden-by.add new
      return true

    if new.shape.is-setter:
      setter-override = new
    else if new.shape.has-getter-shape:
      getter-override = new

    if getter-override and setter-override:
      // Fully shadows the super-member.
      overridden-by.add getter-override
      overridden-by.add setter-override
      return true

  old-overriders.do: | old/Member |
    if not setter-override and old.shape.is-setter:
      setter-override = old
    else if not getter-override and old.shape.has-getter-shape:
      getter-override = old


  // The two can't be the same, as this would be a field for which we
  // already returned.
  assert: getter-override != setter-override

  if getter-override: overridden-by.add getter-override
  if setter-override: overridden-by.add setter-override

  return not getter-override and not setter-override

/**
Categorizes the $iterators for the given $name.

Returns a list with three entries:
- required: A list of iterators that had the name as required.
- optional: A list of iterators that had the name as optional.
- not-exist: A list of iterators that didn't have the name at all.

Consumes the $name in the iterators.
*/
categorize-named name/string iterators/List:
  required := []
  optional := []
  not-exist := []

  iterators.do: | iterator/NamedIterator |
    // Advance the iterator until it has the same name.
    while true:
      current := iterator.current
      if not current or current.name > name:
        not-exist.add iterator
        break

      // Consume the name.
      iterator.advance
      if current.name == name:
        if current.is-optional:
          optional.add iterator
        else:
          required.add iterator
        break

  return [required, optional, not-exist]

/**
Computes if the given super-member of $super-iter is still visible in the subclass.

This method might be called recursively with (some of) the iterators having advanced.

Checks whether all named arguments are overridden. Since named parameters can be
  optional, needs to group and branch depending on how these parameters overlap.
  If the named part matches, dispatches to the positional phase, using the
  $NamedIterator.member's shape.

In this phase we look at named parameters.
All parameters ($super-iter, $old-iterators, $new-iterators) are $NamedIterator
  instances, but we might get the $NamedIterator.member out of them for later
  phases.
Some named parameters might already be handled.

Also see $compute-override-phase-setter.
*/
compute-override-phase-named super-iter/NamedIterator -> bool
    --old-iterators/List
    --new-iterators/List
    --overridden-by/Set:
  if old-iterators.is-empty and new-iterators.is-empty:
    // This happens when called recursively and none of the potential overriders
    // handles a branch of an optional parameter.
    return false

  while true:
    current := super-iter.current
    if not current: break
    super-iter.advance

    if not current.is-optional:
      // Since we know that all entries in the old and new iterators override
      // the super-iter at least partially (due to us running
      // $filter-overriding first).
      // As such all old/new iterators must have the current named parameter
      // (even if optionally).
      continue

    // The named argument is optional. We need to check for both cases, where
    // potential overriders have the named argument and where they don't.
    // We continue recursively for the two cases. When possible, we also have a
    // third branch "optional" to avoid duplicating work.

    name := current.name

    // We have three categories:
    // 1. members that have the named argument as required.
    // 2. members that have the named argument as optional.
    // 3. members that don't have the named argument.
    categorized-new := categorize-named name new-iterators
    required-new := categorized-new[0]
    optional-new := categorized-new[1]
    not-exist-new := categorized-new[2]

    categorized-old := categorize-named name old-iterators
    required-old := categorized-old[0]
    optional-old := categorized-old[1]
    not-exist-old := categorized-old[2]

    if required-new.is-empty and required-old.is-empty and
        not-exist-new.is-empty and not-exist-old.is-empty:
      // The old and new overriders all have this named argument as optional
      // too.
      continue

    // We have to evaluate two branches: one with, and without the named
    // argument.
    // The optional category is used in both cases and thus must be duplicated.
    duplicated-optional-new := optional-new.map: it.copy
    duplicated-optional-old := optional-old.map: it.copy
    // Same for the super-iter.
    duplicated-super := super-iter.copy

    with-new := required-new + optional-new
    with-old := required-old + optional-old
    with-result := compute-override-phase-named super-iter
        --old-iterators=with-old
        --new-iterators=with-new
        --overridden-by=overridden-by

    // Note that we can't return here, even if the 'with-result' is false.
    // We need to run the non-existing one too, so we fill the 'overridden-by'
    // set.

    without-new := not-exist-new + duplicated-optional-new
    without-old := not-exist-old + duplicated-optional-old
    without-result := compute-override-phase-named duplicated-super
        --old-iterators=without-old
        --new-iterators=without-new
        --overridden-by=overridden-by

    return with-result and without-result

  // We have successfully finished the loop for names.
  // Check the positional parameters.
  // We still pass the iterators, even though we only need the shapes.
  return compute-override-phase-positional super-iter
      --old-iterators=old-iterators
      --new-iterators=new-iterators
      --overridden-by=overridden-by

/**
Computes if the given super-member of $super-iter is still visible in the subclass.

Handels the positional parameters.

This function might be called multiple times for the same super-member, depending
  on the branching of named parameters.
*/
compute-override-phase-positional super-iter/NamedIterator -> bool
    --old-iterators/List
    --new-iterators/List
    --overridden-by/Set:

  // The new overriders may have overlapping regions as they
  // don't need to be from the same class. However, they can't
  // fully overlap as that would make calls ambiguous (leading to an
  // error from the Toit compiler).
  // If they do overlap, the algorithm still terminates but might yield a bad
  // result.
  // We also know that the potential overriders have at least some overlap
  // with the super-member as we filtered at the beginning of the whole process
  // (using $filter-overriding).

  super-min := super-iter.member.shape.min-positional-non-block
  super-max := super-iter.member.shape.max-positional-non-block

  // A list where we mark which arities are handled by the overriding methods.
  // We use 1 for being overridden by a new overrider.
  // We use negative numbers when the arity is overridden by an old overrider.
  // The inheritance order of each member ensures that members of subclasses
  // have a higher order than members of superclasses.
  arities := List (super-max - super-min + 1): 0

  new-iterators.do: | new-iter/NamedIterator |
    new-member := new-iter.member
    shape := new-member.shape
    overridden-by.add new-member

    from := (max shape.min-positional-non-block super-min) - super-min
    to := (min shape.max-positional-non-block super-max) - super-min
    for i := from; i <= to; i++:
      arities[i] = 1

  old-iterators.do: | old-iter/NamedIterator |
    added-as-overrider := false
    old-member := old-iter.member
    shape := old-member.shape
    from := (max shape.min-positional-non-block super-min) - super-min
    to := (min shape.max-positional-non-block super-max) - super-min
    for i := from; i <= to; i++:
      if arities[i] <= 0:
        // Either another old overrider, or not overridden yet.
        // Note that we use the negative of the inheritance order as discussed above.
        negated-inheritance-order := -old-member.inheritance-order
        if negated-inheritance-order < arities[i]:
          // This method shadows the previous one (if there was one).
          arities[i] = negated-inheritance-order
          if not added-as-overrider:
            overridden-by.add old-member
            added-as-overrider = true


  // Check if any of the arities isn't covered. If we have a hole then
  // the method is visible and should be shown as inherited.
  return not (arities.any: it == 0)
