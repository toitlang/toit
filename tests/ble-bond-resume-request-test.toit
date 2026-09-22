// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-resume
import ble.experimental.central
import ble.experimental.connection
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.smp-identity
import expect show *
import monitor

import .ble-hci-test as fixture
import .ble-key-reply-test as keys

// Core 6.3 Vol 3 Part H 2.4.6, Figure 2.7: a central with a stored key that
// meets a Security Request encrypts; one whose key cannot meet a request for
// MITM protection and that cannot pair answers Pairing Not Supported.
main:
  with-timeout --ms=10_000:
    request-starts-encryption --authenticated=false --authreq=0x29
    request-starts-encryption --authenticated=true --authreq=0x2d
    insufficient-key-is-rejected
    request-after-encryption-is-ignored

setup [block]:
  local-id := smp-identity.Identity (ByteArray 16 --initial=1) #[6, 5, 4, 3, 2, 1] 0
  peer-id := smp-identity.Identity (ByteArray 16 --initial=2) #[1, 2, 3, 4, 5, 6] 0
  radio := fixture.FakeTransport
  host := central.Central (hci.Controller radio)
  connected := monitor.Latch
  responder := task::
    fixture.status-reply radio
        (hci.command-packet 0x200d (connection.create-parameters peer-id.address --address-type=0))
    event := fixture.connection-event.copy
    event[8] = 0
    radio.received.add event
  try:
    link := host.connect peer-id.address --address-type=0
    block.call radio host link local-id peer-id
  finally:
    host.close
    responder.cancel

request-starts-encryption --authenticated/bool --authreq/int:
  setup: | radio/fixture.FakeTransport host/central.Central link/central.Link local-id peer-id |
    candidate := bond.Candidate keys.KEY local-id peer-id --authenticated=authenticated
    resume := bond-resume.Resume host link candidate --local-address=local-id.address
    sent := radio.sent-count
    resume.receive #[0x0b, authreq]
    // Encryption is submitted without any call to run.
    fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 keys.KEY))
    expect-equals (sent + 1) radio.sent-count
    // A second request during setup is ignored.
    resume.receive #[0x0b, authreq]
    expect-equals (sent + 1) radio.sent-count
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    resume.run
    expect (resume.paired and resume.encrypted)
    expect-equals authenticated resume.authenticated
    expect-throw "BLE_BOND_RESUME_INVALID_STATE": resume.run

insufficient-key-is-rejected:
  setup: | radio/fixture.FakeTransport host/central.Central link/central.Link local-id peer-id |
    candidate := bond.Candidate keys.KEY local-id peer-id --authenticated=false
    resume := bond-resume.Resume host link candidate --local-address=local-id.address
    resume.receive #[0x0b, 0x2d]
    fixture.att-sent radio #[5, 5] --channel=6
    // No encryption was started by the request; the owner remains usable.
    expect-equals 2 radio.sent-count
    expect (not resume.paired)

request-after-encryption-is-ignored:
  setup: | radio/fixture.FakeTransport host/central.Central link/central.Link local-id peer-id |
    candidate := bond.Candidate keys.KEY local-id peer-id --authenticated=false
    resume := bond-resume.Resume host link candidate --local-address=local-id.address
    worker := task:: resume.run
    fixture.status-reply radio (hci.command-packet 0x2019 (encryption.enable-parameters 0x234 keys.KEY))
    radio.received.add #[4, 8, 4, 0, 0x34, 2, 1]
    with-timeout --ms=2_000: while not resume.encrypted: sleep --ms=5
    sent := radio.sent-count
    resume.receive #[0x0b, 0x29]
    expect-equals sent radio.sent-count
    expect resume.encrypted
