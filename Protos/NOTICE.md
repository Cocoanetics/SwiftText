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

The subset needed for Pages document content is vendored: TSP, TSS, TSD, TSWP,
TST, TSK, plus TSCE (calculation engine) and TSCK (collaboration). References into
still-un-vendored archives (charts TSCH, Keynote KN, Pages-app TP types, and the
transient command/undo archives) decode through a lossless `unknownFields`
passthrough, so any document still round-trips byte-for-byte.

Upstream license: MIT (keynote-parser). See the upstream repository for the full
license text.
