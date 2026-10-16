# 0001 - Lock-free values, locked label lookup

## Context
Metrics are updated from hot paths on many threads; a scrape reads them concurrently.

## Decision
Counter, gauge and histogram values are atomics (doubles stored as Int64 bit patterns,
updated by CAS loops). Only the label lookup takes a lock: a read lock for existing
children, a double-checked write lock for the first creation. Label-less families create
their single child in the constructor, so their hot path has no lock at all. Callers are
told to cache the child returned by `Labels(...)`.

## Alternatives rejected
- One mutex per metric: simple, but contended on every update.
- Fully lock-free label map: much more complex, little gain once children are cached.

## Consequences
A scrape is not a perfectly consistent snapshot across bucket, sum and count (same as the
Go client). Opt-in striped counters (`Stripes`) cover the case of one counter hit by many
threads: 8 threads, 16M increments: 2422 ms plain vs 47 ms striped.
