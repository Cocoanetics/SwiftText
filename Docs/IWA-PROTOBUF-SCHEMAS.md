# iWork protobuf schemas (not vendored)

SwiftText's Pages (iWork) support is built on **typed wire models** generated
from Apple iWork (Pages/Numbers/Keynote) protobuf archive schemas. The `.proto`
schemas themselves are **not vendored in this repository** — only the Swift wire
models generated from them are committed, under
`Sources/SwiftTextPages/Generated/IWA/`. Those generated encoders/decoders are
SwiftText's own (backed by `ProtobufReader` / `ProtobufWriter`); no protobuf
runtime dependency is introduced.

## Source of the schemas

The schemas are reverse-engineered from the iWork app binaries' embedded
protobuf descriptors and are published by:

- **psobot/keynote-parser** — <https://github.com/psobot/keynote-parser>
  (MIT License). The relevant files live under **`protos/versions/14.4/`**: the
  `.proto` schemas plus `mapping.py`, which maps IWA type numbers → message
  types.

Upstream license: MIT — see the keynote-parser repository for the full license
text and copyright. SwiftText distributes only its own generated Swift derived
from these schemas, not the schema files.

## Coverage

The committed models cover the subset needed for Pages document content — TSP,
TSS, TSD, TSWP, TST, TSK, plus TSCE (calculation engine) and TSCK
(collaboration). References into still-un-modeled archives (charts TSCH, Keynote
KN, Pages-app TP types, and the transient command/undo archives) decode through
a lossless `unknownFields` passthrough, so any document still round-trips
byte-for-byte.

## Regenerating the Swift models

`Scripts/GenerateIWAModels.swift` is an in-house proto2→Swift generator. Because
the schemas are no longer in-tree, fetch them from upstream first:

1. Clone or download the schemas from the repository above and locate the
   `protos/versions/14.4/` directory (the `.proto` files and `mapping.py`),
   e.g. into `/tmp/iwork-protos/`.
2. Run the generator, pointing it at that directory:

   ```sh
   swift Scripts/GenerateIWAModels.swift /tmp/iwork-protos Sources/SwiftTextPages/Generated/IWA
   ```

This rewrites `Sources/SwiftTextPages/Generated/IWA/*.gen.swift` in place.
