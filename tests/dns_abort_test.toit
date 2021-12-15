// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .dns

main:
  task:: exit 0
  dns_lookup "localhost"
