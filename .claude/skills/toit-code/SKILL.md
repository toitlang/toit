---
name: toit-code
description: Explains how to find Toit code (SDK and packages).
---

Toit has a `toit info` command that shows how to find the SDK and package sources.

Typical use:
```
# Gets the SDK's lib path.
toit info sdk --output-format json | jq -r '."lib-path"'
```

```
# List all prefixes (mapping to packages):
toit info pkg --project-root PATH-TO-PROJECT --output-format=json | jq -r '.packages | keys[]'

# Get the path to the http prefix/package:
toit info pkg --project-root PATH-TO-PROJECT --output-format=json | jq -r '.packages.http.path'
```
