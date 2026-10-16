# 0006 - Retired children, opt-in refcounted Acquire/Release

## Context
Label sets come and go (per connection, per job). The Go client can delete a series
because the GC keeps stale pointers valid. Pascal has no GC.

## Decision
`Labels()` returns a raw pointer that callers cache, so a removed child is "retired": it is
unlinked from the family but freed only when the family is destroyed. For real reclamation
there is an opt-in `Acquire`/`Release` pair: both and the scrape snapshot take a reference
under the family's READ lock, `Remove`/`Clear` run under the WRITE lock, and frees happen
only under the write lock, so a lookup and its claim never straddle a removal. A child ever
returned by `Labels()` stays pinned until `Destroy`.

## Alternatives rejected
- Hazard pointers, epoch-based reclamation, RCU: no FPC-native library exists; too much
  machinery for a metrics library.
- Refcounting as the default: burdens every caller of `Labels()`.

## Consequences
Heavy churn through `Labels()` leaks bounded memory (`RetiredCount`). Verified with
`tests/heap_check.lpr` under heaptrc (use-after-free, double free, leaks) on Windows x64
and Linux x86_64, plus a negative control (`uaf`) proving the check bites.
