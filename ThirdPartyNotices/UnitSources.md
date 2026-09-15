# Unit data sources

Ganit independently encodes the factual unit definitions listed below.
It does not claim conformance with any external unit standard.

## BIPM SI Brochure, 9th edition

- Revision: version 4.01, June 2026
- Source: https://doi.org/10.59161/AUEZ1291
- Terms: Creative Commons Attribution 4.0 International (https://creativecommons.org/licenses/by/4.0/)
- Notice: Definitions were independently encoded from the SI Brochure. BIPM endorsement is not implied.

## IEC 80000-13:2025

- Revision: edition 2.0, 2025-02-11
- Source: https://webstore.iec.ch/en/publication/87379
- Terms: IEC copyrighted standard; factual definitions only (https://www.iec.ch/copyright)
- Notice: Ganit independently encodes bit, byte, and binary-prefix facts. No IEC standard text or tables are redistributed.

## NIST Special Publication 811

- Revision: second printing, November 2008
- Source: https://doi.org/10.6028/NIST.SP.811e2008
- Terms: United States public information (https://www.nist.gov/copyrights-disclaimers)
- Notice: NIST is credited as the source of exact non-SI conversion facts. NIST endorsement is not implied.

## Catalog entries

- `bit` (bit): dimension `data`, transform `ratio 1`, exact, source `iec-80000-13-2025`
- `byte` (B): dimension `data`, transform `ratio 8`, exact, source `iec-80000-13-2025`
- `degree` (°): dimension `angle`, transform `ratio ≈0.017453292519943295`, approximate, source `bipm-si-9-v4.01`
- `degree-celsius` (°C): dimension `temperature`, transform `affine scale 1, offset 27315e-2`, exact, source `bipm-si-9-v4.01`
- `degree-fahrenheit` (°F): dimension `temperature`, transform `affine scale 5/9, offset 45967/180`, exact, source `nist-sp811-2008`
- `foot` (ft): dimension `length`, transform `ratio 381/1250`, exact, source `nist-sp811-2008`
- `gram` (g): dimension `mass`, transform `ratio 1/1000`, exact, source `bipm-si-9-v4.01`
- `hour` (h): dimension `time`, transform `ratio 3600`, exact, source `bipm-si-9-v4.01`
- `inch` (in): dimension `length`, transform `ratio 127/5000`, exact, source `nist-sp811-2008`
- `joule` (J): dimension `length^2·mass·time^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `kelvin` (K): dimension `temperature`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `kilogram` (kg): dimension `mass`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `liter` (L): dimension `length^3`, transform `ratio 1/1000`, exact, source `bipm-si-9-v4.01`
- `meter` (m): dimension `length`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `mile` (mi): dimension `length`, transform `ratio 201168/125`, exact, source `nist-sp811-2008`
- `minute` (min): dimension `time`, transform `ratio 60`, exact, source `bipm-si-9-v4.01`
- `newton` (N): dimension `length·mass·time^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `pascal` (Pa): dimension `length^-1·mass·time^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `radian` (rad): dimension `angle`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `second` (s): dimension `time`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `watt` (W): dimension `length^2·mass·time^-3`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`

This file is generated from `UnitCatalog` metadata. Do not edit it manually.
