# Architecture decision records

Short records of the design decisions behind prometheus_fpc: what was decided, what was
rejected, and what it costs. Format: context, decision, alternatives, consequences.
Decisions are made by the maintainer; the code is written with AI assistance (see the
project README, "Provenance"). Do not reverse a decision here without a new ADR.

| # | Decision |
|---|----------|
| [0001](0001-lock-free-values-locked-lookup.md) | Lock-free values, locked label lookup |
| [0002](0002-exemplars-use-a-lock.md) | Exemplar storage uses a per-family lock |
