// Copyright (C) 2021 Toitware ApS. All rights reserved.

// This import fails as the package is dotting out of its package.
import ...main_test
// Even trying to import a file from our own package isn't allowed.
import ..src.target

export *
