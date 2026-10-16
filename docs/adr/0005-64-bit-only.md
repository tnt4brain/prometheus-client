# 0005 - 64-bit CPUs only

## Decision
32-bit and ARM targets are out of scope and untested. Tested on Windows x64 and Linux
x86_64.

## Consequences
Int64 fields are assumed to be naturally aligned for CAS; the code does not work around
misaligned 64-bit atomics on 32-bit targets. Revisit only if someone needs it.
