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

package toitdoc

import (
	"strings"

	"github.com/toitware/toit.git/toitlsp/lsp/toit"
)

func IsPrivate(name string) bool {
	return strings.HasSuffix(name, "_") || strings.HasSuffix(name, "_=")
}

type StringSet map[string]struct{}

func NewStringSet(strs ...string) StringSet {
	res := StringSet{}
	for _, s := range strs {
		res[s] = struct{}{}
	}
	return res
}

func (s *StringSet) Add(strs ...string) {
	if *s == nil {
		*s = StringSet{}
	}

	for _, str := range strs {
		(*s)[str] = struct{}{}
	}
}

func (s *StringSet) AddFrom(set StringSet) {
	if *s == nil {
		*s = StringSet{}
	}

	for str := range set {
		(*s)[str] = struct{}{}
	}
}

func (s StringSet) Remove(strs ...string) {
	if s == nil {
		return
	}

	for _, str := range strs {
		delete(s, str)
	}
}

func (s StringSet) Contains(str string) bool {
	if s == nil {
		return false
	}

	_, exists := s[str]
	return exists
}

func (s StringSet) Values() []string {
	var res []string
	if s == nil {
		return res
	}

	for k := range s {
		res = append(res, k)
	}
	return res
}

type ToitIDSet map[toit.ID]struct{}

func NewToitIDSet(ids ...toit.ID) ToitIDSet {
	res := ToitIDSet{}
	for _, id := range ids {
		res[id] = struct{}{}
	}
	return res
}

func (s *ToitIDSet) Add(ids ...toit.ID) {
	if *s == nil {
		*s = ToitIDSet{}
	}

	for _, id := range ids {
		(*s)[id] = struct{}{}
	}
}

func (s ToitIDSet) Remove(ids ...toit.ID) {
	if s == nil {
		return
	}

	for _, str := range ids {
		delete(s, str)
	}
}

func (s ToitIDSet) Contains(id toit.ID) bool {
	if s == nil {
		return false
	}

	_, exists := s[id]
	return exists
}

func (s ToitIDSet) Values() []toit.ID {
	var res []toit.ID
	if s == nil {
		return res
	}

	for k := range s {
		res = append(res, k)
	}
	return res
}
