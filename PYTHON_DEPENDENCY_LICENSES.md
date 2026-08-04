# Python dependency licenses

This inventory corresponds to [`Runtime/requirements.lock`](Runtime/requirements.lock). The virtual environment itself is generated locally and is excluded from Git and source archives.

License identifiers below come from the installed wheel metadata and bundled license files for the exact locked versions. Packages may bundle additional components under compatible licenses; the complete authoritative texts remain in each installed wheel's `*.dist-info` license and notice files.

| Package | Version | Declared license |
| --- | ---: | --- |
| anyio | 4.14.2 | MIT |
| certifi | 2026.7.22 | MPL-2.0 |
| charset-normalizer | 3.4.9 | MIT |
| click | 8.4.2 | BSD-3-Clause |
| exceptiongroup | 1.3.1 | MIT |
| filelock | 3.32.2 | MIT |
| fsspec | 2026.7.0 | BSD-3-Clause |
| h11 | 0.16.0 | MIT |
| hf-xet | 1.6.0 | Apache-2.0 |
| httpcore | 1.0.9 | BSD-3-Clause |
| httpx | 0.28.1 | BSD-3-Clause |
| huggingface-hub | 1.26.0 | Apache-2.0 |
| idna | 3.18 | BSD-3-Clause |
| llvmlite | 0.48.0 | BSD-2-Clause AND Apache-2.0 WITH LLVM-exception |
| mlx | 0.32.0 | MIT |
| mlx-metal | 0.32.0 | MIT |
| mlx-whisper | 0.4.3 | MIT |
| more-itertools | 11.1.0 | MIT |
| numba | 0.66.0 | BSD-2-Clause; bundled components retain their notices |
| numpy | 2.4.6 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 |
| packaging | 26.2 | Apache-2.0 OR BSD-2-Clause |
| pip | 26.2 | MIT; vendored packages retain their own licenses |
| PyYAML | 6.0.3 | MIT |
| regex | 2026.7.19 | Apache-2.0 AND CNRI-Python |
| requests | 2.34.2 | Apache-2.0 |
| scipy | 1.18.0 | BSD-3-Clause; bundled components retain their notices |
| setuptools | 83.0.0 | MIT; vendored packages retain their own licenses |
| tiktoken | 0.13.0 | MIT |
| tqdm | 4.70.0 | MPL-2.0 AND MIT |
| typing-extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.7.0 | MIT |
| wheel | 0.47.0 | MIT |

Torch is intentionally absent from the release runtime. The upstream `mlx-whisper` wheel declares it only for an offline model-conversion module outside QuickSRT's production route; see [`Runtime/ROUTE_ANALYSIS.md`](Runtime/ROUTE_ANALYSIS.md) and the machine-readable VEX statement.

When the lock changes, regenerate the runtime, inspect every installed distribution's `License-Expression`, `License`, license classifiers, and shipped license files, then update this inventory in the same change. Run `python3 Scripts/check_python_license_inventory.py` to verify that package names and versions still match the lock. This file is an attribution inventory, not a replacement for the packages' complete license texts.
