# Compact parallel hash tables for the GPU (WIP)

## Installation

As this is a header-only library, it suffices to copy the `include` directory.

## Build instructions

This project was developed using GCC 10 and CUDA Toolkit 12.
It uses Thrust and C++20 for convenience/readability. Both could be eliminated.

To compile the tests,
[install Meson and Ninja](https://mesonbuild.com/Getting-meson.html)
and setup a build directory using
```
meson setup build
```
The tests can then be run with
```
meson test -C build
```

__Warning:__ current versions of Meson do not properly trigger a rebuild for
nvcc executables if included headers change.
Run
```
meson compile -C build --clean
```
to trigger a full rebuild of the tests after modifying the headers.
This should not be necessary for (future) Meson versions > 1.3.1.

## Acknowledgements (TODO: expand)

Non-compact parallel bucketed Cuckoo hashing on the GPU is due to [BGHT][].
Iceberg hashing is due to [IcebergHT][].

Parts of the implementation are inspired by [CompactCuckoo][] and [BGHT][].
In particular, the cooperative-group based approach from [BGHT][] is used,
and the default key permutation is (a one-round Feistel function) based on the
hash family in [BGHT][] for comparison purposes.

[BGHT]: https://github.com/owensgroup/BGHT
[CompactCuckoo]: https://github.com/DaanWoltgens/CompactCuckoo
[IcebergHT]: https://arxiv.org/abs/2210.04068
