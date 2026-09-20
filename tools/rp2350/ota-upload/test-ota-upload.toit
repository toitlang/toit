// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import crypto.sha256 show sha256
import encoding.hex
import expect show *
import host.directory
import host.file
import host.pipe

main args/List:
  if args.size != 2: throw "Usage: test-ota-upload UPLOADER PTY-BRIDGE"
  ["partial-io", "device-error", "bad-ack", "info-timeout"].do: |test|
    with-timeout --ms=12_000: run-case args[0] args[1] test
    print "ota-upload: PASS $test"

run-case uploader/string bridge-path/string test/string:
  temp-dir := directory.mkdtemp "/tmp/toit-ota-upload-"
  path := "$temp-dir/image.bin"
  image := ByteArray (test == "partial-io" ? 9001 : 10): (it * 37 + 11) & 0xff
  file.write-contents image --path=path
  bridge := pipe.fork bridge-path [bridge-path] --create-stdin --create-stdout
  process := null
  try:
    port := bridge.stdout.in.read-line
    process = pipe.fork uploader [uploader, "--port", port, "--no-reboot", path]
        --create-stdout
        --create-stderr
    reader := bridge.stdout.in
    writer := bridge.stdin.out
    expect-equals "TOIT-OTA INFO" reader.read-line
    if test != "info-timeout":
      write-partial writer "unrelated startup log\r\nTOIT-OTA INFO 1 0 0 131072\r\n"
      words := (reader.read-line.split " ")
      expect-structural-equals ["TOIT-OTA", "WRITE"] words[..2]
      expect-equals image.size (int.parse words[2])
      expect-equals (hex.encode (sha256 image)) words[3]
      if test == "device-error":
        write-partial writer "TOIT-OTA ERROR flash-busy\n"
      else:
        write-partial writer "flash worker ready\nTOIT-OTA READY 4096\n"
        offset := 0
        while offset < image.size:
          amount := min 4096 (image.size - offset)
          expect-equals image[offset..offset + amount] (reader.read-bytes amount)
          offset += amount
          write-partial writer "chunk log\nTOIT-OTA ACK $(offset + (test == "bad-ack" ? 1 : 0))\n"
        if test != "bad-ack": write-partial writer "TOIT-OTA COMMITTED\n"
    output := ""
    errors := ""
    // Drain both pipes while waiting, including upload progress output.
    Task.group [
      :: output = read-all process.stdout.in,
      :: errors = read-all process.stderr.in,
    ]
    process.wait
    expect-equals (test == "partial-io" ? 0 : 1) process.exit-code
    if test == "partial-io":
      expect (output.contains "OTA image committed")
      expect (errors.contains "Uploaded $image.size/$image.size bytes")
    else if test == "device-error":
      expect (errors.contains "device rejected OTA request")
      expect (errors.contains "flash-busy")
    else if test == "bad-ack":
      expect (errors.contains "bad ACK offset")
    else:
      expect (errors.contains "timed out")
  finally:
    if process:
      catch: process.kill --hard
      catch: process.wait
      process.stdout.close
      process.stderr.close
    bridge.stdin.close
    catch: bridge.kill --hard
    catch: bridge.wait
    bridge.stdout.close
    file.delete path
    directory.rmdir temp-dir

write-partial writer data/string:
  steps := [1, 2, 5, 3, 11]
  offset := 0
  index := 0
  while offset < data.size:
    end := min data.size (offset + steps[index++ % steps.size])
    writer.write data[offset..end]
    offset = end
    sleep --ms=1

read-all reader -> string:
  output := ""
  while part := reader.read-string: output += part
  return output
