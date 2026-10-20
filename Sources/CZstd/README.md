# CZstd

The decompression half of Zstandard 1.5.7, vendored so the app can read the compressed rollout files that
Codex writes. macOS does not ship a usable libzstd, and writing a decoder from scratch would be far riskier
than using the reference implementation.

* Source: https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
* SHA-256 of that archive (matches upstream's published `.sha256` file):
  `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`
* Files copied unmodified from `lib/common`, `lib/decompress`, plus `lib/zstd.h` and `lib/zstd_errors.h`.
  Compression, dictionary building, multithreading and legacy-format code are not included.
* License: BSD-3-Clause, chosen from the dual BSD / GPLv2 offer. See `LICENSE` in this folder.
