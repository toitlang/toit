// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_is_exception
  test_exception

test_is_exception:
  return_is_exception
  x := null
  try:
     // Do nothing.
  finally: | is_exception exception |
    x = is_exception
  id x

return_is_exception:
  try:
    // Do nothing.
  finally: | is_exception exception |
    return is_exception

test_exception:
  return_exception
  x := null
  try:
     // Do nothing.
  finally: | is_exception exception |
    x = exception
  id x

return_exception:
  try:
    // Do nothing.
  finally: | is_exception exception |
    return exception

id x:
  return x