// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.


resource_group_ ::= rmt_init_

rmt_init_:
  #primitive.rmt.init

rmt_use_ resource_group channel_num:
  #primitive.rmt.use

rmt_unuse_ resource_group resource:
  #primitive.rmt.unuse

rmt_config_ pin_num/int channel_num/int is_tx/bool mem_block_num/int:
  #primitive.rmt.config

rmt_transfer_ tx_num/int items_bytes/*/Blob*/:
  #primitive.rmt.transfer

rmt_transfer_and_read_ tx_num/int rx_num/int items_bytes max_output_len/int:
  #primitive.rmt.transfer_and_read
