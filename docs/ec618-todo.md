# EC618 port — open work list

Companion to [ec618-roadmap.md](ec618-roadmap.md). This file contains only
work that still needs an explicit Florian action or decision; completed work
belongs in the roadmap, tests, or commit history.

## Florian's queue

- [ ] **First base/envelope release.** The base release workflow
  (`ec618-base-vN`) and consumer path (`EC618_BASE_DIR`) exist, but no base has
  been released yet. Keep it that way until the current review fixes and
  toolchain choice are settled. Each supported base must ultimately have a
  self-contained envelope release; initially the envelopes repository lists
  only the one base actually in use, and adds another only when requested.
