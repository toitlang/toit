// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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

test tester/GoldTester:
  tester.gold "10-init" [
    ["pkg", "init"],
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

  TODO(florian): continue here.
  The original test wasn't great, as it just checked whether the registry was populated.
  We should do better: check that the repository isn't updated once we have a hash checked out.
  That requires us to update the git registry from the test-setup.

  If we have a package.lock, then the `pkg install` should not need to contact the registry.
  If we have a package.yaml, then the `pkg install` should only contact the server if we don't have
    a cached version of the registry.
  Probably a good idea to add a http-connection-counter to the gold tester to ensure that we don't
  contact the server.
