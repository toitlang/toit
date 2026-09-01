# EC618 AP project (PLAT side)

This is the Toit user project that the EC618 SDK's xmake build compiles and
links into the base image. The build selects it through the SDK's
`PROJECT_DIR` interface.

Base stability matters here: slots link directly against the published
`base.elf`, and the base ID prevents them from running against another base.
