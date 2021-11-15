// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary

LIST_INITIAL_LENGTH_ ::= 4
HASHED_COLLECTION_INITIAL_LENGTH_ ::= 4
MAX_PRINT_STRING_ ::= 4000

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
  is_empty -> bool

  /**
  Whether every element in the collection satisfies the given $predicate.
  Returns true, if the collection is empty.
  */
  every [predicate] -> bool

  /**
  Whether any element in the collection satisfies the given $predicate.
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
  abstract do [block] -> none
  abstract size -> int
  abstract operator == other/Collection -> bool

  is_empty -> bool:
    return size == 0

  every [predicate] -> bool:
    do: if not predicate.call it: return false
    return true

  any [predicate] -> bool:
    do: if predicate.call it: return true
    return false

  contains element -> bool:
    return any: it == element

  reduce [block]:
    if is_empty: throw "Not enough elements"
    result := null
    is_first := true
    do:
      if is_first: result = it; is_first = false
      else: result = block.call result it
    return result

  reduce --initial [block]:
    result := initial
    do:
      result = block.call result it
    return result


abstract class List extends CollectionBase:

  /**
  Creates an empty list.
  This operation is identical to creating a list with a list-literal: `[]`.
  */
  constructor: return List_

  constructor.from_subclass:

  /**
  Creates a new List of the given $size where every slot is filled with the
    given $filler.
  */
  constructor size/int filler=null:
    return List_.from_array_ (Array_ size filler)

  /** Creates a List and initializes each element with the result of invoking the block. */
  constructor size/int [block]:
    return List_.from_array_ (Array_ size block)

  /** Creates a List, containing all elements of the given $collection */
  constructor.from collection/Collection:
    return List_.from_array_ (Array_.from collection)


  /**
  Changes the size of this list to the given $new_size.

  If the list grows as a result of this operation, then the elements are filled with null.
  If the list shrinks as a result of this operation, then these elements are dropped.
  */
  abstract resize new_size -> none

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
    #primitive.core.list_add:
      old_size := size
      resize old_size + 1
      this[old_size] = value

  /**
  Adds all elements of the given $collection to the list.
  This operation increases the size of this instance.
  It is an error to call this method on lists that can't grow.
  */
  add_all collection/Collection -> none:
    old_size := size
    resize old_size + collection.size
    index := old_size
    collection.do: this[index++] = it

  /**
  Removes the last element of this instance.
  Returns the removed element.

  It is an error to call this method on lists that can't change size.
  It is an error to call this method on empty lists.
  */
  remove_last:
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
    target_index := 0
    size.repeat:
      entry := this[it]
      if entry != needle:
        this[target_index++] = entry
    resize target_index

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
  Whether this instance is equal to $other, using $element_equals to compare
    the elements.

  Equality only returns true when both operands are of the same type.

  Returns false, if this instance and $other are not of the same $size, or if
    the contained elements are not equal themselves (using $element_equals).

  It is an error to compare self-recursive data-structures, if the $element_equals
    block is not ensuring that the comparison leads to infinite loops.

  # Inheritance
  Collections do *not* need to ensure that recursive data structures don't lead to
    infinite loops.
  */
  equals other/List [--element_equals] -> bool:
    // TODO(florian): we want to check whether the given [other] is in fact a List of
    // the same type.
    if other is not List: return false
    if size != other.size: return false
    size.repeat:
      if not element_equals.call this[it] other[it]: return false
    return true

  /** See $super. */
  operator == other -> bool:
    if other is not List: return false
    return equals other --element_equals=: |a b| a == b

  /** See $super. */
  do [block]:
    this_size := size
    this_size.repeat: block.call this[it]
    // It is not allowed to change the size of the list while iterating over it.
    assert: size == this_size

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
    $in_place is true.
  If $in_place is false, then this function is equivalent to $(map [block]).
  */
  // We have a second function here, since the `block` has implicitly a different
  // type. It needs to have T->T.
  // That said: would also be convenient to just reuse the list and change its type.
  map --in_place/bool [block] -> List:
    return map_ (in_place ? this : []) block

  map_ target/List [block] -> List:
    this_size := size
    target.resize this_size
    this_size.repeat: target[it] = block.call this[it]
    // It is an error to modify the list (in size) while iterating over it.
    assert: size == this_size
    return target

  /**
  Filters this instance using the given $predicate.

  Returns a new list if $in_place is false. Returns this instance otherwise.

  The result contains all the elements of this instance for which the $predicate returns
    true.
  */
  filter --in_place/bool=false [predicate] -> List:
    target := in_place ? this : []
    this_size := size
    target.resize this_size
    result_size := 0
    this_size.repeat:
      element := this[it]
      if predicate.call element: target[result_size++] = element
    // It is not allowed to modify the list (in size) while iterating over it.
    assert: size == this_size
    target.resize result_size
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

  join separator/string -> string:
    result := join_ 0 size separator: it.stringify
    if result == "": return result
    return result

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

  static INSERTION_SORT_LIMIT_ ::= 16
  static TEMPORARY_BUFFER_MINIMUM_ ::= 16

  /**
  Sorts the range [$from..$to[ using the given $compare block. The sort is stable,
    meaning that equal elements do not change their relative order.
  Returns a new list if $in_place is false. Returns this instance otherwise.

  The $compare block should take two arguments `a` and `b` and should return:
  - -1 if `a < b`,
  -  0 if `a == b`, and
  -  1 if `a > b`.
  */
  sort --in_place/bool=false from/int = 0 to/int = size [compare] -> List:
    result := in_place ? this : copy
    length := to - from
    if length <= INSERTION_SORT_LIMIT_:
      result.insertion_sort_ from to compare
      return result
    // Create temporary merge buffer.  It is one quarter the size of the list
    // we are sorting.  This means the top level recursions are 25%-75% of the
    // array and, at the second level, 25%-50%.  All other recursions are on
    // almost equal-sized halves.
    buffer := Array_
      max TEMPORARY_BUFFER_MINIMUM_ ((length + 3) >> 2)
    result.merge_sort_ from to buffer compare
    return result

  /**
  Sorts the range [$from..$to[ using the the < and > operators.  The sort is
    stable, meaning that equal elements do not change their relative order.
  Returns a new list if $in_place is false. Returns this instance otherwise.
  */
  sort --in_place/bool=false from/int = 0 to/int = size -> List:
    return sort --in_place=in_place from to: | a b | compare_ a b

  /**
  Searches for $needle in the range $from (inclusive) - $to (exclusive).
  If $last is false (the default) returns the index of the first occurrence
    of $needle in the given range $from - $to. Otherwise returns the last
    occurrence.

  The optional range $from - $to must satisfy: 0 <= $from <= $to <= $size

  Returns -1 if $needle is not contained in the range.
  */
  index_of --last/bool=false needle from/int=0 to/int=size -> int:
    return index_of --last=last needle from to --if_absent=: -1

  /**
  Variant of $(index_of --last needle from to).
  Calls $if_absent without argument if the $needle is not contained
    in the range, and returns the result of the call.
  */
  // TODO(florian): once we have labeled breaks, we could require the
  //   block to return an int, and let users write `break.index_of other_type`.
  index_of --last/bool=false needle from/int=0 to/int=size [--if_absent]:
    if not 0 <= from <= size: throw "BAD ARGUMENTS"
    if not last:
      for i := from; i < to; i++:
        if this[i] == needle: return i
    else:
      for i := to - 1; i >= from; i--:
        if this[i] == needle: return i
    return if_absent.call

  /**
  Variant of $(index_of --last needle from to).
  Uses binary search, with `<`, `>` and `==`, to find the element.
  The given range must be sorted.
  Searches for $needle in the sorted range $from (inclusive) - $to (exclusive).
  Uses binary search with `<`, `>` and `==` to find the $needle.
  The $binary flag must be true.
  */
  index_of --binary/bool needle from/int=0 to/int=size -> int:
    return index_of --binary needle from to --if_absent=: -1

  /**
  Variant of $(index_of --binary needle from to).
  If not found, calls $if_absent with the smallest index at which the
    element is greater than $needle. If no such index exists (either because
    this instance is empty, or because the first element is greater than
    the needle) calls $if_absent with $to (where $to was adjusted
    according to the rules in $(index_of --last needle from to)).
  */
  index_of --binary/bool needle from/int=0 to/int=size [--if_absent]:
    comp := : | a b |
      if a < b:      -1
      else if a == b: 0
      else:           1
    return index_of --binary_compare=comp  needle from to --if_absent=if_absent

  /**
  Variant of $(index_of --binary needle from to).
  Uses $binary_compare to compare the elements in the sorted range.
  The $binary_compare block always receives one of the list elements as
    first argument, and the $needle as second argument.
  */
  index_of needle from/int=0 to/int=size [--binary_compare] -> int:
    return index_of --binary_compare=binary_compare needle from to --if_absent=: -1

  /**
  Variant of $(index_of --binary needle from to [--if_absent]).
  Uses $binary_compare to compare the elements in the sorted range.
  The $binary_compare block always receives one of the list elements as
    first argument, and the $needle as second argument.
  */
  index_of needle from/int=0 to/int=size [--binary_compare] [--if_absent]:
    if not 0 <= from <= size: throw "BAD ARGUMENTS"
    if from == to: return if_absent.call from
    last_comp := binary_compare.call this[to - 1] needle
    if last_comp == 0: return to - 1
    if last_comp < 0: return if_absent.call to
    first_comp := binary_compare.call this[from] needle
    if first_comp == 0: return from
    if first_comp > 0: return if_absent.call from
    while from < to:
      // Invariant 1: this[from] <= needle < this[to]
      mid := from + (to - from) / 2
      // Invariant 2: mid != from unless from + 1 == to.
      // Also: mid != to.
      comp := binary_compare.call this[mid] needle
      if comp == 0: return mid
      if comp > 0:
        to = mid
      else:
        from = mid
        // Either `from` changed, or from + 1 == to. (Invariant 2)
        // Due to invariant2, we hit the break if from didn't change.
        if (binary_compare.call this[mid + 1] needle) > 0: break
    return if_absent.call from + 1

  is_sorted [compare]:
    if is_empty: return true
    reduce: | a b | if (compare.call a b) > 0: return false else: b
    return true

  is_sorted:
    return is_sorted: | a b | compare_ a b

  swap i j:
    t := this[i]
    this[i] = this[j]
    this[j] = t

  merge_sort_ from/int to/int buffer/Array_ [compare] -> none:
    if to - from <= INSERTION_SORT_LIMIT_:
      insertion_sort_ from to compare
      return
    middle := from + (min buffer.size ((to - from) >> 1))
    merge_sort_ from middle buffer compare
    merge_sort_ middle to buffer compare
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
    left_end := middle - merged
    l := buffer[left]
    if (compare.call this[to - 1] l) < 0:  // Presorted in reverse order.
      replace merged this middle to
      replace (to - left_end) buffer 0 left_end
      return
    while true:
      if (compare.call l r) <= 0:
        this[merged++] = l
        left++
        if left == left_end:            // No more to merge from left side.
          assert: merged == right       // Rest of list is already in place.
          return                        // We are done.
        l = buffer[left]
      else:
        this[merged++] = r
        right++
        if right == to:                 // No more to merge from right side.
          replace merged buffer left left_end  // Rest of unmerged elements.
          return
        r = this[right]

  insertion_sort_ from/int to/int [compare]:
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
    invocations switch to $max_available elements (which by default is
    the same as $available).  Returns $to - $from.
  */
  static chunk_up from/int to/int available/int max_available/int=available [block] -> int:
    result := to - from
    to_do := to - from
    while to_do > 0:
      chunk := min available to_do
      block.call from from + chunk chunk
      to_do -= chunk
      from += chunk
      available = max_available
    return result

/** Internal function to create a list literal with one element. */
create_array_ x -> Array_:
  array := Array_ 1 null
  array[0] = x
  return array

/** Internal function to create a list literal with two elements. */
create_array_ x y -> Array_:
  array := Array_ 2 null
  array[0] = x
  array[1] = y
  return array

/** Internal function to create a list literal with three elements. */
create_array_ x y z -> Array_:
  array := Array_ 3 null
  array[0] = x
  array[1] = y
  array[2] = z
  return array

/** Internal function to create a list literal with four elements. */
create_array_ x y z u -> Array_:
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
    #primitive.core.array_new:
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

  constructor.from_subclass_:
    super.from_subclass

  do [block]:
    return do_ this.size block

  // Optimized helper method for iterating over the array elements.
  abstract do_ end/int [block] -> none

  /** Create a new array, copying up to old_length elements from this array. */
  resize_for_list_ old_length/int new_length/int -> Array_:
    result := Array_ new_length
    for i := 0; i < old_length and i < new_length; i++:
      result[i] = this[i]
    return result

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
  resize new_size:
    throw "ARRAY_CANNOT_CHANGE_SIZE"

  /** See $super. */
  operator + collection -> Array_:
    result := Array_ size + collection.size
    index := 0
    do: result[index++] = it
    collection.do: result[index++] = it
    return result

  copy from/int=0 to/int=size -> Array_:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    result_size := to - from
    result := Array_ result_size
    result.replace 0 this from to
    return result

/** An array for limited number of elements. */
class SmallArray_ extends Array_:
  // TODO(florian) remove the constructor.
  // Currently SmallArrays_ are exclusively allocated through a native call in $Array_.
  constructor.internal_:
    throw "Should never be used."
    super.from_subclass_

  /// See $super.
  size -> int:
    #primitive.core.array_length

  /// Returns the $n'th element in the array.
  operator [] n/int -> any:
    #primitive.core.array_at

  /// Updates the $n'th element in the array with $value.
  operator []= n/int value/any -> any:
    #primitive.core.array_at_put

  /// Iterates through the array elements up to, but not including, the
  ///   element at the $end index, and invokes $block on them
  do_ end/int [block] -> none:
    #primitive.intrinsics.array_do:
      // The intrinsic only fails if we cannot call the block with a single
      // argument. We force this to throw by doing the same here.
      block.call null

  stringify -> string:
    return "Array of size $size"

  /// Creates a new array of size $new_length, copying up to $old_length elements from this array.
  resize_for_list_ old_length/int new_length/int -> Array_:
    #primitive.core.array_expand:
      // Fallback if the primitive fails.  For example, the primitive can only
      // create SmallArray_ so we hit this on the border between SmallArray_
      // and LargeArray_.
      if old_length == LargeArray_.ARRAYLET_SIZE:
        return LargeArray_.with_arraylet_ this new_length
      return super old_length new_length

  replace index/int source from/int to/int -> none:
    #primitive.core.array_replace:
      super index source from to

/**
An array for a larger number of elements.

LargeArray_ is used for arrays that cannot be allocated in one page of memory.
The implementation segments the payload into chunks of at most ARRAYLET_SIZE elements.
*/
class LargeArray_ extends Array_:

  // Just small enough to fit one per page (two per page on 32 bits).
  // Must match objects.h.
  static ARRAYLET_SIZE ::= 500

  constructor size/int:
    return LargeArray_ size null

  constructor .size_/int filler/any:
    full_arraylets := size_ / ARRAYLET_SIZE
    left := size_ % ARRAYLET_SIZE
    if left == 0:
      vector_ = Array_ full_arraylets
    else:
      vector_ = Array_ full_arraylets + 1
      vector_[full_arraylets] = Array_ left filler
    full_arraylets.repeat:
      vector_[it] = Array_ ARRAYLET_SIZE filler
    // TODO(florian): remove this hack.
    super.from_subclass_

  constructor.internal_ .vector_ .size_:
    // TODO(florian): remove this hack.
    super.from_subclass_

  constructor.with_arraylet_ arraylet new_size:
    assert: arraylet is SmallArray_
    assert: arraylet.size == ARRAYLET_SIZE
    assert: ARRAYLET_SIZE < new_size <= ARRAYLET_SIZE * 2
    size_ = new_size
    vector_ = Array_ 2
    vector_[0] = arraylet
    vector_[1] = Array_ new_size - ARRAYLET_SIZE
    super.from_subclass_

  // An expand that uses the backing arraylets from the old array.  Used by List.
  resize_for_list_ old_size/int new_size/int:
    // Rounding up division.
    number_of_arraylets := ((new_size - 1) / ARRAYLET_SIZE) + 1
    new_vector := Array_ number_of_arraylets
    left := new_size
    number_of_arraylets.repeat:
      if (it + 1) * ARRAYLET_SIZE <= old_size:
        new_vector[it] = vector_[it]
        left -= ARRAYLET_SIZE
      else:
        limit := min left ARRAYLET_SIZE
        arraylet := Array_ limit
        new_vector[it] = arraylet
        if it * ARRAYLET_SIZE < old_size:
          old_arraylet := vector_[it]
          arraylet.replace 0 old_arraylet 0 (old_size % ARRAYLET_SIZE)
        left -= limit
    assert: left == 0
    return LargeArray_.internal_ new_vector new_size

  size -> int:
    return size_

  operator [] n/int -> any:
    if n is not int: throw "WRONG_OBJECT_TYPE"
    if not 0 <= n < size_: throw "OUT_OF_BOUNDS"
    return vector_[n / ARRAYLET_SIZE][n % ARRAYLET_SIZE]

  operator []= n/int value/any -> any:
    if n is not int: throw "WRONG_OBJECT_TYPE"
    if not 0 <= n < size_: throw "OUT_OF_BOUNDS"
    return vector_[n / ARRAYLET_SIZE][n % ARRAYLET_SIZE] = value

  /// Iterates through the array elements up to, but not including, the
  ///   element at the $end index. Uses $SmallArray_.do_ to make the
  ///   iteration over the parts efficient.
  do_ end/int [block] -> none:
    if end <= 0: return
    full_arraylets := end / ARRAYLET_SIZE
    left := end % ARRAYLET_SIZE
    full_arraylets.repeat:
      vector_[it].do_ ARRAYLET_SIZE block
    if left != 0:
      vector_[full_arraylets].do_ left block

  size_ /int ::= 0
  vector_ /Array_ ::= ?

/**
A container specialized for bytes.

A byte array can only contain (non-null) integers in the range 0-255.
*/
interface ByteArray:

  /**
  Creates a new byte array of the given $size.

  All elements are initialized to 0.
  */
  constructor size/int:
    #primitive.core.byte_array_new

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
  is_empty -> bool

  /**
  Compares this instance to $other.

  Returns whether the $other instance is a $ByteArray with the same content.
  */
  operator == other -> bool

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
  Whether every byte satisfies the given $predicate.
  Returns true, if the byte array is empty.
  */
  every [predicate] -> bool

  /**
  Whether there is a byte that satisfies the given $predicate.
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
  to_string from/int=0 to/int=size -> string

  /** Deprecated. Use $binary.ByteOrder.float64 instead. */
  to_float from/int --big_endian/bool?=true -> float

  /**
  Converts the UTF-8 byte array to a string.

  Invalid UTF-8 sequences are replaced with the Unicode replacement
    character, `\uFFFD`.
  */
  to_string_non_throwing from=0 to=size

  /**
  Whether this instance has a valid UTF-8 string content in the range $from-$to.
  */
  is_valid_string_content from/int=0 to/int=size -> bool

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
  index_of byte/int --from/int=0 --to/int=size -> int

/** Internal function to create a byte array with one element. */
create_byte_array_ x/int -> ByteArray_:
  bytes := ByteArray_ 1
  bytes[0] = x
  return bytes

/** Internal function to create a byte array with one element. */
create_byte_array_ x/int y/int -> ByteArray_:
  bytes := ByteArray_ 2
  bytes[0] = x
  bytes[1] = y
  return bytes

/** Internal function to create a byte array with one element. */
create_byte_array_ x/int y/int z/int -> ByteArray_:
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
  Use $replace_generic_ as fallback if the primitive operation failed.
  */
  abstract replace index source from/int=0 to/int=source.size -> none

  /**
  Whether this instance is empty.
  */
  is_empty -> bool:
    return size == 0

  /**
  Compares this instance to $other.

  Returns whether the $other instance is a $ByteArray with the same content.
  */
  operator == other -> bool:
    if other is not ByteArray: return false
    s := size
    if s != other.size: return false
    s.repeat: if this[it] != other[it]: return false
    return true

  /**
  Invokes the given $block on each element of this instance.
  */
  do [block]:
    this_size := size
    this_size.repeat: block.call this[it]
    // It is not allowed to change the size of the list while iterating over it.
    assert: size == this_size

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
  */
  to_string from/int=0 to/int=size -> string:
    #primitive.core.byte_array_convert_to_string

  /// Deprecated. Use $binary.ByteOrder.float64 instead.
  to_float from/int --big_endian/bool?=true -> float:
    bin := big_endian ? binary.BIG_ENDIAN : binary.LITTLE_ENDIAN
    bits := bin.int64 this from
    return float.from_bits bits

  do_utf8_with_replacements_ from to [block]:
    for i := from; i < to; i++:
      c := this[i]
      bytes := 1
      if c >= 0xf0:
        bytes = 4
      else if c >= 0xe0:
        bytes = 3
      else if c >= 0xc0:
        bytes = 2
      if i + bytes > to or not is_valid_string_content i i + bytes:
        block.call i 1 false
      else:
        block.call i bytes true
        i += bytes - 1 // Skip some.

  /// Converts the UTF-8 byte array to a string.  If we encounter invalid UTF-8
  ///   we replace sequences of invalid bytes with a Unicode replacement
  ///   character, `\uFFFD`.
  to_string_non_throwing from=0 to=size:
    if is_valid_string_content from to:
      return to_string from to
    len := 0
    last_was_replacement := false
    do_utf8_with_replacements_ from to: | i bytes ok |
      if ok:
        len += bytes
        last_was_replacement = false
      else if not last_was_replacement:
        len += 3  // Length of replacement character \uFFFD.
        last_was_replacement = true
    ba := ByteArray len
    len = 0
    last_was_replacement = false
    do_utf8_with_replacements_ from to: | i bytes ok |
      if ok:
        bytes.repeat:
          ba[len++] = this[i + it]
        last_was_replacement = false
      else if not last_was_replacement:
        ba[len++] = 0xef  // UTF-8 encoding of \uFFFD.
        ba[len++] = 0xbf
        ba[len++] = 0xbd
        last_was_replacement = true
    return ba.to_string

  /**
  Whether this instance has a valid UTF-8 string content in the range $from-$to.
  */
  is_valid_string_content from/int=0 to/int=size -> bool:
    #primitive.core.byte_array_is_valid_string_content

  /**
  Concatenates this instance with $other.
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
  replace_generic_ index/int source from/int to/int -> none:
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
    (to - from).repeat: this[it + from] = value

  /**
  Fills values, computed by evaluating $block, into list elements [$from..$to[.
  */
  fill --from/int=0 --to/int=size [block]:
    (to - from).repeat: this[it + from] = block.call it

  stringify:
    // Don't print more than 50 elements.
    to_be_printed_count := min 50 size
    if to_be_printed_count == 0: return "#[]"
    ba := (", 0x00" * to_be_printed_count).to_byte_array
    ba[0] = '#'
    ba[1] = '['
    to_be_printed_count.repeat:
      byte := this[it]
      ba[it * 6 + 4] = "0123456789abcdef"[byte >> 4]
      ba[it * 6 + 5] = "0123456789abcdef"[byte & 0xf]
    if to_be_printed_count == size:
      return ba.to_string + "]"
    else:
      return (ba.to_string) + ", ...]"

  index_of byte/int --from/int=0 --to/int=size -> int:
    #primitive.core.blob_index_of

/**
A container specialized for bytes.

A byte array can only contain (non-null) integers in the range 0-255.
*/
class ByteArray_ extends ByteArrayBase_:

  /**
  Creates a new byte array of the given $size.

  All elements are initialized to 0.
  */
  constructor size/int:
    #primitive.core.byte_array_new

  constructor.external_ size/int:
    #primitive.core.byte_array_new_external

  /**
  The number of bytes in this instance.
  */
  size:
    #primitive.core.byte_array_length

  /**
  Returns the $n'th byte.
  */
  operator [] n/int -> int:
    #primitive.core.byte_array_at

  /**
  Sets the $n'th byte to $value.

  The $value is truncated to byte size if necessary, only using the
    least-significant 8 bits.
  */
  operator []= n/int value/int -> int:
    #primitive.core.byte_array_at_put

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[
  */
  replace index/int source from/int=0 to/int=source.size -> none:
    #primitive.core.byte_array_replace:
      // TODO(florian): why can't we throw here?
      replace_generic_ index source from to

  // Returns true if the byte array has raw bytes as opposed to an off-heap C struct.
  is_raw_bytes_ -> bool:
    #primitive.core.byte_array_is_raw_bytes

  stringify:
    if not is_raw_bytes_: return "Proxy"
    return super

/**
A Slice of a ByteArray.

The ByteArray slice is simply a view into an existing byte array.
*/
class ByteArraySlice_ extends ByteArrayBase_:
  // The order of fields is important as the primitives read them out
  // directly.
  byte_array_ / ByteArray
  from_ / int
  to_ / int

  constructor .byte_array_ .from_ .to_:
    if not 0 <= from_ <= to_ <= byte_array_.size:
      throw "OUT_OF_BOUNDS"

  size:
    return to_ - from_

  operator [] n/int -> int:
    actual_index := from_ + n
    if not from_ <= actual_index < to_: throw "OUT_OF_BOUNDS"
    return byte_array_[actual_index]

  operator []= n/int value/int -> int:
    actual_index := from_ + n
    if not from_ <= actual_index < to_: throw "OUT_OF_BOUNDS"
    return byte_array_[actual_index] = value

  operator [..] --from/int=0 --to/int=size -> ByteArray:
    actual_from := from_ + from
    actual_to := from_ + to
    if not from_ <= actual_from <= actual_to <= to_: throw "OUT_OF_BOUNDS"
    return ByteArraySlice_ byte_array_ actual_from actual_to

  /**
  Replaces this[$index..$index+($to-$from)[ with $source[$from..$to[
  */
  replace index/int source from/int=0 to/int=source.size -> none:
    actual_index := from_ + index
    if from == to and actual_index == to_: return
    if not from_ <= actual_index < to_: throw "OUT_OF_BOUNDS"
    if actual_index + (to - from) <= to_:
      byte_array_.replace actual_index source from to
    else:
      replace_generic_ index source from to

/**
Internal function to create a list literal with any elements stored in array.
*/
create_list_literal_from_array_ array/Array_ -> List: return List_.from_array_ array

/**
Creates a List backed by a constant ByteArray.
This is an internal function and should only be used by the compiler.
*/
create_cow_byte_array_ byte_array -> CowByteArray_:
  return CowByteArray_ byte_array

class CowByteArray_ implements ByteArray:
  // The byte-array backing must be first, so that the primitives use that one.
  // The second field must be whether the byte array is mutable.
  backing_ /ByteArray_ := ?
  is_mutable_ := false

  constructor .backing_:

  index_of byte/int --from/int=0 --to/int=size -> int:
    return backing_.index_of byte --from=from --to=to

  size:
    return backing_.size

  is_empty -> bool:
    return size == 0

  operator == other -> bool:
    return backing_ == other

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
    return ensure_mutable_[n] = value

  operator [..] --from=0 --to=size -> ByteArray:
    // We are not allowed to redirect to `mutable or immutable` as
    // a slice must always see the latest value.
    if from == 0 and to == size: return this
    return ByteArraySlice_ this from to

  to_string from/int=0 to/int=size -> string:
    return backing_.to_string from to

  /// Deprecated. Use $binary.ByteOrder.float64 instead.
  to_float from/int --big_endian/bool?=true -> float:
    byte_order /binary.ByteOrder := big_endian
        ? binary.BIG_ENDIAN
        : binary.LITTLE_ENDIAN
    return byte_order.float64 backing_ from

  to_string_non_throwing from=0 to=size:
    return backing_.to_string_non_throwing from to

  is_valid_string_content from/int=0 to/int=size -> bool:
    return backing_.is_valid_string_content from to

  operator + other/ByteArray -> ByteArray:
    return backing_ + other

  copy from/int=0 to/int=size -> ByteArray:
    return backing_.copy from to

  replace index/int source from/int=0 to/int=source.size -> none:
    ensure_mutable_.replace index source from to

  fill --from/int=0 --to/int=size value:
    ensure_mutable_.fill --from=from --to=to value

  fill --from/int=0 --to/int=size [block]:
    ensure_mutable_.fill --from=from --to=to block

  stringify:
    return backing_.stringify

  ensure_mutable_ -> ByteArray_:
    if not is_mutable_:
      backing_ = backing_.copy
      is_mutable_ = true
    return backing_

class ListSlice_ extends List:
  list_ / List
  from_ / int
  to_ / int

  constructor .list_ .from_ .to_:
    super.from_subclass

  operator [] index:
    actual_index := from_ + index
    if not from_ <= actual_index < to_: throw "OUT_OF_BOUNDS"
    // If the underlying list changed size this might throw.
    return list_[actual_index]

  operator []= index value:
    actual_index := from_ + index
    if not from_ <= actual_index < to_: throw "OUT_OF_BOUNDS"
    // If the underlying list changed size this might throw.
    return list_[actual_index] = value

  operator [..] --from=0 --to=size -> List:
    actual_from := from_ + from
    actual_to := from_ + to
    if not from_ <= actual_from <= actual_to <= to_: throw "OUT_OF_BOUNDS"
    // Note that we don't actually check whether the underlying list has changed
    // size.
    return ListSlice_ list_ actual_from actual_to

  size -> int:
    return to_ - from_

  copy from/int=0 to/int=size -> List:
    actual_from := from_ + from
    actual_to := from_ + to
    if not from_ <= actual_from <= actual_to <= to_: throw "OUT_OF_BOUNDS"
    // If the underlying list changed size this might throw.
    return list_.copy actual_from actual_to

  resize new_size -> none:
    throw "SLICE_CANNOT_CHANGE_SIZE"

/**
The implementation class for the standard growable list.
This class is used for list literals.
*/
class List_ extends List:
  constructor:
    array_ = Array_ 0
    super.from_subclass

  constructor.from_array_ array/Array_:
    array_ = array
    size_ = array.size
    super.from_subclass

  constructor.private_ backing_size size:
    array_ = Array_ backing_size
    size_ = size
    super.from_subclass

  /** See $super. This is an optimized implementation. */
  do [block]:
    return array_.do_ size_ block

  /** See $super. This is an optimized implementation. */
  remove_last:
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
  resize new_size:
    if size_ < new_size:
      array_size := array_.size
      if array_size < new_size:
        // Use powers of two: 4, 8, 16, 32, 64, 128, 256
        // then move to arraylet steps, 500, 1000, 1500,...
        // After about 8000, go back to a mild geometric growth.
        new_array_size := (array_size < LargeArray_.ARRAYLET_SIZE / 2)
          ? array_size + array_size
          : (round_up (array_size + 1 + (array_size >> 4)) LargeArray_.ARRAYLET_SIZE)
        if new_array_size < LIST_INITIAL_LENGTH_: new_array_size = LIST_INITIAL_LENGTH_
        while new_array_size < new_size: new_array_size += 1 + (new_array_size >> 1)
        array_ = array_.resize_for_list_ size_ new_array_size

      size_ = new_size
    else:
      if new_size < array_.size - LargeArray_.ARRAYLET_SIZE:
        array_ = array_.resize_for_list_ size_ (round_up new_size LargeArray_.ARRAYLET_SIZE)
      // Clear entries so they can be GC'ed.
      limit := min size_ array_.size
      for i := new_size; i < limit; i++:
        array_[i] = null
      size_ = new_size

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
  // method on Array_.  Currently there's no acceleration for LargeArray_.
  replace index/int source from/int=0 to/int=source.size -> none:
    if source is List_:
      // Array may be bigger than this List_, so we must check for
      // that before delegating to the Array_ method, while being
      // careful about integer overflow.
      len := to - from
      if len < 0 or index > size - len or to > source.size: throw "BAD ARGUMENTS"
      array_.replace index source.array_ from to
    else:
      super index source from to

  /** See $super. */
  copy from/int=0 to/int=size -> List:
    if not 0 <= from <= to <= size: throw "BAD ARGUMENTS"
    result_size := to - from
    result := List_
    result.resize result_size
    result.array_.replace 0 this.array_ from to
    return result

  sort --in_place/bool=false from/int = 0 to/int = size_ [compare] -> List_:
    if from < 0 or from > to or to > size_: throw "OUT_OF_BOUNDS"
    result := in_place ? this : copy
    result.array_.sort --in_place from to compare
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

  static SMALL_SKIPS_ ::= 9

  constructor.private_ .skip_:

  // Get skip distance ignoring entries that indicate backwards skip distance.
  skip -> int:
    if skip_ < 1: return 1
    return skip_

  // Get skip distance ignoring entries that indicate forwards skip distance.
  skip_backwards default_step -> int:
    if skip_ > -1: return default_step
    return skip_

  // May return a new object with the correct skip or may mutate the current object.
  increase_distance_to skp:
    assert: not -10 <= skp <= 10
    if skip_ == 0: return Tombstone_.private_ skp
    skip_ = skp
    return this

/// 'Tombstone' that marks deleted entries in the backing.
SMALL_TOMBSTONE_ ::= Tombstone_.private_ 0

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
  $pick_new_index_size_.

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
  index_spaces_left_ := 0
  index_ := null
  backing_ := null

  /** Removes all elements from this instance. */
  clear -> none:
    size_ = 0
    index_spaces_left_ = 0
    index_ = null
    backing_ = null

  abstract rebuild_ old_size --allow_shrink/bool

  compare_ key key_or_probe:
    return key == key_or_probe

  hash_code_ key:
    return key.hash_code

  /** The number of elements in this instance. */
  size -> int:
    return size_

  /** Whether this instance is empty. */
  is_empty -> bool:
    return size_ == 0

  /** Whether this instance contains the given $key. */
  contains key -> bool:
    action := find_ key: return false
    return true

  /** Whether this instance contains all elements of $collection. */
  contains_all collection/Collection -> bool:
    collection.do: if not contains it: return false
    return true

  /**
  Removes the given $key from this instance.

  The key does not need to be present.
  */
  remove key -> none:
    remove key --if_absent=: return

  /**
  Removes the given $key from this instance.

  If the key is absent, calls $if_absent with the key.
  */
  abstract remove key [--if_absent]

  /** Removes all elements of $collection from this instance. */
  remove_all collection/Collection -> none:
    collection.do: remove it --if_absent=: null

  /**
  Skips to next non-deleted entry, possibly updating the delete entry in the
    backing to make it faster the next time.
  */
  skip_ delete i limit:
    skip := delete.skip
    new_i := i + skip
    while new_i < limit and backing_[new_i] is Tombstone_:
      next_skip := backing_[new_i].skip
      skip += next_skip
      new_i += next_skip
    // There is a sufficient number of fields to skip, so create a bigger
    // skip entry.
    if skip > 10:
      backing_[i] = delete.increase_distance_to skip
    return new_i

  /**
  Skips to next non-deleted entry, possibly updating the delete entry in the
    backing to make it faster the next time.
  */
  skip_backwards_ delete i default_step:
    skip := delete.skip_backwards default_step
    new_i := i + skip
    while new_i >= 0 and backing_[new_i] is Tombstone_:
      next_skip := backing_[new_i].skip_backwards default_step
      skip += next_skip
      new_i += next_skip
    // There is a sufficient number of fields to skip, so create a bigger
    // skip entry.
    if skip < -10:
      backing_[i] = delete.increase_distance_to skip
    return new_i

  // The index has sizes that are powers of 2.  This is a geometric
  //   progression, so it gives us amortized constant time growth.  We need a
  //   fast, deterministic way to get from the (prime-multiplied) hash code to an
  //   initial slot in the index.  Since sizes are a power of 2 we merely take
  //   the modulus of the size, which can be done by bitwise and-ing with the
  //   size - 1.
  pick_new_index_size_ old_size --allow_shrink/bool:
    minimum := allow_shrink ? 2 : index_.size * 2
    enough := 1 + old_size + (old_size >> 3)  // old_size * 1.125.
    new_index_size := max
      minimum
      1 << (64 - (count_leading_zeros enough))

    index_spaces_left_ = (new_index_size * 0.85).to_int
    if index_spaces_left_ <= old_size: index_spaces_left_ = old_size + 1
    // Found large enough index size.
    index_ = Array_ new_index_size 0

  /// We store this much of the hash code in each slot.
  static HASH_MASK_ ::= 0xfff
  static HASH_SHIFT_ ::= 12

  static INVALID_SLOT_ ::= -1

  /// Returns the position recorded for the $key in the index.  If the key is not
  ///   found, it calls the given block, which can either do a non-local return
  ///   (in which case the collection is unchanged) or return the position of the
  ///   next free position in the backing.  If the key was not found and the block
  ///   returns normally, a new entry is created in the index.  The position in
  ///   the backing is returned, or APPEND_, which indicates that the key was not
  ///   found and the block was called.  The caller doesn't strictly need the
  ///   APPEND_ return value, since it knows whether its block was called, but it
  ///   is often more convenient to use the return value.
  find_ key [not_found]:
    append_position := null  // Use null/non-null to avoid calling block twice.

    if not index_:
      if size_ == 0:
        if not backing_: backing_ = List
        not_found.call  // May not return.
        return APPEND_
      else:
        assert: size_ == 1
        k := backing_[0]
        if k is not Tombstone_:
          if compare_ key k:
            return 0
          append_position = not_found.call
          rebuild_ 1 --allow_shrink
        else:
          rebuild_ 1 --allow_shrink

    // TODO(erik): Multiply by a large prime to mix up bad hash codes, e.g.
    //               (0x1351d * (hash_code_ key)) & 0x3fffffff
    //             that doesn't allocate large integers.
    hash := hash_code_ key

    return find_body_ key hash append_position not_found
      (: rebuild_ it --allow_shrink=false)
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
  find_body_ key hash append_position [not_found] [rebuild] [compare]:
    #primitive.intrinsics.hash_find:
      // State START.
      while true:  // Loop to retry after rebuild.
        index_mask := index_.size - 1
        slot := hash & index_mask
        starting_slot := slot
        // The variable is initialized to the invalid slot, but updated to the
        // slot of the first deleted entry we find while searching for the key.
        // If we don't find the key (with its value), we will use the deleted
        // slot instead of a new one at the end of the probe sequence.
        deleted_slot := INVALID_SLOT_
        // Used for triangle-number probe order
        slot_step := 1
        while true:
          hash_and_position := index_[slot]
          if hash_and_position == 0:
            old_size := size_
            // Found free slot.
            if not append_position: append_position = not_found.call  // May not return.
            // State NOT_FOUND.
            if index_spaces_left_ == 0:
              // State REBUILD.
              rebuild.call old_size
              // Go to state START.
              break
            new_hash_and_position := ((append_position + 1) << HASH_SHIFT_) | (hash & HASH_MASK_)
            if deleted_slot < 0:
              index_[slot] = new_hash_and_position
              index_spaces_left_--
            else:
              index_[deleted_slot] = new_hash_and_position
            return APPEND_
            // End of state START.
          // Found non-free slot.
          position := (hash_and_position >> HASH_SHIFT_) - 1
          k := backing_[position]
          if deleted_slot == INVALID_SLOT_ and k is Tombstone_:
            deleted_slot = slot
          if hash_and_position & HASH_MASK_ == hash & HASH_MASK_:
            // Found hash match.
            if k is not Tombstone_ and (compare.call key k):
              // State AFTER_COMPARE where block returns true.
              // It's not obvious why we have to return APPEND_ here, after all,
              // we already found the entry in the index.  The reason is that the
              // not_found call can add an entry to the backing, then we find the
              // index is full.  Rebuilding the index puts the newly added
              // backing entry in the index, and so we find it when we do another
              // iteration of the outer loop here.
              return append_position ? APPEND_ : position
          // State AFTER_COMPARE where block returns false.
          slot = (slot + slot_step) & index_mask
          slot_step++
          if slot == starting_slot:  // Index is full and we didn't find the entry.
            old_size := size_
            // Give the caller the chance to add the entry to the backing.
            if not append_position: append_position = not_found.call  // May not return.
            // State REBUILD.
            // Rebuild - this makes a new index which can contain the new entry.
            rebuild.call old_size
            // Go to state START.
            break

  // Returns how far we got, or null if we are done.
  hash_do_ step reversed [block]:
    #primitive.intrinsics.hash_do:
      // If the intrinsic fails, return the start position.  This
      // is very rare because the intrinsic will generally return a
      // progress-indicating integer rather than failing.
      return reversed
        ? backing_ ? backing_.size - step : 0
        : 0

  rebuild_ old_size/int step/int --allow_shrink/bool --rebuild_backing/bool:
    if rebuild_backing:
      // Rebuild backing to remove deleted elements.
      i := 0
      backing_.do:
        if it is not Tombstone_:
          backing_[i++] = it
      length := size_ * step
      backing_.resize size_ * step
    old_index := index_
    pick_new_index_size_ old_size --allow_shrink=allow_shrink
    index_mask := index_.size - 1
    if not old_index or index_mask > HASH_MASK_ or rebuild_backing:
      // Rebuild the index by iterating over the backing and entering each key
      // into the index in the conventional way.  During this operation, the
      // index is big enough and the backing does not change.  The find_ operation
      // does not compare keys again.  It knows that they were not equal when
      // they were first added to the collection, and keeps using that fact.
      size := backing_.size
      throw_block := (: | _ | throw null)  // During rebuild we never rebuild.
      false_block := (: | _ _ | false)     // During rebuild no objects are equal.
      for i := 0; i < size; i += step:
        key := backing_[i]
        if key is not Tombstone_:
          action := find_body_ key (hash_code_ key) null
            (: i)  // not_found block, returns the position of where to add the new entry.
            throw_block
            false_block
          assert: action == APPEND_
    else:
      // We can do an simple rebuild.  There are enough hash bits in the index
      // slots to tell us where the slot goes in the new index, so we don't need
      // to call hash_code or equality for the entries in the backing.
      index_spaces_left_ -= size_
      simple_rebuild_hash_index_ old_index index_

simple_rebuild_hash_index_ old_index index_ -> none:
  #primitive.core.rebuild_hash_index:
    // Fallback version written in Toit.
    index_mask := index_.size - 1
    old_index.do: | hash_and_position |
      if hash_and_position != 0:
        slot := hash_and_position & index_mask
        slot_step := 1
        while index_[slot] != 0:
          slot = (slot + slot_step) & index_mask
          slot_step++
        index_[slot] = hash_and_position

/** A set of keys. */
class Set extends HashedInsertionOrderedCollection_ implements Collection:
  static STEP_ ::= 1

  /**
  Removes the given $key from this instance.

  If the key is absent, calls $if_absent with the $key.
  */
  remove key [--if_absent] -> none:
    position := find_ key:
      if_absent.call key
      return
    backing_[position] = SMALL_TOMBSTONE_
    size_--
    shrink_if_needed_

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
  get_by_hash_ hash/int [--initial] [--compare] -> any:
    if not index_:
      if size_ == 0:
        new_entry := initial.call
        if new_entry != null:
          add new_entry
        return new_entry
      assert: size_ == 1
      found := backing_[0]
      if found is not Tombstone_:
        if compare.call found:
          return found
      new_entry := initial.call
      if new_entry != null:
        add new_entry
      return new_entry

    append_position := -1
    find_body_ null hash null
      // Not found.
      (:
        new_entry := initial.call
        if new_entry == null:
          return null
        append_position = backing_.size
        backing_.add new_entry
        size_++
        append_position  // Return from block.
      )
      // Rebuild.
      (: rebuild_ it --allow_shrink=false)
      // Possible match found.
      (: | _ found |
        was_found := compare.call found
        if was_found: return found
        false
      )
    return backing_[append_position]

  /**
  Adds the given $key to this instance.
  If an equal key is already in this instance, it is overwritten by the new one.
  */
  add key -> none:
    position := find_ key:
      append_position := backing_.size
      backing_.add key
      size_++
      append_position  // Return from block.
    if position != APPEND_:
      backing_[position] = key

  /**
  Adds all elements of the given $collection to this instance.
  */
  add_all collection/Collection -> none:
    collection.do: add it

  /** See $Collection.do. */
  do [block] -> none:
    i := hash_do_ STEP_ false block
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
    i := hash_do_ STEP_ true block
    if not i: return
    assert: backing_
    while i >= 0:
      element := backing_[i]
      if element is not Tombstone_:
        block.call element
        i--
      else:
        i = skip_backwards_ element i -STEP_

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
    if is_empty: throw "Not enough elements"
    result := null
    is_first := true
    do:
      if is_first: result = it; is_first = false
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

  Returns a new set if $in_place is false (the default).
  Returns this instance if $in_place is true.

  The result contains all the elements of this instance for which the $predicate returns
    true.

  Users must not otherwise modify this instance during the operation.
  */
  filter --in_place/bool=false [predicate] -> Set:
    if not in_place:
      result := Set
      do: | key | if predicate.call key : result.add key
      return result
    limit := backing_ ? backing_.size : 0
    limit.repeat:
      key := backing_[it]
      if key is not Tombstone_ and not predicate.call key:
        backing_[it] = SMALL_TOMBSTONE_
        size_--
    shrink_if_needed_
    return this

  /**
  Intersects this instance with the $other set.

  The result contains all elements that are both in this instance, as well
    as in the $other set.

  Returns a new set if $in_place is false (the default).
  Returns this instance, if $in_place is true.
  */
  intersect --in_place/bool=false other/Set -> Set:
    return filter --in_place=in_place: other.contains it

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
  get key [--if_absent]:
    position := find_ key:
      return if_absent.call key
    return backing_[position]

  /**
  Returns an element that is equal to the $key.
  Returns null if this instance doesn't contain the $key.
  See $(get key [--if_absent]).
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

  shrink_if_needed_:
    if backing_ and backing_.size > 4 and backing_.size > size_ + (size_ >> 1):
      rebuild_ size_ STEP_ --allow_shrink --rebuild_backing

  rebuild_ old_size --allow_shrink/bool:
    rebuild_ old_size STEP_ --allow_shrink=allow_shrink --rebuild_backing=false


/**
A set that uses object identity instead of the == operator to test equality
  of elements. This set still uses the hash_code method on elements. There is
  no identity hash code operation on arbitrary classes in Toit.
*/
class IdentitySet extends Set:

  hash_code_ key:
    return key.hash_code

  compare_ key key_or_probe:
    return identical key key_or_probe

class Map extends HashedInsertionOrderedCollection_:
  static STEP_ ::= 2

  // A map that only works with strings, integers, and objects supporting hash_code and equals.
  constructor:
    super

  /**
  Constructs a Map with a given $size.
  For each key-value pair, first the block $get_key and then the block $get_value are called.
  */
  constructor size [get_key] [get_value]:
    size.repeat: this[get_key.call it] = get_value.call it

  /**
  Removes the given $key from this instance.

  If the key is absent, calls $if_absent with the $key.
  */
  remove key [--if_absent] -> none:
    position := find_ key:
      if_absent.call key
      return
    backing_[position] = SMALL_TOMBSTONE_
    backing_[position + 1] = SMALL_TOMBSTONE_
    size_--
    shrink_if_needed_

  shrink_if_needed_:
    if backing_ and backing_.size > 8 and backing_.size > (size_ << 1) + size_:
      rebuild_ size_ STEP_ --allow_shrink --rebuild_backing

  rebuild_ old_size --allow_shrink/bool:
    rebuild_ old_size STEP_ --allow_shrink=allow_shrink --rebuild_backing=false

  /**
  Returns the element stored at location $key.
  The $key must be in the map.
  */
  operator [] key:
    position := find_ key: throw "key not found"
    assert: position != APPEND_
    return backing_[position + 1]

  /**
  Stores $value in the location for the given $key.
  If the $key is already present, overrides the previous value.
  */
  operator []= key value:
    action := find_ key:
      append_position := backing_.size
      backing_.add key
      backing_.add value
      size_++
      append_position  // Return from block.
    if action != APPEND_:
      backing_[action + 1] = value
    return value

  /**
  Retrieves the value for $key.

  Returns the value verbatim, if the $key is contained in the map.
  Returns null, otherwise.
  */
  get key: return get key --if_present=(: it) --if_absent=(: null)

  /**
  Retrieves the value for $key.

  Returns the value verbatim, if this instance contains the $key.
  Otherwise, calls $if_absent with the $key and returns the result of the call.
  */
  get key [--if_absent]:
    return get key --if_absent=if_absent --if_present=: it

  /**
  Retrieves the value for $key.

  If this instance contains the $key calls $if_present with the corresponding
    value and returns the result.
  Returns null otherwise.
  */
  get key [--if_present]:
    return get key --if_present=if_present --if_absent=: null

  /**
  Retrieves the value for $key.

  If this instance contains the $key calls $if_present with the corresponding
    value and returns the result.
  Otherwise, calls $if_absent with the $key and returns the result of the call.
  */
  get key [--if_present] [--if_absent]:
    action := find_ key: return if_absent.call key
    assert: action != APPEND_
    return if_present.call backing_[action + 1]

  /**
  Retrieves the value for $key.

  Returns the value verbatim, if this instance contains the $key.
  Otherwise, initializes the slot with the result of calling $init first.
  */
  get key [--init]:
    return get key
      --if_absent=:
        initial_value := init.call
        this[key] = initial_value
        return initial_value
      --if_present=: it

  /**
  Updates the value of the given $key.

  Calls the $updater with the current value, and replaces the old value with the result.
  Returns the result of calling the $updater.

  This instance must contain the $key.
  */
  update key [updater]:
    return update key updater --if_absent=: throw "key not found"

  /**
  Updates the value of the given $key.

  If this instance contains the $key, calls the $updater with the current value,
    and replaces the old value with the result. Returns the result of the call.

  If this instance does not contain the $key, calls $if_absent with the $key instead, and
    stores the result of the call in this instance. Returns the result of the call.
  */
  update key [updater] [--if_absent]:
    new_value := null
    position := find_ key:
      new_value = if_absent.call key
      append_position := backing_.size
      backing_.add key
      backing_.add new_value
      size_++
      append_position  // Return from block.
    if position != APPEND_:
      new_value = updater.call backing_[position + 1]
      backing_[position + 1] = new_value
    return new_value

  /**
  Updates the value of the given $key.

  If this instance contains the $key, calls the $updater with the current value,
    and replaces the old value with the result. Returns the result of the call.

  If this instance does not contain the $key, stores $if_absent in this instance. Returns $if_absent.
  */
  update key [updater] --if_absent:
    return update key updater --if_absent=: if_absent

  /**
  Updates the value of the given $key.

  If this instance does not contain the $key, calls $init with the $key first, and stores it
    in this instance.

  Calls the $updater with the current value (which might be the initial value that was
    just stored) and replaces the old value with the result.

  Returns the result of the call to the $updater.
  */
  update key [--init] [updater]:
    new_value := null
    position := find_ key:
      new_value = updater.call (init.call key)
      append_position := backing_.size
      backing_.add key
      backing_.add new_value
      size_++
      append_position  // Return from block.
    if position != APPEND_:
      new_value = updater.call backing_[position + 1]
      backing_[position + 1] = new_value
    return new_value

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
    i := hash_do_ STEP_ false block
    if not i: return
    assert: backing_
    limit := backing_ ? backing_.size : 0
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
    i := hash_do_ STEP_ true block
    if not i: return
    assert: backing_
    while i >= 0:
      key := backing_[i]
      if key is not Tombstone_:
        block.call key backing_[i + 1]
        i -= 2
      else:
        i = skip_backwards_ key i -STEP_

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
    if is_empty: throw "Not enough elements"
    result := null
    is_first := true
    do --values:
      if is_first: result = it; is_first = false
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
    if is_empty: throw "Not enough elements"
    result := null
    is_first := true
    do --keys:
      if is_first: result = it; is_first = false
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

  The flag $in_place must be true.

  Invokes the given $block on each key/value pair and replaces the old value with
    the result of the call.

  */
  map --in_place/bool [block] -> none:
    if in_place != true: throw "Bad Argument"
    limit := backing_ ? backing_.size : 0
    for i := 0; i < limit; i += STEP_:
      key := backing_[i]
      if key is not Tombstone_:
        new_value := block.call key backing_[i + 1]
        backing_[i + 1] = new_value

  /**
  Filters this instance using the given $predicate.

  Returns a new map if $in_place is false. Returns this instance otherwise.

  The result contains all the elements of this instance for which the $predicate returns
    true.

  Users must not otherwise modify this instance during the operation.
  */
  filter --in_place/bool=false [predicate] -> Map:
    if not in_place:
      result := Map
      do: | key value | if predicate.call key value: result[key] = value
      return result
    limit := backing_ ? backing_.size : 0
    for i := 0; i < limit; i += STEP_:
      key := backing_[i]
      value := backing_[i + 1]
      if key is not Tombstone_ and not predicate.call key value:
        backing_[i] = SMALL_TOMBSTONE_
        backing_[i + 1] = SMALL_TOMBSTONE_
        size_--
    shrink_if_needed_
    return this

  stringify:
    if is_empty: return "{:}"
    key_value_strings := []
    size := 0
    do: | key value |
      key_value_string := "$key.stringify: $value.stringify"
      size += key_value_string.size + 2
      if size > MAX_PRINT_STRING_:
        return "{$(key_value_strings.join ", ")..."
      key_value_strings.add key_value_string
    return "{$(key_value_strings.join ", ")}"

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
  of keys. This map still uses the hash_code method on keys. There is no
  identity hash code operation on arbitrary classes in Toit.
*/
class IdentityMap extends Map:

  hash_code_ key:
    return key.hash_code

  compare_ key key_or_probe:
    return identical key key_or_probe

/**
A collection where you can add to the end, and remove items from
  either end efficiently.
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

  is_empty -> bool:
    return backing_.size == first_

  add element -> none:
    backing_.add element

  add_all collection/Collection -> none:
    backing_.add_all collection

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

  remove_last -> any:
    if first_ == backing_.size: throw "OUT_OF_RANGE"
    result := backing_.remove_last
    shrink_if_needed_
    return result

  remove_first -> any:
    backing := backing_
    first := first_
    if first == backing.size: throw "OUT_OF_RANGE"
    result := backing[first]
    backing[first] = null
    first_ = first + 1
    shrink_if_needed_
    return result

  shrink_if_needed_ -> none:
    backing := backing_
    first := first_
    if first * 2 > backing.size:
      backing.replace 0 backing first first + size
      backing.resize size
      first_ = 0
