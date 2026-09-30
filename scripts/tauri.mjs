// `npm run tauri …` — the Tauri CLI, with the build environment this platform
// needs.
//
// .cargo/config.toml carries the Windows SDK paths (src-tauri/ffmpeg,
// src-tauri/tools), so on macOS ffmpeg-sys needs FFMPEG_DIR and LIBCLANG_PATH
// from scripts/macos-env.sh instead. Cargo's `[env]` never overrides a variable
// already in the environment, so exporting them first is enough. Doing it here
// rather than in a separate `tauri:macos` script means `npm run tauri dev` is
// right on both platforms, instead of failing on a Mac inside ffmpeg-sys.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);

const result =
  process.platform === 'darwin'
    ? // One source of truth for the macOS paths: the same file the dev and
      // release scripts source. It exits non-zero with its own message when
      // the FFmpeg SDK or libclang is missing.
      spawnSync(
        'bash',
        ['-c', 'set -euo pipefail; source scripts/macos-env.sh; exec npx tauri "$@"', 'tauri', ...args],
        { cwd: root, stdio: 'inherit' },
      )
    : spawnSync('npx', ['tauri', ...args], { cwd: root, stdio: 'inherit', shell: true });

if (result.error) throw result.error;
process.exit(result.status ?? 1);
