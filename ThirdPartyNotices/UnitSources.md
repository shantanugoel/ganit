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

- `acre` (ac): dimension `length^2`, transform `ratio 316160658/78125`, exact, source `nist-sp811-2008`
- `ampere` (A): dimension `current`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `ampere-hour` (Ah): dimension `time·current`, transform `ratio 3600`, exact, source `bipm-si-9-v4.01`
- `atmosphere` (atm): dimension `length^-1·mass·time^-2`, transform `ratio 101325`, exact, source `nist-sp811-2008`
- `bar` (bar): dimension `length^-1·mass·time^-2`, transform `ratio 100000`, exact, source `bipm-si-9-v4.01`
- `bit` (bit): dimension `data`, transform `ratio 1`, exact, source `iec-80000-13-2025`
- `bit-per-second` (bps): dimension `time^-1·data`, transform `ratio 1`, exact, source `iec-80000-13-2025`
- `byte` (B): dimension `data`, transform `ratio 8`, exact, source `iec-80000-13-2025`
- `calorie` (cal): dimension `length^2·mass·time^-2`, transform `ratio 523/125`, exact, source `nist-sp811-2008`
- `coulomb` (C): dimension `time·current`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `cup` (cup): dimension `length^3`, transform `ratio 473176473/2000000000000`, exact, source `nist-sp811-2008`
- `degree` (°): dimension `angle`, transform `ratio ≈0.017453292519943295`, approximate, source `bipm-si-9-v4.01`
- `degree-celsius` (°C): dimension `temperature`, transform `affine scale 1, offset 27315e-2`, exact, source `bipm-si-9-v4.01`
- `degree-fahrenheit` (°F): dimension `temperature`, transform `affine scale 5/9, offset 45967/180`, exact, source `nist-sp811-2008`
- `electronvolt` (eV): dimension `length^2·mass·time^-2`, transform `ratio 1602176634e-28`, exact, source `bipm-si-9-v4.01`
- `farad` (F): dimension `length^-2·mass^-1·time^4·current^2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `fluid-ounce` (floz): dimension `length^3`, transform `ratio 473176473/16000000000000`, exact, source `nist-sp811-2008`
- `foot` (ft): dimension `length`, transform `ratio 381/1250`, exact, source `nist-sp811-2008`
- `gallon` (gal): dimension `length^3`, transform `ratio 473176473/125000000000`, exact, source `nist-sp811-2008`
- `gram` (g): dimension `mass`, transform `ratio 1/1000`, exact, source `bipm-si-9-v4.01`
- `hectare` (ha): dimension `length^2`, transform `ratio 10000`, exact, source `bipm-si-9-v4.01`
- `henry` (H): dimension `length^2·mass·time^-2·current^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `hertz` (Hz): dimension `time^-1`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `horsepower` (hp): dimension `length^2·mass·time^-3`, transform `ratio 37284993579113511/50000000000000`, exact, source `nist-sp811-2008`
- `hour` (h): dimension `time`, transform `ratio 3600`, exact, source `bipm-si-9-v4.01`
- `inch` (in): dimension `length`, transform `ratio 127/5000`, exact, source `nist-sp811-2008`
- `joule` (J): dimension `length^2·mass·time^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `kelvin` (K): dimension `temperature`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `kilogram` (kg): dimension `mass`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `knot` (kn): dimension `length·time^-1`, transform `ratio 463/900`, exact, source `nist-sp811-2008`
- `liter` (L): dimension `length^3`, transform `ratio 1/1000`, exact, source `bipm-si-9-v4.01`
- `meter` (m): dimension `length`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `mile` (mi): dimension `length`, transform `ratio 201168/125`, exact, source `nist-sp811-2008`
- `mile-per-hour` (mph): dimension `length·time^-1`, transform `ratio 1397/3125`, exact, source `nist-sp811-2008`
- `minute` (min): dimension `time`, transform `ratio 60`, exact, source `bipm-si-9-v4.01`
- `nautical-mile` (nmi): dimension `length`, transform `ratio 1852`, exact, source `nist-sp811-2008`
- `newton` (N): dimension `length·mass·time^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `ohm` (Ω): dimension `length^2·mass·time^-3·current^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `ounce` (oz): dimension `mass`, transform `ratio 45359237/1600000000`, exact, source `nist-sp811-2008`
- `pascal` (Pa): dimension `length^-1·mass·time^-2`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `pint` (pt): dimension `length^3`, transform `ratio 473176473/1000000000000`, exact, source `nist-sp811-2008`
- `pound` (lb): dimension `mass`, transform `ratio 45359237/100000000`, exact, source `nist-sp811-2008`
- `pound-per-square-inch` (psi): dimension `length^-1·mass·time^-2`, transform `ratio 8896443230521/1290320000`, exact, source `nist-sp811-2008`
- `quart` (qt): dimension `length^3`, transform `ratio 473176473/500000000000`, exact, source `nist-sp811-2008`
- `radian` (rad): dimension `angle`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `second` (s): dimension `time`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `stone` (st): dimension `mass`, transform `ratio 317514659/50000000`, exact, source `nist-sp811-2008`
- `tablespoon` (tbsp): dimension `length^3`, transform `ratio 473176473/32000000000000`, exact, source `nist-sp811-2008`
- `teaspoon` (tsp): dimension `length^3`, transform `ratio 157725491/32000000000000`, exact, source `nist-sp811-2008`
- `tonne` (t): dimension `mass`, transform `ratio 1000`, exact, source `bipm-si-9-v4.01`
- `volt` (V): dimension `length^2·mass·time^-3·current^-1`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `watt` (W): dimension `length^2·mass·time^-3`, transform `ratio 1`, exact, source `bipm-si-9-v4.01`
- `watt-hour` (Wh): dimension `length^2·mass·time^-2`, transform `ratio 3600`, exact, source `bipm-si-9-v4.01`
- `yard` (yd): dimension `length`, transform `ratio 1143/1250`, exact, source `nist-sp811-2008`

This file is generated from `UnitCatalog` metadata. Do not edit it manually.
