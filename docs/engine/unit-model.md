# Unit and dimension model

`GanitEngine` models dimensions independently from unit names. A `Dimension`
is a bounded exponent vector over length, mass, time, temperature, angle, and
data. Area, volume, speed, acceleration, force, pressure, energy, power, and
data rate are derived vectors. Angle remains distinct from a plain scalar so
the evaluator cannot accidentally add radians to an unrelated number.

`UnitDefinition` has a stable identifier, display symbol, dimension, prefix
policy, and one of two transforms to its dimension's canonical unit:

- A ratio transform uses `canonical = value × scale`.
- An affine transform uses `canonical = value × scale + offset`.

Scale and prefix factors must be strictly positive. They use `NumericValue`,
so exact rational and decimal definitions remain exact and binary floating
point is used only when a definition explicitly carries an approximate value.

`UnitAlgebra` applies prefixes, builds products, quotients, and integer powers,
and cancels matching factors. Compound algebra accepts ratio units only.
Affine units remain standalone because multiplying an absolute temperature
would apply its offset incorrectly. Conversion may cross ratio units or affine
units with the same dimension.

`QuantityValue.Kind` records whether a quantity is relative or absolute.
Temperature quantities default to absolute, and arithmetic and conversion
preserve this role even when an absolute Celsius value is converted to a
ratio-based Kelvin unit. Callers creating temperature differences mark them
relative explicitly.
Relative temperature conversion applies scale only and never an affine offset.

Quantity addition and subtraction first validate dimensions and convert the
right operand to the left operand's unit. Absolute quantities are rejected for
both operations until a distinct temperature-difference result policy is
provided; this prevents physically invalid operations such as adding two
Celsius readings or laundering one through Kelvin. Multiplication and division
derive compound dimensions and reject absolute operands.

Dimension and unit-factor exponent magnitudes are capped at 64, compound units
at 32 distinct factors, identifiers at 128 UTF-8 bytes, and symbols at 64 UTF-8
bytes. Exceeding a cap produces a typed resource or definition error
rather than an overflow or an unbounded compound representation.

The model intentionally contains no built-in catalog entries. The reviewed
catalog, aliases, and source/license metadata are a separate versioned data
task so conversion mechanics are testable without coupling them to parser
vocabulary.
