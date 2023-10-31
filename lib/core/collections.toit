// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary
import bitmap

LIST-INITIAL-LENGTH_ ::= 4
HASHED-COLLECTION-INITIAL-LENGTH_ ::= 4
MAX-PRINT-STRING_ ::= 4000

/** A collection of elements. */
interface Collection:

  /**
  Invokes the given $block on each element of this instance.
  Users must not modify the collection while iterating over it.

  # Inheritance
  Needs to be implemented by all subclasses.
  This function should never throw.
  This function does *not* need to protect itself against
    modifications of this instance during the iteration.
    Subclasses are, however, encouraged to do so if they
    can do it cheaply (especially in debug-mode).

  # Examples
  ```
  [1, 2].do: debug it  // Prints 1, 2
  ```

  # Categories
  - Iteration
  */
  do [block] -> none

  /**
  The number of elements in this instance.
  This operation can be assumed to be in O(1).

  # Inheritance
  This method must be implemented by subclasses.
  If the operation is not in O(1) consider not implementing
    the $Collection interface. Exceptional cases, where all users
    are clearly aware of this restriction, are permitted.
  */
  size -> int

  /**
  Whether this instance is equal to $other.

  Equality only returns true when both operands are of the same type.

  Returns false, if this instance and $other are not of the same $size, or if
    the contained elements are not equal themselves. Unless otherwise specified or
    configured, uses the default `==` operator for comparison.
  Subclasses may decide not to support deep equality.

  It is an error to compare self-recursive data-structures.

  # Inheritance
  Collections do *not* need to ensure that recursive data structures don't lead to
    infinite loops.
  */
  operator == other/Collection -> bool

  /**
  Whether this instance is empty.

  # Inheritance
  Subclasses should overwrite this method if the $size getter
    is not constant and the subclass has a more efficient way of
    determining whether this instance is empty.
  */
  is-empty -> bool

  /**
  Whether all elements in the collection satisfy the given $predicate.
  Returns true, if the collection is empty.
  */
  every [predicate] -> bool

  /**
  Whether at least one element in the collection satisfies the given $predicate.
  Returns false, if the collection is empty.
  */
  any [predicate] -> bool

  /** Whether this instance contains the given $element. */
  contains element -> bool

  /**
  Takes all elements and combines them using $block.
  It's an error if this instance does not have at least one element.
  */
  reduce [block]

  /**
  Takes all elements and combines them using $block.
  Returns the $initial value if this instance is empty.
  If this instance contains at least one element calls $block first with
    the $initial value and the first element.
  */
  reduce --initial [block]


abstract class CollectionBase implements Collection:
  /// See $Collection.do.
  abstract do [block] -> none
  /// See $Collection.size.
  abstract size -> int
  /// See $Collection.==.
  abstract operator == other/Collection -> bool

  /// See $Collection.is-empty.
  is-empty -> bool:
    return size == 0

  /// See $Collection.every.
  every [predicate] -> bool:
    do: if not predicate.call it: return false
    return true

  /// See $Collection.any.
  any [predicate] -> bool:
    do: if predicate.call it: return true
    return false

  /// See $Collection.contains.
  contains element -> bool:
    return any: it == element

  /// See $Collection.reduce.
  reduce [block]:
    if is-empty: throw "Not enough elements"
    result := null
    is-first := true
    do:
      if is-first: result = it; is-first = false
      else: result = block.call result it
    return result

  /// See $Collection.reduce.
  reduce --initial [block]:
    result := initial
    do:
      result = block.call result it
    return result


/**
A linear collection of objects.
A List is an array with constant-time access to numbered elements,
  starting at index zero.  (This is not a linked-list collection.)
Lists are mutable and growable.
See also https://docs.toit.io/language/listsetmap.
*/
abstract class List extends CollectionBase:

  /**
  Creates an empty list.
  This operation is identical to creating a list with a list-literal: `[]`.
  */
  constructor: return List_

  constructor.from-subclass:

  /**
  Creates a new List of the given $size where every slot is filled with the
    given $filler.
  */
  constructor size/int filler=null:
    return List_.from-array_ (Array_ size filler)

  /** Creates a List and initializes each element with the result of invoking the block. */
  constructor size/int [block]:
    return List_.from-array_ (Array_ size block)

  /** Creates a List, containing all elements of the given $collection */
  constructor.from collection/Collection:
    return List_.from-array_ (Array_.from collection)


  /**
  Changes the size of this list to the given $new-size.

  If the list grows as a result of this operation, then the elements are filled with null.
  If the list shrinks as a result of this operation, then these elements are dropped.
  */
  abstract resize new-size -> none

  /**
  Returns the element in the slot of the given $index.

  // TODO(florian): document whether it's ok to index with -1 etc.
  */
  abstract operator [] index/int

  /**
  Stores the given $value in the slot of the given $index.

  // TODO(florian): document whether it's ok to index with -1 etc.
  */
  abstract operator []= index/int value

  /**
  Returns a slice of this list.

  Slices are views on the underlying object. As such they see and modify
    the object they come from.

  The parameter $from is inclusive.
  The parameter $to is exclusive.

  # Advanced
  Slices keep the whole underlying object alive. This can lead to memory
    waste if the underlying object is not used otherwise. In some cases it
    might thus make sense to call $copy on the slice.

  At the call-site the arguments $from and $to are passed in with the slice
    syntax: `list[from..to]`. Since both arguments are optional (as they have
    default values), it is valid to omit `from` or `to`.

  # Examples
  ```
  list := [1, 2, 3, 4, 5]
  sub := list[1..3] // A view into [2, 3]
  sub[0] = 22
  print list  // => [1, 22, 3, 4, 5]
  sub = list[..3]      // A view into [1, 22, 3]
  sub.sort --in_place  // Sorts just the 3 values.
  print sub   // => [1, 3, 22]
  print list  // => [1, 3, 22, 4, 5]
  sub2 := sub[1..]
  print sub2  // => [3, 22]
  sub2[1] = 499
  print list  // => [1, 3, 499, 4, 5]
  sub3 := list[2..].copy  // => Creates a copy of [499, 4, 5]
  sub3[0] = 3 // This time only the copy is affected.
  print sub3  // => [3, 4, 5]
  print list  // => [1, 3, 499, 4, 5]
  ```
  */
  operator [..] --from=0 --to=size -> List:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    return ListSlice_ this from to

  /**
  Creates a copy of a slice of this list.

  The returned object generally has the same type is this instance. Some subclasses
    may decide to return an object of different type, if the new size allows a
    more efficient class to be used.

  The arguments $from and $to must satisfy: `0 <= from <= to <= size`.

  # Aliases
  - `slice`: JavaScript.
  - `sublist`: Dart, Java,

  # Inheritance
  This method should be implemented by each subclass of `List`, as the
    type of the returned object should match the one of this instance. As exception,
    classes that have multiple implementations (say a `SmallCarList` and `LargeCarList`)
    may switch type, *especially* if the individual types are not visible to the users.
  */
  abstract copy from/int=0 to/int=size -> List

  /** Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[ */
  replace index/int source from/int=0 to/int=source.size -> none:
    len := to - from
    if index <= from:
      len.repeat:
        this[index + it] = source[from + it]
    else:
      end := index + len
      len.repeat:
        i := it + 1
        this[end - i] = source[to - i]

  /**
  Adds the given $value to the list.
  This operation increases the size of this instance.
  It is an error to call this method on lists that can't grow.
  */
  add value -> none:
    #primitive.core.list-add:
      old-size := size
      resize old-size + 1
      this[old-size] = value

  /**
  Adds all elements of the given $collection to the list.
  This operation increases the size of this instance.
  It is an error to call this method on lists that can't grow.
  */
  add-all collection/Collection -> none:
    old-size := size
    resize old-size + collection.size
    index := old-size
    collection.do: this[index++] = it

  /**
  Removes the last element of this instance.
  Returns the removed element.

  It is an error to call this method on lists that can't change size.
  It is an error to call this method on empty lists.
  */
  remove-last:
    result := last
    resize size - 1
    return result

  /**
  Removes the first entry that is equal to the given $needle.

  Does nothing if the $needle is not in this instance.
  This operation is in `O(n)` and thus not efficient.

  It is an error to call this method on lists that can't change size.
  */
  remove needle -> none:
    i := 0
    while i < size and this[i] != needle: i++
    if i == size: return
    i++
    while i < size:
      this[i - 1] = this[i]
      i++
    resize size - 1

  /**
  Removes all entries that are equal to the given $needle.

  Does nothing if the $needle is not in this instance.
  This operation is in `O(n)` and thus not efficient.

  It is an error to call this method on lists that can't change size.
  */
  remove --all/bool needle -> none:
    if all != true: throw "Argument Error"
    target-index := 0
    size.repeat:
      entry := this[it]
      if entry != needle:
        this[target-index++] = entry
    resize target-index

  /**
  Removes the last entry that is equal to the given $needle.

  Does nothing if the $needle is not in this instance.
  This operation is in `O(n)` and thus not efficient.

  It is an error to call this method on lists that can't change size.
  */
  remove --last/bool needle -> none:
    if last != true: throw "Argument Error"
    for i := size - 1; i >= 0; i--:
      entry := this[i]
      if entry == needle:
        for j := i + 1; j < size; j++:
          this[j - 1] = this[j]
        resize size - 1
        break

  /**
  Clears this list, setting the size to 0.

  It is an error to call this method on lists that can't change size.
  */
  clear -> none:
    resize 0

  /**
  Concatenates this list with the $other list.
  Returns a new $List object.

  # Inheritance
  Subclasses may return a subclass of $List, but should mention this in the documentation
    or in the return-type.
  */
  operator + other/List -> List:
    result := []
    result.resize size + other.size
    index := 0
    do:       result[index++] = it
    other.do: result[index++] = it
    return result

  /**
  Whether this instance is equal to $other, using $element-equals to compare
    the elements.

  Equality only returns true when both operands are of the same type.

  Returns false, if this instance and $other are not of the same $size, or if
    the contained elements are not equal themselves (using $element-equals).

  It is an error to compare self-recursive data-structures, if the $element-equals
    block is not ensuring that the comparison leads to infinite loops.

  # Inheritance
  Collections do *not* need to ensure that recursive data structures don't lead to
    infinite loops.
  */
  equals other/List [--element-equals] -> bool:
    // TODO(florian): we want to check whether the given [other] is in fact a List of
    // the same type.
    if other is not List: return false
    if size != other.size: return false
    size.repeat:
      if not element-equals.call this[it] other[it]: return false
    return true

  /** See $super. */
  operator == other -> bool:
    if other is not List: return false
    return equals other --element-equals=: |a b| a == b

  /** See $super. */
  do [block]:
    this-size := size
    this-size.repeat: block.call this[it]
    // It is not allowed to change the size of the list while iterating over it.
    assert: size == this-size

  /**
  Iterates over all elements in reverse order and invokes the given $block on each of them.

  The argument $reversed must be true.
  */
  do --reversed/bool [block] -> none:
    if reversed != true: throw "Argument Error"
    l := size - 1
    size.repeat: block.call this[l - it]

  /**
  The first element of the list.
  The list must not be empty.
  */
  first:
    return this[0]

  /**
  The last element of the list.
  The list must not be empty.
  */
  last:
    return this[size - 1]

  /**
  Invokes the given $block on each element and returns a new list with the results.
  */
  map [block] -> List:
    return map_ [] block

  /**
  Invokes the given $block on each element and stores the result in this list if
    $in-place is true.
  If $in-place is false, then this function is equivalent to $(map [block]).
  */
  // We have a second function here, since the `block` has implicitly a different
  // type. It needs to have T->T.
  // That said: would also be convenient to just reuse the list and change its type.
  map --in-place/bool [block] -> List:
    return map_ (in-place ? this : []) block

  map_ target/List [block] -> List:
    this-size := size
    target.resize this-size
    this-size.repeat: target[it] = block.call this[it]
    // It is an error to modify the list (in size) while iterating over it.
    assert: size == this-size
    return target

  /**
  Filters this instance using the given $predicate.

  Returns a new list if $in-place is false. Returns this instance otherwise.

  The result contains all the elements of this instance for which the $predicate returns
    true.
  */
  filter --in-place/bool=false [predicate] -> List:
    target := in-place ? this : []
    this-size := size
    target.resize this-size
    result-size := 0
    this-size.repeat:
      element := this[it]
      if predicate.call element: target[result-size++] = element
    // It is not allowed to modify the list (in size) while iterating over it.
    assert: size == this-size
    target.resize result-size
    return target

  /**
  Fills $value into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size value:
    (to - from).repeat: this[it + from] = value

  /**
  Fills values, computed by evaluating $block, into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size [block]:
    (to - from).repeat: this[it + from] = block.call it

  /** See $super. */
  stringify -> string:
    str := "["
    size.repeat:
      if it != 0: str = str + ", "
      str = str + this[it].stringify
    return str + "]"

  /**
  Calls stringify on each element of the list, and concatenates the results
    into one string, using the separator.

  # Examples
  ```
  [1, 2].join ", "  // "1, 2"
  ```
  */
  join separator/string -> string:
    result := join_ 0 size separator: it.stringify
    if result == "": return result
    return result

  /**
  Calls the block on each element of the list, and concatenates the results
    into one string, using the separator.

  # Examples
  ```
  [1, 2].join ", ": "0x$(%02x it)"  // "0x01, 0x02"
  ```
  */
  join separator/string [stringify] -> string:
    result := join_ 0 size separator stringify
    if result == "": return result
    return result

  join_ from to separator [stringify]:
    if from == to: return ""
    if from + 1 == to: return stringify.call this[from]
    middle := from + ((to - from) >> 1)
    left := join_ from middle separator stringify
    right := join_ middle to separator stringify
    return "$left$separator$right"

  static INSERTION-SORT-LIMIT_ ::= 16
  static TEMPORARY-BUFFER-MINIMUM_ ::= 16

  /**
  Sorts the range [$from..$to[ using the given $compare block. The sort is stable,
    meaning that equal elements do not change their relative order.
  Returns a new list if $in-place is false. Returns this instance otherwise.

  The $compare block should take two arguments `a` and `b` and should return:
  - -1 if `a < b`,
  -  0 if `a == b`, and
  -  1 if `a > b`.
  */
  sort --in-place/bool=false from/int = 0 to/int = size [compare] -> List:
    result := in-place ? this : copy
    length := to - from
    if length <= INSERTION-SORT-LIMIT_:
      result.insertion-sort_ from to compare
      return result
    // Create temporary merge buffer.  It is one quarter the size of the list
    // we are sorting.  This means the top level recursions are 25%-75% of the
    // array and, at the second level, 25%-50%.  All other recursions are on
    // almost equal-sized halves.
    buffer := Array_
      max TEMPORARY-BUFFER-MINIMUM_ ((length + 3) >> 2)
    result.merge-sort_ from to buffer compare
    return result

  /**
  Sorts the range [$from..$to[ using the the < and > operators.  The sort is
    stable, meaning that equal elements do not change their relative order.
  Returns a new list if $in-place is false. Returns this instance otherwise.
  */
  sort --in-place/bool=false from/int = 0 to/int = size -> List:
    return sort --in-place=in-place from to: | a b | compare_ a b

  /**
  Searches for $needle in the range $from (inclusive) - $to (exclusive).
  If $last is false (the default) returns the index of the first occurrence
    of $needle in the given range $from - $to. Otherwise returns the last
    occurrence.

  The optional range $from - $to must satisfy: 0 <= $from <= $to <= $size

  Returns -1 if $needle is not contained in the range.
  */
  index-of --last/bool=false needle from/int=0 to/int=size -> int:
    return index-of --last=last needle from to --if-absent=: -1

  /**
  Variant of $(index-of --last needle from to).
  Calls $if-absent without argument if the $needle is not contained
    in the range, and returns the result of the call.
  */
  // TODO(florian): once we have labeled breaks, we could require the
  //   block to return an int, and let users write `break.index_of other_type`.
  index-of --last/bool=false needle from/int=0 to/int=size [--if-absent]:
    if not 0 <= from <= size: throw "BAD ARGUMENTS"
    if not last:
      for i := from; i < to; i++:
        if this[i] == needle: return i
    else:
      for i := to - 1; i >= from; i--:
        if this[i] == needle: return i
    return if-absent.call

  /**
  Variant of $(index-of --last needle from to).
  Uses binary search, with `<`, `>` and `==`, to find the element.
  The given range must be sorted.
  Searches for $needle in the sorted range $from (inclusive) - $to (exclusive).
  Uses binary search with `<`, `>` and `==` to find the $needle.
  The $binary flag must be true.
  */
  index-of --binary/bool needle from/int=0 to/int=size -> int:
    return index-of --binary needle from to --if-absent=: -1

  /**
  Variant of $(index-of --binary needle from to).
  If not found, calls $if-absent with the smallest index at which the
    element is greater than $needle. If no such index exists (either because
    this instance is empty, or because the first element is greater than
    the needle) calls $if-absent with $to (where $to was adjusted
    according to the rules in $(index-of --last needle from to)).
  */
  index-of --binary/bool needle from/int=0 to/int=size [--if-absent]:
    comp := : | a b |
      if a < b:      -1
      else if a == b: 0
      else:           1
    return index-of --binary-compare=comp  needle from to --if-absent=if-absent

  /**
  Variant of $(index-of --binary needle from to).
  Uses $binary-compare to compare the elements in the sorted range.
  The $binary-compare block always receives one of the list elements as
    first argument, and the $needle as second argument.
  */
  index-of needle from/int=0 to/int=size [--binary-compare] -> int:
    return index-of --binary-compare=binary-compare needle from to --if-absent=: -1

  /**
  Variant of $(index-of --binary needle from to [--if-absent]).
  Uses $binary-compare to compare the elements in the sorted range.
  The $binary-compare block always receives one of the list elements as
    first argument, and the $needle as second argument.
  */
  index-of needle from/int=0 to/int=size [--binary-compare] [--if-absent]:
    if not 0 <= from <= size: throw "BAD ARGUMENTS"
    if from == to: return if-absent.call from
    last-comp := binary-compare.call this[to - 1] needle
    if last-comp == 0: return to - 1
    if last-comp < 0: return if-absent.call to
    first-comp := binary-compare.call this[from] needle
    if first-comp == 0: return from
    if first-comp > 0: return if-absent.call from
    while from < to:
      // Invariant 1: this[from] <= needle < this[to]
      mid := from + (to - from) / 2
      // Invariant 2: mid != from unless from + 1 == to.
      // Also: mid != to.
      comp := binary-compare.call this[mid] needle
      if comp == 0: return mid
      if comp > 0:
        to = mid
      else:
        from = mid
        // Either `from` changed, or from + 1 == to. (Invariant 2)
        // Due to invariant2, we hit the break if from didn't change.
        if (binary-compare.call this[mid + 1] needle) > 0: break
    return if-absent.call from + 1

  is-sorted [compare]:
    if is-empty: return true
    reduce: | a b | if (compare.call a b) > 0: return false else: b
    return true

  is-sorted:
    return is-sorted: | a b | compare_ a b

  swap i j:
    t := this[i]
    this[i] = this[j]
    this[j] = t

  merge-sort_ from/int to/int buffer/Array_ [compare] -> none:
    if to - from <= INSERTION-SORT-LIMIT_:
      insertion-sort_ from to compare
      return
    middle := from + (min buffer.size ((to - from) >> 1))
    merge-sort_ from middle buffer compare
    merge-sort_ middle to buffer compare
    // Merge the two sorted parts.
    merged := from   // All elements to the left of this are in sorted order.
    right := middle  // Unmerged right-half elements are to the right of this.
    r := this[right]
    // As an optimization, check for the buffer being already in correct order.
    if (compare.call this[right - 1] r) <= 0: return
    // Skip the leftmost elements that are already in order vs. the leftmost of
    // the right-part element.
    while (compare.call this[merged] r) <= 0:
      merged++
      // If we return here the compare method is returning inconsistent
      // results, since we already checked for the two halves being already
      // sorted.
      if merged == right: return
    buffer.replace 0 this merged middle  // Copy left side to temporary buffer.
    left := 0        // Unmerged left-half elements are to the right of this.
    left-end := middle - merged
    l := buffer[left]
    if (compare.call this[to - 1] l) < 0:  // Presorted in reverse order.
      replace merged this middle to
      replace (to - left-end) buffer 0 left-end
      return
    while true:
      if (compare.call l r) <= 0:
        this[merged++] = l
        left++
        if left == left-end:            // No more to merge from left side.
          assert: merged == right       // Rest of list is already in place.
          return                        // We are done.
        l = buffer[left]
      else:
        this[merged++] = r
        right++
        if right == to:                 // No more to merge from right side.
          replace merged buffer left left-end  // Rest of unmerged elements.
          return
        r = this[right]

  insertion-sort_ from/int to/int [compare]:
    for i := from + 1; i < to; i++:
      element := this[i]
      if (compare.call element this[i - 1]) < 0:
        j := i - 2
        while j >= from:
          if (compare.call element this[j]) >= 0:
            break
          j--
        replace (j + 2) this j + 1 i
        this[j + 1] = element

  compare_ a b:
    return (a > b) ? 1 : (a < b ? -1 : 0)

  /**
  Calls the given $block with indexes splitting the $from-$to range into chunks
    of the $available size.  The block is called with three arguments:
    `chunk_from`, `chunk_to`, and `chunk_size`, where `chunk_size`
    is always equal to `chunk_to - chunk_from`.  The first invocation
    receives indexes for at most $available elements. Subsequent
    invocations switch to $max-available elements (which by default is
    the same as $available).  Returns $to - $from.
  */
  static chunk-up from/int to/int available/int max-available/int=available [block] -> int:
    result := to - from
    to-do := to - from
    chunk := min available to-do
    while to-do > 0:
      block.call from from + chunk chunk
      to-do -= chunk
      from += chunk
      chunk = min max-available to-do
    return result

/** Internal function to create a list literal with one element. */
create-array_ x -> Array_:
  array := Array_ 1 null
  array[0] = x
  return array

/** Internal function to create a list literal with two elements. */
create-array_ x y -> Array_:
  array := Array_ 2 null
  array[0] = x
  array[1] = y
  return array

/** Internal function to create a list literal with three elements. */
create-array_ x y z -> Array_:
  array := Array_ 3 null
  array[0] = x
  array[1] = y
  array[2] = z
  return array

/** Internal function to create a list literal with four elements. */
create-array_ x y z u -> Array_:
  array := Array_ 4 null
  array[0] = x
  array[1] = y
  array[2] = z
  array[3] = u
  return array

/**
A non-growable list.

This class is the most efficient way of storing elements, but requires the user to
  know the size of the list in advance.
*/
abstract class Array_ extends List:
  // Factory methods.
  constructor size/int filler=null:
    // TODO(florian): we are instantiating a SmallArray here. It would be cleaner
    //   if we could do this in the subclass instead.
    // TODO(florian): currently avoids the call to the super constructor.
    //   That's fine here, but feels not right.
    #primitive.core.array-new:
      if it == "OUT_OF_RANGE": return LargeArray_ size filler
      throw it

  /** Creates an array and initializes each element with the result of invoking the block. */
  constructor size/int [block]:
    result := Array_ size
    size.repeat: result[it] = block.call it
    return result

  constructor.from collection/Collection:
    result := Array_ collection.size
    i := 0
    collection.do: result[i++] = it
    return result

  constructor.from-subclass_:
    super.from-subclass

  do [block]:
    return do_ this.size block

  // Optimized helper method for iterating over the array elements.
  abstract do_ end/int [block] -> none

  /// Create a new array, copying up to $copy-size elements from this array.
  abstract resize-for-list_ copy-size/int new-size/int filler -> Array_

  /**
  Returns the given $collection as an $Array_.

  If it is already one, returns the input.
  Otherwise copies the content of the $collection into a freshly allocated $Array_.
  */
  static ensure collection/Collection -> Array_:
    if collection is Array_:
      // TODO(florian): remove this hack.
      //   Requires that `is` checks are taken into account for typing.
      tmp := null
      tmp = collection
      return tmp
    return Array_.from collection

  /** See $super. */
  resize new-size:
    throw "COLLECTION_CANNOT_CHANGE_SIZE"

  /** See $super. */
  operator + collection -> Array_:
    result := Array_ size + collection.size
    index := 0
    do: result[index++] = it
    collection.do: result[index++] = it
    return result

  copy from/int=0 to/int=size -> Array_:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    result-size := to - from
    result := Array_ result-size
    result.replace 0 this from to
    return result

/** An array for limited number of elements. */
class SmallArray_ extends Array_:
  // TODO(florian) remove the constructor.
  // Currently SmallArrays_ are exclusively allocated through a native call in $Array_.
  constructor.internal_:
    throw "Should never be used."
    super.from-subclass_

  /// See $super.
  size -> int:
    #primitive.core.array-length

  /// Returns the $n'th element in the array.
  operator [] n/int -> any:
    #primitive.core.array-at

  /// Updates the $n'th element in the array with $value.
  operator []= n/int value/any -> any:
    #primitive.core.array-at-put

  /// Iterates through the array elements up to, but not including, the
  ///   element at the $end index, and invokes $block on them
  do_ end/int [block] -> none:
    #primitive.intrinsics.array-do:
      // The intrinsic only fails if we cannot call the block with a single
      // argument. We force this to throw by doing the same here.
      block.call this[0]

  /// Creates a new array of size $new-size, copying up to $copy-size elements from this array.
  resize-for-list_ copy-size/int new-size/int filler -> Array_:
    #primitive.core.array-expand:
      // Fallback if the primitive fails.  For example, the primitive can only
      // create SmallArray_ so we hit this on the border between SmallArray_
      // and LargeArray_.

      result := Array_ new-size filler
      result.replace 0 this 0 (min copy-size new-size)
      return result

  replace index/int source from/int to/int -> none:
    #primitive.core.array-replace:
      super index source from to

/**
An array for a larger number of elements.

LargeArray_ is used for arrays that cannot be allocated in one page of memory.
The implementation segments the payload into chunks of at most ARRAYLET_SIZE elements.
*/
class LargeArray_ extends Array_:

  // Just small enough to fit one per page (two per page on 32 bits).
  // Must match objects.h.
  static ARRAYLET-SIZE ::= 500

  constructor size/int:
    return LargeArray_ size null

  constructor .size_/int filler/any:
    if size_ <= ARRAYLET-SIZE: throw "OUT_OF_RANGE"
    full-arraylets := size_ / ARRAYLET-SIZE
    remaining := size_ % ARRAYLET-SIZE
    if remaining == 0:
      vector_ = Array_ full-arraylets
    else:
      vector_ = Array_ full-arraylets + 1
      vector_[full-arraylets] = Array_ remaining filler
    full-arraylets.repeat:
      vector_[it] = Array_ ARRAYLET-SIZE filler
    // TODO(florian): remove this hack.
    super.from-subclass_

  constructor.internal_ .vector_ .size_:
    // TODO(florian): remove this hack.
    super.from-subclass_

  constructor.with-arraylet_ arraylet new-size:
    assert: arraylet is SmallArray_
    assert: arraylet.size == ARRAYLET-SIZE
    assert: ARRAYLET-SIZE < new-size <= ARRAYLET-SIZE * 2
    size_ = new-size
    vector_ = Array_ 2
    vector_[0] = arraylet
    vector_[1] = Array_ new-size - ARRAYLET-SIZE
    super.from-subclass_

  // An expansion or shrinking that uses the backing arraylets from the old
  // array.  Used by List, Set, and Map.
  resize-for-list_ copy-size/int new-size/int filler:
    // Rounding up division.
    number-of-arraylets := ((new-size - 1) / ARRAYLET-SIZE) + 1
    if number-of-arraylets == 1:
      return vector_[0].resize-for-list_ copy-size new-size filler
    new-vector := Array_ number-of-arraylets  // new_vector may be a LargeArray_!
    remaining := new-size
    pos := 0
    number-of-arraylets.repeat:
      arraylet := ?
      limit := min remaining ARRAYLET-SIZE
      if pos + limit <= size:
        arraylet = vector_[it]
        // Sometimes from and to are reversed, which harmlessly does nothing.
        arraylet.fill --from=(max 0 (copy-size - pos)) --to=limit filler
      else:
        arraylet = Array_ limit filler
        if pos < copy-size:
          old-arraylet := vector_[it]
          arraylet.replace 0 old-arraylet 0 (min limit (copy-size - pos))
      new-vector[it] = arraylet
      remaining -= limit
      pos += limit
    assert: remaining == 0
    return LargeArray_.internal_ new-vector new-size

  size -> int:
    return size_

  operator [] n/int -> any:
    if n is not int: throw "WRONG_OBJECT_TYPE"
    if not 0 <= n < size_: throw "OUT_OF_BOUNDS"
    return vector_[n / ARRAYLET-SIZE][n % ARRAYLET-SIZE]

  operator []= n/int value/any -> any:
    if n is not int: throw "WRONG_OBJECT_TYPE"
    if not 0 <= n < size_: throw "OUT_OF_BOUNDS"
    return vector_[n / ARRAYLET-SIZE][n % ARRAYLET-SIZE] = value

  /// Iterates through the array elements up to, but not including, the
  ///   element at the $end index. Uses $SmallArray_.do_ to make the
  ///   iteration over the parts efficient.
  do_ end/int [block] -> none:
    if end <= 0: return
    full-arraylets := end / ARRAYLET-SIZE
    remaining := end % ARRAYLET-SIZE
    full-arraylets.repeat:
      vector_[it].do_ ARRAYLET-SIZE block
    if remaining != 0:
      vector_[full-arraylets].do_ remaining block

  /** Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[ */
  replace index/int source from/int=0 to/int=source.size -> none:
    count := to - from
    if count < 5:
      super index source from to
      return
    dest-div := index / ARRAYLET-SIZE
    dest-mod := index % ARRAYLET-SIZE
    first-chunk-max := ARRAYLET-SIZE - dest-mod
    if source is SmallArray_:
      List.chunk-up from to first-chunk-max ARRAYLET-SIZE: | from to length |
        vector_[dest-div++].replace dest-mod source from to
        dest-mod = 0
    else if source is LargeArray_:
      // The accelerated version requires SmallArray_, so do it on the arraylets.
      if index <= from or not identical source this:
        source-div := from / ARRAYLET-SIZE
        source-mod := from % ARRAYLET-SIZE
        // Because of alignment, each arraylet of the destination may take values
        // from two arraylets of the source.
        List.chunk-up from to first-chunk-max ARRAYLET-SIZE: | _ _ length |
          part1-size := min length (ARRAYLET-SIZE - source-mod)
          vector_[dest-div].replace dest-mod source.vector_[source-div] source-mod (source-mod + part1-size)
          if length != part1-size:
            // Copy part two from the next source arraylet.
            vector_[dest-div].replace (dest-mod + part1-size) source.vector_[source-div + 1] 0 (length - part1-size)
          source-mod += length
          if source-mod >= ARRAYLET-SIZE:
            source-div++
            source-mod -= ARRAYLET-SIZE
          dest-mod = 0
          dest-div++
      else:
        // Copying to a higher index, we have to do it backwards from the end
        // because of aliasing.
        source-div := to / ARRAYLET-SIZE
        source-mod := to % ARRAYLET-SIZE
        // These three were calculated wrong for backwards iteration, so redo
        // them here.
        dest-div = (index + count) / ARRAYLET-SIZE
        dest-mod = (index + count) % ARRAYLET-SIZE
        first-chunk-max = dest-mod
        // Because of alignment, each arraylet of the destination may take
        // values from two arraylets of the source.  Since we are ignoring the
        // first two block args we can just negate and swap the `to` and `from`
        // to iterate backwards.
        List.chunk-up -to -from first-chunk-max ARRAYLET-SIZE: | _ _ length |
          part1-size := min length source-mod
          vector_[dest-div].replace (dest-mod - part1-size) source.vector_[source-div] (source-mod - part1-size) source-mod
          if length != part1-size:
            // Copy part two from the next source arraylet.
            vector_[dest-div].replace (dest-mod - length) source.vector_[source-div - 1] (ARRAYLET-SIZE - length + part1-size) ARRAYLET-SIZE
          source-mod -= length
          if source-mod <= 0:
            source-div--
            source-mod += ARRAYLET-SIZE
          dest-mod = ARRAYLET-SIZE
          dest-div--
    else:  // Not SmallArray_ or LargeArray_.
      super index source from to

  size_ /int ::= 0
  vector_ /Array_ ::= ?  // This is the array of arraylets.  It may itself be a LargeArray_!

/**
A container specialized for bytes.

A byte array can only contain (non-null) integers in the range 0-255.
*/
interface ByteArray:

  /**
  Creates a new byte array of the given $size.

  All elements are initialized to the $filler, which defaults to 0.
  */
  constructor size/int --filler/int=0:
    #primitive.core.byte-array-new

  /**
  Creates a new byte array of the given $size and initializes the elements
    using the provided $initializer.
  The $initializer is invoked for each element, receiving the index as argument.
  */
  constructor size/int [initializer]:
    result := ByteArray size
    size.repeat: result[it] = initializer.call it
    return result

  /**
  The number of bytes in this instance.
  */
  size

  /**
  Whether this instance is empty.
  */
  is-empty -> bool

  /**
  Compares this instance to $other.

  Returns whether the $other instance is a $ByteArray with the same content.
  */
  operator == other -> bool

  /**
  Returns a hash code that depends on the content of this ByteArray.
  */
  hash-code -> int

  /**
  Invokes the given $block on each byte of this instance.
  */
  do [block]

  /**
  Iterates over all bytes in reverse order and invokes the given $block on each of them.

  The argument $reversed must be true.
  */
  do --reversed/bool [block] -> none

  /**
  Whether all bytes satisfy the given $predicate.
  Returns true, if the byte array is empty.
  */
  every [predicate] -> bool

  /**
  Whether there is at least one byte that satisfies the given $predicate.
  Returns false, if the byte array is empty.
  */
  any [predicate] -> bool

  /**
  The first element of this instance.
  The byte array must not be empty.
  */
  first -> int

  /**
  The last element of this instance.
  The byte array must not be empty.
  */
  last -> int

  /**
  Returns the $n'th byte.
  */
  operator [] n/int -> int

  /**
  Sets the $n'th byte to $value.

  The $value is truncated to byte size if necessary, only using the
    least-significant 8 bits.
  */
  operator []= n/int value/int -> int

  /**
  Returns a slice of this byte array.

  Slices are views on the underlying object. As such they see and modify
    the object they come from.

  The parameter $from is inclusive.
  The parameter $to is exclusive.

  # Advanced
  Slices keep the whole underlying object alive. This can lead to memory
    waste if the underlying object is not used otherwise. In some cases it
    might thus make sense to call $copy on the slice.

  At the call-site the arguments $from and $to are passed in with the slice
    syntax: `list[from..to]`. Since both arguments are optional (as they have
    default values), it is valid to omit `from` or `to`.

  # Examples
  ```
  bytes := #[1, 2, 3, 4, 5]
  sub := bytes[1..3] // A view into [2, 3]
  sub[0] = 22
  print bytes  // => [1, 22, 3, 4, 5]
  ```
  */
  operator [..] --from/int=0 --to/int=size -> ByteArray

  /**
  Converts this instance to a string, interpreting its bytes as UTF-8.
  */
  to-string from/int=0 to/int=size -> string

  /** Deprecated. Use $binary.ByteOrder.float64 instead. */
  to-float from/int --big-endian/bool?=true -> float

  /**
  Converts the UTF-8 byte array to a string.

  Invalid UTF-8 sequences are replaced with the Unicode replacement
    character, `\uFFFD`.
  */
  to-string-non-throwing from=0 to=size

  /**
  Whether this instance has a valid UTF-8 string content in the range $from-$to.
  */
  is-valid-string-content from/int=0 to/int=size -> bool

  /**
  Concatenates this instance with $other.
  */
  operator + other/ByteArray -> ByteArray

  /**
  Creates a copy of a slice of this instance.

  The arguments $from and $to must satisfy: `0 <= from <= to <= size`.
  */
  copy from/int=0 to/int=size -> ByteArray

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[
  */
  replace index/int source from/int to/int -> none
  // TODO(florian): use optional arguments in the interface.
  replace index/int source from/int -> none
  replace index/int source -> none

  /**
  Fills $value into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size value

  /**
  Fills values, computed by evaluating $block, into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size [block]

  /**
  Returns the index of the first occurrence of the $byte.
  Returns -1 otherwise.
  */
  index-of byte/int --from/int=0 --to/int=size -> int

/** Internal function to create a byte array with one element. */
create-byte-array_ x/int -> ByteArray_:
  bytes := ByteArray_ 1
  bytes[0] = x
  return bytes

/** Internal function to create a byte array with one element. */
create-byte-array_ x/int y/int -> ByteArray_:
  bytes := ByteArray_ 2
  bytes[0] = x
  bytes[1] = y
  return bytes

/** Internal function to create a byte array with one element. */
create-byte-array_ x/int y/int z/int -> ByteArray_:
  bytes := ByteArray_ 3
  bytes[0] = x
  bytes[1] = y
  bytes[2] = z
  return bytes

/**
The base class for ByteArray implementations.
*/
abstract class ByteArrayBase_ implements ByteArray:

  /**
  The number of bytes in this instance.
  */
  abstract size -> int

  /**
  Returns the $n'th byte.
  */
  abstract operator [] n/int -> int

  /**
  Sets the $n'th byte to $value.

  The $value is truncated to byte size if necessary, only using the
    least-significant 8 bits.
  */
  abstract operator []= n/int value/int -> int

  operator [..] --from/int=0 --to/int=size -> ByteArray:
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    if from == 0 and to == size: return this
    return ByteArraySlice_ this from to

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[

  # Inheritance
  Use $replace-generic_ as fallback if the primitive operation failed.
  */
  abstract replace index source from/int=0 to/int=source.size -> none

  /**
  Whether this instance is empty.
  */
  is-empty -> bool:
    return size == 0

  /**
  Compares this instance to $other.

  Returns whether the $other instance is a $ByteArray with the same content.
  */
  operator == other -> bool:
    if other is not ByteArray: return false
    #primitive.core.blob-equals

  /**
  Returns a hash code that depends on the content of this ByteArray.
  */
  hash-code -> int:
    #primitive.core.blob-hash-code

  /**
  Invokes the given $block on each element of this instance.
  */
  do [block]:
    this-size := size
    this-size.repeat: block.call this[it]
    // It is not allowed to change the size of the list while iterating over it.
    assert: size == this-size

  /**
  Iterates over all elements in reverse order and invokes the given $block on each of them.

  The argument $reversed must be true.
  */
  do --reversed/bool [block] -> none:
    if reversed != true: throw "Argument Error"
    l := size - 1
    size.repeat: block.call this[l - it]

  /**
  Whether every byte satisfies the given $predicate.
  Returns true, if the collection is empty.
  */
  every [predicate] -> bool:
    do: if not predicate.call it: return false
    return true

  /**
  Whether there is a byte that satisfies the given $predicate.
  Returns false, if the collection is empty.
  */
  any [predicate] -> bool:
    do: if predicate.call it: return true
    return false

  /**
  The first element of the list.
  The byte array must not be empty.
  */
  first -> int:
    return this[0]

  /**
  The last element of the list.
  The byte array must not be empty.
  */
  last -> int:
    return this[size - 1]

  /**
  Converts this instance to a string, interpreting its bytes as UTF-8.
  Invalid UTF-8 sequences are rejected with an exception.  This includes
    overlong encodings, encodings of UTF-16 surrogates and encodings of
    values that are outside the Unicode range.
  */
  to-string from/int=0 to/int=size -> string:
    #primitive.core.byte-array-convert-to-string

  /// Deprecated. Use $binary.ByteOrder.float64 instead.
  to-float from/int --big-endian/bool?=true -> float:
    bin := big-endian ? binary.BIG-ENDIAN : binary.LITTLE-ENDIAN
    bits := bin.int64 this from
    return float.from-bits bits

  do-utf8-with-replacements_ from to [block]:
    for i := from; i < to; i++:
      c := this[i]
      bytes := 1
      if c >= 0xf0:
        bytes = 4
      else if c >= 0xe0:
        bytes = 3
      else if c >= 0xc0:
        bytes = 2
      if i + bytes > to or not is-valid-string-content i i + bytes:
        block.call i 1 false
      else:
        block.call i bytes true
        i += bytes - 1 // Skip some.

  /// Converts the UTF-8 byte array to a string.  If we encounter invalid UTF-8
  ///   we replace sequences of invalid bytes with a Unicode replacement
  ///   character, `\uFFFD`.
  to-string-non-throwing from=0 to=size:
    if is-valid-string-content from to:
      return to-string from to
    len := 0
    last-was-replacement := false
    do-utf8-with-replacements_ from to: | i bytes ok |
      if ok:
        len += bytes
        last-was-replacement = false
      else if not last-was-replacement:
        len += 3  // Length of replacement character \uFFFD.
        last-was-replacement = true
    ba := ByteArray len
    len = 0
    last-was-replacement = false
    do-utf8-with-replacements_ from to: | i bytes ok |
      if ok:
        bytes.repeat:
          ba[len++] = this[i + it]
        last-was-replacement = false
      else if not last-was-replacement:
        ba[len++] = 0xef  // UTF-8 encoding of \uFFFD.
        ba[len++] = 0xbf
        ba[len++] = 0xbd
        last-was-replacement = true
    return ba.to-string

  /**
  Whether this instance has a valid UTF-8 string content in the range $from-$to.
  */
  is-valid-string-content from/int=0 to/int=size -> bool:
    #primitive.core.byte-array-is-valid-string-content

  /**
  Concatenates this instance with $other.
  Always creates a fresh byte array even if the receiver or the argument is empty.
  */
  operator + other/ByteArray -> ByteArray:
    result := ByteArray size + other.size
    result.replace 0 this
    result.replace size other
    return result

  /**
  Creates a copy of a slice of this ByteArray.

  The arguments $from and $to must satisfy: `0 <= from <= to <= size`.
  */
  copy from/int=0 to/int=size -> ByteArray_:
    target := ByteArray_ to - from
    target.replace 0 this from to
    return target

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[
  */
  replace-generic_ index/int source from/int to/int -> none:
    len := to - from
    if index <= from:
      len.repeat:
        this[index + it] = source[from + it]
    else:
      end := index + len
      len.repeat:
        i := it + 1
        this[end - i] = source[to - i]

  /**
  Fills $value into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size value:
    if from == 0 and to == size:
      bitmap.bytemap-zap this value
    else if to - from < 10:
      // Cutoff tuned for ESP32 - tradeoff between looping and alllocating a slice object.
      (to - from).repeat: this[it + from] = value
    else:
      bitmap.bytemap-zap this[from..to] value

  /**
  Fills values, computed by evaluating $block, into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size [block]:
    (to - from).repeat: this[it + from] = block.call it

  stringify:
    // Don't print more than 50 elements.
    to-be-printed-count := min 50 size
    if to-be-printed-count == 0: return "#[]"
    ba := (", 0x00" * to-be-printed-count).to-byte-array
    ba[0] = '#'
    ba[1] = '['
    to-be-printed-count.repeat:
      byte := this[it]
      ba[it * 6 + 4] = "0123456789abcdef"[byte >> 4]
      ba[it * 6 + 5] = "0123456789abcdef"[byte & 0xf]
    if to-be-printed-count == size:
      return ba.to-string + "]"
    else:
      return (ba.to-string) + ", ...]"

  index-of byte/int --from/int=0 --to/int=size -> int:
    #primitive.core.blob-index-of

/**
A container specialized for bytes.

A byte array can only contain (non-null) integers in the range 0-255.
*/
class ByteArray_ extends ByteArrayBase_:

  /**
  Creates a new byte array of the given $size.

  All elements are initialized to 0.
  */
  constructor size/int --filler/int=0:
    #primitive.core.byte-array-new

  constructor.external_ size/int:
    #primitive.core.byte-array-new-external

  /**
  The number of bytes in this instance.
  */
  size:
    #primitive.core.byte-array-length

  /**
  Returns the $n'th byte.
  */
  operator [] n/int -> int:
    #primitive.core.byte-array-at

  /**
  Sets the $n'th byte to $value.

  The $value is truncated to byte size if necessary, only using the
    least-significant 8 bits.
  */
  operator []= n/int value/int -> int:
    #primitive.core.byte-array-at-put

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[
  */
  replace index/int source from/int=0 to/int=source.size -> none:
    #primitive.core.byte-array-replace:
      // TODO(florian): why can't we throw here?
      replace-generic_ index source from to

  // Returns true if the byte array has raw bytes as opposed to an off-heap C struct.
  is-raw-bytes_ -> bool:
    #primitive.core.byte-array-is-raw-bytes

  stringify:
    if not is-raw-bytes_: return "Proxy"
    return super

/**
A Slice of a ByteArray.

The ByteArray slice is simply a view into an existing byte array.
*/
class ByteArraySlice_ extends ByteArrayBase_:
  // The order of fields is important as the primitives read them out
  // directly.
  byte-array_ / ByteArray
  from_ / int
  to_ / int

  constructor .byte-array_ .from_ .to_:
    if not 0 <= from_ <= to_ <= byte-array_.size:
      throw "OUT_OF_BOUNDS"

  size:
    return to_ - from_

  operator [] n/int -> int:
    actual-index := from_ + n
    if not from_ <= actual-index < to_: throw "OUT_OF_BOUNDS"
    return byte-array_[actual-index]

  operator []= n/int value/int -> int:
    actual-index := from_ + n
    if not from_ <= actual-index < to_: throw "OUT_OF_BOUNDS"
    return byte-array_[actual-index] = value

  operator [..] --from/int=0 --to/int=size -> ByteArray:
    actual-from := from_ + from
    actual-to := from_ + to
    if not from_ <= actual-from <= actual-to <= to_: throw "OUT_OF_BOUNDS"
    return ByteArraySlice_ byte-array_ actual-from actual-to

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[
  */
  replace index/int source from/int=0 to/int=source.size -> none:
    actual-index := from_ + index
    if from == to and actual-index == to_: return
    if not from_ <= actual-index < to_: throw "OUT_OF_BOUNDS"
    if actual-index + (to - from) <= to_:
      byte-array_.replace actual-index source from to
    else:
      replace-generic_ index source from to

/**
Internal function to create a list literal with any elements stored in array.
*/
create-list-literal-from-array_ array/Array_ -> List: return List_.from-array_ array

/**
Creates a List backed by a constant ByteArray.
This is an internal function and should only be used by the compiler.
*/
create-cow-byte-array_ byte-array -> CowByteArray_:
  return CowByteArray_ byte-array

class CowByteArray_ implements ByteArray:
  // The byte-array backing must be first, so that the primitives use that one.
  // The second field must be whether the byte array is mutable.
  backing_ /ByteArray_ := ?
  is-mutable_ := false

  constructor .backing_:

  index-of byte/int --from/int=0 --to/int=size -> int:
    return backing_.index-of byte --from=from --to=to

  size:
    return backing_.size

  is-empty -> bool:
    return size == 0

  operator == other -> bool:
    return backing_ == other

  hash-code -> int:
    #primitive.core.blob-hash-code

  do [block] -> none:
    backing_.do block

  do --reversed/bool [block] -> none:
    backing_.do --reversed=reversed block

  every [predicate] -> bool:
    return backing_.every predicate

  any [predicate] -> bool:
    return backing_.any predicate

  first -> int:
    return backing_.first

  last -> int:
    return backing_.last

  operator [] n/int -> int:
    return backing_[n]

  operator []= n/int value/int -> int:
    return ensure-mutable_[n] = value

  operator [..] --from=0 --to=size -> ByteArray:
    // We are not allowed to redirect to `mutable or immutable` as
    // a slice must always see the latest value.
    if from == 0 and to == size: return this
    return ByteArraySlice_ this from to

  to-string from/int=0 to/int=size -> string:
    return backing_.to-string from to

  /// Deprecated. Use $binary.ByteOrder.float64 instead.
  to-float from/int --big-endian/bool?=true -> float:
    byte-order /binary.ByteOrder := big-endian
        ? binary.BIG-ENDIAN
        : binary.LITTLE-ENDIAN
    return byte-order.float64 backing_ from

  to-string-non-throwing from=0 to=size:
    return backing_.to-string-non-throwing from to

  is-valid-string-content from/int=0 to/int=size -> bool:
    return backing_.is-valid-string-content from to

  operator + other/ByteArray -> ByteArray:
    return backing_ + other

  copy from/int=0 to/int=size -> ByteArray:
    return backing_.copy from to

  replace index/int source from/int=0 to/int=source.size -> none:
    ensure-mutable_.replace index source from to

  fill --from/int=0 --to/int=size value:
    ensure-mutable_.fill --from=from --to=to value

  fill --from/int=0 --to/int=size [block]:
    ensure-mutable_.fill --from=from --to=to block

  stringify:
    return backing_.stringify

  ensure-mutable_ -> ByteArray_:
    if not is-mutable_:
      backing_ = backing_.copy
      is-mutable_ = true
    return backing_

class ListSlice_ extends List:
  list_ / List
  from_ / int
  to_ / int

  constructor sublist/List .from_ .to_:
    if sublist is ListSlice_:
      slice := sublist as ListSlice_
      if not 0 <= from_ <= to_ <= slice.size: throw "OUT_OF_BOUNDS"
      sublist = slice.list_
      from_ += slice.from_
      to_ += slice.from_
    list_ = sublist
    super.from-subclass

  operator [] index:
    actual-index := from_ + index
    if not from_ <= actual-index < to_: throw "OUT_OF_BOUNDS"
    // If the underlying list changed size this might throw.
    return list_[actual-index]

  operator []= index value:
    actual-index := from_ + index
    if not from_ <= actual-index < to_: throw "OUT_OF_BOUNDS"
    // If the underlying list changed size this might throw.
    return list_[actual-index] = value

  operator [..] --from=0 --to=size -> List:
    actual-from := from_ + from
    actual-to := from_ + to
    if not from_ <= actual-from <= actual-to <= to_: throw "OUT_OF_BOUNDS"
    // Note that we don't actually check whether the underlying list has changed
    // size.
    return ListSlice_ list_ actual-from actual-to

  size -> int:
    return to_ - from_

  copy from/int=0 to/int=size -> List:
    actual-from := from_ + from
    actual-to := from_ + to
    if not from_ <= actual-from <= actual-to <= to_: throw "OUT_OF_BOUNDS"
    // If the underlying list changed size this might throw.
    return list_.copy actual-from actual-to

  replace index/int source from/int=0 to/int=source.size -> none:
    actual-index := from_ + index
    actual-index-end := actual-index + to - from
    if not from_ <= actual-index <= actual-index-end <= to_: throw "OUT_OF_BOUNDS"
    list_.replace actual-index source from to

  resize new-size -> none:
    throw "SLICE_CANNOT_CHANGE_SIZE"

/**
The implementation class for the standard growable list.
This class is used for list literals.
*/
class List_ extends List:
  constructor:
    array_ = Array_ 0
    super.from-subclass

  constructor.from-array_ array/Array_:
    array_ = array
    size_ = array.size
    super.from-subclass

  constructor.private_ backing-size size:
    array_ = Array_ backing-size
    size_ = size
    super.from-subclass

  /** See $super. This is an optimized implementation. */
  do [block]:
    return array_.do_ size_ block

  /** See $super. This is an optimized implementation. */
  remove-last:
    array := array_
    size := size_
    index := size - 1
    result := array[index]
    array[index] = null
    size_ = index
    return result

  /** See $super. */
  size:
    return size_

  /** See $super. */
  resize new-size:
    if size_ < new-size:
      array-size := array_.size
      if array-size < new-size:
        // Use powers of two: 4, 8, 16, 32, 64, 128, 256
        // then move to arraylet steps, 500, 1000, 1500,...
        // After about 8000, go back to a mild geometric growth.
        new-array-size := (array-size < LargeArray_.ARRAYLET-SIZE / 2)
          ? array-size + array-size
          : (round-up (array-size + 1 + (array-size >> 4)) LargeArray_.ARRAYLET-SIZE)
        if new-array-size < LIST-INITIAL-LENGTH_: new-array-size = LIST-INITIAL-LENGTH_
        while new-array-size < new-size: new-array-size += 1 + (new-array-size >> 1)
        array_ = array_.resize-for-list_ size_ new-array-size null

      size_ = new-size
    else:
      if new-size < array_.size - LargeArray_.ARRAYLET-SIZE:
        array_ = array_.resize-for-list_ size_ (round-up new-size LargeArray_.ARRAYLET-SIZE) null
      // Clear entries so they can be GC'ed.
      limit := min size_ array_.size
      for i := new-size; i < limit; i++:
        array_[i] = null
      size_ = new-size

  /** See $super. */
  operator [] index:
    if index is not int: throw "WRONG_OBJECT_TYPE"
    if index >= size_: throw "OUT_OF_BOUNDS"
    return array_[index]

  /** See $super. */
  operator []= index value:
    if index is not int: throw "WRONG_OBJECT_TYPE"
    if index >= size_: throw "OUT_OF_BOUNDS"
    return array_[index] = value

  /** See $super. */
  // This override is present in order to make use of the accelerated replace
  // method on Array_.
  replace index/int source from/int=0 to/int=source.size -> none:
    if source is ListSlice_:
      slice := source as ListSlice_
      if not 0 <= from <= to <= source.size: throw "OUT_OF_BOUNDS"
      from += slice.from_
      to += slice.from_
      source = slice.list_
    if source is List_:
      // Array may be bigger than this List_, so we must check for
      // that before delegating to the Array_ method, while being
      // careful about integer overflow.
      len := to - from
      if not 0 <= index <= index + to - from <= size: throw "OUT_OF_BOUNDS"
      array_.replace index source.array_ from to
    else:
      super index source from to

  /** See $super. */
  copy from/int=0 to/int=size -> List:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    result-size := to - from
    result := List_            // Uses singleton empty array as backing.
    result.resize result-size  // Allocates a backing array of the right size.
    result.array_.replace 0 this.array_ from to
    return result

  sort --in-place/bool=false from/int = 0 to/int = size_ [compare] -> List_:
    if from < 0 or from > to or to > size_: throw "OUT_OF_BOUNDS"
    result := in-place ? this : copy
    result.array_.sort --in-place from to compare
    return result

  // TODO(kasper): The interpreter depends on the order of these two fields. Clean
  // that up and make sure we validate the indexes assigned to them.
  array_ := ?
  size_ := 0

/// Special return value for find_, indicating we need to grow the backing.
// Must be coordinated with the value in interpreter_run.cc.
APPEND_ ::= -1

class Tombstone_:
  // Do not move - this field is read from the HASH_DO intrinsic code in
  // interpreter_run.cc.  Note that the native code (and the Toit code here)
  // assume that instances with a non-zero skip value are only used in one
  // place, and can be mutated, whereas the instance with zero skip is a
  // singleton that may not be modified.
  skip_/int := ?

  static SMALL-SKIPS_ ::= 9

  constructor.private_ .skip_:

  // Get skip distance ignoring entries that indicate backwards skip distance.
  skip -> int:
    if skip_ < 1: return 1
    return skip_

  // Get skip distance ignoring entries that indicate forwards skip distance.
  skip-backwards default-step -> int:
    if skip_ > -1: return default-step
    return skip_

  // May return a new object with the correct skip or may mutate the current object.
  increase-distance-to skp:
    assert: not -10 <= skp <= 10
    if skip_ == 0: return Tombstone_.private_ skp
    skip_ = skp
    return this

/// 'Tombstone' that marks deleted entries in the backing.
SMALL-TOMBSTONE_ ::= Tombstone_.private_ 0

/**
Implementation for hash maps and hash sets that separates the hash table and
  the keys/values.  The implementation is inspired by the PyPy insertion
  ordered dictionaries:
  https://morepypy.blogspot.com/2015/01/faster-more-memory-efficient-and-more.html
The keys (and values, in the case of the map) are stored in an array called
  the backing.  This is ordered in insertion order, so new elements are
  appended.  The actual hashing takes place in a parallel data structure
  called the index, which is an array of 'slots'.  This is an 'open
  addressing' hash table, ie it does not have buckets.

Backing: |K|V|K|V|K|V|K|V...  alternating keys and values.
Index: |F|I|I|F|F|I|F|I...  free slots and slots with integers.

The index serves to map hashes to positions in the backing object.  It
  functions similarly to standard open-address hash tables.  Since we need to
  be able to mark free slots we reserve the 0 index for free slots and add 1
  to all the stored positions.

Each slot only needs the position, but we store the last 8 bits of the hash
  too, for efficiency.

A lookup starts with the hash code, which tells us where to start searching
  in the index.  At each search point we either find.
* A free slot.  This means the key was not found.
* A non-matching hash code (low 8 bits).  We continue a linear search.
* A matching hash code and a non-matching key at the given position.  Keep
  searching.
* A matching hash code and a matching key.  Successful lookup.

We use triangle numbers to advance to the next slot when searching the
  index, searching at offsets 1, 3, 6, 10... from the initial guess.  This
  helps to avoid 'hot spots' of hash collisions caused by bad hash_code
  implementations, eg the java.lang.Integer hashCode() which returns the
  integer.  We tried stepping forwards at offsets 1, 2, 3, 4, ...  from the
  initial guess, using 'Fibonacci hashing' to make hot-spots less likely.  This
  did not work well with our string hash algorithm, suffering greatly from
  hot-spots.

The index grows when occupancy hits about 90%.  See the comment at
  $pick-new-index-size_.

Since we want to be able to iterate the keys and values by simply walking
  the backing array we mark any removals from the hash table there.  We use an
  instance of the Tombstone_ class as a marker on both the key and value of a
  deleted position.  No change is made in the index.  Deletion is fairly rare
  and this allows us to ignore it most of the time.  When there are too many
  deleted positions in the backing we rebuild the hash table from the bottom,
  squeezing out any deleted positions.

Certain access patterns, including repeated removal of the first element,
  will result in long runs of deleted positions, which can cause quadratic
  behavior.  To avoid this, instances of the Tombstone_ class can contain a
  skip number, indicating that the next n positions are also deleted.
*/
abstract class HashedInsertionOrderedCollection_:
  // The offsets of these four fields are used by the hash_find intrinsic in
  // the interpreter, so we can't move them.
  size_ := 0
  index-spaces-left_ := 0
  index_ := null
  backing_ := null

  /** Removes all elements from this instance. */
  clear -> none:
    size_ = 0
    index-spaces-left_ = 0
    index_ = null
    backing_ = null

  abstract rebuild_ old-size --allow-shrink/bool

  compare_ key key-or-probe:
    return key == key-or-probe

  hash-code_ key:
    return key.hash-code

  /** The number of elements in this instance. */
  size -> int:
    return size_

  /** Whether this instance is empty. */
  is-empty -> bool:
    return size_ == 0

  /** Whether this instance contains the given $key. */
  contains key -> bool:
    action := find_ key: return false
    return true

  /** Whether this instance contains all elements of $collection. */
  contains-all collection/Collection -> bool:
    collection.do: if not contains it: return false
    return true

  /**
  Removes the given $key from this instance.

  The key does not need to be present.
  */
  remove key -> none:
    remove key --if-absent=: return

  /**
  Removes the given $key from this instance.

  If the key is absent, calls $if-absent with the key.
  */
  abstract remove key [--if-absent]

  /** Removes all elements of $collection from this instance. */
  remove-all collection/Collection -> none:
    collection.do: remove it --if-absent=: null

  /**
  Skips to next non-deleted entry, possibly updating the delete entry in the
    backing to make it faster the next time.
  */
  skip_ delete i limit:
    skip := delete.skip
    new-i := i + skip
    while new-i < limit and backing_[new-i] is Tombstone_:
      next-skip := backing_[new-i].skip
      skip += next-skip
      new-i += next-skip
    // There is a sufficient number of fields to skip, so create a bigger
    // skip entry.
    if skip > 10:
      backing_[i] = delete.increase-distance-to skip
    return new-i

  /**
  Skips to next non-deleted entry, possibly updating the delete entry in the
    backing to make it faster the next time.
  */
  skip-backwards_ delete i default-step:
    skip := delete.skip-backwards default-step
    new-i := i + skip
    while new-i >= 0 and backing_[new-i] is Tombstone_:
      next-skip := backing_[new-i].skip-backwards default-step
      skip += next-skip
      new-i += next-skip
    // There is a sufficient number of fields to skip, so create a bigger
    // skip entry.
    if skip < -10:
      backing_[i] = delete.increase-distance-to skip
    return new-i

  // The index has sizes that are powers of 2.  This is a geometric
  //   progression, so it gives us amortized constant time growth.  We need a
  //   fast, deterministic way to get from the (prime-multiplied) hash code to an
  //   initial slot in the index.  Since sizes are a power of 2 we merely take
  //   the modulus of the size, which can be done by bitwise and-ing with the
  //   size - 1.
  // Returns the new index size.
  pick-new-index-size_ old-size --allow-shrink/bool -> int:
    minimum := allow-shrink ? 2 : index_.size * 2
    enough := 1 + old-size + (old-size >> 3)  // old_size * 1.125.
    new-index-size := max
      minimum
      1 << (64 - enough.count-leading-zeros)

    index-spaces-left_ = (new-index-size * 0.85).to-int
    if index-spaces-left_ <= old-size: index-spaces-left_ = old-size + 1
    // Found large enough index size.
    return new-index-size

  /// We store this much of the hash code in each slot.
  static HASH-MASK_ ::= 0xfff
  static HASH-SHIFT_ ::= 12

  static INVALID-SLOT_ ::= -1

  /// Returns the position recorded for the $key in the index.  If the key is not
  ///   found, it calls the given block, which can either do a non-local return
  ///   (in which case the collection is unchanged) or return the position of the
  ///   next free position in the backing.  If the key was not found and the block
  ///   returns normally, a new entry is created in the index.  The position in
  ///   the backing is returned, or APPEND_, which indicates that the key was not
  ///   found and the block was called.  The caller doesn't strictly need the
  ///   APPEND_ return value, since it knows whether its block was called, but it
  ///   is often more convenient to use the return value.
  find_ key [not-found]:
    append-position := null  // Use null/non-null to avoid calling block twice.

    // TODO(erik): Multiply by a large prime to mix up bad hash codes, e.g.
    //               (0x1351d * (hash_code_ key)) & 0x3fffffff
    //             that doesn't allocate large integers.
    // Call this early so we can't get away with single-entry sets/maps
    // that have incompatible keys.
    hash := hash-code_ key

    if not index_:
      if size_ == 0:
        if not backing_: backing_ = List
        not-found.call  // May not return.
        return APPEND_
      else if size_ != 1:
        // Map built by deserializer, has no index.
        rebuild_ size --allow-shrink
      else:
        k := backing_[0]
        if k is not Tombstone_:
          if compare_ key k:
            return 0
          append-position = not-found.call
          rebuild_ 1 --allow-shrink
        else:
          rebuild_ 1 --allow-shrink

    return find-body_ key hash append-position not-found
      (: rebuild_ it --allow-shrink=false)
      (: | k1 k2 | compare_ k1 k2)

  // To be implemented by an intrinsic byte code.  Makes no calls apart from:
  // * Array.operator[]
  // * Array.operator[]=
  // * List.operator[]
  // * Block.call
  // * is Tombstone_
  // Note that each block call will cause the intrinsic to restart.  Therefore we
  // must store a state which enables us to know what to do when the byte code
  // restarts.  Two of the calls cause the method to restart, with no saved state
  // other than the parameters, which are modified - in this case we can reuse the
  // START state.
  // State vars:
  // * state (START, NOT_FOUND, REBUILD, or AFTER_COMPARE).
  // * old_size (used in REBUILD to call the rebuild block).
  // * deleted_slot (used in NOT_FOUND and AFTER_COMPARE reset in START).
  // * slot (used in NOT_FOUND and AFTER_COMPARE)
  // * position, slot_step, and starting_slot (used in AFTER_COMPARE).
  find-body_ key hash append-position [not-found] [rebuild] [compare]:
    #primitive.intrinsics.hash-find:
      // State START.
      while true:  // Loop to retry after rebuild.
        index-mask := index_.size - 1
        slot := hash & index-mask
        starting-slot := slot
        // The variable is initialized to the invalid slot, but updated to the
        // slot of the first deleted entry we find while searching for the key.
        // If we don't find the key (with its value), we will use the deleted
        // slot instead of a new one at the end of the probe sequence.
        deleted-slot := INVALID-SLOT_
        // Used for triangle-number probe order
        slot-step := 1
        while true:
          hash-and-position := index_[slot]
          if hash-and-position == 0:
            old-size := size_
            // Found free slot.
            if not append-position: append-position = not-found.call  // May not return.
            // State NOT_FOUND.
            if index-spaces-left_ == 0:
              // State REBUILD.
              rebuild.call old-size
              // Go to state START.
              break
            new-hash-and-position := ((append-position + 1) << HASH-SHIFT_) | (hash & HASH-MASK_)
            if deleted-slot < 0:
              index_[slot] = new-hash-and-position
              index-spaces-left_--
            else:
              index_[deleted-slot] = new-hash-and-position
            return APPEND_
            // End of state START.
          // Found non-free slot.
          position := (hash-and-position >> HASH-SHIFT_) - 1
          k := backing_[position]
          if deleted-slot == INVALID-SLOT_ and k is Tombstone_:
            deleted-slot = slot
          if hash-and-position & HASH-MASK_ == hash & HASH-MASK_:
            // Found hash match.
            if k is not Tombstone_ and (compare.call key k):
              // State AFTER_COMPARE where block returns true.
              // It's not obvious why we have to return APPEND_ here, after all,
              // we already found the entry in the index.  The reason is that the
              // not_found call can add an entry to the backing, then we find the
              // index is full.  Rebuilding the index puts the newly added
              // backing entry in the index, and so we find it when we do another
              // iteration of the outer loop here.
              return append-position ? APPEND_ : position
          // State AFTER_COMPARE where block returns false.
          slot = (slot + slot-step) & index-mask
          slot-step++
          if slot == starting-slot:  // Index is full and we didn't find the entry.
            old-size := size_
            // Give the caller the chance to add the entry to the backing.
            if not append-position: append-position = not-found.call  // May not return.
            // State REBUILD.
            // Rebuild - this makes a new index which can contain the new entry.
            rebuild.call old-size
            // Go to state START.
            break

  // Returns how far we got, or null if we are done.
  hash-do_ step reversed [block]:
    #primitive.intrinsics.hash-do:
      // If the intrinsic fails, return the start position.  This
      // is very rare because the intrinsic will generally return a
      // progress-indicating integer rather than failing.
      if backing_ == null: return null
      return reversed ? backing_.size - step : 0

  rebuild_ old-size/int step/int --allow-shrink/bool --rebuild-backing/bool:
    if rebuild-backing:
      // Rebuild backing to remove deleted elements.
      i := 0
      backing_.do:
        if it is not Tombstone_:
          backing_[i++] = it
      length := size_ * step
      backing_.resize size_ * step
    new-index-size := pick-new-index-size_ old-size --allow-shrink=allow-shrink
    index-mask := new-index-size - 1
    if not index_ or index-mask > HASH-MASK_ or rebuild-backing:
      // Rebuild the index using the backing array.
      // By using resize_for_list_ we reuse the arraylets when growing large
      // arrays.  This reduces GC churn and, more importantly, peak memory
      // usage.
      if index_:
        index_ = index_.resize-for-list_ /*copy_size=*/0 new-index-size /*filler=*/0
        index_.fill 0
      else:
        index_ = Array_ new-index-size 0
      assert: index_.size == new-index-size
      // Rebuild the index by iterating over the backing and entering each key
      // into the index in the conventional way.  During this operation, the
      // index is big enough and the backing does not change.  The find_ operation
      // does not compare keys again.  It knows that they were not equal when
      // they were first added to the collection, and keeps using that fact.
      size := backing_.size
      throw-block := (: | _ | throw null)  // During rebuild we never rebuild.
      false-block := (: | _ _ | false)     // During rebuild no objects are equal.
      for i := 0; i < size; i += step:
        key := backing_[i]
        if key is not Tombstone_:
          action := find-body_ key (hash-code_ key) null
            (: i)  // not_found block, returns the position of where to add the new entry.
            throw-block
            false-block
          assert: action == APPEND_
    else:
      // We can do an simple index rebuild from the old index.  There are
      // enough hash bits in the index slots to tell us where the slot goes in
      // the new index, so we don't need to call hash_code or equality for the
      // entries in the backing.
      old-index := index_
      index_ = Array_ new-index-size 0
      index-spaces-left_ -= size_
      simple-rebuild-hash-index_ old-index index_

simple-rebuild-hash-index_ old-index index_ -> none:
  #primitive.core.rebuild-hash-index:
    // Fallback version written in Toit.
    index-mask := index_.size - 1
    old-index.do: | hash-and-position |
      if hash-and-position != 0:
        slot := hash-and-position & index-mask
        slot-step := 1
        while index_[slot] != 0:
          slot = (slot + slot-step) & index-mask
          slot-step++
        index_[slot] = hash-and-position

/**
A set of keys.
The objects used as keys must have a hash_code method that returns
  an integer that does not change while the object is in the set.
The == operator should be compatible with the hash_code method so
  that objects that test equal also have the same hash code.
  However, objects that test unequal are not required to have
  different hash codes: Hash code clashes are allowed, but should
  be rare to maintain good performance.
Strings, byte arrays, and numbers fulfill these requirements and can be used as
  keys in sets.
See also https://docs.toit.io/language/listsetmap.
*/
class Set extends HashedInsertionOrderedCollection_ implements Collection:
  static STEP_ ::= 1

  /**
  Removes the given $key from this instance.

  If the key is absent, calls $if-absent with the $key.
  */
  remove key [--if-absent] -> none:
    position := find_ key:
      if-absent.call key
      return
    backing_[position] = SMALL-TOMBSTONE_
    size_--
    shrink-if-needed_

  /**
  Finds an object where you have the $hash code, but you haven't
    necessarily created the object yet.
  Returns either a matching object that was found in the set,
    or a newly created object that was returned by the not_found
    block and inserted into the set.
  If a matching entry is not found, then the $initial block
    is called.  It can create an object that will be added to
    the set, or it can non-locally return in which case the set
    is unchanged.  If it evaluates to null then nothing is added.
  When a potential match is found in the set, the $compare block
    is called with the potential match.  If it returns true then
    the find call returns the found object.  If it returns false
    the search continues.
  */
  get-by-hash_ hash/int [--initial] [--compare] -> any:
    if not index_:
      if size_ == 0:
        new-entry := initial.call
        if new-entry != null:
          add new-entry
        return new-entry
      assert: size_ == 1
      found := backing_[0]
      if found is not Tombstone_:
        if compare.call found:
          return found
      new-entry := initial.call
      if new-entry != null:
        add new-entry
      return new-entry

    append-position := -1
    find-body_ null hash null
      // Not found.
      (:
        new-entry := initial.call
        if new-entry == null:
          return null
        append-position = backing_.size
        backing_.add new-entry
        size_++
        append-position  // Return from block.
      )
      // Rebuild.
      (: rebuild_ it --allow-shrink=false)
      // Possible match found.
      (: | _ found |
        was-found := compare.call found
        if was-found: return found
        false
      )
    return backing_[append-position]

  /**
  Adds the given $key to this instance.
  If an equal key is already in this instance, it is overwritten by the new one.
  */
  add key -> none:
    position := find_ key:
      append-position := backing_.size
      backing_.add key
      size_++
      append-position  // Return from block.
    if position != APPEND_:
      backing_[position] = key

  /**
  Adds all elements of the given $collection to this instance.
  */
  add-all collection/Collection -> none:
    collection.do: add it

  /** See $Collection.do. */
  do [block] -> none:
    i := hash-do_ STEP_ false block
    if not i: return
    assert: backing_
    limit := backing_.size
    while i < limit:
      element := backing_[i]
      if element is not Tombstone_:
        block.call element
        i++
      else:
        i = skip_ element i limit

  /**
  Variant of $(Collection.do [block]).
  Iterates over the elements of this collection in reverse order.
  The flag $reversed must be true.
  */
  do --reversed/bool [block] -> none:
    if reversed != true: throw "Argument Error"
    i := hash-do_ STEP_ true block
    if not i: return
    assert: backing_
    while i >= 0:
      element := backing_[i]
      if element is not Tombstone_:
        block.call element
        i--
      else:
        i = skip-backwards_ element i -STEP_

  /** See $Collection.==. */
  operator == other/Set -> bool:
    if other is not Set: return false
    // TODO(florian): we want to be more precise and check for exact class-match?
    if other.size != size: return false
    other.do:
      if not contains it: return false
    return true

  /** See $Collection.every. */
  // TODO(florian): should be inherited from CollectionBase.
  every [predicate] -> bool:
    do: if not predicate.call it: return false
    return true

  /** See $Collection.any. */
  // TODO(florian): should be inherited from CollectionBase.
  any [predicate] -> bool:
    do: if predicate.call it: return true
    return false

  /** See $(Collection.reduce [block]). */
  // TODO(florian): should be inherited from CollectionBase.
  reduce [block]:
    if is-empty: throw "Not enough elements"
    result := null
    is-first := true
    do:
      if is-first: result = it; is-first = false
      else: result = block.call result it
    return result

  /** See $(Collection.reduce --initial [block]). */
  // TODO(florian): should be inherited from CollectionBase.
  reduce --initial [block]:
    result := initial
    do:
      result = block.call result it
    return result

  /**
  Invokes the given $block on each element and returns a new set with the results.
  */
  map [block] -> Set:
    return reduce --initial=Set: | set value |
      set.add (block.call value)
      set

  /**
  Filters this instance using the given $predicate.

  Returns a new set if $in-place is false (the default).
  Returns this instance if $in-place is true.

  The result contains all the elements of this instance for which the $predicate returns
    true.

  Users must not otherwise modify this instance during the operation.
  */
  filter --in-place/bool=false [predicate] -> Set:
    if not in-place:
      result := Set
      do: | key | if predicate.call key : result.add key
      return result
    limit := backing_ ? backing_.size : 0
    limit.repeat:
      key := backing_[it]
      if key is not Tombstone_ and not predicate.call key:
        backing_[it] = SMALL-TOMBSTONE_
        size_--
    shrink-if-needed_
    return this

  /**
  Intersects this instance with the $other set.

  The result contains all elements that are both in this instance, as well
    as in the $other set.

  Returns a new set if $in-place is false (the default).
  Returns this instance, if $in-place is true.
  */
  intersect --in-place/bool=false other/Set -> Set:
    return filter --in-place=in-place: other.contains it

  stringify:
    str := "{"
    first := true
    do:
      if first: first = false else: str = str + ", "
      str = str + it.stringify
    return str + "}"

  /**
  Returns an element that is equal to the $key.
  The key may be a lightweight object that has compatible hash code and equality to the element.
  */
  get key [--if-absent]:
    position := find_ key:
      return if-absent.call key
    return backing_[position]

  /**
  Returns an element that is equal to the $key.
  Returns null if this instance doesn't contain the $key.
  See $(get key [--if-absent]).
  */
  get key:
    position := find_ key:
      return null
    return backing_[position]

  /**
  The first element of the set by insertion order.
  Throws an error if the set is empty.
  */
  first:
    do: return it
    throw "Not enough elements"

  /**
  The last element of the set by insertion order.
  Throws an error if the set is empty.
  */
  last:
    do --reversed: return it
    throw "Not enough elements"

  shrink-if-needed_:
    if backing_ and backing_.size > 4 and backing_.size > size_ + (size_ >> 1):
      rebuild_ size_ STEP_ --allow-shrink --rebuild-backing

  rebuild_ old-size --allow-shrink/bool:
    rebuild_ old-size STEP_ --allow-shrink=allow-shrink --rebuild-backing=false

  /**
  Returns a list of the elements of this set.
  */
  to-list -> List:
    result := List size
    index := 0
    do:
      result[index++] = it
    return result

/**
A set that uses object identity instead of the == operator to test equality
  of elements. This set still uses the hash_code method on elements (see $Set). There is
  no identity hash code operation on arbitrary classes in Toit.
*/
class IdentitySet extends Set:

  hash-code_ key:
    return key.hash-code

  compare_ key key-or-probe:
    return identical key key-or-probe

/**
A map from key objects to values.
The objects used as keys must have a hash_code method that returns
  an integer that does not change while the object is in the map.
The == operator should be compatible with the hash_code method so
  that objects that test equal also have the same hash code.
  However, objects that test unequal are not required to have
  different hash codes: Hash code clashes are allowed, but should
  be rare to maintain good performance.
Strings, byte arrays, and numbers fulfill these requirements and can be used as
  keys in maps.
See also https://docs.toit.io/language/listsetmap.
*/
class Map extends HashedInsertionOrderedCollection_:
  static STEP_ ::= 2

  /**
  Constructs an empty map.
  */
  constructor:
    super

  /**
  Constructs a weak map where the values may be replaced by null when there is
    memory pressure.
  A cleanup task may remove keys whose values are null at some later point, but
    your program should not rely on this.  This cleanup task will also remove
    key-value pairs where the value was deliberately set to null.
  */
  constructor.weak:
    super
    add-gc-processing_ this::
      backing := backing_
      length := backing.size
      for position := 0; position < length; position += 2:
        key := backing[position]
        value := backing[position + 1]
        if key is Tombstone_ or value != null: continue
        backing[position] = SMALL-TOMBSTONE_
        backing[position + 1] = SMALL-TOMBSTONE_
        size_--

  /**
  Constructs a Map with a given $size.
  For each key-value pair, first the block $get-key and then the block $get-value are called.
  */
  constructor size [get-key] [get-value]:
    size.repeat: this[get-key.call it] = get-value.call it

  /**
  Removes the given $key from this instance.

  If the key is absent, calls $if-absent with the $key.
  */
  remove key [--if-absent] -> none:
    position := find_ key:
      if-absent.call key
      return
    backing_[position] = SMALL-TOMBSTONE_
    backing_[position + 1] = SMALL-TOMBSTONE_
    size_--
    shrink-if-needed_

  shrink-if-needed_:
    if backing_ and backing_.size > 8 and backing_.size > (size_ << 1) + size_:
      rebuild_ size_ STEP_ --allow-shrink --rebuild-backing

  rebuild_ old-size --allow-shrink/bool:
    rebuild_ old-size STEP_ --allow-shrink=allow-shrink --rebuild-backing=false

  /**
  Returns the element stored at location $key.
  The $key must be in the map.
  */
  operator [] key:
    position := find_ key:
      if key is string or key is num:
        throw "key '$key' not found"
      throw "key not found"
    assert: position != APPEND_
    return backing_[position + 1]

  /**
  Stores $value in the location for the given $key.
  If the $key is already present, overrides the previous value.
  */
  operator []= key value:
    action := find_ key:
      append-position := backing_.size
      backing_.add key
      backing_.add value
      size_++
      append-position  // Return from block.
    if action != APPEND_:
      backing_[action + 1] = value
    return value

  /**
  Retrieves the value for $key.

  Returns the value verbatim, if the $key is contained in the map.
  Returns null, otherwise.
  */
  get key: return get key --if-present=(: it) --if-absent=(: null)

  /**
  Retrieves the value for $key.

  Returns the value verbatim, if this instance contains the $key.
  Otherwise, calls $if-absent with the $key and returns the result of the call.
  */
  get key [--if-absent]:
    return get key --if-absent=if-absent --if-present=: it

  /**
  Retrieves the value for $key.

  If this instance contains the $key calls $if-present with the corresponding
    value and returns the result.
  Returns null otherwise.
  */
  get key [--if-present]:
    return get key --if-present=if-present --if-absent=: null

  /**
  Retrieves the value for $key.

  If this instance contains the $key calls $if-present with the corresponding
    value and returns the result.
  Otherwise, calls $if-absent with the $key and returns the result of the call.
  */
  get key [--if-present] [--if-absent]:
    action := find_ key: return if-absent.call key
    assert: action != APPEND_
    return if-present.call backing_[action + 1]

  /**
  Retrieves the value for $key.

  Returns the value verbatim, if this instance contains the $key.
  Otherwise, initializes the slot with the result of calling $init first.
  */
  get key [--init]:
    return get key
      --if-absent=:
        initial-value := init.call
        this[key] = initial-value
        return initial-value
      --if-present=: it

  /**
  Updates the value of the given $key.

  Calls the $updater with the current value, and replaces the old value with the result.
  Returns the result of calling the $updater.

  This instance must contain the $key.
  */
  update key [updater]:
    return update key updater --if-absent=: throw "key not found"

  /**
  Updates the value of the given $key.

  If this instance contains the $key, calls the $updater with the current value,
    and replaces the old value with the result. Returns the result of the call.

  If this instance does not contain the $key, calls $if-absent with the $key instead, and
    stores the result of the call in this instance. Returns the result of the call.
  */
  update key [updater] [--if-absent]:
    new-value := null
    position := find_ key:
      new-value = if-absent.call key
      append-position := backing_.size
      backing_.add key
      backing_.add new-value
      size_++
      append-position  // Return from block.
    if position != APPEND_:
      new-value = updater.call backing_[position + 1]
      backing_[position + 1] = new-value
    return new-value

  /**
  Updates the value of the given $key.

  If this instance contains the $key, calls the $updater with the current value,
    and replaces the old value with the result. Returns the result of the call.

  If this instance does not contain the $key, stores $if-absent in this instance. Returns $if-absent.
  */
  update key [updater] --if-absent:
    return update key updater --if-absent=: if-absent

  /**
  Updates the value of the given $key.

  If this instance does not contain the $key, calls $init with the $key first, and stores it
    in this instance.

  Calls the $updater with the current value (which might be the initial value that was
    just stored) and replaces the old value with the result.

  Returns the result of the call to the $updater.
  */
  update key [--init] [updater]:
    new-value := null
    position := find_ key:
      new-value = updater.call (init.call key)
      append-position := backing_.size
      backing_.add key
      backing_.add new-value
      size_++
      append-position  // Return from block.
    if position != APPEND_:
      new-value = updater.call backing_[position + 1]
      backing_[position + 1] = new-value
    return new-value

  /**
  Updates the value of the given $key.

  If this instance does not contain the $key, stores $init in this instance.

  Calls the $updater with the current value (which might be the initial value that was
    just stored) and replaces the old value with the result.

  Returns the result of the call to the $updater.
  */
  update key --init [updater]:
    return update key updater --init=: init

  /**
  Invokes the given $block on each key/value pair of this instance.
  The key/value pairs are iterated in key insertion order.
  Users must not modify this instance while iterating over it.
  */
  do [block] -> none:
    i := hash-do_ STEP_ false block
    if not i: return
    assert: backing_
    limit := backing_.size
    while i < limit:
      key := backing_[i]
      if key is not Tombstone_:
        block.call key backing_[i + 1]
        i += STEP_
      else:
        i = skip_ key i limit

  /**
  Variant of $(do [block]).
  Iterates over all key/value pairs in reverse order.
  The flag $reversed must be true.
  Users must not modify this instance while iterating over it.
  */
  do --reversed/bool [block] -> none:
    if reversed != true: throw "Argument Error"
    i := hash-do_ STEP_ true block
    if not i: return
    assert: backing_
    while i >= 0:
      key := backing_[i]
      if key is not Tombstone_:
        block.call key backing_[i + 1]
        i -= 2
      else:
        i = skip-backwards_ key i -STEP_

  /**
  Invokes the given $block on each key of this instance.
  Users must not modify this instance while iterating over it.

  The flag $keys must be true.
  */
  do --keys/bool --reversed/bool=false [block] -> none:
    if keys != true: throw "Bad Argument"
    if reversed:
      do --reversed: | key value | block.call key
    else:
      do: | key value | block.call key

  /**
  Invokes the given $block on each value of this instance.
  Users must not modify this instance while iterating over it.

  The flag $values must be true.
  */
  do --values/bool --reversed/bool=false [block] -> none:
    if values != true: throw "Bad Argument"
    if reversed:
      do --reversed: | key value | block.call value
    else:
      do: | key value | block.call value

  /**
  Returns the keys of this instance as a list.
  This operation instantiates a fresh list and is thus in O(n).
  When possible use $(do --keys [block]) instead.
  */
  keys -> List:
    result := List size_
    i := 0
    do: |key value| result[i++] = key
    return result

  /**
  Returns the values of this instance as a list.
  This operation instantiates a fresh list and is thus in O(n).
  When possible use $(do --values [block]) instead.
  */
  values -> List:
    result := List size_
    i := 0
    do: |key value| result[i++] = value
    return result

  /**
  Reduces the values of the map into a single value.
  See $(Collection.reduce [block]).
  */
  reduce --values/bool [block]:
    if values != true: throw "Bad Argument"
    if is-empty: throw "Not enough elements"
    result := null
    is-first := true
    do --values:
      if is-first: result = it; is-first = false
      else: result = block.call result it
    return result

  /**
  Reduces the values of the map into a single value.
  See $(Collection.reduce --initial [block]).
  */
  reduce --values/bool --initial [block]:
    if values != true: throw "Bad Argument"
    result := initial
    do --values:
      result = block.call result it
    return result

  /**
  Reduces the keys of the map into a single value.
  See $(Collection.reduce [block]).
  */
  reduce --keys/bool [block]:
    if keys != true: throw "Bad Argument"
    if is-empty: throw "Not enough elements"
    result := null
    is-first := true
    do --keys:
      if is-first: result = it; is-first = false
      else: result = block.call result it
    return result

  /**
  Reduces the keys of the map into a single value.
  See $(Collection.reduce --initial [block]).
  */
  reduce --keys/bool --initial [block]:
    if keys != true: throw "Bad Argument"
    result := initial
    do --keys:
      result = block.call result it
    return result

  /**
  Reduces the map entries into a single value.
  The given $block is called with three arguments:
    1. the accumulated result, so far
    2. the key of the current entry
    3. the value of the current entry.

  See $(Collection.reduce --initial [block]). */
  reduce --initial [block]:
    result := initial
    do: | key value |
      result = block.call result key value
    return result

  /**
  Whether at least one key in the map satisfies the given $predicate.
  The flag $keys must be true.
  Returns false, if the map is empty.
  */
  any --keys/bool [predicate] -> bool:
    if keys != true: throw "Bad Argument"
    do --keys: if predicate.call it: return true
    return false

  /**
  Whether at least one value in the map satisfies the given $predicate.
  The flag $values must be true.
  Returns false, if the map is empty.
  */
  any --values/bool [predicate] -> bool:
    if values != true: throw "Bad Argument"
    do --values: if predicate.call it: return true
    return false

  /**
  Whether at least one key-value pair in the map satisfies the given $predicate.
  The $predicate block is called with two arguments: a key, and its value.
  Returns false, if the map is empty.
  */
  any [predicate] -> bool:
    do: | key value | if predicate.call key value: return true
    return false

  /**
  Whether all keys in the map satisfy the given $predicate.
  The flag $keys must be true.
  Returns true, if the map is empty.
  */
  every --keys/bool [predicate] -> bool:
    if keys != true: throw "Bad Argument"
    do --keys: if not predicate.call it: return false
    return true

  /**
  Whether all values in the map satisfy the given $predicate.
  The flag $values must be true.
  Returns true, if the map is empty.
  */
  every --values/bool [predicate] -> bool:
    if values != true: throw "Bad Argument"
    do --values: if not predicate.call it: return false
    return true

  /**
  Whether all key-value pairs in the map satisfy the given $predicate.
  The $predicate block is called with two arguments: a key, and its value.
  Returns true, if the map is empty.
  */
  every [predicate] -> bool:
    do: | key value | if not predicate.call key value: return false
    return true

  /**
  Copies the map.
  The copy is shallow.
  */
  copy -> Map:
    return map: | _ value | value

  /**
  Invokes the given $block on each key/value pair and returns a new map with the results.

  The $block is invoked with two arguments for each entry in this instance:
    the key and the value. The returned value becomes the new value for the key.
  */
  map [block] -> Map:
    result := Map
    do: | key value | result[key] = block.call key value
    return result

  /**
  Maps the values of this instance.

  The flag $in-place must be true.

  Invokes the given $block on each key/value pair and replaces the old value with
    the result of the call.

  */
  map --in-place/bool [block] -> none:
    if in-place != true: throw "Bad Argument"
    limit := backing_ ? backing_.size : 0
    for i := 0; i < limit; i += STEP_:
      key := backing_[i]
      if key is not Tombstone_:
        new-value := block.call key backing_[i + 1]
        backing_[i + 1] = new-value

  /**
  Filters this instance using the given $predicate.

  Returns a new map if $in-place is false. Returns this instance otherwise.

  The result contains all the elements of this instance for which the $predicate returns
    true.

  Users must not otherwise modify this instance during the operation.
  */
  filter --in-place/bool=false [predicate] -> Map:
    if not in-place:
      result := Map
      do: | key value | if predicate.call key value: result[key] = value
      return result
    limit := backing_ ? backing_.size : 0
    for i := 0; i < limit; i += STEP_:
      key := backing_[i]
      value := backing_[i + 1]
      if key is not Tombstone_ and not predicate.call key value:
        backing_[i] = SMALL-TOMBSTONE_
        backing_[i + 1] = SMALL-TOMBSTONE_
        size_--
    shrink-if-needed_
    return this

  stringify:
    if is-empty: return "{:}"
    key-value-strings := []
    size := 0
    do: | key value |
      key-value-string := "$key.stringify: $value.stringify"
      size += key-value-string.size + 2
      if size > MAX-PRINT-STRING_:
        return "{$(key-value-strings.join ", ")..."
      key-value-strings.add key-value-string
    return "{$(key-value-strings.join ", ")}"

  /**
  The first key of the map by insertion order.
  Throws an error if the map is empty.
  */
  first:
    do: | key value | return key
    throw "Not enough elements"

  /**
  The last key of the map by insertion order.
  Throws an error if the map is empty.
  */
  last:
    do --reversed: | key value | return key
    throw "Not enough elements"

/**
A map that uses object identity instead of the == operator to test equality
  of keys. This map still uses the hash_code method on keys (see $Map). There is no
  identity hash code operation on arbitrary classes in Toit.
*/
class IdentityMap extends Map:

  hash-code_ key:
    return key.hash-code

  compare_ key key-or-probe:
    return identical key key-or-probe

/**
A double-ended queue.

A collection of items, where new items can be added at the end. They can
  be removed at the beginning and the end. These operations are efficient
  and use an amortized time of O(1).

A deque is a generalization of a stack and a queue, and can be used for both
  purposes.
*/
class Deque implements Collection:
  // Traditionally we would have a head index, a tail index and an array
  // backing, used as a circular buffer.  Instead we have only the tail index
  // (called first_) and use a growable list as backing, copying down when
  // there is enough free space.  This gives an extra level of indirection, but
  // the same amortized big-O performance, and much less code, avoiding all the
  // complications around wrapping around the end of the backing.  If we
  // determine that the collection is used very frequently and requires better
  // performance, we can reimplement with the a more traditional
  // implementation.
  first_ := 0
  backing_/List := []

  size -> int:
    return backing_.size - first_

  is-empty -> bool:
    return backing_.size == first_

  add element -> none:
    backing_.add element

  add-all collection/Collection -> none:
    backing_.add-all collection

  do [block]:
    backing_[first_..].do block

  do --reversed/bool [block] -> none:
    backing_[first_..].do --reversed block

  any [predicate] -> bool:
    return backing_[first_..].any predicate

  every [predicate] -> bool:
    return backing_[first_..].every predicate

  reduce [block]:
    return backing_[first_..].reduce block

  reduce --initial [block]:
    return backing_[first_..].reduce --initial=initial block

  contains element -> bool:
    return backing_[first_..].contains element

  clear -> none:
    backing_.clear
    first_ = 0

  first -> any:
    if first_ == backing_.size: throw "OUT_OF_RANGE"
    return backing_[first_]

  last -> any:
    if first_ == backing_.size: throw "OUT_OF_RANGE"
    return backing_.last

  remove-last -> any:
    if first_ == backing_.size: throw "OUT_OF_RANGE"
    result := backing_.remove-last
    shrink-if-needed_
    return result

  remove-first -> any:
    backing := backing_
    first := first_
    if first == backing.size: throw "OUT_OF_RANGE"
    result := backing[first]
    backing[first] = null
    first_++
    shrink-if-needed_
    return result

  add-first element -> none:
    first := first_
    if first == 0:
      padding-size := (backing_.size >> 1) + 1
      new_size := backing_.size + padding-size
      // Pad both ends so we are not inefficient in the case where the next
      // operation adds to the end.
      new_backing := List_.private_ (new_size + padding-size) new_size
      new_backing.replace padding-size backing_
      backing_ = new_backing
      first = padding-size
    first--
    backing_[first] = element
    first_ = first

  shrink-if-needed_ -> none:
    backing := backing_
    first := first_
    if first * 2 > backing.size:
      backing.replace 0 backing first first + size
      backing.resize size
      first_ = 0
