---
name: toit-package
description: Helps with creating Toit packages. Use when creating a new package or deciding where to place files.
---

# Toit Package Skill
This skill provides instructions on how to create and structure a new [Toit package](https://docs.toit.io/language/package). The Toit Package Manager (TPM) uses `jag pkg` commands. Packages are distributed decentralized via Git repositories.

## When to use this skill
Use this when
- creating a new Toit package.
- extracting a package from an existing Toit project.
- deciding where to place files in a Toit package.

## Directory Structure
A Toit package has to have:
- `package.yaml`: The package specification file at the root.
- `src/`: Directory containing the public Toit source code.

It should have:
- `README.md`: Package description and usage.
- `LICENSE`: The package license.
- `examples/`: Directory containing examples. (less important).

If it has tests, it should have:
- `tests/`: Directory containing tests.

It typically has:
- `Makefile` & `CMakeLists.txt`: Build system files for running tests.
- `.github/workflows/`: CI/CD pipelines for testing and publishing.

## Creating a New Package
When asked to create a new Toit package, generate the standard boilerplate files by copying them from this skill's `resources/` directory.

### `package.yaml`
Create a `package.yaml` file at the root of the project to allow the Toit Package Manager to recognize it.
```yaml
name: <package_name>
description: <short description>
environment:
  sdk: <sdk_version>
```

Use `toit version` to find the current SDK version.

### Internal references
If there is a testing and/or examples folder, use `toit pkg install --local ..` to refer to the
package. This requires the `package.yaml` to be present.

Example:
```
cd tests
toit pkg install --local ..
```

### Testing
Tests should go into the `tests/` directory and should end with `-test.toit`.

### Makefile and CMake
It is common, but not required to use Makefile and CMake in Toit packages.

#### Build Files (`Makefile` and `CMakeLists.txt`)
Copy the standard build boilerplate files to the root of the package:
- Copy `resources/Makefile` to `Makefile`.
- Copy `resources/CMakeLists.txt` to `CMakeLists.txt` and replace `<package_name>` with the actual name of the package.

#### Testing (`tests/CMakeLists.txt`)
- Copy `resources/tests/CMakeLists.txt` to `tests/CMakeLists.txt` to discover and run tests.

### GitHub Actions CI/CD
Establish CI/CD pipelines in `.github/workflows/`.
- Copy `resources/.github/workflows/publish.yml` to `.github/workflows/publish.yml`.
- Copy `resources/.github/dependabot.yml` to `.github/dependabot.yml`.

If the package has tests, also copy:
- Copy `resources/.github/workflows/ci.yml` to `.github/workflows/ci.yml`. The workflow extracts the oldest supported SDK version from `package.yaml` automatically.

### Best Practices
- **README.md**: Include a title, a short description, and an example of usage.
- **License**: Include a `LICENSE` file.
- **Documentation**: Use Toitdoc comments on public code.
- **.gitignore**: Ignore `.packages/` and `build/`. (See `resources/.gitignore`).

### License
Typically, Toit packages should be MIT (or similar).
Tests and examples are often BSD0.

Files should start with:
```
// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.
```

Users can, of course, replace the copyright with their name and/or choose other
licenses.
If there are different license files (like with BSD0), don't forget to update
the "found in the LICENSE file" with the correct name of the file.

### Verify the package
Use `toit pkg describe` to see whether the name, description and license are correctly recognized.

If there are tests, make sure `make test` works.
