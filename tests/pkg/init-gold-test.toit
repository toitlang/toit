// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fs
import host.directory
import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

/*
		lockPath := filepath.Join(pt.dir, "package.lock")
		pkgPath := filepath.Join(pt.dir, "package.yaml")

		assert.NoFileExists(t, pkgPath)
		assert.NoFileExists(t, lockPath)

		pt.GoldToit("init1", [][]string{
			{"pkg", "init"},
		})

		assert.FileExists(t, pkgPath)
		assert.FileExists(t, lockPath)

		err := os.Remove(pkgPath)
		assert.NoError(t, err)
		err = os.Remove(lockPath)
		assert.NoError(t, err)

		pt.GoldToit("already_init", [][]string{
			{"pkg", "init"},
			{"pkg", "init"},
		})

		assert.FileExists(t, pkgPath)
		assert.FileExists(t, lockPath)

		// Make sure the generated lock file can be used.
		pt.GoldToit("app-install", [][]string{
			{"exec", "main.toit"},
			{"pkg", "install", "--local", "pkg"},
			{"exec", "main2.toit"},
		})

		other := filepath.Join(pt.dir, "other")
		err = os.Mkdir(other, 0700)
		assert.NoError(t, err)

		pt.GoldToit("initOther", [][]string{
			{"pkg", "init", "--project-root=" + other},
		})

		assert.FileExists(t, filepath.Join(other, "package.yaml"))
		assert.FileExists(t, filepath.Join(other, "package.lock"))

*/

test tester/GoldTester:
  lock-path := fs.join tester.working-dir "package.lock"
  pkg-path := fs.join tester.working-dir "package.yaml"

  expect-not (file.is-file lock-path)
  expect-not (file.is-file pkg-path)

  tester.gold "10-init" [
    ["pkg", "init"],
  ]

  expect (file.is-file pkg-path)
  expect (file.is-file lock-path)

  file.delete pkg-path
  file.delete lock-path

  tester.gold "20-already-init" [
    ["pkg", "init"],
    ["pkg", "init"],
  ]

  expect (file.is-file pkg-path)
  expect (file.is-file lock-path)

  // Make sure the generated lock file can be used.
  tester.gold "30-app-install" [
    ["exec", "main.toit"],
    ["pkg", "install", "--local", "pkg"],
    ["exec", "main2.toit"],
  ]

  other := fs.join tester.working-dir "other"
  directory.mkdir other

  tester.gold "40-init-other" [
    ["pkg", "init", "--project-root", other],
  ]

  expect (file.is-file (fs.join other "package.yaml"))
  expect (file.is-file (fs.join other "package.lock"))
