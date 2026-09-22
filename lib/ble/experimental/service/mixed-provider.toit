// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import ..bounded-central as bounded
import ..central as central
import ..controller-states as states
import ..hci as hci
import .api as api
import .gatt-provider as gatt
import .shared-host as shared

/**
Provides two central sessions or one central and one peripheral session.

Each session belongs to a different application client. A configured peripheral
  builder reserves its slot before advertising starts. Scanning and standalone
  advertising remain exclusive. Setup is serialized; established links use the
  ordinary shared receive task and controller credits.

Requires extended advertising and both mixed-role establishment orders. Original
  ESP32 is unsupported; ESP32-S3 and supporting Linux controllers can use this
  path. Cancellation waits for finite advertising expiry and disconnects a
  winning link. Uncertain cleanup may fail all sessions explicitly.

The default host installs no security owner. Trusted providers may override
  $create-shared-host with one early security policy for both roles, preserving
  this module's $configure and bounded accept cleanup. The separate exclusive
  central/peripheral host hooks are not used by shared sessions.
*/
abstract class Provider extends gatt.Provider:
  central-session-limit -> int: return 2
  mixed-role-sessions -> bool: return true

  capabilities -> List:
    result := super
    result[0] |= api.CAP-MIXED-ROLES
    return result

  reserve-peripheral-host -> shared.Host?: return reserve-shared-host

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    configure controller info
    return bounded.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit
        --link-limit=2
        --early-acl-timeout=early-acl-timeout

/** Configures the extended command family and checks both establishment orders. */
configure controller/hci.Controller info/hci.Capabilities -> none:
  bounded.configure controller info
  supported := states.read controller
  if not (supported.supports states.CONNECTABLE-ADVERTISING-WITH-CENTRAL) or
      not (supported.supports states.INITIATING-WITH-PERIPHERAL):
    throw "GATT_MIXED_CONTROLLER_UNSUPPORTED"
