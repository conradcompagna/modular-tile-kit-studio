# Contributing

Start with the [development commands](docs/DEVELOPMENT.md) and the
[architecture map](docs/ARCHITECTURE.md). Open a focused branch/PR describing the
user-visible behavior, affected contracts, validation and external resources needed.
Keep research claims tied to published evidence, and label synthetic fixtures clearly.

Use feature boundaries and explicit imports; keep maintained first-party files below
2,000 lines (including comments and blank lines), with smaller modules where a
responsibility fits naturally. Generated browser bundles and vendored code have a
different lifecycle; do not split/minify evidence or dependencies to game this limit.
Historical logs/data are split only with ordered, verifiable reconstruction metadata.

Run relevant checks before submitting. Preserve public entrypoints, Unicode offsets,
serialization formats and dependency notices. Include a regression fixture when a
change affects those contracts; keep unrelated formatting out of behavior changes.
Do not commit credentials, account records, private corpora, model weights or generated
caches. Repository checks do not deploy the application or imply a production release.

See [security reporting](SECURITY.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
No new project-wide license is granted by this cleanup; existing component terms
remain in force, and broader licensing requires the owner's decision.
