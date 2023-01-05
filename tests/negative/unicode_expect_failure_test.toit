import expect show *

main:
  expect_equals """
    ╒════╤════════╕
    │ no   header │
    ╘════╧════════╛
    """
    """
    ┌────┬────────┐
    │ no   header │
    └────┴────────┘
    """
