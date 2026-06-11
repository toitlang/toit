---
name: toit-driver
description: How to write a Toit driver for a hardware peripheral and expose it as a service. Use when creating a sensor/peripheral driver package, especially when implementing the `sensors` package interfaces.
---

# Toit Driver Skill
A Toit "driver" is the package that talks to a peripheral (sensor, display,
radio, etc.) over a transport like I2C, SPI, UART, or GPIO. A well-structured
driver package ships in three layers, each useful on its own:

1. A plain class that talks to the device (used directly when the user
   already owns the bus and wants in-process access).
2. A *provider* that wraps the driver and exposes it through a standard
   abstraction package — for sensors, that's [`toit-sensors`](https://github.com/toitware/toit-sensors).
3. A *service container* with a `main` that reads its configuration (assets
   or args) and installs the provider on boot.

This split lets one user link the driver into their own program, while another
just installs the prebuilt service container and consumes the sensor through
the abstraction.

For the underlying RPC mechanics (selectors, indexes, `ServiceClient`,
`ServiceProvider`, lifecycle), see `toit-services`. This skill assumes those
exist and focuses on *driver* conventions on top.

## When to use this skill
Use this when:
- creating a new package for a sensor or peripheral,
- adding service support to an existing low-level driver,
- deciding how to lay out `src/`, `service/`, and `examples/` for a driver
  package,
- choosing between the `sensors` package and a different abstraction.

For general package layout (`package.yaml`, `Makefile`, CI), use `toit-package`
first; this skill layers on top.

## Choosing the abstraction package
Drivers should expose themselves through a *category* package whose interfaces
abstract away the specific chip. For environmental and ranging sensors that's
`sensors` (`github.com/toitware/toit-sensors`), with `TemperatureSensor-v1`,
`HumiditySensor-v1`, `PressureSensor-v1`, `DistanceSensor-v1`.

Other categories may have their own abstraction packages (displays, motors,
batteries, …). Pick the one the rest of the ecosystem already uses; only
define a new category package if nothing fits and several drivers will share
it. A category package is itself just a Toit services API (see
`toit-services`).

A driver may implement *several* category interfaces — the BME280 implements
temperature, humidity, and pressure simultaneously.

## Package layout
```
package.yaml
src/
  driver.toit          // The plain driver class. No service dependency.
  <chip>.toit          // export *  from .driver — re-export public symbols.
  provider.toit        // Provider class + `install` helper.
service/
  main.toit            // Container entrypoint: parse config, call install.
  schema.json          // JSON Schema for the assets/args configuration.
  package.yaml         // Local package referencing `..` so the service can
                       // import the driver.
examples/
  i2c.toit             // Direct (in-process) usage of the driver class.
  package.yaml
README.md
LICENSE
```

The driver class lives in `src/driver.toit`; `src/<chip>.toit` is a thin
re-export so users write `import bme280` and pick up `Driver`,
`I2C-ADDRESS`, etc. without leaking internal file names.

`provider.toit` and `service/` are *only* loaded by people running the
service. A program that just wants `bme280.Driver` directly never pays for
`system.services`, the abstraction package, or the discovery code.

## Layer 1 — the plain driver
A regular class. Takes whatever the bus library hands it (e.g.
`serial.Device`), exposes plain methods, manages its own resources, has no
dependency on `system.services` or the abstraction package.

```toit
import serial.device as serial
import serial.registers as serial

class Driver:
  reg_/serial.Registers
  constructor dev/serial.Device:
    reg_ = dev.registers
    // ... probe, calibrate, configure ...

  read-temperature -> float:
    // ... talk to the chip ...

  close:
    // Put the chip back to a safe/low-power state.
```

Conventions:
- Constants like `I2C-ADDRESS` and `I2C-ADDRESS-ALT` are top-level so users
  can reference them from `examples/i2c.toit`.
- All register addresses are `static` and end with `_` (private).
- `close` puts the device into a safe state but does *not* close the bus —
  that's the caller's job, since the caller owns it.
- Throw on hardware errors (e.g. `"INVALID_CHIP"`, `"BME280: Unable to measure"`).
- Toitdoc public methods (see `toit-toitdoc`).

The example program in `examples/i2c.toit` constructs the bus, creates the
driver, prints a reading, and exits — no provider, no service. This is the
canonical "I just want to read this chip" path.

## Layer 2 — the provider
Wraps the driver and implements one or more category interfaces. The
abstraction package usually exports a generic `Provider` helper that handles
selector registration and reference counting; the driver only supplies the
concrete sensor object plus a list of handlers.

```toit
import gpio
import i2c
import sensors.providers

import .driver as bme280

NAME ::= "toit.io/bme280"
MAJOR ::= 1
MINOR ::= 0

class Sensor_
    implements
      providers.TemperatureSensor-v1
      providers.HumiditySensor-v1
      providers.PressureSensor-v1:
  sda_/gpio.Pin? := null
  scl_/gpio.Pin? := null
  i2c_/i2c.Bus? := null
  device_/i2c.Device? := null
  sensor_/bme280.Driver? := null

  constructor --sda/int --scl/int --address/int:
    succeeded := false
    try:
      sda_ = gpio.Pin sda
      scl_ = gpio.Pin scl
      i2c_ = i2c.Bus --sda=sda_ --scl=scl_
      device_ = i2c_.device address
      sensor_ = bme280.Driver device_
      succeeded = true
    finally:
      if not succeeded: close

  temperature-read -> float?: return sensor_.read-temperature
  humidity-read    -> float : return sensor_.read-humidity
  pressure-read    -> float : return sensor_.read-pressure

  close -> none:
    if sensor_:
      sensor_.close
      sensor_ = null
    if device_:
      device_.close
      device_ = null
    if i2c_:
      i2c_.close
      i2c_ = null
    if scl_:
      scl_.close
      scl_ = null
    if sda_:
      sda_.close
      sda_ = null

install --sda/int --scl/int --address/int -> providers.Provider:
  provider := providers.Provider NAME
      --major=MAJOR
      --minor=MINOR
      --open=:: Sensor_ --sda=sda --scl=scl --address=address
      --close=:: it.close
      --handlers=[
        providers.TemperatureHandler-v1,
        providers.HumidityHandler-v1,
        providers.PressureHandler-v1,
      ]
  provider.install
  return provider
```

Key points:
- Unlike layer 1, the provider *does* own the bus and pins. It opens them in
  the constructor and closes them when the last client disconnects. The
  `--open` / `--close` lambdas in `sensors.providers.Provider` implement
  reference-counted lifecycle on top of `on-opened` / `on-closed` (see
  `toit-services`).
- `NAME` should be a globally unique, human-readable string in
  `vendor.tld/name` form. It's how administrators refer to this provider.
- Bump `MAJOR`/`MINOR` only when the *driver's own* identity changes; the
  selectors picked up from `sensors.providers` already carry their own
  versions.
- `Sensor_` is private (trailing `_`): it's an implementation detail of the
  service.
- Construct cautiously: if any setup step throws, close everything that did
  succeed, so we don't leak GPIOs or bus handles.

If the abstraction package you target does *not* provide a generic
`Provider` helper, write your own subclass of `services.ServiceProvider`
following the pattern in `toit-services`.

## Layer 3 — the service container
A small `main` that reads configuration and calls `install`. Two sources of
config, in priority order:

1. Command-line `args` — useful for `jag run service/main.toit -- 22 21`.
2. Container *assets* under the `configuration` or `artemis.defines` key —
   how Artemis-managed devices configure containers in production.

```toit
import encoding.tison
import system.assets
import bme280.provider
import bme280 show I2C-ADDRESS I2C-ADDRESS-ALT

install-from-args_ args/List:
  if args.size != 3: throw "Usage: main <scl> <sda> <address>"
  scl := int.parse args[0]
  sda := int.parse args[1]
  address := address-from-string_ args[2]
  provider.install --scl=scl --sda=sda --address=address

install-from-assets_ configuration/Map:
  scl := configuration.get "scl"
  if scl is not int: throw "SCL must be an integer."
  sda := configuration.get "sda"
  if sda is not int: throw "SDA must be an integer."
  address := configuration.get "address" or I2C-ADDRESS
  if address is string and address.to-ascii-lower == "alt": address = I2C-ADDRESS-ALT
  provider.install --scl=scl --sda=sda --address=address

main args:
  if args.size != 0:
    install-from-args_ args
    return
  decoded := assets.decode
  ["configuration", "artemis.defines"].do: | key/string |
    bytes := decoded.get key
    if bytes:
      install-from-assets_ (tison.decode bytes)
      return
  throw "No configuration found."
```

Pair the container with a JSON Schema in `service/schema.json` describing the
expected asset shape — Artemis (and humans) use it to validate configs:

```json
{
  "$schema": "http://json-schema.org/draft-2020-12/schema",
  "title": "BME280 Configuration",
  "type": "object",
  "required": ["scl", "sda"],
  "properties": {
    "scl": { "type": "integer", "description": "GPIO pin for I2C SCL." },
    "sda": { "type": "integer", "description": "GPIO pin for I2C SDA." },
    "address": { "description": "I2C address. Omit for default, 'alt' for alternate, or an integer." }
  }
}
```

`service/package.yaml` simply depends on the parent package via `path: ..`,
so the container can import the driver during local development:

```yaml
dependencies:
  bme280:
    path: ..
```

## Examples
Ship at least two examples:
- `examples/i2c.toit` — direct in-process use of the driver class. No
  service involved. Demonstrates the cheapest way to read the chip.
- (optional) An end-to-end example that spawns the provider and a client in
  the same process for testing, mirroring `toit-sensors`'s `multi.toit`.
  Useful when documenting how the service layer behaves.

`examples/package.yaml` references the parent package by path:

```yaml
dependencies:
  bme280:
    path: ..
```

## Checklist for a new driver
- [ ] `package.yaml` with name, description, sdk constraint, and any deps
      (typically just `sensors`).
- [ ] `src/driver.toit` with a plain class and well-named constants. No
      `system.services` import.
- [ ] `src/<chip>.toit` re-exporting the driver.
- [ ] `src/provider.toit` with a private sensor wrapper and an `install`
      function returning the provider.
- [ ] `service/main.toit` parsing args *and* assets, plus
      `service/schema.json` documenting the asset shape and
      `service/package.yaml` depending on `..`.
- [ ] `examples/i2c.toit` (or equivalent transport) showing direct use.
- [ ] README, LICENSE, CI, Makefile per `toit-package`.
- [ ] Toitdoc on every public symbol per `toit-toitdoc`.
