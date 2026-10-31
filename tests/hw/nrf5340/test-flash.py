# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Validate ordinary two-core programming inputs and failure handling without hardware."""
from pathlib import Path
import hashlib
import io
import json
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/nrf5340"))
import flash


def image(network=False):
    return struct.pack("<II", 0x21001000 if network else 0x20001000,
                       0x01000011 if network else 0x11) + bytes(248)


class FlashTests(unittest.TestCase):
    def bundle(self, path, mutate=None, extra=None, link=False):
        files = {"application.bin": image(), "network.bin": image(True)}
        manifest = {"format": 1, "target": "nrf5340"}
        for role, address in (("application", 0), ("network", 0x01000000)):
            name = role + ".bin"
            manifest[role] = {"file": name, "address": address, "size": len(files[name]),
                              "sha256": hashlib.sha256(files[name]).hexdigest()}
        if mutate:
            mutate(manifest)
        files["manifest.json"] = json.dumps(manifest).encode()
        with tarfile.open(path, "w") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                if link and name == "application.bin":
                    member.type = tarfile.SYMTYPE
                    member.linkname = "/outside/file"
                    member.size = 0
                archive.addfile(member, io.BytesIO(data))
            if extra:
                archive.addfile(tarfile.TarInfo(extra), io.BytesIO())

    def test_bundle_round_trip_and_metadata_rejections(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "firmware.tar"
            self.bundle(path)
            self.assertEqual(flash.load_bundle(path), (image(), image(True)))
            mutations = [lambda m: m.update(target="other-board"), lambda m: m.update(format=True),
                         lambda m: m.update(application=[])]
            for field, value in (("address", 0), ("file", "../outside.bin"), ("size", 42),
                                 ("sha256", "0" * 64), ("address", True)):
                mutations.append(lambda m, field=field, value=value: m["network"].update({field: value}))
            for mutate in mutations:
                self.bundle(path, mutate)
                with self.assertRaises(ValueError):
                    flash.load_bundle(path)

    def test_bundle_rejects_links_duplicates_extra_files_and_damage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "firmware.tar"
            for extra in ("../outside.bin", "network.bin", "unexpected"):
                self.bundle(path, extra=extra)
                with self.assertRaises(ValueError):
                    flash.load_bundle(path)
            self.bundle(path, link=True)
            with self.assertRaises(ValueError):
                flash.load_bundle(path)
            self.bundle(path)
            data = bytearray(path.read_bytes())
            data[512 + 100] ^= 1  # Corrupt a payload while preserving its tar header.
            path.write_bytes(data)
            with self.assertRaises(ValueError):
                flash.load_bundle(path)
            path.write_bytes(data[:100])
            with self.assertRaises(ValueError):
                flash.load_bundle(path)

    def test_vectors_and_partition_boundaries(self):
        for network, limit in ((False, flash.FIRMWARE_LIMIT), (True, 0x40000)):
            good = image(network)
            flash.validate_image(good, network=network)
            flash.validate_image(good + bytes(limit - len(good)), network=network)
            for bad in (b"", good[:7], good + bytes(limit + 1 - len(good)), image(not network)):
                with self.assertRaises(ValueError):
                    flash.validate_image(bad, network=network)
            stack, entry = struct.unpack_from("<II", good)
            for sp, pc in ((stack + 1, entry), (stack, entry & ~1), (stack, entry + limit),
                           (stack, (entry & 0xff000000) | 1)):
                with self.assertRaises(ValueError):
                    flash.validate_image(struct.pack("<II", sp, pc) + good[8:], network=network)

    def test_staged_bytes_and_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            application = bytearray(image())
            network = bytearray(image(True))
            app_path, net_path = flash.stage_images(out, application, network)
            application[:] = bytes(len(application))
            network[:] = bytes(len(network))
            self.assertEqual(app_path.read_bytes(), image())
            self.assertEqual(net_path.read_bytes(), image(True))
            for record in json.loads((out / "images.json").read_text()):
                data = (out / record["file"]).read_bytes()
                self.assertEqual(record["size"], len(data))
                self.assertEqual(record["sha256"], hashlib.sha256(data).hexdigest())

    def test_program_order_and_no_recovery(self):
        commands = flash.programming_commands(Path("/tmp/app.bin"), 250, Path("/tmp/net.bin")).split("; ")
        probe = commands.index("nrf53.cpunet arp_examine")
        net_write = commands.index("flash write_image erase {/tmp/net.bin} 0x01000000 bin")
        net_verify = commands.index("verify_image {/tmp/net.bin} 0x01000000 bin")
        app_write = commands.index("flash write_image erase {/tmp/app.bin} 0 bin")
        app_verify = commands.index("verify_image {/tmp/app.bin} 0 bin")
        self.assertLess(probe, net_write)
        self.assertLess(net_write, net_verify)
        self.assertLess(net_verify, app_write)
        self.assertIn("nrf53.cpuapp mww 0x50005614 1", commands[net_verify:app_write])
        self.assertLess(app_write, app_verify)
        self.assertEqual(commands[app_verify + 1:], ["reset run", "shutdown"])
        self.assertFalse(any("recover" in c or "erase_all" in c or "uicr" in c for c in commands))
        ordinary = flash.programming_commands(Path("/tmp/app.bin"), 250)
        self.assertNotIn("cpunet", ordinary)
        self.assertNotIn("0x01000000", ordinary)

    def test_tcl_quoting(self):
        self.assertEqual(flash.tcl_path(Path('/tmp/a $x [command].bin')), '{/tmp/a $x [command].bin}')
        for path in ("/tmp/a{b", "/tmp/a}b", "/tmp/a\\b", "/tmp/a\nb", "/tmp/a\rb"):
            with self.assertRaises(ValueError):
                flash.programming_commands(Path(path), 250)

    def invoke(self, tmp, network):
        out = Path(tmp)
        (out / "app.bin").write_bytes(image())
        (out / "net.bin").write_bytes(network)
        return ["flash.py", str(out / "app.bin"), "--network-image", str(out / "net.bin"),
                "--serial", "/dev/not-a-real-port", "--log-dir", str(out / "logs"), "--seconds", "0"]

    def test_invalid_network_never_opens_hardware(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv = self.invoke(tmp, image())
            with patch.object(sys, "argv", argv), patch.object(flash.serial, "Serial") as serial:
                with self.assertRaises(SystemExit) as error:
                    flash.main()
                self.assertEqual(error.exception.code, 2)
                serial.assert_not_called()

    def test_failure_closes_port_without_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv = self.invoke(tmp, image(True))
            port = Mock()
            failure = subprocess.CalledProcessError(1, ["openocd"])
            with patch.object(sys, "argv", argv), patch.object(flash.serial, "Serial", return_value=port), \
                    patch.object(flash.subprocess, "run", side_effect=failure) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    flash.main()
                run.assert_called_once()
                port.close.assert_called_once()
                command = run.call_args.args[0]
                self.assertIn("set TOIT_NETWORK_CORE 1; set TOIT_FLASH_NETWORK 1", command)
                self.assertNotIn("set TOIT_RECOVERY 1", command)
                self.assertTrue((Path(tmp) / "logs/images.json").exists())

    @unittest.skipUnless((ROOT / ".cache/nrf5340/openocd/src/openocd").is_file(), "Pinned OpenOCD not built")
    def test_tcl_aborts_before_restart(self):
        # Run the actual OpenOCD interpreter, replacing all hardware commands
        # with recording procedures. No adapter or target is configured.
        setup = '''
proc mark {name args} {
  set record "$name [join $args { }]"
  echo $record
  if {$record eq $::failure} {error INJECTED}
}
proc adapter {args} {mark ADAPTER {*}$args}
proc reset {args} {mark RESET {*}$args}
proc nrf53.cpuapp {args} {mark APP {*}$args}
proc nrf53.cpunet {args} {mark NET {*}$args}
proc targets {args} {mark TARGET {*}$args}
proc flash {args} {mark FLASH {*}$args}
proc verify_image {args} {mark VERIFY {*}$args}
'''
        app_write = "FLASH write_image erase /unused/app.bin 0 bin"
        failures = ["NET arp_examine",
                    "FLASH write_image erase /unused/net.bin 0x01000000 bin",
                    "VERIFY /unused/net.bin 0x01000000 bin", app_write,
                    "VERIFY /unused/app.bin 0 bin", "no failure"]
        command = flash.programming_commands(Path("/unused/app.bin"), 250, Path("/unused/net.bin"))
        for index, failure in enumerate(failures):
            with self.subTest(failure=failure):
                run = subprocess.run([str(ROOT / ".cache/nrf5340/openocd/src/openocd"),
                                      "-c", "set failure {" + failure + "}; " + setup,
                                      "-c", command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, timeout=10)
                if failure == "no failure":
                    self.assertEqual(run.returncode, 0, run.stdout)
                    self.assertEqual(run.stdout.count("RESET run"), 1)
                else:
                    self.assertNotEqual(run.returncode, 0, run.stdout)
                    self.assertIn("INJECTED", run.stdout)
                    self.assertNotIn("RESET run", run.stdout)
                    if index < 3:
                        self.assertNotIn(app_write, run.stdout)


if __name__ == "__main__":
    unittest.main()
