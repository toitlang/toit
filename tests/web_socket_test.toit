// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .tcp
import http
import web_socket show *
import monitor show *

YAYA ::= "yayayaya"
LALA ::= "lålalala"

main:
  ready := Channel 1
  task:: server ready
  port := ready.receive
  task:: client port

server ready:
  server := TcpServerSocket
  server.listen "" 0
  ready.send server.local_address.port

  socket := server.accept
  connection := http.Connection socket
  request := connection.read_request
  expect request.should_web_socket_upgrade
  web_socket := WebSocketServer connection request

  expect_equals LALA web_socket.read
  web_socket.write YAYA         // Write a string as TEXT.

  expect_equals LALA web_socket.read.to_string
  web_socket.write YAYA.to_byte_array  // Write a byte array as BINARY.

  web_socket.close_write
  expect_null web_socket.read

client port:
  host := "localhost"
  socket := TcpSocket
  socket.connect host port
  connection := http.Connection socket host
  request := connection.new_request "GET" "/"

  web_socket := WebSocketClient connection request
  web_socket.write LALA         // Write a Unicode string as TEXT.
  expect_equals YAYA web_socket.read

  web_socket.write LALA.to_byte_array  // Write a UTF-8 byte array as BINARY.
  expect_equals YAYA web_socket.read.to_string

  web_socket.close_write
  expect_null web_socket.read
