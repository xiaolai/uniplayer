# GitHub releases and Homebrew

`.github/workflows/release.yml` releases a stable tag on GitHub's hosted
`xcode-27` runner. It uses Xcode 27.1 and the macOS 27 SDK, builds both CPU
slices, and calls the existing `scripts/release-macos.py` signing/notarization
pipeline. It does not require the workspace's `.env` or `scripts/release.sh`.

## One-time configuration

In `xiaolai/uniplayer` → Settings → Secrets and variables → Actions, configure:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of a password-protected `.p12` containing the Developer ID Application certificate **and its private key** |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting that `.p12` |
| `APPLE_ID` | Apple ID authorized for notarization |
| `APP_SPECIFIC_PASSWORD` | Its app-specific password, not the account password |
| `TEAM_ID` | Apple Developer team matching the signing certificate |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token for `xiaolai/homebrew-tap`, with **Contents: read and write** |

Export the signing identity through Keychain Access. To upload its Base64 without
printing it, use your own exported file:

```sh
base64 -i /path/to/DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo xiaolai/uniplayer
```

The other secrets can be entered through Settings or the interactive
`gh secret set NAME --repo xiaolai/uniplayer` prompt. Do not commit them.
The workflow's automatic `GITHUB_TOKEN` handles releases in `xiaolai/uniplayer`;
the tap needs its separate token because it is a different repository.

No repository secrets were populated by this implementation. Certificate export
and secret configuration are one-time owner setup, not part of a version bump.

The runner's default developer directory is
`/Applications/Xcode_27.1.app/Contents/Developer`. If the hosted image layout
changes, set the repository variable `RELEASE_DEVELOPER_DIR` to a supported
Xcode directory. Preflight requires Xcode 27.1+ and macOS SDK 27+; it does not
silently lower the deployment target. The public preview label and Xcode paths
are documented in [GitHub's runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

## Start a release

1. Commit the version/build in `Configs/Deployment.xcconfig`, update README and
   release notes, and push the intended release source to `main`.
2. Create and push its matching stable tag. For the current development version:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

   Use a tag pointing to the intended committed release source, not an unmerged
   topic branch. Tag, config version, build manifest and source SHA are checked.
3. Watch **Actions → Release macOS**. The workflow tests the tagged application,
   builds/signs/notarizes/staples the app and DMG, and requires Gatekeeper checks.

Only stable `vMAJOR.MINOR.PATCH` tags are accepted. Builds and tags must not move
backwards from the current stable release or Homebrew cask. No version is created
or bumped by the workflow itself.

The published assets are:

- `UniPlayer-<version>-universal.dmg`
- `SHA256SUMS.txt`
- `release-manifest.json` containing source SHA, build, sizes and hashes

Only these files are uploaded as a one-day Actions artifact. Signing archives,
keychains, notarization credentials and build logs are not release assets.

## Publication and retention order

The entire release workflow has one concurrency group with
`cancel-in-progress: false`. It does not interrupt a running publication.

1. Validate tag ancestry, version, existing release and tap state.
2. Validate signing secrets, run gates/tests, build, sign, notarize, staple and
   verify. Signing secrets are step-scoped and absent from Xcode's environment.
3. Restore the original keychain search list and delete the temporary keychain
   and imported certificate. Cleanup also runs after a partial signing failure.
4. Create/resume a draft, upload the assets and verify their server digests (or
   download and hash them if GitHub does not supply a digest).
5. Publish the verified release as latest.
6. Update only the cask's version and SHA-256, using a revision-checked Contents
   API update, then read it back. Concurrent unrelated cask edits are preserved.
7. Remove older **published** releases and their assets, including older
   prereleases. Preserve Git tags/source history and unpublished drafts. A newer
   version or a changed latest release stops cleanup.

Thus one latest published release remains after a successful run. Old releases
are never removed before the replacement and Homebrew update are verified.
The workflow does not install or replace an application on the developer's Mac.

## Retry and recovery

Rerun a failed Actions run, or dispatch the workflow with its existing tag:

```sh
gh workflow run release.yml --repo xiaolai/uniplayer -f tag=v0.2.0
```

- Before publication, a failure leaves the existing stable release and tap
  available. An interrupted draft can be completed on retry.
- If publication succeeds but the tap update fails, older releases remain so the
  existing cask URL still works. Fix the token/permission and rerun.
- On a published-tag retry, skip rebuilding/signing. Download and validate that
  release's existing manifest/assets, finish the tap update and retention. Never
  overwrite published assets with a newly signed binary of the same version.
- If pruning fails partway, rerun; the current release and cask remain available.
- A different checksum for the same cask version, a moved tag, a newer release,
  or a newer cask fails closed. Resolve the discrepancy; do not force an overwrite.

Recovery applies to releases produced by this workflow. Older manual releases
without a manifest are not silently adopted. After successful retention, older
DMG download URLs no longer exist; their Git tags remain.

## Local checks

```sh
python3 -m unittest scripts/test_github_release.py scripts/test_release_signing.py
actionlint -ignore 'label "xcode-27" is unknown' .github/workflows/release.yml .github/workflows/ci.yml
git diff --check
```

The actionlint exception is limited to the public-preview runner label, verified
against GitHub's official image inventory; actionlint 1.7.12 has not added it to
its built-in list. All other syntax, context and shell checks remain active.
The helpers use Python 3.11+ and the GitHub CLI, both present on that image.

Tests use fake GitHub services, synthetic assets and isolated Git/keychain
fixtures. They cover publication ordering, tap failure/read-back/conflict,
retry immutability, tag ancestry, checksum corruption, pagination, retention
guards, secret scoping and partial signing cleanup. They do not establish an
actual hosted signing/notarization/publication run; that needs the secrets above
and an explicitly pushed release tag.

The local workspace fallback remains `./scripts/release.sh` from the workspace
root. It produces a verified package without publishing or changing Homebrew.
