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

import .shadow
import .util
import ..lsp-exports as lsp

hash-code-counter_/int := 0

/**
The result of the $compute function.
*/
class Result:
  /**
  A map from a class to a list of $InheritedMember.
  */
  inherited/Map  // From class to inherited members.
  /**
  A map from $ShadowKey to a list of $lsp.ClassMember, that are shadowed by
    the function/lsp.field specified by the key.
  */
  shadowing/Map

  constructor --.inherited --.shadowing:

class InheritedMember:
  member/Member
  partially-shadowed-by/List

  /** See $Member.inheritance-order. */
  inheritance-order/int

  is-field -> bool: return member.is-field
  is-method -> bool: return member.is-method

  as-field -> lsp.Field: return member.as-field
  as-method -> lsp.Method: return member.as-method

  constructor .member --.partially-shadowed-by --.inheritance-order:

/**
A member of a class.
Either a $lsp.Field, a $lsp.Method, or an $InheritedMember.
*/
class Member:
  hash-code/int ::= hash-code-counter_++
  target/any  // Either an lsp.ClassMember or an InheritedMember.
  shape_/Shape? := null
  name_/string? := null
  /**
  A number that allows us to sort the members in the order they are inherited.
  The value is not equivalent to the class depth due to mixins.

  Any member that could potentially override another member is given a higher
    value than the member it could override.
  */
  inheritance-order/int := ?

  constructor .target --.inheritance-order:

  shape -> Shape:
    if not shape_: shape_ = compute-shape_
    return shape_

  is-field -> bool: return target is lsp.Field
  is-method -> bool: return target is lsp.Method
  is-inherited -> bool: return target is InheritedMember

  as-field -> lsp.Field: return target as lsp.Field
  as-method -> lsp.Method: return target as lsp.Method
  as-inherited -> InheritedMember: return target as InheritedMember

  /**
  Returns the targetted $lsp.Method or $lsp.Field.
  In most cases this is just the $target, but if the target is an inherited
    member, then we continue to the target of the inherited member.
  */
  as-toit-member -> lsp.ClassMember:
    if is-field or is-method: return target
    return as-inherited.member.as-toit-member

  /**
  Computes the name of the member.
  For setters the trailing '=' is removed.
  */
  name -> string:
    if not name_:
      if is-field: name_ = as-field.name
      else if is-method: name_ = as-method.name.trim --right "="
      else: name_ = as-inherited.member.name
    return name_

  compute-shape_ -> Shape:
    if is-field:
      return Shape
          --min-positional-non-block=0
          --max-positional-non-block=0
          --positional-block-count=0
          --is-setter=false
          --is-field=true
          --named=[]

    if is-method:
      method := as-method
      is-setter := method.name.ends-with "="
      min-position := 0
      max-positional := 0
      positional-block-count := 0
      named-params := []
      method.parameters.do: | param/lsp.Parameter |
        is-block := param.is-block
        is-optional := not param.is-required
        if param.is-named:
          named := NamedParameter --name=param.name --is-block=is-block --is-optional=is-optional
          named-params.add named
          continue.do
        if is-block:
          positional-block-count++
          continue.do
        max-positional++
        if not is-optional: min-position++
      named-params.sort --in-place: | a/NamedParameter b/NamedParameter | a.name.compare-to b.name
      return Shape
          --min-positional-non-block=min-position
          --max-positional-non-block=max-positional
          --positional-block-count=positional-block-count
          --is-setter=is-setter
          --is-field=false
          --named=named-params

    // The shape of an inherited member is the same as the one of the member.
    return as-inherited.member.compute-shape_


class NamedParameter:
  name/string
  is-block/bool
  is-optional/bool

  constructor --.name --.is-block --.is-optional:

class Shape:
  min-positional-non-block/int
  max-positional-non-block/int
  positional-block-count/int
  is-setter/bool
  is-field/bool
  named/List  // Alpabetically sorted list of NamedParameter.

  constructor
      --.min-positional-non-block
      --.max-positional-non-block
      --.positional-block-count
      --.is-setter
      --.is-field
      --.named:

  has-getter-shape -> bool:
    if is-setter: return false
    if is-field: return true
    if min-positional-non-block != 0 or positional-block-count != 0: return false
    named.do: | named/NamedParameter | if not named.is-optional: return false
    return true

  stringify -> string:
    names := named.map: | named/NamedParameter | "$named.name$(named.is-optional ? "=" : "")"
    joined := names.join ", "
    return "Shape($min-positional-non-block, $max-positional-non-block, $positional-block-count, $is-setter, $is-field, [$joined])"

/**
A map from name to a list of shaped members.
*/
class ShapedMap:
  map_/Map ::= {:}

  add member/Member:
    map_.update member.name --init=(: []):
      it.add member
      it

  operator[] name/string -> List: return map_[name]

  get name/string [--if-absent] -> List:
    return map_.get name --if-absent=if-absent

  do [block]:
    map_.do block

class ShadowKey:
  klass/lsp.Class
  member/lsp.ClassMember

  constructor .klass .member:

  operator== other/ShadowKey -> bool:
    return klass == other.klass and member == other.member

  hash-code -> int:
    return klass.hash-code * 31 + member.hash-code

  stringify -> string:
    return "ShadowKey($klass.name, $member.name)"

class InheritanceBuilder:
  summaries_/Map
  done-classes_ ::= {}
  inherited ::= {:}
  shadowed ::= {:}

  constructor .summaries_:

  build -> Result:
    summaries_.do: | uri/string module/lsp.Module |
      module.classes.do: do-class it
    return Result --inherited=inherited --shadowing=shadowed

  do-class klass/lsp.Class:
    if done-classes_.contains klass: return
    done-classes_.add klass

    if not klass.superclass:
      assert: klass.mixins.is-empty
      // The depth of the Object class (or root class for mixins/interfaces)
      // must be strictly positive.
      // The shadow-computation relies on this.
      inherited[klass] = []
      return

    superclass := resolve-ref klass.superclass
    do-class superclass

    // A list of additional members the (synthetic) superclass has inherited.
    // For each mixin we compute two inherited sets:
    // - the one that is inherited as part of the mixin hierarchy.
    // - the one that the synthetic class would inherit from its super (taking into
    //   account all members of the mixin).
    mixin-inherited := []
    for i := 0; i <= klass.mixins.size; i++:
      is-mixin := i < klass.mixins.size
      super-is-mixin := i > 0
      current-class/lsp.Class := is-mixin
          ? resolve-ref klass.mixins[i]
          : klass

      if is-mixin: do-class current-class

      super-inherited/List := ?
      if super-is-mixin:
        super-inherited = inherited[superclass] + mixin-inherited
      else:
        super-inherited = inherited[superclass]

      current-inherited := compute-inherited-for current-class
          --superclass=superclass
          --super-inherited=super-inherited

      if is-mixin:
        mixin-inherited = current-inherited
      else:
        inherited[klass] = current-inherited

      superclass = current-class

  /**
  Computes the inherited members for the given $klass.
  The $klass can be a Mixin, in which case we are computing the members that
    would be inherited by the superclass + the mixin. In that case, the klass
    might already have inherited members.

  The $super-inherited contains the full list of elements the superclass inherited.
  For mixins this includes the inherited members through the mixin hierarchy *and*
    the members the synthetic class inherited from the super class.
  */
  compute-inherited-for klass/lsp.Class --superclass/lsp.Class --super-inherited/List -> List:
    class-shaped := ShapedMap

    (klass.methods + klass.fields).do: | entry/lsp.ClassMember |
      // We initialize the inheritance order to a high value, so that it is
      // always higher than the inheritance order of the super class or mixins.
      // The current class members are discarded at the end of the function, so
      // don't need any fixing up.
      member := Member entry --inheritance-order=10_000_000
      class-shaped.add member

    // Reset the max.
    max-inheritance-order := 0

    super-shaped := ShapedMap
    super-inherited.do: | inherited/InheritedMember |
      member-order := inherited.inheritance-order
      member := Member inherited --inheritance-order=member-order
      max-inheritance-order = max max-inheritance-order member-order
      super-shaped.add member

    max-inheritance-order++
    (superclass.methods + superclass.fields).do: | entry/lsp.ClassMember |
      // All direct members share the same inheritance order.
      member-order := max-inheritance-order
      member := Member entry --inheritance-order=member-order
      super-shaped.add member

    // Compute the newly inherited members for 'klass'.
    // We go through each super-member (which includes the members that class inherited) and
    // see if they are still visible. If they are fully overridden, we can drop them.
    result := []
    super-shaped.do: | name/string super-members/List |
      class-members := class-shaped.get name --if-absent=(: [])
      if class-members.is-empty:
        // All current members are inherited.
        super-members.do: | super-member/Member |
          if super-member.is-inherited:
            result.add super-member.as-inherited
          else:
            inherited-member := InheritedMember super-member
                --partially-shadowed-by=[]
                --inheritance-order=super-member.inheritance-order
            result.add inherited-member
        continue.do

      // Some members may be shadowed by the class members.
      super-members.do: | super-member/Member |
        partial-overriders := []
        current-order := super-member.inheritance-order
        if super-member.is-inherited:
          inherited-member := super-member.as-inherited
          partial-overriders = inherited-member.partially-shadowed-by
          super-member = inherited-member.member

        overridden-by := {}  // A set of Member.
        fully-overridden := compute-and-fill-override super-member
            --old-overriders=partial-overriders
            --class-members=class-members
            --overridden-by=overridden-by

        overridden-by-list := overridden-by.to-list

        if not fully-overridden:
          inherited-member := InheritedMember super-member
              --partially-shadowed-by=overridden-by-list
              --inheritance-order=current-order
          result.add inherited-member

        mark-overriding klass super-member overridden-by-list

    return result

  mark-overriding klass/lsp.Class super-member/Member overridden-by/List:
    overridden := super-member.as-toit-member
    overridden-by.do: | overridden-by/Member |
      toit-member := overridden-by.as-toit-member
      key := ShadowKey klass toit-member
      shadowed.update key --init=(: []):
        it.add overridden
        it

  resolve-ref ref/lsp.ToplevelRef -> lsp.Class:
    return resolve-class-ref ref --summaries=summaries_

/**
Computes the inheritance information for the toitdoc viewer.

For each class computes the inherited members that are still accessible.
For each method computes the super members that are shadowed.
*/
compute summaries/Map -> Result:
  builder := InheritanceBuilder summaries
  return builder.build
