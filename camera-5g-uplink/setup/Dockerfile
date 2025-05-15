# We will usually want this to agree with the host system where we will
# ultimately run the tools, primarily because the package versions used
# for the ffmpeg build will need to be found at runtime.
FROM ubuntu:24.04

# don't prompt the user for anything w/ apt.
ENV DEBIAN_FRONTEND=noninteractive

# OT_VERSION the version of this Dockerfile.
ARG OT_VERSION=t1ptop-ver-unknown

#  TODO:
#
#   - Make a .pc file for all of the /opt/t1ptop/lib stuff, e.g. for
#     pkg-config --libs t1ptop
#
#   - ensure the CUDA filters are available
#   - see if we even need to build the source packages for VA related
#     libraries. If present at the new /opt/t1ptop/lib location, they
#     cause linking problems at the host
#   - to simplify, install VMAF libs into ${PREFIX}/lib, not ${PREFIX}/lib/${ARCH}
#     (this turns out to be a challenge)
#   - move to OneVPL library instead of MFX.
#
#   - VMAF related python scripts installed to /bin have the wrong python
#     (from the .venv created for vmaf build)
#   - figure out ARCH from uname instead of hard-coding it.

#
#  for nightly full rebuilds:
#  - rename all build directories to build.${package}

# Note for users:
#
#  After you build the image, you can run the install script
#  at install.bash to install into the host system.
#  But usually even this dockerfile is run from another script.
#
#  docker build -t jal_ff -f Dockerfile .
#  docker run -it --rm -v /opt/t1ptop:/hostopt jal_ff  /bin/bash
#       ./install.bash

# See these docs:
# https://github.com/Intel-Media-SDK/MediaSDK/wiki/Build-Media-SDK-on-Ubuntu

# name of root work directory in container, basically just the dir for
# downloading and building source packages.
ARG TOP=/tmp/ffmpeg

# whether this is a debug build
ARG DEBUG=1

# We do lock in specific software versions for ffmpeg, vmaf, and msdk.
# See:
#   LIBVA_VERSION
#   FFMPEG_VERSION
#   VMAF_VERSION
#   MSDK_VERSION
#
# For pragmatic reasons w/ docker, to avoid rebuilding everything all
# the time, search for those variable names further down in this file to
# change their values.

# installation prefix. We'll install to this path inside the container
# and also in the host system. We want to use the same value as the host
# system's location to avoid trouble with the pkg-config .pc files that
# will be installed.
ARG PREFIX="/opt/t1ptop"
ENV ARCH="x86_64-linux-gnu"

# a fake path used inside the docker container to install libraries to
# which will map to the host's ${PREFIX}
ARG INST_PRE="/hostopt"

# package management commands (for Ubuntu)
ENV PKG_UPD="apt-get update"
ENV PKG_INST="apt-get install -y"

# ffmpeg version specifics
# ENV FF_VERSION="4.2.1"
# ENV FF_FNAME="ffmpeg-${FF_VERSION}.tar.bz2"
# ENV FF_URL="http://ffmpeg.org/releases/ffmpeg-${FF_VERSION}.tar.bz2"

# how many parallel compile jobs we can run (via gmake) before we
# overload the system.
ENV SAFE_JOBS 12
ENV MAKE="make -j${SAFE_JOBS}"

WORKDIR ${TOP}

# ENV BIN="/usr/bin"

RUN apt-get update

# these are the Ubuntu package names.

RUN ${PKG_INST} \
    bash \
    git \
    make \
    g++ \
    meson \
    pkg-config \
    libtool \
    xxd \
    cmake \
    nasm

# for troubleshooting only
RUN ${PKG_INST} \
        vim


# we have to do this or else the libraries aren't found
# by pkg-config in any alternative location.
ENV PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig:${PREFIX}/lib/${ARCH}/pkgconfig:/usr/lib/${ARCH}/pkgconfig:/usr/lib/pkgconfig


### libva -- video acceleration
# TODO: try version 2.22.0
WORKDIR ${TOP}
ENV LIBVA_VERSION="2.22.0"
RUN ${PKG_INST} \
        libdrm-dev
RUN git clone https://github.com/intel/libva
WORKDIR libva
RUN git checkout ${LIBVA_VERSION}
RUN ./autogen.sh --prefix=${PREFIX} && ${MAKE} && make install

### libva-utils
# same version as libva-utils
WORKDIR ${TOP}
RUN git clone https://github.com/intel/libva-utils
WORKDIR libva-utils
RUN git checkout ${LIBVA_VERSION}
RUN ./autogen.sh --prefix=${PREFIX} && ${MAKE} && make install

### gmmlib
# TODO: can we put this in a different top-level build dir instead of # inside?
# TODO: try version intel-gmmlib-22.5.2
WORKDIR ${TOP}
ENV GMMLIB_VERSION="intel-gmmlib-22.5.5"
RUN git clone https://github.com/intel/gmmlib
RUN cd gmmlib && git checkout ${GMMLIB_VERSION}
RUN mkdir build.gmmlib
WORKDIR build.gmmlib
RUN cmake -DCMAKE_INSTALL_PREFIX=${PREFIX} \
          -DARCH=64 \
          -DCMAKE_BUILD_TYPE=Release \
          ../gmmlib
RUN ${MAKE} && make install

### Intel-Media-Driver
# this one hogs all the CPU w/ -j , so limit it to -j ${SAFE_JOBS}
# TODO: try version intel-media-23.1.6
WORKDIR ${TOP}
ENV IMD_VERSION="intel-media-24.4.4"
RUN git clone https://github.com/intel/media-driver
WORKDIR media-driver
RUN git checkout ${IMD_VERSION}
WORKDIR ${TOP}

RUN mkdir build.media-driver
WORKDIR build.media-driver
RUN cmake -DCMAKE_INSTALL_PREFIX=${PREFIX} ../media-driver
RUN ${MAKE} && make install


### Intel-Media-SDK
ENV MSDK_VERSION="intel-mediasdk-23.1"
WORKDIR ${TOP}

RUN ${PKG_INST} \
        libmfx-dev \
        libx11-xcb-dev \
        libxcb-dri3-dev \
        libxcb-present-dev \
        libdrm-dev xorg xorg-dev openbox libx11-dev \
        ocl-icd-opencl-dev \
        intel-media-va-driver-non-free

# for wayland
RUN ${PKG_INST} \
        libwayland-dev \
        libwayland-client0

RUN ${PKG_INST} patch

RUN git clone https://github.com/Intel-Media-SDK/MediaSDK msdk

WORKDIR msdk

# unfortunately, one of the .cpp files is missing #include <stdint.h>
# we need to patch it.
RUN git checkout ${MSDK_VERSION}
# COPY mfx_stdint.patch msdk/mfx_stdint.patch
# inline the patch here into a heredoc...
RUN cat <<EOF > mfx_stdint.patch
diff --git a/api/mfx_dispatch/linux/mfxparser.cpp b/api/mfx_dispatch/linux/mfxparser.cpp
index 9d3823ec..467c773a 100644
--- a/api/mfx_dispatch/linux/mfxparser.cpp
+++ b/api/mfx_dispatch/linux/mfxparser.cpp
@@ -22,6 +22,7 @@
 #include <stdio.h>
 #include <stdlib.h>
 #include <string.h>
+#include <stdint.h>

 #include <list>

EOF
RUN patch -p 1 < mfx_stdint.patch

# JAL: changing to build this at top level. WORKDIR build.msdk
WORKDIR ${TOP}
RUN mkdir build.msdk
WORKDIR build.msdk
RUN cmake -DCMAKE_INSTALL_PREFIX=${PREFIX} \
          -DENABLE_WAYLAND=ON \
          -DENABLE_X11_DRI3=ON \
          -DENABLE_OPENCL=ON \
          -DCMAKE_BUILD_TYPE=Release \
          ../msdk

RUN ${MAKE} && make install


### libva (again!)
#
# now we need to build libva again !
# it will build libva-glx / libva-wayland / libva-x11
WORKDIR ${TOP}

RUN cp -R libva libva.step2
RUN cd libva.step2 && ./autogen.sh && ${MAKE} && make install

### VMAF
ENV VMAF_VERSION="d95b69e0"
WORKDIR ${TOP}

ENV VMAF_TAG=
RUN git clone https://github.com/Netflix/vmaf.git vmaf


# TODO: reduce this list down
# RUN ${PKG_INST} build-essential ninja-build nasm doxygen python3-pip python3-venv
RUN ${PKG_INST} python3-pip python3-venv

ENV VMAF_DIR="${TOP}/vmaf"
ENV     VENV="${TOP}/vmaf/.venv"
ENV PIP="${VENV}/bin/pip3"

# install the build tools inside the virtual environment
WORKDIR ${VMAF_DIR}

RUN git checkout ${VMAF_VERSION}

# install some required packages inside the python virtual environment.
RUN python3 -m venv ${VENV}
RUN ${PIP} install meson setuptools
RUN ${PIP} install -r ${VMAF_DIR}/python/requirements.txt

RUN ${PKG_INST} nasm pkg-config xxd

RUN make deps
RUN make clean

# this is a modification of the build step from the Makefile
# putting it here gives better control over the options
#
# We specify --libdir so that we don't end up installing to
#  ${PREFIX}/lib/${ARCH} directories, which complicates other steps.
RUN BT=$([ ${DEBUG} -eq 0 ] && echo "release" || echo "debug") && \
    ${VENV}/bin/meson setup libvmaf/build libvmaf \
        --prefix ${PREFIX} --libdir ${PREFIX}/lib \
        --pkgconfig.relocatable \
        --buildtype ${BT} \
         -Denable_float=true \
         -Denable_avx512=true

RUN ${VENV}/bin/ninja -vC libvmaf/build test
RUN cd python && ${VENV}/bin/python setup.py build_ext --build-lib .
RUN ${VENV}/bin/ninja -vC libvmaf/build install

# this will install several additional helper scripts and a 'VMAF Egg'
# (if I understand correctly)
# note if you want to use the VMAF module that gets installed, you would set
# export PYTHONPATH=/opt/t1ptop/lib/python3.10/site-packages/vmaf-3.0.0-py3.10-linux-x86_64.egg

RUN cd python && ${VENV}/bin/python setup.py install --prefix ${PREFIX}

# used to just be these...
# RUN make
# RUN make install

RUN ldconfig

### nvidia headers for use with FFmpeg
ENV NV_HEADERS_VERSION="n12.2.72.0"
WORKDIR ${TOP}

RUN git clone https://github.com/FFmpeg/nv-codec-headers
WORKDIR nv-codec-headers
RUN git checkout ${NV_HEADERS_VERSION}
# change the makefile so we could override PREFIX if desired.
RUN sed -i 's/PREFIX =/PREFIX ?=/g' Makefile
RUN ${MAKE} && make install
WORKDIR ${TOP}

### Build FFMPEG
ENV FFMPEG_VERSION="n6.1.2"

WORKDIR ${TOP}

RUN git clone https://github.com/FFmpeg/FFmpeg

# some nice extra media formats and codecs for ffmpeg's use.
# we'll take these from the system packages since at the moment we
# aren't interested in hacking on their code.
RUN ${PKG_INST} \
                libfdk-aac-dev \
                libvorbis-dev \
                libmp3lame-dev \
                \
                libvpx-dev \
                libx264-dev \
                libx265-dev \
                libzimg-dev \
                libaom-dev \
                \
                libfreetype-dev

WORKDIR FFmpeg

RUN git checkout ${FFMPEG_VERSION}

# ok, we want to save away a file with our chosen options for ffmpeg configure.
# this makes it easy to jump back into the container and repeat the
# configure step in case we want to add new codecs & filters.
RUN echo \
  --extra-version="t1ptop-project[${OT_VERSION}]"\
  $([ $DEBUG -eq 0 ] && echo "--disable-debug") \
  $([ $DEBUG -eq 1 ] && echo "--disable-stripping --disable-optimizations") \
  \
  --cpu=native \
  --enable-shared \
  \
  --enable-libmfx \
  --enable-vaapi \
  --enable-opencl \
  --enable-libvorbis \
  --enable-libvpx \
  --enable-libdrm \
  --enable-libfdk-aac \
  --enable-libfreetype \
  --enable-libmp3lame \
  \
  --enable-libaom \
  \
  --enable-libx264 \
  --enable-libx265 \
  \
  --enable-libvmaf \
  \
  --enable-ffnvcodec \
  --enable-nvenc \
  --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc \
  --enable-encoder=h264_vaapi,hevc_vaapi,av1_vaapi \
  --enable-decoder=hevc,hevc_nvenc \
  \
  --enable-libzimg \
  \
  --enable-gpl \
  --enable-nonfree  \
 > ffconf_options.txt

RUN ./configure --prefix=${PREFIX} $(cat ffconf_options.txt)
RUN ${MAKE}
RUN make install
RUN make clean

# don't make clean, in case we need to investigate / run code in the container.

### Make the install.bash script.
WORKDIR ${TOP}

RUN ${PKG_INST} rsync
RUN ${PKG_INST} patchelf

# TODO: clean up, uninstall any tools that were only installed for
# build purposes and unlikely to be used again.

# once everything is installed and copied over, we can run patchelf
# against the ffmpeg library to lock its shared library search path.
#

RUN cat <<EOF > ${TOP}/install.bash
#!/bin/env bash

# \${INST_PRE} is where you want to install to, e.g. /opt/t1ptop
# \${ARCH} is the machine's arch triple, e.g. x86_64-linux-gnu
# \${PREFIX} is where we have installed libraries in THIS container.
#            and from where we will copy things to ${INST_PRE}

# let the user pass it in via VAR1=VALUE1 VAR2=VALUE2 (etc.) on the command line
eval "\$@"

echo "# orig PREFIX:     \${PREFIX}"

[[ -z \${INST_PRE}  ]] &&  INST_PRE="${INST_PRE}"
[[ -z \${ARCH}      ]] &&      ARCH="${ARCH}"
[[ -z \${PREFIX}    ]] &&    PREFIX="${PREFIX}"
[[ -z \${RT_PREFIX} ]] && RT_PREFIX="${RT_PREFIX}"
[[ -z \${RUNPATH}   ]] &&   RUNPATH="\${RT_PREFIX}/lib/\${ARCH}:\${RT_PREFIX}/lib:/usr/lib/\${ARCH}:/usr/lib"

echo "# RT_PREFIX:  \${RT_PREFIX}"
echo "# PREFIX:     \${PREFIX}"
echo "# INST_PRE:   \${INST_PRE}"
echo "# ARCH:       \${ARCH}"
echo "# RUNPATH:    \${RUNPATH}"

function die() {
    echo "FATAL-ERROR: \$1"
    exit 1
}

[[ ! -d \${INST_PRE} ]] && die "Install dir: \${INST_PRE} doesn't exist"
[[ ! -w \${INST_PRE} ]] && die "Install dir: \${INST_PRE} not writable!"

echo "# Installing libraries to \${INST_PRE}"
rsync -ravP --delete \${PREFIX}/ \${INST_PRE}/

# NOTE: we could switch to \$ORIGIN/../lib (etc.) instead if we wanted
# to be able to move it around to someplace besides \$PREFIX.
# Let's consider that later on.
# RUNPATH="\${PREFIX}/lib/\${ARCH}:\${PREFIX}/lib:/usr/lib/\${ARCH}:/usr/lib"

echo "# Runpath will be set to \${RUNPATH}"

# we use patchelf to rewrite the rpath in each binary so that it
# preferentially uses the shared libraries from the same install location
# in \${INST_PRE}
for prog in \${INST_PRE}/bin/*; do
      echo " # Patching executable \$prog";
      patchelf --set-rpath \${RUNPATH} \$prog
done

# unfortunately we need to write rpaths into libraries as well --
# the libraries have their own. If it's empty it uses the system
# paths.
for prog in \${INST_PRE}/lib/lib*.so* \${INST_PRE}/lib/\${ARCH}/lib*.so*; do
  if [[ ! -L "\$prog" ]]; then
      echo " # Patching library: \$prog"
      patchelf --set-rpath \${RUNPATH} \$prog
  fi
done

# a hack. We don't want to use our own compiled libva-XXX libs.
# they have some linking incompatibilities with the system versions.
# this could possibly by fixed (if necessary).
for fname in \${INST_PRE}/lib/libva*.{so,a,la}*; do
    if [[ -e "\$fname" ]]; then
        echo "# Remove: \$fname"
        rm "\$fname"
    fi
done

EOF

RUN chmod +rx ${TOP}/install.bash

# build a t1ptop.pc file as a bundle of all the libs we just built.
# the 'echo' below is to keep everything on one line.
ENV PKG_CONFIG_LIBDIR=${INST_PRE}/lib/pkgconfig
ENV INST_PRE=${INST_PRE}

# Note, below we get the names of each 'module' by taking the .pc file's name
# w/o the .pc extension.

RUN cat <<EOF > ${TOP}/t1ptop.pc
# JAL: this is a 'bundle' package that just includes all of our compiled libraries.
prefix=\${pcfiledir}/../..
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: t1ptop
Description: T1PTOP Software Library Bundle
Version: ${OT_VERSION}

Requires: $(echo \
            $(for mod in ${PREFIX}/lib/pkgconfig/*.pc; do \
                basename "${mod%.pc}"; done ))

# auto-magically build the library search path into the executable
Libs: -Wl,-rpath,\${libdir}:\${libdir}/$(gcc -dumpmachine)

EOF

# done


RUN cp ${TOP}/t1ptop.pc ${PREFIX}/lib/pkgconfig/t1ptop.pc
