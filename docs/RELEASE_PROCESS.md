# Release process

Gyrus uses semantic versions without rewriting published history.

## Release channels

- GitHub preview tag: `v1.4.0-beta.1`
- macOS app version: `1.4.0`
- Chrome extension version: `1.4.0`
- Human-readable extension version: `1.4.0 beta 1`
- Backend health version: `1.4.0-beta.1`

Apple and Chromium require numeric application versions. The release script
therefore keeps the technical app version separate from the Git tag and preview
channel. A later preview such as `v1.4.0-beta.2` can reuse app version `1.4.0`
and receives a new build number.

Preview releases are created with GitHub's prerelease flag. They do not replace
the latest stable release link.

## Local workspace

Release builds and artifacts live outside the checkout by default:

```text
~/Builds/Gyrus/
  DerivedData/
  releases/
    v1.4.0-beta.1/
      Gyrus.dmg
      Gyrus-Saver-v1.4.0-beta.1.zip
      SHA256SUMS.txt
      release-notes.md
```

Set `GYRUS_BUILD_ROOT`, `GYRUS_DERIVED_DATA_PATH`, or
`GYRUS_ARTIFACT_DIR` to override these locations.

## Repository hygiene

The tracked `.gitignore` contains only patterns that apply to every contributor:
build products, runtimes, caches, databases, secrets, and release archives.

Personal tools belong in the global Git ignore:

```text
~/.config/git/ignore
```

Private paths that are specific to one Gyrus checkout belong in:

```text
.git/info/exclude
```

Neither file is committed. Before every public push, inspect:

```sh
git status --short
git diff --cached --name-status
git ls-files | rg '(^|/)(\.agents|\.claude|\.codex|\.gstack)(/|$)'
```

## Prepare and publish

1. Add a matching section to `CHANGELOG.md`.
2. Start from a clean `main` branch.
3. Run a complete dry run:

   ```sh
   ./release.sh 1.4.0-beta.1
   ```

4. Inspect the app and artifacts under `~/Builds/Gyrus/releases/`.
5. Keep the prepared version changes in the release PR, or restore them after
   inspection.
6. After that PR is merged, start from clean `main` and publish:

   ```sh
   ./release.sh 1.4.0-beta.1 --publish
   ```

The preparation path increments the build number and places every version
change in the pull request. The publish path verifies that clean `main` already
contains those exact values, reruns backend and Swift tests, builds and signs
the app, launches bundled Chromium as a smoke test, packages the DMG and
extension, creates checksums, pushes only the tag, and creates the GitHub
prerelease. It never bypasses branch protection with a post-merge commit.
