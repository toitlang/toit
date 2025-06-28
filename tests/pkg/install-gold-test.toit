// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import expect show *
import host.directory
import host.file
import .gold-tester

main args:
  with-gold-tester args: test it

/*
		pt.GoldToit("install", [][]string{
			{"pkg", "registry", "add", "--local", "test-reg", "registry"},
			{"pkg", "install", "foo"},
			{"pkg", "install", "bar"},
			{"pkg", "install", "--local", "target"},
			{"exec", "main.toit"},
		})

		fooVersion := "1.2.3"
		fooPath := pt.computePathInCache("foo_git", fooVersion, "")
		info, err := os.Stat(fooPath)
		require.NoError(t, err)
		require.True(t, info.IsDir())
		err = os.RemoveAll(fooPath)
		require.NoError(t, err)

		barVersion := "2.0.1"
		barPath := pt.computePathInCache("bar_git", barVersion, "")
		info, err = os.Stat(barPath)
		require.NoError(t, err)
		require.True(t, info.IsDir())
		err = os.RemoveAll(barPath)
		require.NoError(t, err)

		pt.GoldToit("fail", [][]string{
			{"exec", "main.toit"},
		})
		pt.GoldToit("download", [][]string{
			{"pkg", "download"},
		})
		pt.GoldToit("exec after download", [][]string{
			{"exec", "main.toit"},
		})

		// Ensure that the directories are back.
		info, err = os.Stat(fooPath)
		require.NoError(t, err)
		require.True(t, info.IsDir())

		info, err = os.Stat(barPath)
		require.NoError(t, err)
		require.True(t, info.IsDir())
*/

test tester/GoldTester:
  tester.gold "10-install" [
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["pkg", "install", "foo"],
    ["pkg", "install", "bar"],
    ["pkg", "install", "--local", "target"],
    ["exec", "main.toit"],
  ]

  contents := file.read-contents "$tester.working-dir/.packages/contents.json"
  mapping/Map := json.decode contents

  foo-url/string? := null
  bar-url/string? := null
  mapping.do --keys: | key |
    if key.ends-with "pkg/foo": foo-url = key
    if key.ends-with "pkg/bar": bar-url = key

  foo-version := "1.2.3"
  foo-rel-path := mapping[foo-url][foo-version]
  foo-path := "$tester.working-dir/.packages/$foo-rel-path"
  expect (file.is-directory foo-path)
  directory.rmdir --recursive foo-path

  bar-version := "2.0.1"
  bar-rel-path := mapping[bar-url][bar-version]
  bar-path := "$tester.working-dir/.packages/$bar-rel-path"
  expect (file.is-directory bar-path)
  directory.rmdir --recursive bar-path

  tester.gold "20-fail" [
    ["exec", "main.toit"],
  ]

  tester.gold "30-install" [
    ["pkg", "install"],
  ]

  // Ensure that the directories are back.
  // We don't guarantee that the directories are the same as before.
  contents = file.read-contents "$tester.working-dir/.packages/contents.json"
  mapping = json.decode contents

  mapping.do --keys: | key |
    if key.ends-with "pkg/foo": foo-url = key
    if key.ends-with "pkg/bar": bar-url = key

  foo-rel-path = mapping[foo-url][foo-version]
  foo-path = "$tester.working-dir/.packages/$foo-rel-path"
  expect (file.is-directory foo-path)

  bar-rel-path = mapping[bar-url][bar-version]
  bar-path = "$tester.working-dir/.packages/$bar-rel-path"
  expect (file.is-directory bar-path)
