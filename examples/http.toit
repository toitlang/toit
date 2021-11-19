// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import net
import http

main:
  network := net.open

  host := "www.google.com"
  socket := network.tcp_connect host 80

  connection := http.Connection socket host
  request := connection.new_request "GET" "/"
  response := request.send

  bytes := 0
  while data := response.read:
    bytes += data.size

  print "Read $bytes bytes from http://$host/"
