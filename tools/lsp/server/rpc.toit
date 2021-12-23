// Copyright (C) 2019 Toitware ApS. All rights reserved.

import encoding.json as json
import encoding.ubjson as ubjson
import reader show BufferedReader
import writer show Writer
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

  lookup_ key [when_present]:
    return map_.get key --if_present=: when_present.call it

  at_ key:
    return at_ key: it

  at_ key [when_present]:
    return when_present.call map_[key]

encode_value_ value:
  encoded := null
  if value is MapWrapper:
    encoded = encode_map_ value.map_
  else if value is Map:
    encoded = encode_map_ value
  else if value is List:
    encoded = encode_list_ value
  else:
    encoded = value
  return encoded

encode_list_ list:
  return list.map: encode_value_ it

encode_map_ map:
  result := {:}
  map.do: |key value|
    encoded := encode_value_ value
    if encoded != null:
      result[key] = encoded
  return result

class RpcConnection:
  static CONTENT_TYPE_JSON_   ::= "application/vscode-jsonrpc; charset=utf8"
  static CONTENT_TYPE_UBJSON_ ::= "application/vscode-ubjsonrpc"

  // The id counter for request sent from the server to the client.
  request_id_              := 0
  pending_requests_       ::= {:}  // From request-id to Channel.

  reader_ /BufferedReader ::= ?
  writer_                 ::= ?
  mutex_  /monitor.Mutex  ::= monitor.Mutex

  use_ubjson_             := false

  json_count_             := 0
  ubjson_count_           := 0

  constructor .reader_ writer:
    writer_ = Writer writer

  enable_ubjson: use_ubjson_ = true

  uses_json: return not use_ubjson_

  read_packet:
    while true:
      line := reader_.read_line
      if line == null or line == "": return null
      payload_len := -1
      content_type := ""
      while line != "":
        if line == null: throw "Unexpected end of header"
        if line.starts_with "Content-Length:":
          payload_len = int.parse (line.trim --left "Content-Length:").trim
        else if line.starts_with "Content-Type:":
          content_type = (line.trim --left "Content-Type: ").trim
        else:
          throw "Unexpected RPC header $line"
        line = reader_.read_line
      if payload_len == -1: throw "Bad RPC header (no payload size)"
      encoded := reader_.read_bytes payload_len

      if content_type == CONTENT_TYPE_JSON_ or content_type == "":
        json_count_++
        return (json.Decoder).decode encoded
      if content_type == CONTENT_TYPE_UBJSON_:
        ubjson_count_++
        return ubjson.decode encoded
      throw "Unexpected content-type: '$content_type'"

  write_packet packet:
    encoder := use_ubjson_ ? ubjson.Encoder : json.Encoder
    encoder.encode packet
    payload := encoder.to_byte_array
    mutex_.do:
      writeln_ "Content-Length: $(payload.size)"
      writeln_ "Content-Type: $(use_ubjson_ ? CONTENT_TYPE_UBJSON_ : CONTENT_TYPE_JSON_)"
      writeln_ ""
      write_   payload

  read:
    while true:
      packet := read_packet
      if packet == null: return null
      if packet.contains "result" or packet.contains "error":
        handle_response_ packet
      else:
        return packet

  reply id/any msg/any -> none:
    response := {
      "jsonrpc": "2.0",
      "id": id,
    }
    encoded_value := encode_value_ msg
    if msg is ResponseError:
      response["error"] = encoded_value
    else:
      response["result"] = encoded_value
    write_packet response

  send method/string params/any -> none:
    write_packet {
      "jsonrpc": "2.0",
      "method": method,
      "params": (encode_value_ params)
    }

  request method/string params/any -> any:
    return request method params --id_callback=: null

  request method/string params/any [--id_callback] -> any:
    id := request_id_++
    channel := monitor.Channel 1
    // Update the map before sending the request, in case there is an extremely fast response.
    pending_requests_[id] = channel
    write_packet {
      "jsonrpc": "2.0",
      "method": method,
      "id"    : id,
      "params": (encode_value_ params)
    }
    id_callback.call id
    return channel.receive

  handle_response_ decoded -> none:
    id := decoded["id"]
    channel := pending_requests_[id]
    pending_requests_.remove id
    channel.send
      decoded.get "result" --if_absent=: decoded["error"]

  writeln_ line/string -> none:
    writer_.write line.to_byte_array
    array := ByteArray 2
    array[0] = '\r'
    array[1] = '\n'
    writer_.write array

  write_ data/ByteArray -> none:
    writer_.write data
