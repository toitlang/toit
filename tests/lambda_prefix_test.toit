// Copyright (C) 2018 Toitware ApS. All rights reserved.
import http

foo lambda:
  lambda.call

main:
  foo:: http.Headers
