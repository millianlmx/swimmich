# JPEG XL fixtures

Real JPEG XL files used by `immich_stub_jpeg_xl.py` and `Tests/JpegXLTests.swift`.
They are copied unmodified (not re-encoded) from the JPEG XL conformance suite:

- Source: https://github.com/libjxl/conformance
- Commit: `b1d0f990b03e57bf6d137c365cd5dc8b470b9191`
- Raw URL: `https://raw.githubusercontent.com/libjxl/conformance/<commit>/testcases/<case>/input.jxl`
- Licence: BSD-3-Clause, see `LICENSE` (Copyright (c) the JPEG XL Project Authors)

| File | Case | Bytes | Pixels | SHA-256 |
|---|---|---|---|---|
| `thumbnail-200x200.jxl` | `grayscale` | 1069 | 200x200 | `78fbbba852e99946d187dcf0bcbd7fb0e7c22be2f0852523aaae6ed91e7e3c39` |
| `preview-1024x631.jxl` | `bicycles` | 73501 | 1024x631 | `8ef03ccccb45bdb5f3d37c9a4c392f745e3e4ad7f4ffc2cbc1e1ba68487a75a6` |
| `original-1600x1096.jxl` | `patches` (ISOBMFF container) | 66562 | 1600x1096 | `3d8d3847ba40844b1d829366065261f34cc4b4acc3d9006342c64127c1052a3e` |

The "truncated" fixture is not a file: the stub and the unit tests use the two signature bytes `ff 0a`
(the first two bytes of the preview). Nothing in the app encodes JPEG XL.
