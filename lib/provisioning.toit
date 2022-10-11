// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import bytes

class BLEService:
  group_ ::= ?

  constructor:
    group_ = provisioning_init_

  is_provisioned -> bool:
    return provisioning_is_provisioned_ group_

  get_mac_addr -> ByteArray:
    return provisioning_get_mac_addr_ group_

  get_mac_addr_string upper/bool=true -> string:
    raw_ ::= provisioning_get_mac_addr_ group_
    buffer := bytes.Buffer
    6.repeat:
        byte := raw_[it]
        if upper:
          buffer.write_byte (to_upper_case_hex byte >> 4)
          buffer.write_byte (to_upper_case_hex byte & 0xf)
        else:
          buffer.write_byte (to_lower_case_hex byte >> 4)
          buffer.write_byte (to_lower_case_hex byte & 0xf)
    return buffer.to_string

  start --name/string --pop/string --key/string="" --uuid/ByteArray -> none:
    provisioning_start_ group_ name pop key uuid

  qrcode_print_string --data/string -> none:
    provisioning_qrcode_print_string_ group_ data

  wait_for_done --min/int=0 --sec/int=0 --msec/int=0 -> bool:
    time := (min * 60 + sec) * 1000 + msec
    if time < 0:
      return false

    return provisioning_wait_for_done_ group_ time

  get_ip_addr -> ByteArray:
    return provisioning_get_ip_addr_ group_

  get_ip_addr_string -> string:
    raw_ ::= provisioning_get_ip_addr_ group_
    data_ := ""
    4.repeat:
      byte := raw_[it]
      data_ += byte.stringify
      if it < 3:
        data_ += "."
    return data_

  connect_to_ap -> none:
    provisioning_connect_to_ap_ group_

provisioning_init_:
  #primitive.provisioning.init

provisioning_is_provisioned_ resource_group:
  #primitive.provisioning.is_provisioned

provisioning_get_mac_addr_ resource_group:
  #primitive.provisioning.get_mac_addr

provisioning_start_ resource_group name pop key uuid:
  #primitive.provisioning.start

provisioning_qrcode_print_string_ resource_group data:
  #primitive.provisioning.qrcode_print_string

provisioning_wait_for_done_ resource_group timeout_ms:
  #primitive.provisioning.wait_for_done

provisioning_get_ip_addr_ resource_group:
  #primitive.provisioning.get_ip_addr

provisioning_connect_to_ap_ resource_group:
  #primitive.provisioning.connect_to_ap
