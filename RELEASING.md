# Releasing

The BigWigs packager runs automatically on annotated tag push. Versions
follow `vMAJOR.MINOR.PATCH` (e.g. `v1.0.1`). Tags, the TOC `## Version:`
line, and CHANGELOG entries all use the `v` prefix.

## Pre-flight checklist

1. Add a new entry at the top of `CHANGELOG.md` for the version you're
   about to release.
2. Bump `## Version:` in `MinimapIconBar.toc` to match the tag you'll push.
3. Sanity-check Lua syntax locally:
   ```bash
   for f in *.lua; do luac -p "$f" || break; done
   ```
   And, if you have luacheck installed:
   ```bash
   luacheck *.lua
   ```
4. Commit and push to `main`.

## Cutting a release

```bash
git tag -a v1.0.1 -m "v1.0.1"
git push origin --follow-tags
```

`--follow-tags` pushes the current branch plus any annotated tags
reachable from `HEAD`. If you ever forget to push `main` before tagging,
this still gets the tag's commit onto the remote so the release
workflow's `actions/checkout` step doesn't fail.

The workflow `.github/workflows/release.yml` triggers on the tag push and
runs `BigWigsMods/packager@v2`. It will:

- Read `.pkgmeta`, drop the paths listed under `ignore:`, and package the
  remaining files into a `MinimapIconBar/` folder inside the zip.
- Generate a release zip named `MinimapIconBar-v1.0.1.zip`.
- Upload to CurseForge (via `CF_API_KEY`) and Wago (via
  `WAGO_API_TOKEN`), and create a GitHub Release attached to the tag
  (via `GITHUB_TOKEN`, auto-provided).
- Use `CHANGELOG.md` as the release-notes body (see the `manual-changelog:`
  block in `.pkgmeta`).

## Required GitHub secrets

Configure under Settings → Secrets and variables → Actions:

| Secret | Source |
| --- | --- |
| `CF_API_KEY` | https://legacy.curseforge.com/account/api-tokens |
| `WAGO_API_TOKEN` | https://addons.wago.io/account/apikeys |
| `GITHUB_TOKEN` | (auto-provided; nothing to configure) |

## Project IDs

The CurseForge and Wago projects do not exist yet. Until they do, the
packager simply skips those uploads and still produces the GitHub Release.

Once you create the projects on each platform, edit `MinimapIconBar.toc`,
fill in the IDs, and uncomment these lines:

```
## X-Curse-Project-ID: 123456
## X-Wago-ID: abc123def
```

## Manual packaging (for testing)

To test the packager output without pushing a tag:

```bash
curl -s https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh | bash -s -- -d
```

The `-d` flag skips uploading. Output ends up in `.release/`.
