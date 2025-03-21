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
