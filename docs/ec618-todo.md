# EC618 open work

- Download the pinned published base by default during envelope production.
  Keep local base rebuilding an explicit development option; never select an
  arbitrary latest base because slot OTA requires an exact base identity.
- Coordinate the portable watchdog SDK API with package publication and the
  overlapping API in SDK PR #3241. Publish the native 1-Wire package support.
- Resolve intermittent native ESP32-S3 I2S receive failures. Qualify sustained
  streaming, startup behavior and timing margins with an independent observer.
- Qualify GPIO output-low startup with an opposing pull-up.
- Implement gap-free UART TX across staging buffers at high baud rates if
  required; this needs hardware-chained DMA rather than software rearming.
- Integrate orderly firmware shutdown, including application termination and
  service draining. Qualify cellular teardown and both embedded OTA paths.
- Integrate and qualify Artemis delta OTA, including interruption/recovery and
  pin-trigger scheduling on EC618 wake inputs.
- Finish partition/anchor validation and image-tool error handling review.
  Keep data-partition migration and base OTA outside the initial update API.
- Deploy the public partition schema from website PR #287.
- Qualify toolchain changes against vendor library ABI and runtime behavior.
  Do not substitute a host rebuild for a published base with the same version.
- Remove unnecessary LuatOS startup wrappers after qualifying the replacement.
  Preserve the published base's export contract.
- Establish boot-time FOTA/LittleFS writes and RF-calibration storage needs
  before reducing vendor flash reservations.
