// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import net
import net.impl
import net.tcp
import writer

import system.services show ServiceDefinition ServiceResource
import system.api.network show NetworkService NetworkServiceClient
import expect

service_/NetworkServiceClient? ::= (FakeNetworkServiceClient --no-open).open

main:
  service := FakeNetworkServiceDefinition
  service.install
  test_address service
  test_resolve service
  test_tcp_connect service
  service.uninstall

test_address service/FakeNetworkServiceDefinition:
  local_address ::= net.open.address
  service.address = null
  expect.expect_equals local_address open_fake.address
  service.address = local_address.to_byte_array
  expect.expect_equals local_address open_fake.address
  service.address = #[1, 2, 3, 4]
  expect.expect_equals "1.2.3.4" open_fake.address.stringify
  service.address = #[7, 8, 9, 10]
  expect.expect_equals "7.8.9.10" open_fake.address.stringify
  service.address = null

test_resolve service/FakeNetworkServiceDefinition:
  www_google ::= net.open.resolve "www.google.com"
  service.resolve = null
  expect.expect_list_equals www_google (open_fake.resolve "www.google.com")
  service.resolve = www_google.map: it.to_byte_array
  expect.expect_list_equals www_google (open_fake.resolve "www.google.com")
  service.resolve = []
  expect.expect_equals [] (open_fake.resolve "www.google.com")
  service.resolve = [#[1, 2, 3, 4]]
  expect.expect_equals [net.IpAddress #[1, 2, 3, 4]] (open_fake.resolve "www.google.com")
  service.resolve = [#[3, 4, 5, 6]]
  expect.expect_equals [net.IpAddress #[3, 4, 5, 6]] (open_fake.resolve "www.google.com")
  service.resolve = null

test_tcp_connect service/FakeNetworkServiceDefinition:
  service.enable_tcp_proxying
  fake := open_fake
  socket/tcp.Socket := fake.tcp_connect "www.google.com" 80
  writer := writer.Writer socket
  writer.write """GET / HTTP/1.1\r\nConnection: close\r\n\r\n"""
  size/int := 0
  while data := socket.read:
    size += data.size
  expect.expect size > 0
  socket.close
  fake.close
  service.disable_tcp_proxying

// --------------------------------------------------------------------------

open_fake -> net.Interface:
  return impl.SystemInterface_ service_ service_.connect

interface FakeNetworkService extends NetworkService:
  static UUID  /string ::= "5c6f4b05-5646-4866-856d-b12649ace896"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

class FakeNetworkServiceClient extends NetworkServiceClient:
  constructor --open/bool=true:
    super --open=open

  open -> FakeNetworkServiceClient?:
    return (open_ FakeNetworkService.UUID FakeNetworkService.MAJOR FakeNetworkService.MINOR) and this

class FakeNetworkServiceDefinition extends ServiceDefinition:
  proxy_mask_/int := 0
  network_/net.Interface ::= net.open

  address_/ByteArray? := null
  resolve_/List? := null

  constructor:
    super "system/network/test" --major=1 --minor=2  // Major and minor versions do not matter here.
    provides FakeNetworkService.UUID FakeNetworkService.MAJOR FakeNetworkService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == NetworkService.CONNECT_INDEX:
      return connect client
    if index == NetworkService.ADDRESS_INDEX:
      return address (resource client arguments)
    if index == NetworkService.RESOLVE_INDEX:
      return resolve (resource client arguments[0]) arguments[1]
    if index == NetworkService.TCP_CONNECT_INDEX:
      return tcp_connect client arguments[1] arguments[2]
    if index == NetworkService.SOCKET_READ_INDEX:
      return socket_read (resource client arguments)
    if index == NetworkService.SOCKET_WRITE_INDEX:
      return socket_write (resource client arguments[0]) arguments[1]
    unreachable

  update_proxy_mask_ mask/int add/bool:
    if add: proxy_mask_ |= mask
    else: proxy_mask_ &= ~mask

  address= value/ByteArray?:
    update_proxy_mask_ NetworkService.PROXY_ADDRESS (value != null)
    address_ = value

  resolve= value/List?:
    update_proxy_mask_ NetworkService.PROXY_RESOLVE (value != null)
    resolve_ = value

  enable_tcp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_TCP true
  disable_tcp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_TCP false

  enable_udp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_UDP true
  disable_udp_proxying -> none:
    update_proxy_mask_ NetworkService.PROXY_UDP false

  connect client/int -> List:
    resource := FakeNetworkResource this client
    return [resource.serialize_for_rpc, proxy_mask_]

  address resource/ServiceResource -> ByteArray:
    return address_

  resolve resource/ServiceResource host/string -> List:
    return resolve_

  tcp_connect client/int ip/ByteArray port/int -> ServiceResource:
    socket ::= network_.tcp_connect (net.IpAddress ip).stringify port
    return FakeTcpSocketResource this client socket

  socket_read resource/ServiceResource -> ByteArray?:
    return (resource as FakeSocket).read

  socket_write resource/ServiceResource data -> int:
    return (resource as FakeSocket).write data

class FakeNetworkResource extends ServiceResource:
  constructor service/ServiceDefinition client/int:
    super service client

  on_closed -> none:
    // Do nothing.

abstract class FakeSocket extends ServiceResource:
  constructor service/ServiceDefinition client/int:
    super service client

  abstract read -> ByteArray?
  abstract write data -> int

class FakeTcpSocketResource extends FakeSocket:
  socket/tcp.Socket

  constructor service/ServiceDefinition client/int .socket:
    super service client

  read -> ByteArray?:
    return socket.read

  write data -> int:
    return socket.write data

  on_closed -> none:
    socket.close
