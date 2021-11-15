// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import log
import uart
import at

import .sequans_cellular

/**
Driver for Sequans Monarch, GSM communicating over NB-IoT & M1.
*/
class Monarch extends SequansCellular:
  constructor
      uart
      --logger=log.default:
    super uart --logger=logger --default_baud_rate=921600 --use_psm=false

  on_connected_ session/at.Session:

  on_reset session/at.Session:
