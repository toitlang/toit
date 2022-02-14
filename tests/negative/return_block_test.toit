// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

return_block [block]:
  return block

return_block:
  block := (: 499)
  return block

return_block2:
  block := (: 499)
  return true ? block : block

return_block3:
  block := (: 499)
  return if true: block else: block

return_block4:
  return if true: (: 499) else: (: 499)

return_block_lambda:
  lambda := ::
    : 499
  block := lambda.call
  
  lambda2 := ::
    (: 499)
  block = lambda.call

  lambda3 := ::
    lambda_block := (: 499)
    lambda_block
  block = lambda3.call

  lambda4 := ::
    return (: 499)
  block = lambda4.call
  
  lambda5 := ::
    lambda_block := (: 499)
    return lambda_block
  block = lambda5.call

  lambda6 := ::
    lambda_block := (: 499)
    if true: lambda_block
  block = lambda6.call

  lambda7 := ::
    lambda_block := (: 499)
    if true: lambda_block
    else: lambda_block
  block = lambda6.call

  unreachable

return_block_block:
  block := (:
    : 499
  )
  t := block.call

  block2 := (:
    (: 499))
  t2 := block2.call

  block3 := :
    block_block := (: 499)
    block_block
  t3 := block3.call
  
  block4 := :
    block_block := (: 499)
    if true:
      block_block
  t4 := block4.call

  block5 := :
    block_block := (: 499)
    if true:
      block_block
    else: block_block
  t5 := block5.call
    
main:
  return_block
  return_block: 499
  return_block2
  return_block3
  return_block4
  return_block_lambda
