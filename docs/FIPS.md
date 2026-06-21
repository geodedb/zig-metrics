# FIPS-140-3 Status — metrics

**REQ-ID:** REQ-FIPS-EXEMPT-001 — this library is crypto-free and is therefore
trivially exempt from the workspace FIPS-140-3 routing requirement per
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5.

**Mode:** This library contains no `std.crypto`, non-default `std.hash`, or
`std.Random` call sites (verified 2026-06-20). Nothing to annotate or route. It
is **exempt** from the workspace FIPS-140-3 routing requirement (see `fips`
package spec `docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5). When a
consumer builds with `-Dfips=true`, this library is unaffected: it adds no
`-Dfips` flag and changes no behavior.

## Exempt call sites

None. This library performs no cryptographic, hashing, or random-number
operations. The only textual matches for "shard" in the source are lock /
sharding comments, not crypto.

## Guard test

`src/root.zig` contains a guard test that fails if a `std.crypto` or
`std.Random` use is ever introduced into `root.zig`, forcing re-evaluation of
this document. (The search needles are assembled from string fragments so the
test does not match itself.)

## zlint allow-list

There are no sites to allow-list. Adding any `std.crypto` / `std.hash` /
`std.Random` use to this library REQUIRES adding both an inline
`// fips-exempt: non-security — <reason>` annotation (or routing it through the
`crypto_backend` seam if it is a security primitive) and a row here.
