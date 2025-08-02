// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import host.directory
import host.file
import host.pipe

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

/*
		regPath := filepath.Join(pt.dir, "registry_git_pkgs")
		pt.GoldToit("test-1", [][]string{
			{"// Add git registry"},
			{"pkg", "registry", "add", "test-reg", regPath},
		})

		deleteRegCache(t, pt, regPath)

		pt.GoldToit("test-autosync-list", [][]string{
			{"pkg", "list"},
		})

		deleteRegCache(t, pt, regPath)
		pt.GoldToit("test-autosync-install", [][]string{
			{"pkg", "install"},
		})

		deleteRegCache(t, pt, regPath)
		pt.GoldToit("test-autosync-install2", [][]string{
			{"pkg", "install", "pkg1"},
		})

		deleteRegCache(t, pt, regPath)

		pt.noAutoSync = true
		pt.GoldToit("test-no-autosync", [][]string{
			{"// Without sync there shouldn't be any packages"},
			{"pkg", "list"},
			{"// Install should, however, still work"},
			{"pkg", "install"},
			{"exec", "test.toit"},
			{"// Error is expected now."},
			{"pkg", "install", "pkg1"},
		})
    */

class GitRegistry:
  path/string
  original-hash_/string? := null

  constructor .path:
    original-hash_ = run ["rev-parse", "HEAD"]

  run args/List -> string:
    full-args := ["git", "-C", path] + args
    result := pipe.backticks full-args
    pipe.run-program ["git", "-C", path, "update-server-info"]
    return result.trim

  current-hash -> string:
    return run ["rev-parse", "HEAD"]

  reset-hash hash/string -> none:
    run ["reset", "--hard", hash]

  reset -> none:
    reset-hash original-hash_

  commit -> none:
    run ["commit", "-am", "Update registry"]

  modify -> none:
    // Just add a new pkg.
    pkg4-bytes := file.read-contents "$path/pkg4/4.9.9/desc.yaml"
    pkg4-contents := pkg4-bytes.to-string
    new-pkg := pkg4-contents.replace --all "pkg4" "pkg-new"
    directory.mkdir "$path/pkg-new"
    file.write-contents --path="$path/pkg-new/desc.yaml" new-pkg
    run ["add", "pkg-new"]
    run ["commit", "-am", "Add pkg-new to registry"]

test tester/GoldTester:
  tester.gold "10-init" [
    ["pkg", "init"],
    ["pkg", "registry", "list"],
    ["pkg", "list"],
  ]

  tester.delete-registry-cache "git-pkgs"
  tester.gold "20-auto-sync" [
    ["pkg", "list"],
  ]

  tester.delete-registry-cache "git-pkgs"
  tester.gold "30-auto-sync-install" [
    ["pkg", "install"],
  ]

  tester.delete-registry-cache "git-pkgs"
  tester.gold "40-auto-sync-install2" [
    ["pkg", "install", "pkg1"],
  ]

  tester.delete-registry-cache "git-pkgs"

  registry := GitRegistry (tester.git-registry-path "git-pkgs")

  registry.modify

  tester.gold "50-auto-sync" [
    ["// Without auto-sync, we shouldn't see the new package."],
    ["pkg", "--no-auto-sync", "list"],
    ["// With auto-sync, we should see the new package."],
    ["pkg", "list"],
  ]

  tester.delete-registry-cache "git-pkgs"
  registry.reset

  // Download the registry again.
  tester.run [["pkg", "list"]]
  registry.modify

  directory.rmdir --force --recursive "$tester.working-dir/.packages"
  tester.gold "60-install-doesnt-sync" [
    ["// We don't see the new package yet."],
    ["pkg", "--no-auto-sync", "list"],
    ["// Since we have a package.lock, we don't need to sync."],
    ["pkg", "install"],
    ["// We still don't see the new package."],
    ["pkg", "--no-auto-sync", "list"],
    ["// After an implicit sync, we see it."],
    ["pkg", "list"],
  ]
  expect (file.is-directory "$tester.working-dir/.packages")

  tester.delete-registry-cache "git-pkgs"
  directory.rmdir --force --recursive "$tester.working-dir/.packages"
  tester.gold "70-install-doesnt-sync2" [
    ["// The registry isn't downloaded yet, but install should work"],
    ["pkg", "install"],
  ]
  // Check that the registry wasn't downloaded.
  expect-not (tester.has-registry-cache "git-pkgs")

  2.repeat: | i/int |
    // Download the registry.
    tester.run [["pkg", "list"]]
    registry-cache-path := tester.registry-cache-path "git-pkgs"
    expect (file.is-directory registry-cache-path)
    file.write-contents --path="$registry-cache-path/dummy" "foobar"
    if i == 0:
      tester.gold "80-sync-clear-cache" [
        ["pkg", "sync", "--clear-cache"],
        ["// Should simply list the packages."],
        ["pkg", "list"],
      ]
    else:
      tester.gold "90-registry-sync-clear-cache" [
        ["pkg", "registry", "sync", "--clear-cache"],
        ["// Should simply list the packages."],
        ["pkg", "list"],
      ]
    expect-not (file.is-file "$registry-cache-path/dummy")

  // TODO(florian): continue here.
  // The original test wasn't great, as it just checked whether the registry was populated.
  // We should do better: check that the repository isn't updated once we have a hash checked out.
  // That requires us to update the git registry from the test-setup.

  // If we have a package.lock, then the `pkg install` should not need to contact the registry.
  // If we have a package.yaml, then the `pkg install` should only contact the server if we don't have
  //   a cached version of the registry.
  // Probably a good idea to add a http-connection-counter to the gold tester to ensure that we don't
  // contact the server.
