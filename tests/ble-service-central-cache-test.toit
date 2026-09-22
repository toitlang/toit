// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.attribute-server as attributes
import ble.experimental.service.client as clients
import .ble-fixture as fixture
import .ble-mtu-server-test as wire
import .ble-service-central-test as service

main:
  run false
  run true
  run false --migrate
  run false --body-failure

run active/bool --migrate/bool=false --body-failure/bool=false:
  with-timeout --ms=10_000:
    provider := service.Provider
    provider.install
    client := clients.Client
    client.open
    database := attributes.Database.with-defaults
    database.add-service #[0xf0, 0xff]
    database.add-characteristic #[0xf1, 0xff] --read --write --notify --value=#[7]
    session := database.session
    replacement := attributes.Database.with-defaults
    replacement.add-service #[0xf0, 0xff]
    decoy := replacement.add-characteristic #[0xf2, 0xff] --read --write --value=#[99]
    moved := replacement.add-characteristic #[0xf1, 0xff] --read --write --notify --value=#[8]
    migrated := false
    inject := false
    requests := 0
    responder := task::
      error := catch:
        radio := provider.radio
        fixture.initialize-replies radio
        fixture.status-reply radio fixture.create-command
        radio.received.add fixture.connection-event
        while true:
          packet := radio.sent.take
          expect-equals 2 packet[0]
          radio.received.add #[4, 0x13, 5, 1, 0x34, 2, 1, 0]
          request := packet[9..]
          requests++
          response := session.request request
          if body-failure and request == #[0x12, 9, 0, 0, 0]:
            response = #[1, 0x12, 9, 0, 3]
          if inject:
            inject = false
            if migrate and not migrated:
              // Emulate a remote layout change, including reuse of the old handle.
              session.close
              session = replacement.session
              // Preserve the remote monitor's CCCD across the layout replacement.
              expect-equals #[0x13] (session.request #[0x12, 9, 0, 2, 0])
              session.response-sent
              migrated = true
            wire.incoming radio #[0x1d, 8, 0, 1, 0, 0xff, 0xff]
            fixture.att-sent radio #[0x1e]
          if response:
            wire.incoming radio response
            session.response-sent
      if error and not provider.radio.closed: throw error
    connection/clients.Connection? := null
    try:
      connection = client.connect #[1, 2, 3, 4, 5, 6] --address-type=1
      before := connection.database
      held/clients.DatabaseView? := null
      monitor-error := catch:
        connection.with-service-changed:
          expect-throw "GATT_DATABASE_CHANGED": before.services
          view := connection.database
          services := view.services
          found := services.filter: it[2] == #[0xf0, 0xff]
          expect-equals 1 found.size
          values := view.characteristics found[0][0] found[0][1]
          handle/int := values[0][1]
          original-handle := handle
          expect-equals #[7] (view.read handle)
          records := view.discover-services.filter: it.uuid == #[0xf0, 0xff]
          service-record/clients.ServiceRecord := records[0]
          characteristic/clients.CharacteristicRecord := service-record.characteristics[0]
          descriptor/clients.DescriptorRecord := characteristic.descriptors[0]
          expect-equals #[0, 0] descriptor.read
          uuid := characteristic.uuid
          uuid.fill 0
          system.process-stats --gc
          expect-equals #[0xf1, 0xff] characteristic.uuid
          expect-equals #[7] characteristic.read
          inject = true
          expect-throw "GATT_DATABASE_CHANGED": view.read handle
          count := requests
          expect-throw "GATT_DATABASE_CHANGED": view.write handle #[99]
          expect-throw "GATT_DATABASE_CHANGED": view.write-command handle #[99]
          expect-throw "GATT_DATABASE_CHANGED": characteristic.read
          expect-throw "GATT_DATABASE_CHANGED": characteristic.write #[99]
          expect-throw "GATT_DATABASE_CHANGED": descriptor.read
          expect-throw "GATT_DATABASE_CHANGED": descriptor.write #[1, 0]
          expect-throw "GATT_DATABASE_CHANGED":
            characteristic.subscribe: unreachable
          expect-throw "GATT_DATABASE_CHANGED": service-record.characteristics
          expect-throw "GATT_DATABASE_CHANGED":
            view.subscribe handle --cccd=(handle + 1): unreachable
          expect-equals count requests
          if migrate:
            expect migrated
            expect-equals original-handle decoy
            expect-equals #[99] (replacement.value decoy)
          fresh := connection.database
          // Fresh discovery is required after invalidation; old views stay stale.
          found = fresh.services.filter: it[2] == #[0xf0, 0xff]
          values = fresh.characteristics found[0][0] found[0][1]
          target := values.filter: it[3] == #[0xf1, 0xff]
          expect-equals 1 target.size
          handle = target[0][1]
          if migrate:
            expect-equals 2 values.size
            expect-equals moved handle
            expect handle != original-handle
            fresh-records := fresh.discover-services.filter: it.uuid == #[0xf0, 0xff]
            fresh-values := fresh-records[0].characteristics.filter: it.uuid == #[0xf1, 0xff]
            expect-equals 1 fresh-values.size
            expect-equals moved fresh-values[0].handle
            expect-equals #[8] fresh-values[0].read
            fresh-values[0].write #[42]
            expect-equals #[42] (replacement.value moved)
            expect-equals #[99] (replacement.value decoy)
          fresh.write handle #[8]
          retained := fresh.read handle
          system.process-stats --gc
          expect-equals #[8] retained
          held = fresh
          if body-failure: throw "APPLICATION_FAILED"
          if active:
            records = fresh.discover-services.filter: it.uuid == #[0xf0, 0xff]
            characteristic = records[0].characteristics[0]
            characteristic.subscribe: | stream/clients.Subscription |
              inject = true
              expect-throw "GATT_DATABASE_CHANGED": fresh.read handle
              expect-throw "GATT_DATABASE_CHANGED": stream.receive
      if body-failure:
        expect-equals "APPLICATION_FAILED" monitor-error
        while not provider.radio.closed: yield
      else if active:
        expect-equals "GATT_DATABASE_CHANGED" monitor-error
      else:
        expect-null monitor-error
      if not active:
        expect-throw "GATT_DATABASE_CHANGED": held.services
    finally:
      if connection: connection.close
      client.close
      responder.cancel
      session.close
      provider.uninstall
