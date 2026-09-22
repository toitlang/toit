// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-provider-death-linux as fixture
import .mixed-resume-linux as resume
import .mixed-resume-state as saved

main args/List:
  if args.size != 2: throw "Usage: mixed-authenticated-death-linux.toit INDEX RECORD_FILE"
  state := saved.State (resume.Records args[1]) [saved.S3] "LINUX" --resume-only
  try:
    fixture.run (int.parse args[0]) saved.S3 --pending --state=state
  finally:
    state.close
