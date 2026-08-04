# Python production-route analysis

QuickSRT starts `Scripts/mlx_transcribe_srt.py`, which imports the MLX-native
`mlx_whisper` transcription, decoding, audio, and model-loading modules. These
modules load already-converted MLX weights and do not import PyTorch.

`mlx-whisper==0.4.3` nevertheless declares `torch` as an unconditional
dependency because its wheel also contains `mlx_whisper/torch_whisper.py` for
offline PyTorch-to-MLX model conversion. QuickSRT neither exposes nor imports
that conversion route. The release runtime therefore intentionally omits
Torch, including the vulnerable historical `torch==2.8.0` package.

`Scripts/runtime_dependency_check.py` is the executable control for this
decision. It fails if Torch is installed, if any MLX Whisper module other than
the isolated conversion helper imports Torch, if the production package import
fails without Torch, or if any other declared dependency is absent or has an
incompatible version. The corresponding machine-readable statement is
`Runtime/runtime-vex.json`.
