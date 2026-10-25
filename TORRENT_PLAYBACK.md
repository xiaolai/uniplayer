# Channel torrent playback

The Preview feature is enabled by default. Turn it off in Settings → General → Torrent Playback; it remains a qualified internal candidate. The adjacent Check & Play action opens a native inspection sheet. Press its native Check button to begin network inspection; the page badge alone starts no transfer. Play uses UniPlayer’s existing standalone player; Window → Return to Torrent Source returns to the Channel. Window → Stop Torrent stops the owned transfer without deleting its files.

Transmission is the genuine, unmodified 4.1.0 engine, pinned in `RuntimeDependencies/Transmission.lock.json`. Its identity is not configurable. A private tracker’s approval of this exact release still requires that tracker’s rules and a real authorized announce; a label or local fixture does not establish approval. Pure v2 torrents are unsupported.

New public magnet inspection can download metadata and small test pieces. It uses 64 KiB/s, a 20-second observation window, a 2 MiB soft target and an 8 MiB failure threshold. This is not a hard byte cap or a strict metadata-only mode. Missing seed totals remain Unknown. Full playback can download the entire selected file. Private sources preserve their complete metainfo and tracker context.

The sheet shows the post-close policy. Public transfers default to Stop; private transfers default to Continue Downloading & Seeding the selected file while UniPlayer runs. Settings lists owned transfers and their Stop controls. App quit stops the owned runtime. Restarted jobs are paused. Cached files, metainfo and resume state are retained; there is no automatic deletion. Cache quota defaults to 50 GiB with a 2 GiB free-space reserve. Choose a cache destination before adding jobs.

Site credentials remain in the Channel’s WebKit store. Same-origin protected torrent fetches stream through a bounded 10 MiB reader and require valid metainfo. Cross-origin native WebKit downloads remain separately gated; their candidate implementation requires a known bounded Content-Length and same-host redirects. HTML login/challenge pages, cloud-only posts, multiple ambiguous sources, and JavaScript/POST-only download flows require the original site. Mini4K resource-post actions have a separate experimental switch, enabled by default; turn it off in the same settings page. Current Mini4K authentication and private-group acceptance remain separate manual qualification gates.

## Build

Requires Xcode/macOS 27, CMake, Git, and the existing media dependencies described in CONTRIBUTING. Build before Xcode:

```sh
python3 scripts/build-torrent-runtime.py
python3 scripts/check-torrent-runtime-package.py build/TorrentRuntime
python3 -m unittest discover -s tests/torrent-runtime -p 'test_*.py'
xcodebuild -project uniplayer.xcodeproj -scheme uniplayer -configuration Debug \
  -derivedDataPath build/channel-torrent-check CODE_SIGNING_ALLOWED=NO build
```

The build fetches official Transmission source at its exact commit and pinned submodules, builds arm64/x86_64, uses system frameworks and bundled static dependencies, and includes license notices and the source/dependency manifest. It never uses an installed Transmission app, its personal profile, or a runtime download. Review GPL/source-distribution requirements when distributing binaries; the exact corresponding source can be rebuilt from the lock and build script. The outer app signature seals the final post-signing runtime manifest. `scripts/release-macos.py` verifies it before signing the app.

## Focused verification

`TorrentCoreTests.swift` and `TorrentIntegrationTests.swift` cover source/range/path/privacy contracts, isolated DOM injection, authenticated WebKit downloads, RPC, actual owned runtime, verified HTTP bytes, and the controlled native player lifecycle. The controlled swarm fixture uses temporary profiles and an incoming loopback peer relay because stock Transmission rejects loopback peers learned from trackers. It never contacts a public swarm or group tracker.

Generate the owned sample for the controlled native test (FFmpeg is a test dependency, not a shipped runtime dependency):

```sh
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 12 \
  -c:v libx264 -preset ultrafast -crf 24 -c:a aac -movflags +faststart \
  build/torrent-fixture.mp4
```

Run only the named Torrent/Channel tests. Keep native chrome regression checks focused; do not run a full UI sweep for this feature. The implementation audit in the separate dev-docs repository records actual results and remaining live/manual gates. Component, controlled-swarm, signed-package and real-site acceptance are distinct.

The helper inherits a protected profile lock. Recovery validates the owning app, kernel process start time and inherited lock before stopping an orphan. Personal Transmission profiles are never used. Dedicated torrent players disable plugins, raw mpv logs and mpv watch-later storage; only stable logical identities enter UniPlayer history. Raw magnets are accepted inside UniPlayer without claiming their system URL association.

The stock Unix RPC probe was not qualified; the shipped transport uses authenticated loopback RPC. Live Mini4K, private-group accounting/approval, Intel execution and composited native UI acceptance remain pending.
