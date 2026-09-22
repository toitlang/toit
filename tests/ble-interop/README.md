# Optional interoperability tests (Bumble)

Independent software peer for the experimental host, using
[Bumble](https://github.com/google/bumble) 0.0.234. Not a default build or
test dependency.

```sh
python3 -m venv /tmp/ble-bumble-venv
/tmp/ble-bumble-venv/bin/pip install -r tests/ble-interop/requirements.txt
/tmp/ble-bumble-venv/bin/python tests/ble-interop/run.py \
  --toit-run build/host/sdk/lib/toit/bin/toit.run --output build/ble-bumble-suite
```

`run.py` runs 61 process-pipe cases (ATT client and server, MTU 23/247/517,
long reads and prepared-write transactions, subscriptions, indications, Secure
Connections pairing, descriptors, advertising lifecycle) with Bumble and a Toit
fixture connected over an HCI pipe, no hardware. It writes one log per case and
`results.json`. `*-test.py` files are negative controls for the runner.

`radio-*.py` drive a real adapter against a board (`--help` lists the required
adapter, peer, supervisor and relay arguments); they need the Linux setup in
[docs/ble/hardware.md](../../docs/ble/hardware.md). The GitHub workflow
`ble-interop.yml` runs the software suite on manual dispatch.
