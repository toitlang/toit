// Copyright (C) 2019 Toitware ApS.
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

import encoding.json as json
import encoding.ubjson as ubjson
import io
import monitor
import .protocol.message

/**
Wraps a JSON map so that the fields can easily be accessed in wrapper classes.
*/
class MapWrapper:
  map_ /Map ::= ?

  constructor .map_ = {:}:

  lookup_ key:
    return lookup_ key: it

  lookup_ key [when-present]:
    return map_.get key --if-present=: when-present.call it

  at_ key:
    return at_ key: it

  at_ key [when-present]:
    return when-present.call map_[key]

encode-value_ value:
  encoded := null
  if value is MapWrapper:
    encoded = encode-map_ value.map_
  else if value is Map:
    encoded = encode-map_ value
  else if value is List:
    encoded = encode-list_ value
  else:
    encoded = value
  return encoded

encode-list_ list:
  return list.map: encode-value_ it

encode-map_ map:
  result := {:}
  map.do: |key value|
    encoded := encode-value_ value
    if encoded != null:
      result[key] = encoded
  return result

class RpcConnection:
  static CONTENT-TYPE-JSON_   ::= "application/vscode-jsonrpc; charset=utf8"
  static CONTENT-TYPE-UBJSON_ ::= "application/vscode-ubjsonrpc"

  // The id counter for request sent from the server to the client.
  request-id_              := 0
  pending-requests_       ::= {:}  // From request-id to Channel.

  reader_ /io.Reader ::= ?
  writer_ /io.Writer ::= ?
  mutex_  /monitor.Mutex  ::= monitor.Mutex

  use-ubjson_             := false

  json-count_             := 0
  ubjson-count_           := 0

  constructor .reader_ .writer_:

  enable-ubjson: use-ubjson_ = true

  uses-json: return not use-ubjson_

  read-packet:
    while true:
      line := reader_.read-line
      if line == null or line == "": return null
      payload-len := -1
      content-type := ""
      while line != "":
        if line == null: throw "Unexpected end of header"
        if line.starts-with "Content-Length:":
          payload-len = int.parse (line.trim --left "Content-Length:").trim
        else if line.starts-with "Content-Type:":
          content-type = (line.trim --left "Content-Type: ").trim
        else:
          throw "Unexpected RPC header $line"
        line = reader_.read-line
      if payload-len == -1: throw "Bad RPC header (no payload size)"
      encoded := reader_.read-bytes payload-len

      if content-type == CONTENT-TYPE-JSON_ or content-type == "":
        json-count_++
        return (json.Decoder).decode encoded
      if content-type == CONTENT-TYPE-UBJSON_:
        ubjson-count_++
        return ubjson.decode encoded
      throw "Unexpected content-type: '$content-type'"

  write-packet packet:
    payload/ByteArray := ?
    if use-ubjson_:
      payload = ubjson.encode packet
    else:
      payload = json.encode packet
    mutex_.do:
      writeln_ "Content-Length: $(payload.size)"
      writeln_ "Content-Type: $(use-ubjson_ ? CONTENT-TYPE-UBJSON_ : CONTENT-TYPE-JSON_)"
      writeln_ ""
      write_   payload

  read:
    while true:
      packet := read-packet
      if packet == null: return null
      if packet.contains "result" or packet.contains "error":
        handle-response_ packet
      else:
        return packet

  reply id/any msg/any -> none:
    response := {
      "jsonrpc": "2.0",
      "id": id,
    }
    encoded-value := encode-value_ msg
    if msg is ResponseError:
      response["error"] = encoded-value
    else:
      response["result"] = encoded-value
    write-packet response

  send method/string params/any -> none:
    write-packet {
      "jsonrpc": "2.0",
      "method": method,
      "params": (encode-value_ params)
    }

  request method/string params/any -> any:
    return request method params --id-callback=: null

  request method/string params/any [--id-callback] -> any:
    id := request-id_++
    channel := monitor.Channel 1
    // Update the map before sending the request, in case there is an extremely fast response.
    pending-requests_[id] = channel
    write-packet {
      "jsonrpc": "2.0",
      "method": method,
      "id"    : id,
      "params": (encode-value_ params)
    }
    id-callback.call id
    return channel.receive

  handle-response_ decoded -> none:
    id := decoded["id"]
    channel := pending-requests_[id]
    pending-requests_.remove id
    channel.send
      decoded.get "result" --if-absent=: decoded["error"]

  writeln_ line/string -> none:
    writer_.write line.to-byte-array
    array := ByteArray 2
    array[0] = '\r'
    array[1] = '\n'
    writer_.write array

  write_ data/ByteArray -> none:
    writer_.write data
