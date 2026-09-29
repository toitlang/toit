// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond
import ble.experimental.bond-table
import ble.experimental.bond-registry
import ble.experimental.bond-resume
import ble.experimental.bounded-central as bounded
import ble.experimental.central
import ble.experimental.encryption
import ble.experimental.hci
import ble.experimental.privacy
import ble.experimental.security-owner show Owner
import ble.experimental.service.client as clients
import ble.experimental.service.gatt-provider as policy
import ble.experimental.service.provider as rpc
import ble.experimental.smp-identity as identity
import expect show *
import io
import monitor
import system
import .ble-bond-table-test as storage
import .ble-bounded-accept-test as accept
import .ble-connect-isolation-test as connect
import .ble-fixture as packets
import .ble-key-reply-test as keys
import .ble-multilink-test as links
import .ble-service-mixed-test as mixed
import .ble-service-mixed-security-test as secure
import .ble-service-multiclient-test as wire

main:
  [false, true].do: | private/bool |
    [false, true].do: | peripheral-first/bool |
      [0, 1].do: | revoked/int |
        with-timeout --ms=10_000: run private peripheral-first revoked

run private/bool peripheral-first/bool revoked/int:
  provider := Provider private
  provider.install
  cc := clients.Client
  pc := clients.Client
  cc.open
  pc.open
  ready := monitor.Latch
  survivor-read := monitor.Latch
  replacement-read := monitor.Latch
  deleted := monitor.Latch
  remover/Task? := null
  responder := task::
    mixed.initialize provider.radio
    host/Host := provider.ready.get
    if peripheral-first: resume-peripheral provider
    resume-central provider host
    if not peripheral-first: resume-peripheral provider
    wire.sent provider.radio 0x234 #[0x0a, 3, 0]
    wire.incoming provider.radio 0x234 #[0x0b, 41]
    protected-read provider
    ready.set true
    wire.disconnect provider.radio (0x234 + revoked)
    if revoked == 0:
      protected-read provider
      survivor-read.set true
      resume-central provider host
      wire.sent provider.radio 0x234 #[0x0a, 3, 0]
      wire.incoming provider.radio 0x234 #[0x0b, 43]
      wire.disconnect provider.radio 0x234
      wire.disconnect provider.radio 0x235
    else:
      wire.sent provider.radio 0x234 #[0x0a, 3, 0]
      wire.incoming provider.radio 0x234 #[0x0b, 42]
      resume-peripheral provider
      protected-read provider
      replacement-read.set true
      wire.disconnect provider.radio 0x235
      wire.disconnect provider.radio 0x234
  try:
    p/clients.Session? := null
    if peripheral-first:
      p = secure.peripheral pc
      (provider.secured[1] as monitor.Latch).get
    c := cc.connect provider.addresses[0] --address-type=(private ? 1 : 0) --require-authentication
    if not p: p = secure.peripheral pc
    (provider.secured[1] as monitor.Latch).get
    cs := c.security
    ps := p.security
    expect (cs.authenticated and ps.authenticated)
    expect-equals #[41] (c.read 3)
    ready.get
    old/Owner := (provider.host as Host).owners[0x234 + revoked]
    victim := revoked == 0 ? provider.last-central : provider.last-peripheral
    provider.records.allow = true
    provider.records.pause-deletion = true
    remover = task::
      error := catch: provider.registry.remove revoked
      deleted.set (error or true) --exception=(error != null)
    provider.records.removing.get
    expect (not old.encrypted)
    if revoked == 0: c.close
    else: p.close
    while not victim.is-released: sleep --ms=1
    expect (not provider.radio.closed)
    expect (not deleted.has-value)
    if revoked == 0:
      survivor-read.get
      expect p.security.authenticated
    else:
      expect-equals #[42] (c.read 3)
      expect c.security.authenticated
    system.process-stats --gc
    expect (cs.authenticated and ps.authenticated)
    provider.records.release.set true
    deleted.get
    expect-equals [1 - revoked] provider.table.occupied
    provider.saved-keys[revoked] = ByteArray 16 --initial=(0x33 + revoked)
    expect-equals revoked (provider.registry.add (provider.candidate revoked))
    provider.records.allow = false
    if revoked == 0:
      replacement := cc.connect provider.addresses[0] --address-type=(private ? 1 : 0) --require-authentication
      expect-equals #[43] (replacement.read 3)
      expect (not old.encrypted)
      replacement.disconnect
      p.close
      while not provider.last-peripheral.is-released: sleep --ms=1
    else:
      provider.secured[1] = monitor.Latch
      replacement := secure.peripheral pc
      (provider.secured[1] as monitor.Latch).get
      replacement-read.get
      expect replacement.security.authenticated
      expect (not old.encrypted)
      replacement.close
      while not provider.last-peripheral.is-released: sleep --ms=1
      c.disconnect
    expect provider.radio.closed
    expect-equals 1 provider.opens
    expect-equals 1 provider.radio.closes
    expect-equals 3 provider.host.connections
  finally:
    provider.records.release.set true
    cc.close
    pc.close
    if remover: remover.cancel
    responder.cancel
    provider.uninstall
    provider.registry.close

resume-central provider/Provider host/Host:
  parameters := host.encode-connection provider.addresses[0] --address-type=(provider.private ? 1 : 0) --own-address-type=0
  packets.status-reply provider.radio (hci.command-packet host.connection-opcode parameters)
  provider.radio.received.add (event provider 0)
  packets.gatt-reply provider.radio #[2, 23, 0] #[3, 23, 0]
  packets.status-reply provider.radio (hci.command-packet 0x2019
      (encryption.enable-parameters 0x234 provider.saved-keys[0]))
  secure.encryption-event provider.radio 0x234 true

resume-peripheral provider/Provider:
  radio := provider.radio
  accept.setup radio
  accept.enabled radio
  radio.received.add (event provider 1)
  request := keys.request
  io.LITTLE-ENDIAN.put-uint16 request 4 0x235
  // No Advertising Set Terminated yet: accept cannot have returned to the
  // service's late owner factory. The hook must already have installed this key.
  radio.received.add request
  packets.reply radio (hci.command-packet 0x201a
      (encryption.reply-parameters 0x235 provider.saved-keys[1])) #[0x35, 2]
  secure.encryption-event radio 0x235 true
  accept.terminal radio --won
  accept.remove radio
  packet := radio.sent.take
  expect-equals #[2, 0x35, 2] packet[..3]
  expect-equals #[5, 0] packet[7..9]
  links.completed radio 0x235
  (provider.secured[1] as monitor.Latch).get

event provider/Provider index/int -> ByteArray:
  result := connect.completed-connection (index + 1) (0x234 + index)
  result[7] = index
  result[8] = provider.private ? 1 : 0
  result.replace 9 provider.addresses[index]
  return result

protected-read provider/Provider:
  wire.incoming provider.radio 0x235 #[0x0a, 18, 0]
  wire.sent provider.radio 0x235 #[0x0b, 43]

class Provider extends mixed.Provider:
  private/bool
  local/identity.Identity ::= identity.Identity (ByteArray 16 --initial=1) #[1, 2, 3, 4, 5, 6] 0
  identities/List ::= []
  addresses/List ::= []
  saved-keys/List ::= [ByteArray 16 --initial=0x11, ByteArray 16 --initial=0x22]
  secured/List ::= [monitor.Latch, monitor.Latch]
  records/Records ::= Records {:}
  table/bond-table.Table
  registry/bond-registry.Registry
  host/Host? := null

  constructor .private:
    2.repeat: | index/int |
      peer := identity.Identity (ByteArray 16 --initial=(index + 2)) (links.address (index + 1)) 0
      identities.add peer
      addresses.add (private ? (privacy.from-prand peer.irk #[0x42, 3, index + 4]) : peer.address)
    table = bond-table.Table records (ByteArray 32 --initial=42) --capacity=2
    2.repeat: | index/int |
      saved := bond.Candidate saved-keys[index] local identities[index] --authenticated
      expect-equals index (table.add saved)
    registry = bond-registry.Registry table --owner-limit=2
    super

  candidate index/int -> bond.Candidate:
    return bond.Candidate saved-keys[index] local identities[index] --authenticated

  create-shared-host controller/hci.Controller info/hci.Capabilities receive-limit/int -> central.Central:
    policy.configure-mixed-roles controller info
    records.allow = false
    host = Host controller info receive-limit registry
    ready.set host
    return host

  create-builder client/int name/string -> rpc.Session:
    last-peripheral = super client name
    return last-peripheral

  create-central-security-owner owner/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (owner as Host).owners[link.info.handle]

  create-security-owner owner/central.Central link/central.Link info/hci.Capabilities -> Owner?:
    return (owner as Host).owners[link.info.handle]

  run-central-security-owner selected/Owner -> none: (selected as bond-resume.Resume).run

  run-security-owner selected/Owner -> none:
    (selected as bond-resume.Resume).run
    (secured[1] as monitor.Latch).set true

class Host extends bounded.Central:
  registry_/bond-registry.Registry
  local_/ByteArray
  owners/Map ::= {:}
  connections/int := 0

  constructor controller/hci.Controller info/hci.Capabilities receive-limit/int .registry_:
    local_ = info.address
    super controller --acl-length=info.acl-length --acl-count=info.acl-count
        --receive-limit=receive-limit
        --link-limit=2

  on-connected link/central.Link -> none:
    owner := registry_.resume this link --local-address=local_ --require-authentication
    owners[link.info.handle] = owner
    connections++
    system.process-stats --gc

class Records extends storage.MemoryRecords:
  allow/bool := true
  pause-deletion/bool := false
  removing/monitor.Latch ::= monitor.Latch
  release/monitor.Latch ::= monitor.Latch

  constructor entries/Map: super entries
  read name/string -> ByteArray?:
    expect allow
    return super name
  write name/string bytes/ByteArray -> none:
    expect allow
    super name bytes
  remove name/string -> none:
    expect allow
    if pause-deletion:
      if not removing.has-value: removing.set true
      release.get
    super name
