// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
See $(line-wrap text max-width [--compute-width] [--can-split] [--is-space]).
  Trims space (0x20) characters around wrap points.
*/
line-wrap text/string max-width/num [--compute-width] [--can-split] -> List:
  return line-wrap text max-width --compute-width=compute-width --can-split=can-split --is-space=:
    it == ' '

/**
Wraps a line of $text to a given $max-width, and returns the
  resulting lines, trimming whitespace characters around wrap points.
  The $compute-width block takes a string, a
  from-position and a to-position (non-inclusive) and returns the width.
  The $can-split block takes a string and a position, and returns true if we
  can split at that point.
  The $is-space block takes an integer code point and returns
  true if it should be trimmed.
*/
line-wrap text/string max-width/num [--compute-width] [--can-split] [--is-space] -> List:
  if text == "": return [ "" ]
  result := []
  last-cut := 0
  while last-cut != text.size:
    ok-place := last-cut
    for i := last-cut + 1; i <= text.size; i++:
      if i != text.size and not text[i]: continue  // Avoid the middle of UTF-8 sequences.
      pixel-width := compute-width.call text last-cut i
      if pixel-width <= max-width and can-split.call text i:
        ok-place = i
      if pixel-width > max-width:
        break
    if ok-place == last-cut:
      // Failed to find a place to split.  This could be because one word is
      // longer than the line width, in which case we will just cut it at the
      // width limit.  We will allow a single-character overlong line in order
      // to be sure to make progress.
      while ok-place < text.size:
        next-cut := ok-place + 1
        // Skip UTF-8.
        while next-cut < text.size and not text[next-cut]: next-cut++
        pixel-width := compute-width.call text last-cut next-cut
        if pixel-width > max-width and ok-place > last-cut:
          break
        ok-place = next-cut
    first-line := text.copy last-cut ok-place
    result.add
      trim_ first-line is-space
    // Trim leading spaces after automatic splits (and thus not at the start of
    // the un-wrapped string).
    while ok-place < text.size and is-space.call text[ok-place]: ok-place++
    last-cut = ok-place
  return result

trim_ text [is-space]:
  end := text.size
  while end > 0:
    if not is-space.call text[end - 1]: return text.copy 0 end
    end--
  return ""
