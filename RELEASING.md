# Manual local releases

Releases run from this Mac using its existing Developer ID identity,
notarization profile and `gh` login. No GitHub release Action, cloud signing
certificate, repository secrets or separate tap token are required.

From the main checkout:

```sh
python3 scripts/release_local.py --check  # readiness only; no publication
python3 scripts/release_local.py          # complete release
```

From the workspace root, prefix the path with `main/`.

## What the release command does

1. Require clean `main`, matching version/build/notes, the intended GitHub origin,
   write access to UniPlayer and its tap, and no newer release/cask or moved tag.
   It does not stash, commit, reset, force-push or include pending source edits.
2. Verify Xcode 27.1+, macOS SDK 27+, an unlocked Developer ID Application
   signing identity, and a working local notarytool profile.
3. Clone the captured commit into a private build snapshot under
   `release-artifacts/<version>/<commit>/source`. Later working-copy edits do not
   enter that build. Copy hash-verified dependencies from the local cache, or
   download and verify them against the universal lock.
4. Run token, script, browser and application tests. Build both CPU slices;
   sign, notarize and staple the app and DMG; verify signatures and Gatekeeper.
   Save a manifest with the full source SHA, build, asset sizes and checksums.
5. Recheck that main is still clean and at the captured commit. Push that exact
   commit to `origin/main`, create its stable version tag and push only that tag.
   Git hooks remain active; no force push or tag replacement is used.
6. Upload/verify a draft's DMG, checksum and manifest, then publish it as latest.
7. Update Homebrew's version and checksum, read back the cask, and only then
   delete older published releases/assets. Keep the current release, all Git
   tags/source history and unpublished drafts.

An exclusive local repository lock prevents two release commands from running
at once across its worktrees. Remote latest/cask checks also protect retention.
The command does not install or replace `/Applications/UniPlayer.app`.

## Existing local setup

- `gh auth login` must be signed into an account with write access to
  `xiaolai/uniplayer` and `xiaolai/homebrew-tap`. The helper uses that saved login;
  it never extracts the token with `gh auth token`.
- The signing certificate and private key stay in the local Keychain. With more
  than one identity, select a Developer ID Application name through
  `UNIPLAYER_SIGN_IDENTITY`.
- The default notary profile is `uniplayer-notary` in the login keychain.
  Override with `--profile NAME`, `--keychain PATH`, or
  `UNIPLAYER_NOTARY_KEYCHAIN`.
- If the profile is unavailable during a full release, the existing workspace
  `scripts/release.sh --profile-only` credential loader prepares it. That loader
  alone reads the workspace `.env`; the release helper never reads or prints its
  values. Its output is captured, and credentials do not propagate into build
  subprocesses. A standalone clone can supply `--credential-loader PATH` or
  prepare its notarytool profile manually once.
- `--check` only probes readiness. It does not provision profiles, build, push,
  create tags, publish, change Homebrew or delete releases.
- Python 3.11+, GitHub CLI and Node are needed. Existing local Xcode/dependencies
  are reused; no hosted-runner setup is involved.

## Failure and recovery

Builds, logs and verified candidates are kept locally under the commit-specific
artifact directory. `--output PATH` chooses another directory. A changed or dirty
candidate snapshot is refused rather than reset or deleted.

- Before publication, build/signing/push failures leave the previous release and
  Homebrew download available.
- If main changes during the build, publication stops. The snapshot/candidate
  stays available; retry from the intended clean main.
- If a verified candidate manifest already exists for the same source, its DMG
  is checked with Gatekeeper and reused rather than re-signed.
- If publication succeeds but Homebrew fails, older releases remain. Finish an
  already published release without a build or source push:

  ```sh
  python3 scripts/release_local.py --resume v0.2.0
  ```

  Recovery reads version/build from the original remote tag, downloads and
  validates its existing manifest/assets, and finishes the tap and retention.
  The ordinary command also takes this path if its current version/source is
  already published. A different checksum for an existing version is refused.
- Pruning failure can be retried. A changed latest release or cask stops further
  deletion. Old DMG URLs disappear only after successful retention; Git tags stay.
- Legacy manual releases without a manifest are not silently adopted.

## Scope and verification

`.github/workflows/release.yml` and its temporary CI keychain importer were
removed. The ordinary CI still tests the release helpers without credentials;
no release runs automatically when a tag is pushed.

```sh
python3 -m unittest scripts/test_github_release.py scripts/test_release_local.py
python3 -m py_compile scripts/github_release.py scripts/release_local.py
git diff --check
```

Tests use synthetic assets, fake GitHub services and isolated Git repositories.
They cover immutable snapshots, source/tag guards, locking, cache hashes, secret
scoping, check-mode side effects, exact non-force pushes, recovery, Homebrew
failure/read-back/conflicts and retention ordering. App runtime acceptance and a
real publication are separate from these helper checks.

The old workspace `./scripts/release.sh` still offers package-only operation.
The new tracked `main/scripts/release_local.py` is the complete manual publisher.
