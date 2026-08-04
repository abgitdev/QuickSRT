# QuickSRT compatibility evidence

Last evidence refresh: 2026-08-04 from [GitHub Actions run 30921135039](https://github.com/abgitdev/QuickSRT/actions/runs/30921135039).

This document reports environments that were actually exercised. A build setting, minimum deployment target, simulator, or configured CI job is not presented as hardware validation.

## Status vocabulary

- **Physical pass** — exercised on identified physical hardware.
- **Automated pass** — a named CI environment completed the workflow for the published revision.
- **Configured** — automation exists, but no workflow result for these changes has been published yet.
- **Policy only** — source/build inspection supports the requirement, but the requested environment was not exercised.
- **Not tested** — no representative evidence exists.
- **Not applicable** — the required distribution artifact does not exist.

## Hardware and memory matrix

| Requested environment | Status | Evidence and limits |
| --- | --- | --- |
| M1 with 8 GB | **Automated pass** at 7 GB; not a physical 8-GB pass | The completed `macos-15` and `macos-26` jobs each reported a virtual Apple M1, native arm64, and exactly 7 GiB RAM. Both passed the full automated workflow for Version 1 / Build 2. This is the closest hosted low-memory tier, not an exact physical 8-GB test, and the 8-GB long-video soak remains not tested. |
| M2 | Not tested | No M2 machine is available. GitHub's paid larger M2 runner is not enabled because it requires separately authorized runner capacity/cost. |
| M3 | Not tested | No representative local or hosted runner is available. |
| M4 with 32 GB | **Physical pass** | Mac mini M4, 32 GB, macOS 26.5.2. The Version 1 / Build 2 candidate passed 94 Python and 207 Release Swift tests, native runtime checks, packaging diagnostics, and isolated first launch. A predecessor with the same transcription and translation pipeline passed a real model transcription and real Apple Translation English → Russian; that heavyweight end-to-end run was not repeated after the metadata-only public-version reset. This does not substitute for other memory tiers or a long-video soak. |
| M5 | Not tested | No representative local or hosted runner is available. |
| 8 GB | Not tested exactly | The passing CI M1 VM exposes 7 GiB, not 8 GiB. Resource-preflight and bounded-memory regression tests pass, but no result is relabeled as an exact 8-GB hardware pass. |
| 16 GB | Not tested | No 16-GB machine or exact CI tier is available. |
| 32 GB | **Physical pass** | Covered only by the M4 host described above. |

General runner specifications are documented by the [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). Runner labels and capacities can change; the privacy-safe artifacts from the linked run record the virtual Apple M1, native arm64 architecture, and 7 GiB RAM that each job actually received.

## macOS and clean-environment matrix

| Requested environment | Status | Evidence and limits |
| --- | --- | --- |
| macOS 15 | **Automated pass** | The linked `macos-15` arm64 job passed on macOS 15.7.7 with Xcode 16.4. It compiled and ran all 207 Release Swift tests, ran the two primary-workflow UI tests, built a separate clean Release app, passed isolated first launch, confirmed Version 1 / Build 2 and arm64-only native code, and created a clean source archive. |
| macOS 26 | **Physical and automated pass** | Physical Version 1 / Build 2 evidence is from macOS 26.5.2 on an M4. The linked `macos-26` arm64 job also passed on macOS 26.5.2 with Xcode 26.6 and completed the Release, clean-launch, architecture, evidence, and source-archive gates. |
| Clean system without Rosetta | Policy only | Every Mach-O in the installed Version 1 / Build 2 bundle is arm64-only, and CI rejects a non-arm64 host. The physical M4 currently has Rosetta installed and can execute x86_64, so it is not a clean no-Rosetta test. |
| First launch without model or caches | **Physical and automated pass** | `Scripts/verify_clean_first_launch.sh` launches the packaged app with isolated empty home/temp roots, confirms it stays alive without model files or prior QuickSRT caches, then requires termination within 10 seconds. It passed locally and in both linked CI jobs. It does not download or run Whisper. |

`Scripts/collect_compatibility_evidence.py` records only an allowlisted machine class, chip, architecture, RAM, OS/build, the Rosetta package receipt, app metadata, Mach-O architecture summary, and distribution-security booleans. It deliberately excludes usernames, computer names, serial numbers, UUIDs, runner names, and absolute paths. It does not attempt x86_64 execution by default, because that probe could disturb a genuinely clean no-Rosetta host; the opt-in `--test-rosetta-execution` flag is used only when that side effect is acceptable.

## Gatekeeper and public binary distribution

**Downloaded notarized archive: not applicable and not tested.** QuickSRT has no Developer ID Application certificate and publishes source only. Therefore there is no authorized notarized `.app`, `.zip`, `.dmg`, or `.pkg` to download, quarantine, and assess with Gatekeeper.

The local Version 1 / Build 2 candidate is ad-hoc signed. It has no secure timestamp or stapled notarization ticket and is not evidence for downloaded-distribution trust. `Scripts/verify_release_security.sh distribution <app>` intentionally fails closed unless a future artifact has a Developer ID signature, secure timestamp, stapled ticket, and positive `spctl` assessment. A real downloaded-archive test must remain **not tested** until such an artifact exists; local `spctl` output is not a substitute.

## CI scope

The CI matrix is configured to run the following on both `macos-15` and `macos-26`:

1. Validate repository whitespace, shell syntax, Release settings, and locked dependencies.
2. Run all Python tests.
3. Run all Release Swift tests on a native arm64 host.
4. Run the primary-workflow UI suite on macOS 15.
5. Create a separate clean Release app without injected XCTest frameworks.
6. Launch that app from isolated empty home/temp roots without a model or caches.
7. Require every app Mach-O to be arm64-only, record host/app evidence, and upload it as a workflow artifact.
8. Verify the clean-tree source archive path.

CI cannot honestly emulate M2, M3, M4, M5, exact 8/16/32-GB configurations, external volumes, or long-video thermal and memory behavior. Those rows change to a pass only after evidence from the actual environment is retained for a specific revision.
