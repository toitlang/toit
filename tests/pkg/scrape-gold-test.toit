// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import host.directory

import .gold-tester

main args:
  with-gold-tester args: test it

/*
	t.Run("Scrape", func(t *tedi.T, pt PkgTest) {
		dirs, err := ioutil.ReadDir(filepath.Join(pt.dir, "pkg_dirs"))
		assert.NoError(t, err)
		for _, entry := range dirs {
			if !entry.IsDir() {
				continue
			}
			test := entry.Name()
			if test == "gold" {
				continue
			}
			t.Run(test, func() {
				p := filepath.Join("pkg_dirs", test)
				pt.GoldToit(test, [][]string{
					{"pkg", "describe", p},
					{"pkg", "describe", "--verbose", p},
				})
			})
		}
		t.Run("local_path", func() {
			p := filepath.Join("local_path")
			pt.GoldToit("local_path", [][]string{
				{"pkg", "describe", p},
				{"pkg", "describe", "--verbose", p},
				{"pkg", "describe", "--allow-local-deps", p},
				{"pkg", "describe", "--disallow-local-deps", p},
				{"pkg", "describe", "--allow-local-deps", "--disallow-local-deps", p},
			})
		})
	})

*/
test tester/GoldTester:
  directory-stream := directory.DirectoryStream "$tester.working-dir/packages"

  while name := directory-stream.next:
    test-path := "$tester.working-dir/packages/$name"
    expect (file.is-directory test-path)

    tester.gold "test-$name" [
      ["pkg", "describe", test-path],
      ["pkg", "describe", "--verbose", test-path],
    ]
