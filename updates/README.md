# Signed update feeds

`latest-arm64.json` is the fixed feed for Apple Silicon builds.

Only signed release metadata belongs here. The release ZIP must be publicly available before the
feed is promoted. Generate with `zsh scripts/prepare-update.sh`, verify the release assets, then
copy the generated `dist/latest-arm64.json` without modifying its signed payload.

The private signing key stays in the publisher's login Keychain. Never commit it or an export.
See [publisher instructions](../docs/UPDATES.md).
