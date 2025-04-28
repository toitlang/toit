// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .font

class Icon:
  code-point_/int ::= ?
  font_/Font ::= ?

  constructor .code-point_ .font_:

  stringify -> string:
    return "$(%c code-point_)"

  /**
  Gets the pixel width of the icon.
  Note that when you actually draw the icon it may go a few pixels to the left
    of the origin or to the right of x origin + pixel-width.  See $icon-extent.
  */
  pixel-width -> int:
    return font_.pixel-width stringify

  /**
  Gets the bounding box of the icon.
  Returns [width, height, x-offset, y-offset].
  */
  icon-extent -> List:
    return font_.text-extent stringify
