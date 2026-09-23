/// Dimensionless multipliers people write after an amount: `11.5 million`.
enum ScaleWord {
  static let digits: [String: String] = [
    "thousand": "1000", "thousands": "1000", "k": "1000",
    "lakh": "100000", "lakhs": "100000", "lac": "100000", "lacs": "100000",
    "l": "100000",
    "million": "1000000", "millions": "1000000", "mn": "1000000", "mil": "1000000",
    "m": "1000000",
    "crore": "10000000", "crores": "10000000", "cr": "10000000",
    "billion": "1000000000", "billions": "1000000000", "bn": "1000000000",
    "trillion": "1000000000000", "trillions": "1000000000000",
    "dozen": "12", "dozens": "12",
  ]
}
