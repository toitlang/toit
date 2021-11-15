// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .message

class Response:
  token/Token? ::= ?
  message/Message? ::= null
  error ::= null

  constructor.message .message:
    token = message.token
  constructor.error .token .error:

interface Transport:
  write msg/Message
  read -> Response?

  close

  new_message --reliable=true -> Message

  // Returns true if the underlying protocol is reliable, meaning no
  // messages are lost and are delivered in order.
  reliable -> bool

  mtu -> int
