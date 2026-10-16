# 0002 - Exemplar storage uses a per-family lock

## Context
Exemplars (OpenMetrics only) hold a label set, a value and a timestamp: more than one atomic
word can carry.

## Decision
One critical section per family guards the exemplar slots. Only exemplar calls and
OpenMetrics scrapes take it; plain `Inc`/`Observe` and the classic scrape never do. A scrape
copies the slots under the lock and writes after releasing it. Labels are validated and
pre-formatted before anything is recorded, so a rejected exemplar changes nothing.

## Alternatives rejected
- CAS-swapped immutable exemplar objects: cannot be freed without a GC, leak per call.
- Seqlock: unsafe with reference-counted strings.

## Consequences
Exemplar-heavy code can contend on that lock; the common paths are unaffected.
