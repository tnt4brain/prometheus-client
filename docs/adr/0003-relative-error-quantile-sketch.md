# 0003 - DDSketch-style sketch for summary quantiles

## Context
Summaries with quantiles need a sliding-window estimate, and `Observe` must stay lock-free.

## Decision
A log-bucket sketch with a bounded relative error (default 1%), values 1e-9..1e9, a ring of
5 time slots covering 600 s. Counters live in lazily allocated pages of 64 buckets published
by pointer CAS. `_sum`/`_count` stay cumulative; an empty window yields NaN. Estimates are
rounded to 6 significant digits so golden files match across platforms.

## Alternatives rejected
- CKMS (mutex, large) and t-digest (mutex, large).
- Sample ring: window by count, not time; fuzzy.
- Per-quantile error targets as in Go's `Objectives`: one relative error serves all
  quantiles and the cost does not depend on the quantile, so they would save nothing.

## Consequences
An increment racing with a slot reset may be lost at window boundaries (documented).
