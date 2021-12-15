// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .tcp
import http
import monitor show *
import reader show *
import writer show *

main:
  header_test
  all_in_one_responder_test false
  all_in_one_responder_test true
  all_in_one_requester_test false
  all_in_one_requester_test true
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

  while request := connection.read_request:
    expect_equals "POST" request.method
    expect_equals "/funny.jpg" request.path
    expect_equals "HTTP/1.1" request.version

    request_body := ""

    while data := request.read:
      request_body += data.to_string

    expect_equals "giraffe with short neck" request_body
    expect_equals (request.headers.single "x-foo") "Bar"
    expect (request.headers.matches "X-foo" "bar")

    response := request.response
    response.body = "HAHAHAHAHA!"
    response.send

  socket.close

client port:
  host := "localhost"
  socket := TcpSocket
  socket.connect host port
  connection := http.Connection socket host

  2.repeat:
    request := connection.new_request "POST" "/funny.jpg"
    request.headers.set "X-FoO" "Bar"

    request.body = "giraffe with short neck"

    response := request.send

    expect_equals "HTTP/1.1" response.version
    expect_equals 200 response.status_code
    expect_equals "OK" response.status_message

    response_body := ""

    while data := response.read:
      response_body += data.to_string

    expect_equals "HAHAHAHAHA!" response_body

  socket.close

header_test:
  h := http.Headers
  expect_equals "Foo" (h.ascii_normalize_ "Foo")
  expect_equals "Foo" (h.ascii_normalize_ "foo")
  expect_equals "" (h.ascii_normalize_ "")
  expect_equals "SøRen" (h.ascii_normalize_ "Søren")
  expect_equals "SØRen" (h.ascii_normalize_ "SØREN")
  expect_equals "The Best" (h.ascii_normalize_ "the best")
  expect_equals "Foo-Bar" (h.ascii_normalize_ "Foo-Bar")
  expect_equals "Foo-Bar" (h.ascii_normalize_ "Foo-bar")
  expect_equals "Foo-Bar" (h.ascii_normalize_ "foo-bar")

// How do we handle an HTTP server that returns the whole response in one packet?
all_in_one_responder_test one_byte_packets:
  server_socket := PseudoSocket
  // TODO(589): avoid 'null' hack to get dynamic typing.
  client_socket := null
  client_socket = PseudoSocket server_socket
  task:: all_in_one_server server_socket one_byte_packets
  if one_byte_packets: client_socket = SplittingSocketAdapter client_socket
  host := "localhost"
  connection := http.Connection client_socket host
  request := connection.new_request "GET" "/"
  response := request.send
  expect_equals "text/plain" (response.headers.single "content-type")
  expect_equals "text/plain" (response.headers.single "Content-Type")
  expect_equals "text/plain" (response.headers.single "coNtEnt-tYPe")
  expect (response.headers.matches "Content-Type" "text/plain")
  expect (response.headers.matches "cOnTeNt-TyPe" "tExT/pLaIn")
  expect (not response.headers.matches "Content-Type" "text/html")
  ba := ByteArray 0
  while data := response.read:
    ba = ba + data
  client_socket.close
  expect_equals "There are fortytwø bytes in this sentence" ba.to_string

// Really dumb HTTP server that always serves the same data and returns.  It
// sends everything in one packet to test that we don't expect a packet
// boundary between the headers and the data.  Optionally it can send every
// byte in a separate packet instead.
all_in_one_server socket one_byte_packets -> none:
  if one_byte_packets: socket = SplittingSocketAdapter socket
  reader := BufferedReader socket
  writer := Writer socket
  while true:
    index := reader.index_of '\r'
    reader.skip index + 1
    if (reader.byte 0) == '\n' and (reader.byte 1) == '\r' and (reader.byte 2) == '\n':
      reader.skip 3
      // We also have extra whitespace in the headers which the server must trim.
      writer.write "HTTP/1.1 200 OK\r\nContent-Type: \t text/plain\r\nContent-Length: \t 42\r\n\r\nThere are fortytwø bytes in this sentence"
      socket.close
      return

all_in_one_requester_test one_byte_packets:
  // TODO(589): avoid 'null' hack to get dynamic typing.
  server_socket := null
  server_socket = PseudoSocket
  client_socket := PseudoSocket server_socket

  task:: all_in_one_client client_socket one_byte_packets

  if one_byte_packets: server_socket = SplittingSocketAdapter server_socket
  connection := http.Connection server_socket

  request := connection.read_request
  expect_equals "GET" request.method
  expect_equals "/jim" request.path
  expect_equals "HTTP/1.1" request.version

  request_body := ""

  expect_equals "foo-bar" (request.headers.single "x-foo-bar")
  expect (request.headers.matches "x-foo-bar" "Foo-Bar")
  expect_equals "identity" (request.headers.single "Accept-Encoding")
  expect (request.headers.matches "Accept-Encoding" "IDENTITY")
  expect (request.headers.matches "accept-encoding" "IDENTITY")

  response := request.response
  response.body = "There are fortytwø bytes in this sentence"
  response.send

  server_socket.close

// Really dumb HTTP client that always expects the same data and returns.  It
// sends everything in one packet to test that we don't expect packet
// boundaries anywhere.  Optionally it can send every byte in a separate packet
// instead.
all_in_one_client socket one_byte_packets:
  if one_byte_packets: socket = SplittingSocketAdapter socket
  // We also have extra whitespace in the headers which the server must trim.
  writer := Writer socket
  writer.write "GET /jim HTTP/1.1\r\nX-Foo-Bar:  foo-bar\r\nAccept-Encoding:  identity\r\n\r\n"
  reader := BufferedReader socket
  are_headers_read_ := false
  while not are_headers_read_:
    index := reader.index_of '\r'
    reader.skip index + 1
    if (reader.byte 0) == '\n' and (reader.byte 1) == '\r' and (reader.byte 2) == '\n':
      reader.skip 3
      are_headers_read_ = true
  ba := ByteArray 0
  while data := reader.read:
    ba = ba + data
  socket.close
  expect_equals "There are fortytwø bytes in this sentence" ba.to_string

// Acts like a socket (read/write/close), but is actually using a channel for
// its operations.  Has a buffer capacity of 1, where an actual socket has an
// unknown buffer capacity, so it can deadlock in some situations where a
// genuine socket might not.
class PseudoSocket implements Reader:
  read_channel_ := Channel 1
  write_channel_ := Channel 1
  write_closed_ := false
  read_closed_ := false
  counterpart_ := null

  constructor:

  // Construct a pseudo socket that is the other end of the given PseudoSocket.
  constructor other:
    super
    other.counterpart_ = this
    counterpart_ = other
    read_channel_ = other.write_channel_
    write_channel_ = other.read_channel_

  write obj from = 0 to = obj.size:
    expect (from == 0 and to == obj.size)  // Other values are not implemented.
    expect (not write_closed_)
    if obj is string:
      write_channel_.send obj.to_byte_array
    else:
      write_channel_.send
        ByteArray obj.size: obj[it]
    return obj.size

  read:
    if read_closed_: return null
    obj := read_channel_.receive
    if obj == null:
      read_closed_ = true
    return obj

  close:
    write_channel_.send null
    write_closed_ = true
    read_closed_ = true

  set_no_delay value:

// Wrapper that takes a socket and creates a socket that writes only one byte per packet.
class SplittingSocketAdapter implements Reader:
  constructor .socket:

  socket := ?

  read:
    return socket.read

  close:
    return socket.close

  write str from = 0 to = str.size:
    expect (from == 0 and to == str.size)  // Other values are not implemented.
    ba := ByteArray 1
    str.size.repeat:
      ba[0] = str.at --raw it
      socket.write ba
    return str.size

  set_no_delay value:
