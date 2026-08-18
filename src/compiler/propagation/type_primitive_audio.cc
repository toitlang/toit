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

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(audio, MODULE_AUDIO)

TYPE_PRIMITIVE_SMI(pcm_convert)
TYPE_PRIMITIVE_SMI(pcm_extract)
TYPE_PRIMITIVE_SMI(pcm_mix)
TYPE_PRIMITIVE_FLOAT(dot_product)
TYPE_PRIMITIVE_FLOAT(reduce)
TYPE_PRIMITIVE_SMI(framed_energy)
TYPE_PRIMITIVE_SMI(normalized_correlation)
TYPE_PRIMITIVE_SMI(goertzel)
TYPE_PRIMITIVE_SMI(real_fft_q15)
TYPE_PRIMITIVE_SMI(gcc_phat_delay)
TYPE_PRIMITIVE_SMI(fir)
TYPE_PRIMITIVE_SMI(biquad)
TYPE_PRIMITIVE_SMI(resample_linear)

}  // namespace toit::compiler
}  // namespace toit
