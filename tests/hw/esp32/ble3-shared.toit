// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Exercises the GC while using BLE.

Unfortunately it's almost impossible to trigger the GC in the
  nimBLE callback this way.

Run `ble3-board1.toit` on board1, first.
Once that one is running, run `ble3-board2.toit` on board2.

As of 2024-04-24 the test is still somewhat flaky. Board2 sometimes gets
  disconnected which then leads to an NimBLE error it can't recover from
  leading to a crash in native code.
*/

import ble show *
import expect show *
import monitor

import .ble-util
import .test

ITERATIONS ::= 100

UUIDS ::= [
  "ffe21239-d8a2-4536-b751-0881a9f2e3de",
  "9e3d1c10-9421-499e-851d-8e6bf2bd8808",
  "f626e5c8-1551-4e64-861c-25705f35f8c2",
  "417b7728-8ccf-4b78-b18b-4719326dc61b",
  "e844f115-afcb-47f3-a1a1-dfe979218d49",
  "ca7c8b92-cf6f-4833-b701-09d0fc145a28",
  "f90e7b00-f202-45f2-9c26-bb4eb6d80215",
  "03b0ac6c-1f8c-468f-bceb-f3c2d61d352c",
  "79a95d28-daa2-46e7-907d-c2ebdc95b1d4",
  "0e9b460f-373a-41c9-a004-8ca7a06e84cc",
  "1c74c550-b096-4144-8869-63135d7a9c2e",
  "19e049bf-7418-4b45-9e0f-c65ac0477e05",
  "e88a40d9-b3e1-45d4-aa1c-a60a40a5f845",
  "961c6b3c-6eed-419a-823e-02c4351db16f",
  "e06e05b5-e652-46a7-a673-220e9fec67ac",
  "22a01e47-6947-4456-b6c9-1831b7c2b5a0",
  "83dfca9e-cab4-48a3-ba19-8fb4ac2c2a17",
  "9733b066-6dcc-405e-aecb-59fd526d190a",
  "1c678206-87e5-4c9e-8fc1-12d4df7c2d4f",
  "a30abdc2-46fe-4146-ab5c-baa1ba2d9d40",
  "d7ffd5bb-d76f-48a5-8ddb-ab3d720785ea",
  "8b0e9150-d88e-46af-9b12-b56c612d1190",
  "0090796b-2cef-4c0c-a3b7-d9543a679135",
  "98d0bfb6-94d2-4fd7-ba52-aca8f3a724fe",
  "44645794-f43a-4954-8349-31d0fa48bf1c",
  "6f5dc1db-ed29-4f56-8835-df2ae851fbac",
  "b0ec9e62-0c49-4c03-b598-c91c86e885c1",
  "9c6e9b78-92c4-43b0-8976-ef1f41209db2",
  "e746736b-07fe-43eb-834c-dc29b8d8c55a",
  "a0398a16-7475-4850-a989-ebc8cf005902",
  "33b58111-3702-4cc2-8bcc-f32b1d5bdcb8",
  "b22ac1df-3d9c-4cb6-80d4-dddc7b8591e1",
  "e0597d85-90f9-42f3-9924-79849021501d",
  "01391f31-426b-47ca-aba0-0272e44e8675",
  "f903486a-6b1c-435c-ae6f-d1f5f5b07fed",
  "16c25458-8f60-42b3-b464-46d64f5a8e16",
  "6f5eb2db-1c6f-46cb-94e9-ec72548b3fd9",
  "2e223389-c111-4728-a051-8b4f6069fcc4",
  "cbf4d2a4-ada1-4085-8e0f-ea8ae88a32e5",
  "6c8e642c-4b48-4fc0-bf20-3a822a6e1dce",
  "d47bbfbd-f7d5-4cc0-a6ae-9c8bfa73fb68",
  "0e7dca2d-8d76-4365-8774-95aa1e268bf7",
  "6fdd76fc-d242-4632-95d3-7c5c9c4cb6c6",
  "c2bf39f0-9467-4d8b-a069-d48fc181bc56",
  "23a5efaa-9f5a-4f15-9397-b8767c82bd30",
  "18e3c06e-a035-4e35-aeeb-fe6b173f22dd",
  "49156873-4d62-4ec8-8342-72476345c0ed",
  "74a03eb8-b632-4274-b8fe-43b220b44da1",
]

DONE-CHARACTERISTIC-UUID := "3450e50b-d1c8-4e6d-ba54-ff3ff0f17b1d"

main-peripheral:
  run-test: test-peripheral

test-peripheral:
  adapter := Adapter
  peripheral := adapter.peripheral

  first-service/LocalService? := null
  UUIDS.do: | uuid |
    service := peripheral.add-service (BleUuid uuid)
    if not first-service:
      first-service = service

  done-characteristic := first-service.add-write-only-characteristic (BleUuid DONE-CHARACTERISTIC-UUID)

  peripheral.deploy
  print "Deployed $UUIDS.size services"

  advertisement := Advertisement
      --name="Test"
      --services=[first-service.uuid]
  peripheral.start-advertise --connection-mode=BLE-CONNECT-MODE-UNDIRECTIONAL advertisement

  done-characteristic.read

  adapter.close

main-central:
  run-test: test-central

test-central:
  done := false

  keep-alive := List 100
  task::
    i := 0
    while not done:
      ba := ByteArray.external 100
      keep-alive[i % keep-alive.size] = ba
      ByteArray 10
      yield

  adapter := Adapter
  central := adapter.central

  first-uuid := BleUuid UUIDS.first
  address := find-device-with-service central first-uuid

  ITERATIONS.repeat: | i/int |
    print "iteration $i"
    remote-device := central.connect address
    print "connected"

    remote-device.discover-services
    services := remote-device.discovered-services
    print "got $services.size services"

    if i == ITERATIONS - 1:
      services.do: | service/RemoteService |
        if service.uuid == first-uuid:
          characteristics := service.discover-characteristics
          characteristics.do: | characteristic/RemoteCharacteristic |
            if characteristic.uuid == (BleUuid DONE-CHARACTERISTIC-UUID):
              print "Sending done"
              characteristic.write "done".to-byte-array

    print "closing device"
    remote-device.close
    print "closed"
    // TODO(florian): why is this sleep necessary?
    sleep --ms=200

  adapter.close
  done = true
