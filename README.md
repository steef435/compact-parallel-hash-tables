# Compact parallel hash tables for the GPU

## Installation

As this is a header-only library, it suffices to copy the `include` directory.

## Build instructions

This project was developed using GCC 10 and CUDA Toolkit 12.
It uses Thrust and C++20 for convenience/readability. Both could be eliminated.

To compile the tests and benchmark suite,
[install Meson and Ninja](https://mesonbuild.com/Getting-meson.html)
and setup a build directory using
```
meson setup build -Dbuildtype=debugoptimized -Dwerror=false
```
In particular, `werror` must be disabled because of some warnings generated in
CUB. The tests can then be run with
```
meson test -C build
```

The interface of the `tests` executable (built in the build directory) is
automatically generated by [doctest][] and has useful options. For example,
```
./build/tests -s
```
also reports passed tests (useful for debugging).

## Benchmarks

The `benchmarks` folder contains code for benchmark executables, as well as
data generators. Edit `generate.py` to generate unique keys and write them to a
file. Pass the file to the `rates` executable to run the main benchmarks used
in the paper. See (code) in the `benchmarks` folder for additional benchmarks.

For proper results, configure your meson build folder with `buildtype=release`
and disable assertions with `ndebug=true` or `ndebug=if-release`. (Assertions
in GPU code can have noticeable performance impact.)

## Implementation notes

These are key-only hash tables. The code can be used as a basis for key-value
implementations.

As implemented, the number N of buckets in (each level of) the hash tables is
always a power of 2. This slightly eases the implementation, as the address of
a key is then the first log N bits of its permutation σ(k), and the remainder
the other bits. More granular variation of N can be obtained by letting the
address of k be σ(k) % N and the (unfortunately named) remainder N / σ(k).

The main algorithms are in `include/cuckoo.cuh` and `include/iceberg.cuh`.

## Acknowledgements

Non-compact parallel bucketed Cuckoo hashing on the GPU is due to [BGHT][].
Iceberg hashing is due to [IcebergHT][].

Parts of the implementation are inspired by [CompactCuckoo][] and [BGHT][].
In particular, the cooperative-group based approach from [BGHT][] is used,
and the default key permutation is (a one-round Feistel function) based on the
hash family in [BGHT][] for comparison purposes.

[BGHT]: https://github.com/owensgroup/BGHT
[CompactCuckoo]: https://github.com/DaanWoltgens/CompactCuckoo
[doctest]: https://github.com/doctest/doctest
[IcebergHT]: https://arxiv.org/abs/2210.04068
