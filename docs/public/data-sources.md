# Data sources and attribution

| Data | Source | Terms | Notice |
| --- | --- | --- | --- |
| Currency exchange rates | European Central Bank euro foreign exchange reference rates. Source: ECB statistics. | Free reuse with the source quoted and the statistics unmodified | [CurrencyDataSources.md](../../ThirdPartyNotices/CurrencyDataSources.md) |
| Units and prefixes | Independently encoded from the BIPM SI Brochure, IEC 80000-13, and NIST SP 811, among others | Factual definitions; see each source | [UnitSources.md](../../ThirdPartyNotices/UnitSources.md) |
| Time zones | The IANA time-zone database as shipped with macOS | Public domain | — |
| Currency codes | ISO 4217 active codes and minor units | Code list facts | — |
| Arbitrary-precision integers | [attaswift/BigInt](https://github.com/attaswift/BigInt) 6.0.1 | MIT License | [BigInt-LICENSE.md](../../ThirdPartyNotices/BigInt-LICENSE.md) |

Exchange rates are indicative and not for transactions. Rates between two
non-euro currencies are calculated by Ganit from ECB reference rates and are
not ECB statistics. The notices ship inside the app, and every currency answer
shows its source in the answer details.
