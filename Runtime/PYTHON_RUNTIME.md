# Packaged Python runtime

QuickSRT uses the official python.org universal2 Python 3.13.14 macOS installer.
Its URL, installer SHA-256 and expected Developer ID Installer identity are
pinned in `runtime-policy.json`. The original package is verified before its
framework payload is extracted; a developer virtual environment is never
copied into a release.

`Scripts/setup_runtime.sh` installs the hash-locked wheels into a new staging
directory, removes bytecode and non-relocatable RECORD entries, rewrites console
entry points to locate the packaged interpreter relative to themselves, removes
embedded personal home-directory build paths without changing binary size, re-signs Mach-O
files and creates a SHA-256 manifest covering every runtime file and symlink.
It then runs Python, pip, dependency checks and representative entry points from
the final location before committing the atomic replacement.

`requirements.lock` records every installed wheel with its exact version and
SHA-256. `runtime-sbom.cdx.json` is the corresponding CycloneDX 1.6 release
SBOM. `runtime-vex.json` and `ROUTE_ANALYSIS.md` document why the optional
`mlx_whisper.torch_whisper` compatibility route is excluded and why Torch is
absent from production. `Scripts/audit_runtime.sh` audits the exact lock with a
pinned isolated `pip-audit` and fails on any applicable known vulnerability.

Python is distributed under the Python Software Foundation License Version 2.
The complete license shipped by python.org is retained inside
`Python.framework/Versions/3.13/lib/python3.13/LICENSE.txt` and copied
into every review app with the unchanged framework payload.
