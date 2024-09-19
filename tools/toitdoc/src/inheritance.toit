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

  is-field -> bool: return member.is-field
  is-method -> bool: return member.is-method

  as-field -> lsp.Field: return member.as-field
  as-method -> lsp.Method: return member.as-method

  constructor .member --.partially-shadowed-by:

/**
A member of a class.
Either a $lsp.Field, a $lsp.Method, or an $InheritedMember.
*/
class Member:
  hash-code/int ::= hash-code-counter_++
  target/any
  shape_/Shape? := null
  name_/string? := null

  constructor.field field/lsp.Field:
    target = field

  constructor.method method/lsp.Method:
    target = method

  constructor.inherited inherited/InheritedMember:
    target = inherited

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

  add-method method/lsp.Method: add (Member.method method)
  add-field field/lsp.Field: add (Member.field field)
  add-inherited inherited/InheritedMember: add (Member.inherited inherited)

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
  holders_ ::= {:}
  class-depths_ ::= {:}
  inherited ::= {:}
  shadowed ::= {:}

  constructor .summaries_:

  build -> Result:
    hack-class-depths = class-depths_
    hack-holders = holders_
    summaries_.do: | uri/string module/lsp.Module |
      module.classes.do: do-class it
    return Result --inherited=inherited --shadowing=shadowed

  do-class klass/lsp.Class:
    if done-classes_.contains klass: return
    done-classes_.add klass

    klass.methods.do: | method/lsp.Method | holders_[method] = klass
    klass.fields.do:  | field/lsp.Field |   holders_[field] = field

    if not klass.superclass:
      class-depths_[klass] = 1
      inherited[klass] = []
      return

    class-shaped := ShapedMap
    klass.methods.do: class-shaped.add-method it
    klass.fields.do: class-shaped.add-field it

    class-inherited := []

    // Note that we run to <= size. The last iteration is for the super.
    for i := 0; i <= klass.mixins.size; i++:
      is-superclass := i == klass.mixins.size
      current-class-ref/lsp.ToplevelRef? := is-superclass
          ? klass.superclass
          : klass.mixins[i]
      if not current-class-ref: continue  // Object and Mixin-top.
      current-class := resolve-ref current-class-ref
      do-class current-class
      if is-superclass: class-depths_[klass] = class-depths_[current-class] + 1

      current-shaped := ShapedMap
      current-class.methods.do: current-shaped.add-method it
      current-class.fields.do: current-shaped.add-field it
      inherited[current-class].do: current-shaped.add-inherited it

      // Compute the newly inherited members for 'klass'.
      current-inherited := []
      current-shaped.do: | name/string current-members/List |
        class-members := class-shaped.get name --if-absent=(: [])
        if class-members.is-empty:
          // All current members are inherited.
          current-members.do: | current-member/Member |
            if current-member.is-inherited:
              current-inherited.add current-member.as-inherited
            else:
              inherited-member := InheritedMember current-member --partially-shadowed-by=[]
              current-inherited.add inherited-member
          continue.do

        current-members.do: | current-member/Member |
          partial-overriders := []
          if current-member.is-inherited:
            inherited-member := current-member.as-inherited
            partial-overriders = inherited-member.partially-shadowed-by
            current-member = inherited-member.member

          overridden-by := {}  // A set of Member.
          fully-overridden := compute-and-fill-override current-member
              --old-overriders=partial-overriders
              --class-members=class-members
              --overridden-by=overridden-by

          overridden-by-list := overridden-by.to-list

          if not fully-overridden:
            inherited-member := InheritedMember current-member
                --partially-shadowed-by=overridden-by-list
            current-inherited.add inherited-member

          mark-overriding klass current-member overridden-by-list

      // Add all newly inherited mumbers to the class shape, so we can use it
      // for the next mixin/super.
      current-inherited.do: | inherited-member/InheritedMember |
        class-shaped.add-inherited inherited-member

      // Add the current inherited members to the inherited members of the class.
      class-inherited.add-all current-inherited

    inherited[klass] = class-inherited

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
