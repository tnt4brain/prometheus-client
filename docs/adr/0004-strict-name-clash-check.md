# 0004 - Name clashes are refused as strictly as OpenMetrics needs

## Context
OpenMetrics forbids two metric families whose names or derived sample names overlap. The
classic 0.0.4 format tolerates, for example, counter `foo_total` next to gauge `foo`.

## Decision
`Register` computes the set of names each metric claims (family name, `_total`, `_created`,
`_bucket`, `_count`, `_sum`, `_gcount`, `_gsum`, `_info` as the type allows) and raises
`EArgumentException` for any overlap, even when the classic format would accept it.

## Alternatives rejected
Per-format checking at scrape time: a scraper negotiating OpenMetrics would receive an
invalid document, and the error would surface far from the cause.

## Consequences
Slightly stricter than Prometheus' own text parser. Failing early at registration is cheap.
