# Description

Ericsson and AT&T would like to release a whitepaper detailing best practices
for encoding non-realtime video for transmission over cellular networks. A
common use case is 5G-Connected Security Cameras.

This is not quite an academic paper (i.e. to a journal) but we will make
certain recommendations in the paper and want to substantiate them by providing
means to reproduce the results, embodied in a bash script and a dockerfile.

The script itself runs video encoding tasks on various hardware and software
video encoders and measures the runtime performance (e.g. frames/sec/core) and
compression efficiency (picture quality vs. size). It utilizes the VMAF picture
quality model from Netflix, which is open source and built from source. The
results are reported as benchmarks in CSV format.

The Dockerfile simplifies a very complex process of building software and
hardware-accelerated codecs in a rigorous and repeatable manner.

The script itself is deliberately written to be very boring but easy to modify
as needed where particular readers at different companies will want to adapt
the script for their environments. New codecs will be added, e.g. VVC, over
time when they become suitable for the relevant use cases.

# Business Case
Our intention is to provide a benchmark for independent software vendors
and system integrators to evaluate the technical benefits of hardware and
software choices for video related applications on cellular networks. We
also intend to publish a whitepaper with our analysis of current benchmark
data.

# Adoption Strategy
We would like to be able to welcome others to add new codecs or testing conditions as open-source contributions, subject to internal approvals.

# Licensing
BSD license, see included LICENSE file.

# Stakeholders
- Eric Petajan, AT&T
- Hessam Moeini, AT&T
- Mallik Shah, AT&T
- Sobaan Kazi, AT&T CU
- Neha Aneja, Ericsson MANA
- David Lindero, Ericsson ER DRI
- Lars Ernstrom, Ericsson ER NAP
- Szilveszter Nadas, Ericsson ER NAP

# Getting Started

## Supported Hardware

Only genuine x86_64 hardware running Ubuntu 24.04 is currently supported. 
Ubuntu 22.04 was previously supported and the changes to use 24.04 were 
non-trivial. It's fairly difficult to move to a different OS due to
version specific dependencies.

## File Reference

| Path                            | Description                                              |
|---------------------------------|----------------------------------------------------------|
| `src/`                          | Main source code directory.                              |
| `src/benchmark/`                | All code related to running the video benchmark          |
| `src/benchmark/tc_perf.bash`    | The actual benchmark script. Note you must edit this to make it do something useful | 
| `setup/`                        | Related to building the requrired tools, e.g. ffmpeg (w/ accelerators) and VMAF. |
| `setup/build_ffmpeg`            | This script uses docker to build tools, which it will then copy back out to the host machine. For this reason, generally the container used in the Dockerfile must match the host OS | `
| `setup/Dockerfile`              | Dockerfile for building video tools                      |
| `clips/`                        | Put video clips here to use as input to the tc_perf.bash benchmark script | 

## Why do we need to build video tools?

Ubuntu does not offer a VMAF package. Many sites have instructions for 
building VMAF, but usually without any accelerated decoding, or more recent
VMAF enhancements such as AVX512 or NVCodec support. 

Recent Ubuntu versions do seem to include QuickSync and NVCodec support in their 
ffmpeg packages. It would be feasible to use the system ffmpeg and only compile 
VMAF. The chief argument against this would be that I and maybe others would 
like to keep more precise control over software versions of ffmpeg and the 
codec libraries. This allows us to build confidence in the software by only 
using versions that are extensively tested, and also should help to produce 
more repeatable results.

## Build the tools using Docker

The `build_ffmpeg` script manages running docker in order to build the video 
related tools, including ffmpeg w/ accelerated codecs, and VMAF. The `Dockerfile`
downloads several open source packages, compiles them, and installs them in the 
container. Unlike typical Docker usage, the script then copies the tools *out* of 
the container and into the host system (into a versioned subdirectory inside /opt) 
and leaving a symlink at `$PREFIX` (which defaults to /opt/t1ptop). The script 
can build both debug (unstripped) and release (stripped / optimized) versions of the 
tools. 

In general the debug paths are written into the compiled executables such that
they find their symbols or library dependencies in versioned directories, e.g.
`/opt/.t1ptop_versions/v1.0.007-dbg` This allows you to build and test a new
version of the script or libraries without affecting previously installed ones, 
you just need to be mindful that every script run will update the symlink at `$PREFIX`

## Run the Benchmark

Run the `sw/benchmark/tc_perf.bash` script. No arguments are needed.

## Configuring the Benchmark

In `tc_perf.bash`, toward the bottom, you will see function main(). This will call 
perf_test <filename> <arguments> a number of times, either as regular literal 
bash commands or as part of a loop. perf_test() will perform all required 
execution (CPU/Wall time, etc.) and efficiency (VMAF) tests, automatically 
naming resulting output artifacts (transcoded clips, VMAF score files, 
/bin/time output, etc.) according to the ffmpeg parameters used in their encoding. 

Extra parameters can also be passed to perf_test(), e.g. -ss and -t to control 
the starting point to encode from inside a video file and how many seconds 
of video to encode. It is common to treat a long video file as multiple 10 
second 'clips' by passing in the same file multiple times to perf_test() 
but with different -ss parameter values. 

You can change main() to do whatever iteration over video clips is
required for processing your set of clips.

`perf_test()` calls `run_encoding_tests()` which will iterate over
different codecs and parameters, and call `encode_clip()` setting up a
command line that is very close to the exact ffmpeg parameters.
. You can modify `run_encoding_tests()` function as needed, 
but for many simple changes, like adding a different CBR bitrate, you can
instead just modify a parameter list variable instead. Here are some of
the parameters that `run_encoding_tests()` uses.


| Variable     | Description                                            |
|--------------|--------------------------------------------------------|
| `CODEC_LIST` | list of codecs to use for encoding                     |
| `RESO_LIST`  | list of different video resolutions to encode to       |
| `BR_LIST`    | list of bitrates for CBR encoding                      |
| `CRF_LIST`   | list of CRF values to use for encoding                 |
|


