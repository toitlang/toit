// Copyright (C) 2022 Toitware ApS.

/**
  $oo
*/
foo:

/**
  $x.oo
*/
bar:

/**
  $for
*/
gee:

/**
  $(x oo)
*/
toto:

/**
  '//' comments should not eat rest of line.
  $// $unresolved
*/
foo2:

/**
  '//' comments should not eat rest of line.
  We used to have a crash when there was a '\0' in the line with a comment.
  $// $unresolved '\0' here: ' '.
*/
foo3:

/**
  '//' comments should eat rest of line in signature ref.
  $(// $unresolved)
*/
foo4:

/**
  '//' comments should not eat rest of line in signature ref.
  We used to have a crash when there was a '\0' in the line with a comment.
  $(// $unresolved '\0' here: ' '.)
*/
foo5:

