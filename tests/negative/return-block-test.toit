// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

return-block [block]:
  return block

return-block:
  block := (: 499)
  return block

return-block2:
  block := (: 499)
  return true ? block : block

return-block3:
  block := (: 499)
  return if true: block else: block

return-block4:
  return if true: (: 499) else: (: 499)

return-block-lambda:
  lambda := ::
    : 499
  block := lambda.call
  
  lambda2 := ::
    (: 499)
  block = lambda.call

  lambda3 := ::
    lambda-block := (: 499)
    lambda-block
  block = lambda3.call

  lambda4 := ::
    return (: 499)
  block = lambda4.call
  
  lambda5 := ::
    lambda-block := (: 499)
    return lambda-block
  block = lambda5.call

  lambda6 := ::
    lambda-block := (: 499)
    if true: lambda-block
  block = lambda6.call

  lambda7 := ::
    lambda-block := (: 499)
    if true: lambda-block
    else: lambda-block
  block = lambda6.call

  unreachable

return-block-block:
  block := (:
    : 499
  )
  t := block.call

  block2 := (:
    (: 499))
  t2 := block2.call

  block3 := :
    block-block := (: 499)
    block-block
  t3 := block3.call
  
  block4 := :
    block-block := (: 499)
    if true:
      block-block
  t4 := block4.call

  block5 := :
    block-block := (: 499)
    if true:
      block-block
    else: block-block
  t5 := block5.call
    
main:
  return-block
  return-block: 499
  return-block2
  return-block3
  return-block4
  return-block-lambda
