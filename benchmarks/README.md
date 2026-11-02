# Benchmarks

Benchmarks for native code, and the scripts used for working on it:

- `run.py` compares native executables to interpreted ones.
- `compare_tests.py` checks that tests behave the same as native code.
- `fuzz/run.py` compares generated programs as bytecodes and as native code.

The `gold` folder has what the benchmarks print. They are also tests: see
`tests/native`.


| Files | Origin | License |
|---|---|---|
| fib.toit | Written here | - |
| richards.toit | Port of V8's Richards | BSD-3-Clause, header in the file |
| deltablue.toit | Port of V8's DeltaBlue | GPL, part of GNU Smalltalk, header in the file |
| splay.toit | Port of Octane's Splay | BSD-3-Clause, header in the file |
| navierstokes.toit | Port of Octane's NavierStokes (solver by Oliver Hunt) | MIT-style, header in the file |
| raytrace.toit, crypto.toit | Written here, inspired by Octane; no shared code | - |
| fannkuch, spectralnorm, mandelbrot, binarytrees, nbody, knucleotide | Written here from Benchmarks Game task descriptions | - |
| everything else | Written here | - |

The original Octane license is in LICENSE-octane. Octane is at
https://github.com/chromium/octane (archived).
