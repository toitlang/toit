// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import net
import http

main:
  network := net.open
  client := http.Client network
  host := "www.google.com"
  response := client.get host "/"

  bytes := 0
  while data := response.body.read:
    bytes += data.size

  print "Read $bytes bytes from http://$host/"
