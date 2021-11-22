// Copyright (C) 2021 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

package uri

import "github.com/sourcegraph/go-lsp"

type Set map[lsp.DocumentURI]struct{}

func NewSet(strs ...lsp.DocumentURI) Set {
	res := Set{}
	for _, s := range strs {
		res[s] = struct{}{}
	}
	return res
}

func (s *Set) UnmarshalYAML(unmarshal func(interface{}) error) error {
	l := []lsp.DocumentURI{}

	if err := unmarshal(&l); err != nil {
		return err
	}

	s.Add(l...)
	return nil
}

func (s *Set) Add(uris ...lsp.DocumentURI) {
	if *s == nil {
		*s = Set{}
	}

	for _, uri := range uris {
		(*s)[uri] = struct{}{}
	}
}

func (s Set) Remove(strs ...lsp.DocumentURI) {
	if s == nil {
		return
	}

	for _, str := range strs {
		delete(s, str)
	}
}

func (s Set) Contains(str lsp.DocumentURI) bool {
	if s == nil {
		return false
	}

	_, exists := s[str]
	return exists
}

func (s Set) Values() []lsp.DocumentURI {
	var res []lsp.DocumentURI
	if s == nil {
		return res
	}

	for k := range s {
		res = append(res, k)
	}
	return res
}
