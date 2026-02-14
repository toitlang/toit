// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import net.udp
import net.tcp

import system.services show ServiceSelector ServiceClient
import system.base.network show NetworkServiceClientBase

// For references in documentation comments.
import system.services show ServiceResource ServiceResourceProxy

interface NetworkService:
  static SELECTOR ::= ServiceSelector
      --uuid="063e228a-3a7a-44a8-b024-d55127255ccb"
      --major=0
      --minor=4

  /**
  List of common tags that providers of $NetworkService may use
    to make their services easier to distinguish.
  */
  static TAG-CELLULAR /string ::= "cellular"
  static TAG-ETHERNET /string ::= "ethernet"
  static TAG-WIFI     /string ::= "wifi"

  /**
  Proxy mask bits that indicate which operations must be proxied
    through the service. See $connect.
  */
  static PROXY-NONE       /int ::= 0
  static PROXY-ADDRESS    /int ::= 1 << 0
  static PROXY-RESOLVE    /int ::= 1 << 1
  static PROXY-UDP        /int ::= 1 << 2
  static PROXY-TCP        /int ::= 1 << 3
  static PROXY-QUARANTINE /int ::= 1 << 4

  /**
  The socket options can be read or written using $socket-get-option
    and $socket-set-option.
  */
  static SOCKET-OPTION-UDP-BROADCAST            /int ::= 0
  static SOCKET-OPTION-UDP-MULTICAST-MEMBERSHIP /int ::= 1
  static SOCKET-OPTION-UDP-MULTICAST-LOOPBACK   /int ::= 2
  static SOCKET-OPTION-UDP-MULTICAST-TTL        /int ::= 3
  static SOCKET-OPTION-UDP-REUSE-ADDRESS        /int ::= 4
  static SOCKET-OPTION-UDP-REUSE-PORT           /int ::= 5
  static SOCKET-OPTION-TCP-NO-DELAY             /int ::= 100

  /**
  The notification constants are used as arguments to $ServiceResource.notify_
    and consequently $ServiceResourceProxy.on-notified_.
  */
  static NOTIFY-CLOSED /int ::= 200

  // The connect call returns a handle to the network resource and
  // the proxy mask bits in a list. The proxy mask bits indicate
  // which operations the service definition wants the client to
  // proxy through it.
  connect -> List
  static CONNECT-INDEX /int ::= 0

  address handle/int -> ByteArray
  static ADDRESS-INDEX /int ::= 1

  resolve handle/int host/string -> List
  static RESOLVE-INDEX /int ::= 2

  quarantine name/string -> none
  static QUARANTINE-INDEX /int ::= 3

  udp-open handle/int port/int? -> int
  static UDP-OPEN-INDEX /int ::= 100

  udp-open-multicast -> int
      handle/int
      address/ByteArray
      port/int
      if-addr/ByteArray?
      reuse-address/bool
      reuse-port/bool
      loopback/bool
      ttl/int
  static UDP-OPEN-MULTICAST-INDEX /int ::= 104

  udp-connect handle/int ip/ByteArray port/int -> none
  static UDP-CONNECT-INDEX /int ::= 101

  udp-receive handle/int -> List
  static UDP-RECEIVE-INDEX /int ::= 102

  udp-send handle/int data/ByteArray ip/ByteArray port/int -> none
  static UDP-SEND-INDEX /int ::= 103

  tcp-connect handle/int ip/ByteArray port/int -> int
  static TCP-CONNECT-INDEX /int ::= 200

  tcp-listen handle/int port/int -> int
  static TCP-LISTEN-INDEX /int ::= 201

  tcp-accept handle/int -> int
  static TCP-ACCEPT-INDEX /int ::= 202

  tcp-close-write handle/int -> none
  static TCP-CLOSE-WRITE-INDEX /int ::= 203

  socket-get-option handle/int option/int -> any
  static SOCKET-GET-OPTION-INDEX /int ::= 300

  socket-set-option handle/int option/int value/any -> none
  static SOCKET-SET-OPTION-INDEX /int ::= 301

  socket-local-address handle/int -> List
  static SOCKET-LOCAL-ADDRESS-INDEX /int ::= 302

  socket-peer-address handle/int -> List
  static SOCKET-PEER-ADDRESS-INDEX /int ::= 303

  socket-read handle/int -> ByteArray?
  static SOCKET-READ-INDEX /int ::= 304

  socket-write handle/int data -> int
  static SOCKET-WRITE-INDEX /int ::= 305

  socket-mtu handle/int -> int
  static SOCKET-MTU-INDEX /int ::= 306

class NetworkServiceClient extends NetworkServiceClientBase:
  static SELECTOR ::= NetworkService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector
