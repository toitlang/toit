// Copyright (C) 2026 Toit contributors.
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

/**
EC618 (Air780E) related functionality.
*/

/**
Enters deep sleep for the specified $duration and does not return.
Exiting deep sleep causes the device to start over from main.
*/
deep-sleep duration/Duration -> none:
  __deep-sleep__ duration.in-ms
