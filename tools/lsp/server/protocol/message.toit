// Copyright (C) 2020 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import ..rpc

class CancelParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /** The request id. */
  id:  // -> number | string
    return at_ "id"

class ResponseError extends MapWrapper:
  constructor
      --code     /int
      --message  /string
      --data     /any?=null:
    map_["code"] = code
    map_["message"] = message
    if data != null: map_["data"] = data

class ErrorCodes:
  static parse_error            ::= -23700
  static invalid_request        ::= -32600
  static method_not_found       ::= -32601
  static invalid_params         ::= -32602
  static internal_error         ::= -32603
  static server_error_start     ::= -32099
  static server_error_end       ::= -32000
  static server_not_initialized ::= -32002
  static unknown_error_code     ::= -32001
  // Defined by the protocol.
  static request_cancelled      ::= -32800
  static content_modified       ::= -32801
