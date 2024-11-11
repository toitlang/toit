// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-is-exception
  test-exception
  test-catchy
  test-nlb-out-of-try
  test-throw-update-in-finally
  test-break-update-in-finally
  test-break-update-in-finally-block0
  test-break-update-in-finally-block1
  test-break-update-in-finally-block2
  test-break-update-in-finally-block3
  test-break-update-in-finally-nested

test-is-exception:
  return-is-exception
  x := null
  try:
    // Do nothing.
  finally: | is-exception exception |
    x = is-exception
  id x

return-is-exception:
  try:
    // Do nothing.
  finally: | is-exception exception |
    return is-exception

test-exception:
  return-exception
  x := null
  try:
    // Do nothing.
  finally: | is-exception exception |
    x = exception
  id x

return-exception:
  try:
    // Do nothing.
  finally: | is-exception exception |
    return exception

test-catchy:
  catchy

catchy:
  try:
    return null
  finally: | is-exception exception |
    return is-exception

test-nlb-out-of-try:
  x/any := 4
  try:
    while true:
      invoke: break
    x = "hest"
    if pick: invoke: return
    x = null
  finally:
    id x
test-throw-update-in-finally:
  x := false
  invoke-catch:
    try:
      throw "ugh"
    finally:
      x = true
  id x

test-break-update-in-finally:
  x := false
  while true:
    try:
      break
    finally:
      x = true
  id x

test-break-update-in-finally-block0:
  x := false
  while true:
    invoke:
      try:
        break
      finally:
        x = true
  id x

test-break-update-in-finally-block1:
  x := false
  while true:
    block := (: break)
    try:
      block.call
    finally:
      x = true
  id x

test-break-update-in-finally-block2:
  x/any := null
  while true:
    block := (: break)
    try:
      block.call
    finally:
      x = true
      try:
        block.call
      finally:
        x = false
  id x

test-break-update-in-finally-block3:
  x := false
  y := null
  while true:
    block := (: break)
    while true:
      try:
        if pick: block.call
        else: break
      finally:
        x = true
    y = x
  id x
  id y

test-break-update-in-finally-nested:
  x/any := null
  while true:
    try:
      try:
        x = 0
        break
      finally:
        x = true
    finally:
      x = "horse"
  id x

id x:
  return x

pick:
  return (random 100) < 50

invoke [block]:
  block.call

invoke-catch [block]:
  try:
    block.call
  finally:
    return
