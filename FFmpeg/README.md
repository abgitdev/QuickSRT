# QuickSRT FFmpeg build

QuickSRT distributes FFmpeg 8.1.2 as two ad-hoc-signed native Apple Silicon
executables. The build is intentionally LGPL-2.1-or-later: GPL, version-3-only,
nonfree and auto-detected external libraries are disabled.

The exact upstream source URL and SHA-256, reviewed build toolchain, configure
flags, binary SHA-256 values, architecture and license are recorded in
`manifest.json`. `configure.flags` is passed to upstream `configure` one line at
a time by `Scripts/build_ffmpeg_tools.sh`.

To reproduce the reviewed binaries on the recorded Xcode toolchain:

```sh
Scripts/build_ffmpeg_tools.sh
```

The script downloads only the pinned source archive, verifies it before
extraction, builds from a fixed `/private/tmp/QuickSRT-FFmpeg-8.1.2` path, signs
both executables, verifies the complete manifest, and atomically replaces
`Tools`. A toolchain change can legitimately change the binary hashes; such a
change must be reviewed and intentionally recorded in `manifest.json` rather
than accepted automatically.

The reduced build keeps FFmpeg's built-in input support so QuickSRT can decode
the user's video, but emits only the PCM/WAV and raw `s16le` intermediates used
by the transcription pipeline and MLX Whisper. It has no network or
capture-device support.

FFmpeg source corresponding to the binaries is the unmodified archive named in
the manifest. Its complete license files and source are contained in that
archive. The LGPL 2.1 text distributed with the app is in
`FFmpeg/COPYING.LGPLv2.1`.
