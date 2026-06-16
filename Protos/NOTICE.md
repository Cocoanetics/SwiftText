# Vendored iWork protobuf schemas

These `.proto` files are reverse-engineered Apple iWork (Pages/Numbers/Keynote)
archive schemas, vendored from:

- **psobot/keynote-parser** — <https://github.com/psobot/keynote-parser> (MIT
  License), `protos/versions/14.4/`. The schemas are dumped from the iWork app
  binaries' embedded protobuf descriptors.

They are used here **only as format documentation**: `Scripts/GenerateIWAModels.swift`
reads them to generate Swift wire-model types (`Sources/SwiftTextPages/Generated/IWA/`)
backed by SwiftText's own `ProtobufReader`/`ProtobufWriter`. No protobuf runtime
dependency is introduced — the generated encoders/decoders are SwiftText's own.

Only the subset needed for Pages document structure is vendored (TSP, TSS, TSD,
TSWP, TST, TSK). References into un-vendored archives (TSCE calculation engine,
TSCK collaboration) decode through a lossless `unknownFields` passthrough.

Upstream license: MIT (keynote-parser). See the upstream repository for the full
license text.
