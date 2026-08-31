# swift-redact-kit

Destroy the sensitive parts of images, PDFs and text — verifiably.

```swift
import RedactKit

let outcome = try ImageRedactor.redact(
    imageAt: scan, options: .init(types: [.card, .email]),
    to: output, dryRun: false)
// outcome.findings == ["card": ["••••1111"], "email": ["••••e.com"]]
```

## The one rule

**Redaction is destruction, not decoration.** Every mode guarantees the
sensitive content is unrecoverable from the output, and every guarantee
is verified by a test that attempts the recovery:

| Mode | Guarantee | Verified by |
|---|---|---|
| Images | matched lines painted with **opaque** boxes (never blur — blur is reversible), copy re-encoded with **no metadata** | re-OCR the output; re-read the metadata |
| EXIF strip | GPS, camera, serials, owner fields, capture date gone; orientation **baked into pixels** first | re-read via ImageIO; width/height swap on rotated sources |
| PDFs | matched pages **rasterized** — a black box over live text is the classic failed redaction and is never shipped | re-extract the text layer |
| Text | matches become `[REDACTED-CARD]`-style markers | exact-string pins |

The price is stated, not hidden: rasterized PDF pages lose selectable
text (untouched pages keep theirs), and rotated PDF pages are covered
whole rather than maybe-misplaced.

## What it finds

Every detector is a candidate pattern **plus a verification** — looking
the part is not grounds for destruction:

- **card** — 12–19 digits passing the Luhn check and per-scheme length
  rules ([swift-credit-card-validator](https://github.com/arraypress/swift-credit-card-validator))
- **mrz** — ICAO 9303 TD3 passport lines, validated by the real 7-3-1
  check digits (pinned against Doc 9303's own worked example)
- **iban** — mod-97 verified (ISO 13616)
- **email**, **ssn** (dashed form only, deliberately)
- **phone** — heuristic, therefore **opt-in**: needs international form
  or visible formatting, so order numbers stay unredacted
- **secret** — API keys and tokens via
  [swift-secret-scanner](https://github.com/arraypress/swift-secret-scanner)'s
  named catalogue (medium severity and up; the cry-wolf generic rules stay off)
- **custom** — caller-supplied regular expressions, which outrank the
  built-ins

Overlaps resolve to one finding per span. Findings carry **masked**
values only (`••••1111`) — the kit never stores what it destroys.

## Measured

Apple-silicon laptop, release build, via the `redact` CLI: a 13-file
tree (11 × 1200×800 JPEGs, a 3-page PDF, a text file) redacted in
**1.32 s**; ten OCR'd images alone ≈ **8 images/s**; the 3-page PDF with
one rasterized page **0.099 s**.

## Honest limits

- OCR finds what OCR can read: skewed, tiny or stylised text can hide a
  value from the detector. `dryRun` first on anything that matters.
- PDFKit drops outlines on save (an Apple limitation); document
  attributes are stripped deliberately.
- Text files must be UTF-8.

## Requirements

macOS 26+, Swift 6. Frameworks: Vision, ImageIO, CoreImage, PDFKit —
Apple's stack only.

## License

MIT — see [LICENSE](LICENSE).
