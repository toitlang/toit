// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  try: null
  finally: | in_throw/string exception |

  try: null
  finally: | in_throw=true exception=null |
  
  try: null
  finally: | --in_throw exception |

  try: null
  finally: | exception |

  try: null
  finally: it

  try: null
  finally: | a b c |

  try: null
  finally: | this super |

  try: null
  finally: | [a] [b] |

  try: null
  finally: | a [b] |

  try: null
  finally: | .field other |

  try: null
  finally: | same same |

  try: null
  finally: | _ exception |
    _

  try: null
  finally: | in_throw _ |
    _
