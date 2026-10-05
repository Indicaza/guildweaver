# Guildweaver Releases

Guildweaver is distributed through GitHub Release artifacts built by CI.

## Channels

- `edge` — replaced automatically after every merge to `main`
- `beta` — replaced when an alpha, beta, or release-candidate `v*` tag is pushed
- `stable` — replaced when a stable `v*` tag is pushed

Tagged releases are also preserved under their version tag.

## Artifacts

Each release contains:

- `Guildweaver.zip`
- `Guildweaver.zip.sha256`
- `release.json`

The ZIP contains a top-level `Guildweaver` directory suitable for `Interface/AddOns` and its own `release.json` marker.

Pull requests run the packaging job without publishing a release. This keeps packaging failures inside the normal CI review loop.
