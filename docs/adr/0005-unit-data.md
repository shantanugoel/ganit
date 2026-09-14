# ADR 0005: Curate a minimal unit catalog from authoritative sources

- Status: Accepted
- Date: 2026-09-14

## Context

Ganit needs exact dimensional algebra, compound units, prefixes, and separate affine conversions. Foundation `Measurement` does not define the complete runtime type system or parsing data required by the engine. UCUM is comprehensive, but its June 2024 license prohibits modifying the work or creating derivative works; copying and adapting its tables would add obligations and uncertainty that are unnecessary for the P0 catalog.

NIST publishes SI guidance and conversion factors, identifies exact factors, and permits distribution of public site information unless material is separately marked; it requests appropriate credit. A small reviewed catalog is easier to audit than a broad imported dataset.

## Decision

- Implement Ganit's own dimension vectors, ratio factors, affine transforms, canonical unit identifiers, and parser aliases.
- Seed only the P0 units required by the product scenarios and named dimensions in `PLAN.md`.
- Derive SI definitions and exact conversion factors from NIST publications and primary standards referenced by NIST. Record, beside each catalog entry, its source URL/publication revision, exact-or-approximate status, canonical symbol, dimension, and factor or affine transform.
- Curate parser aliases as Ganit-owned locale data. Do not copy UCUM tables, codes, descriptions, or comments.
- Use Foundation `Measurement` only at presentation or differential-test boundaries where its semantics match; it is not the dimensional core or source of truth.
- Generate a human-readable attribution file from the same catalog metadata and validate that every production entry has source and license metadata.

Any future adoption of UCUM data requires a separate legal and technical ADR, unmodified licensed data, complete attribution, and proof that Ganit does not create a prohibited derivative standard.

## Consequences

- The initial catalog is deliberately narrower but fully reviewable and explainable.
- Adding a unit is a versioned data change with conversion and dimensional property tests.
- Exact factors stay rational/decimal and do not enter `Double`.
- Ganit must maintain its own conservative aliases and cannot claim UCUM conformance.

## References

- [NIST Guide to the SI, Appendix B: Conversion Factors](https://www.nist.gov/pml/special-publication-811/nist-guide-si-appendix-b-conversion-factors)
- [NIST copyrights and disclaimers](https://www.nist.gov/copyrights-disclaimers)
- [UCUM license, version 1.1](https://ucum.org/license)
