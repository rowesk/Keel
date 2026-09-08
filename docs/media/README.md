# Release media

See [third-party notices](../../THIRD_PARTY_NOTICES.md) for image credits and permissions.

| File | Use |
| --- | --- |
| `icon.png` | Byte-for-byte copy of the current PNG icon master |
| `home-light.png` | Current Home view with its actual embedded address field |
| `hero.png` | Home capture framed on a warm paper background for the README |
| `queue-light.png` | Current expanded Home queue in light appearance |
| `queue-dark.png` | The same queue in dark appearance |
| `social-preview.png` | 1280 × 640 GitHub share card |

The screenshots use fictional example.com links. They contain no browser profile, private History, or signed-in website. They are offscreen renders of the app's actual views, not evidence that a complete installed-app workflow was exercised. The Home scene is the current bundled Como image.

## Regenerate the captures

From the repository root:

```sh
KEEL_RELEASE_MEDIA_DIRECTORY=/tmp/keel-release-media \
KEEL_ALLOW_FOREGROUND_TESTS=0 KEEL_RECORD_SNAPSHOTS=0 \
swift test --filter KeelReleaseMediaCaptureTests
```

Review the exported PNGs before copying `home-light.png`, `queue-light.png`, and `queue-dark.png` here. The capture never creates a window or reads the installed app's data. It does not modify snapshot baselines.

`Scripts/render-release-media.py` generates the hero frame and share card from those assets. It requires Python Playwright and its Chromium browser, runs headlessly, and blocks external requests. These are media-production dependencies only; Keel has no dependency on them.

Inspect every regenerated output and update the asset credits if their source changes. GitHub's README selects the dark queue image with a `picture` source and retains a light fallback. The local preview checks do not replace testing GitHub's renderer after publication.
