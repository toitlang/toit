// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import encoding.json
import monitor
import net.wifi
import ble
import protobuf

/** This UUID is used in PC and Phone APP by default. */
SERVICE_UUID ::= #[0x02, 0x1a, 0x90, 0x04, 0x03, 0x82, 0x4a, 0xea,
                   0xbf, 0xf4, 0x6b, 0x3f, 0x1c, 0x5a, 0xdf, 0xb4]

/** This security mode doesn't encrypt/decrypt */
SECURITY0 := Security0_

class BLECharacteristic_:
  characteristic/ble.LocalCharacteristic := ?

  static UUID_BASE ::= 0xff
  static PROPERTYS ::= ble.CHARACTERISTIC_PROPERTY_READ | ble.CHARACTERISTIC_PROPERTY_WRITE
  static PERMISSIONS ::= ble.CHARACTERISTIC_PERMISSION_READ | ble.CHARACTERISTIC_PERMISSION_WRITE
  static DESC_UUID ::= ble.BleUuid #[0x00, 0x00, 0x29, 0x01, 0x00, 0x00, 0x10, 0x00,
                                     0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb]

  constructor service/ble.LocalService service_uuid/ByteArray id/int desc/string:
    uuid := ByteArray service_uuid.size : service_uuid[it]
    uuid[2] = UUID_BASE
    uuid[3] = id

    characteristic = service.add_characteristic
        ble.BleUuid uuid
        --properties=PROPERTYS
        --permissions=PERMISSIONS
    characteristic.add_descriptor
        DESC_UUID
        PROPERTYS
        PERMISSIONS
        desc.to_byte_array
  
  write data/ByteArray:
    characteristic.write data

  read -> ByteArray:
    return characteristic.read

class BLEService_:
  uuid/ByteArray
  name/string

  characteristics/Map := ?
  peripheral/ble.Peripheral := ?

  static CHARACTERISTICS ::= [
    {"name":"prov-scan",    "id":0x50},
    {"name":"prov-session", "id":0x51},
    {"name":"prov-config",  "id":0x52},
    {"name":"proto-ver",    "id":0x53},
    {"name":"custom-data",  "id":0x54}
  ]

  constructor .uuid/ByteArray .name/string:
    adapter := ble.Adapter
    peripheral = adapter.peripheral
    service := peripheral.add_service
        ble.BleUuid uuid

    characteristics = Map
    CHARACTERISTICS.do:
      characteristics[it["name"]] =
          BLECharacteristic_
              service
              uuid
              it["id"]
              it["name"]

    service.deploy

  start:
    peripheral.start_advertise
        ble.AdvertisementData
            --name=name
            --service_classes=[ble.BleUuid uuid]
            --flags=ble.BLE_ADVERTISE_FLAGS_GENERAL_DISCOVERY |
                    ble.BLE_ADVERTISE_FLAGS_BREDR_UNSUPPORTED
        --interval=Duration --us=160000
        --connection_mode=ble.BLE_CONNECT_MODE_UNDIRECTIONAL
  
  operator [] name/string -> BLECharacteristic_:
    return characteristics[name]

abstract class Security_:
  abstract encrypt data/ByteArray -> ByteArray
  abstract decrypt data/ByteArray -> ByteArray
  abstract version -> int

class Security0_ extends Security_:
  encrypt data/ByteArray -> ByteArray:
    return data

  decrypt data/ByteArray -> ByteArray:
    return data
  
  version -> int:
    return 0

abstract class Process_:
  abstract run data/ByteArray -> ByteArray

class VerProcess_ extends Process_:
  static VERSION := "v1.1"
  static BASE_CAPS := ["wifi_scan"]

  resp_msg/ByteArray := ? 

  constructor version/int:
    caps := List BASE_CAPS.size: BASE_CAPS[it]
    if version == 0:
      caps.add "no_sec"
    ver_map := {"prov":{"ver":VERSION, "sec_ver":version, "cap":caps}}
    ver_json := json.stringify ver_map
    resp_msg = ver_json.to_byte_array

  run data/ByteArray -> ByteArray:
    return resp_msg

class SessionProcess_ extends Process_:
  static SESSION_0 ::= 10 /** type: message */
  static SESSION_0_MSG ::= 1 /** type: enum */
  static SESSION_0_REQ ::= 20 /** type: message */
  static SESSION_0_RESP ::= 21 /** type: message */

  sec0 r/protobuf.Reader -> ByteArray:
    r.read_message:
      r.read_field SESSION_0_REQ:
        tmp := r.read_primitive protobuf.PROTOBUF_TYPE_BYTES

    resp_msg := {
      SESSION_0: {
        SESSION_0_MSG: 1 /** 1: no need encryption */
      }
    }

    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp

  run data/ByteArray -> ByteArray:
    resp := #[]

    r := protobuf.Reader data
    r.read_message:
      r.read_field SESSION_0:
        resp = sec0 r

    return resp

class ScanProcess_ extends Process_:
  static MSG ::= 1 /** type: enum */

  /** Message enum number */
  static MSG_REQ_START ::= 0
  static MSG_RESP_START ::= 1
  static MSG_REQ_STATUS ::= 2
  static MSG_RESP_STATUS ::= 3
  static MSG_REQ_RESULT ::= 4
  static MSG_RESP_RESULT ::= 5

  static REQ_START ::= 10 /** type: message */
  static REQ_START_BLOCK ::= 1 /** type: bool */
  static REQ_START_PERIOD ::= 4 /** type: uint32 */

  static REQ_STATUS ::= 12 /** type: message */

  static RESP_STATUS ::= 13 /** type: message */
  static RESP_STATUS_FINISHED ::= 1 /** type: bool */
  static RESP_STATUS_COUNT ::= 2 /** type: uint32 */

  static REQ_RESULT ::= 14 /** type: message */
  static REQ_RESULT_START ::= 1 /** type: uint32 */
  static REQ_RESULT_COUNT ::= 2 /** type: uint32 */

  static RESP_RESULT ::= 15 /** type: message */
  static RESP_RESULT_ENTRIES ::= 1 /** type: Repeated message */
  static RESP_RESULT_ENTRIES_SSID ::= 1 /** type: bytes */
  static RESP_RESULT_ENTRIES_CHANNEL ::= 2 /** type: uint32 */
  static RESP_RESULT_ENTRIES_RSSI ::= 3 /** type: int32_t */
  static RESP_RESULT_ENTRIES_BSSID ::= 4 /** type: bytes */
  static RESP_RESULT_ENTRIES_AUTH ::= 5 /** type: uint32 */

  static CHANNEL_NUM ::= 14
  static SCAN_AP_MAX ::= 16

  ap_list/List := List
  scan_done/bool := false
  report_count/int := 4
  scan_period/int := 120
  msg_offset/int := 0

  comp_ap_by_rssi a/wifi.AccessPoint b/wifi.AccessPoint -> int:
    if a.rssi < b.rssi:
      return 1
    else if a.rssi == b.rssi:
      return 0
    else:
      return -1

  init_parameters -> none:
    ap_list = List
    scan_done = false
    report_count = 4
    scan_period = 120
    msg_offset = 0

  scan_task:
    channels := ByteArray CHANNEL_NUM: it + 1
    ap_list = wifi.scan
        channels
        --period_per_channel_ms=scan_period
    ap_list.sort --in_place=true:
      | a b | comp_ap_by_rssi a b
    size := min ap_list.size SCAN_AP_MAX
    ap_list = ap_list[0..size]
    scan_done = true

  scan_start r/protobuf.Reader -> ByteArray:
    r.read_message:
      r.read_field REQ_START_BLOCK:
        /** block=true is not supported, because it blocks NimBLE system task */
        block := r.read_primitive protobuf.PROTOBUF_TYPE_INT32
      r.read_field REQ_START_PERIOD:
        scan_period = r.read_primitive protobuf.PROTOBUF_TYPE_INT32

    init_parameters
    task:: scan_task

    resp_msg := {
        MSG: MSG_RESP_START
    }
    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp
  
  scan_status -> ByteArray:
    buffer := bytes.Buffer
    w := protobuf.Writer buffer

    resp_msg := {
        MSG: MSG_RESP_STATUS,
        RESP_STATUS: Map
    }

    if scan_done == false:
      resp_msg[RESP_STATUS][RESP_STATUS_FINISHED] = 0
    else:
      resp_msg[RESP_STATUS][RESP_STATUS_FINISHED] = 1
      resp_msg[RESP_STATUS][RESP_STATUS_COUNT] = ap_list.size

    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp
  
  scan_result r/protobuf.Reader -> ByteArray:
    r.read_message:
        r.read_field REQ_RESULT_COUNT:
          report_count = r.read_primitive protobuf.PROTOBUF_TYPE_INT32

    ap_info_msg := List
    if msg_offset < ap_list.size:
      ap_num := min (ap_list.size - msg_offset) report_count
      ap_num.repeat:
        ap ::= ap_list[msg_offset + it]
        ap_info := {
          RESP_RESULT_ENTRIES_SSID: ap.ssid,
          RESP_RESULT_ENTRIES_CHANNEL: ap.channel,
          RESP_RESULT_ENTRIES_RSSI: ap.rssi,
          RESP_RESULT_ENTRIES_BSSID: ap.bssid,
          RESP_RESULT_ENTRIES_AUTH: ap.authmode,
        }
        ap_info_msg.add ap_info

      msg_offset += ap_num

    resp_msg := {
      MSG: MSG_RESP_RESULT,
      RESP_RESULT: {
        RESP_RESULT_ENTRIES: ap_info_msg
      }
    }
    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp

  run data/ByteArray -> ByteArray:
    resp := #[]
    
    r := protobuf.Reader data
    r.read_message:
      r.read_field MSG:
        msgid := r.read_primitive protobuf.PROTOBUF_TYPE_INT32
        if msgid == 2:
          resp = scan_status
      r.read_field REQ_START:
        resp = scan_start r
      r.read_field REQ_STATUS:
        tmp := r.read_primitive protobuf.PROTOBUF_TYPE_BYTES
        resp = scan_status
      r.read_field REQ_RESULT:
        resp = scan_result r

    return resp

class ConfigProcess_ extends Process_:
  static MSG ::= 1 /** type: enum */

  /** Message enum number */
  static MSG_REQ_STATUS ::= 0
  static MSG_RESP_STATUS ::= 1
  static MSG_SET_CONFIG ::= 2
  static MSG_RESP_CONFIG ::= 3
  static MSG_SET_APPLY ::= 4
  static MSG_RESP_APPY ::= 5

  static REQ_STATUS ::= 10 /** type: message */

  static RESP_STATUS ::= 11 /** type: message */
  static RESP_STATUS_CONNECTED ::= 11 /** type: message */
  static RESP_STATUS_CONNECTED_IPV4_ADDR ::= 1 /** type: string */
  static RESP_STATUS_CONNECTED_AUTH_MODE ::= 2 /** type: uint32 */
  static RESP_STATUS_CONNECTED_SSID ::= 3 /** type: bytes */
  static RESP_STATUS_CONNECTED_BSSID ::= 4 /** type: bytes */
  static RESP_STATUS_CONNECTED_CHANNEL ::= 5 /** type: uint32 */

  static SET_CONFIG ::= 12 /** type: message */
  static SET_CONFIG_SSID ::= 1 /** type: bytes */
  static SET_CONFIG_PASSWORD ::= 2 /** type: bytes */

  static REQ_APPLY ::= 14 /** type: message */

  ssid/string := ""
  password/string := ""
  network := null

  latch/monitor.Latch := ?

  constructor .latch/monitor.Latch:

  set_config r/protobuf.Reader -> ByteArray:
    r.read_message:
      r.read_field SET_CONFIG_SSID:
        ssid = r.read_primitive protobuf.PROTOBUF_TYPE_STRING
      r.read_field SET_CONFIG_PASSWORD:
        password = r.read_primitive protobuf.PROTOBUF_TYPE_STRING
    
    resp_msg := {
      MSG: MSG_RESP_CONFIG
    }
    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp

  set_apply -> ByteArray:
    network = wifi.open
        --ssid=ssid
        --password=password

    resp_msg := {
        MSG: MSG_RESP_APPY
    }
    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp   

  req_status -> ByteArray:
    ap ::= network.access_point

    resp_msg := {
      MSG: MSG_RESP_STATUS,
      RESP_STATUS: {
        RESP_STATUS_CONNECTED: {
          RESP_STATUS_CONNECTED_IPV4_ADDR: "$(network.address)",
          RESP_STATUS_CONNECTED_AUTH_MODE: ap.authmode,
          RESP_STATUS_CONNECTED_SSID: ap.ssid,
          RESP_STATUS_CONNECTED_BSSID: ap.bssid,
          RESP_STATUS_CONNECTED_CHANNEL: ap.channel,
        }
      }
    }
    resp := protobuf_map_to_bytes_ --message=resp_msg
    return resp     

  run data/ByteArray -> ByteArray:
    resp := #[]

    r := protobuf.Reader data
    r.read_message:
      r.read_field MSG:
        msgid := r.read_primitive protobuf.PROTOBUF_TYPE_INT32
        if msgid == MSG_SET_APPLY:
          resp = set_apply
      r.read_field SET_CONFIG:
        resp = set_config r
      r.read_field REQ_STATUS:
        tmp := r.read_primitive protobuf.PROTOBUF_TYPE_BYTES
        resp = req_status
        latch.set true
      r.read_field REQ_APPLY:
        tmp := r.read_primitive protobuf.PROTOBUF_TYPE_BYTES
        resp = set_apply

    return resp

class Provisioning:
  service_/BLEService_ := ?
  security_/Security_ := ?
  latch_ := monitor.Latch

  constructor.ble  service_name/string security/Security_:
    return Provisioning.ble_with_uuid SERVICE_UUID service_name security
  
  constructor.ble_with_uuid service_uuid/ByteArray service_name/string .security_/Security_:
    service_ = BLEService_ service_uuid service_name

  start -> none:
    task:: ch_ver_task_
    task:: ch_config_task_
    task:: ch_session_task_
    task:: ch_scan_task_

    service_.start
  
  wait -> none:
    ret := latch_.get

  static common_process_ security/Security_ process/Process_ characteristic/BLECharacteristic_:
    encrypt_data := characteristic.read
    data := security.decrypt encrypt_data
    resp := process.run data
    if resp.size > 0:
      data = security.encrypt resp
      characteristic.write data

  ch_ver_task_:
    characteristic := service_["proto-ver"]
    session_process := VerProcess_ security_.version
    common_process_ security_ session_process characteristic

  ch_session_task_:
    characteristic := service_["prov-session"]
    session_process := SessionProcess_
    while true:
      common_process_ security_ session_process characteristic

  ch_scan_task_:
    characteristic := service_["prov-scan"]
    session_process := ScanProcess_
    while true:
      common_process_ security_ session_process characteristic

  ch_config_task_:
    characteristic := service_["prov-config"]
    session_process := ConfigProcess_ latch_
    while true:
      common_process_ security_ session_process characteristic  

protobuf_map_to_bytes_ --message/Map /** field:value */ -> ByteArray:
  buffer := bytes.Buffer
  w := protobuf.Writer buffer

  message.do:
    if it is not int:
      throw "WRONG_OBJECT_TYPE"
    value := message[it]
    if value is int:
      w.write_primitive protobuf.PROTOBUF_TYPE_INT32 value --as_field=it --oneof=true
    else if value is string:
      w.write_primitive protobuf.PROTOBUF_TYPE_STRING value --as_field=it
    else if value is ByteArray:
      w.write_primitive protobuf.PROTOBUF_TYPE_BYTES value --as_field=it
    else if value is List:
      id := it
      value.do:
        w.write_primitive
            protobuf.PROTOBUF_TYPE_BYTES
            protobuf_map_to_bytes_ --message=it
            --as_field=id
    else if value is Map:
      w.write_primitive 
          protobuf.PROTOBUF_TYPE_BYTES
          protobuf_map_to_bytes_ --message=value
          --as_field=it
    else:
      throw "WRONG_OBJECT_TYPE"

  return buffer.bytes

get_mac_address -> ByteArray:
  #primitive.esp32.get_mac_address
