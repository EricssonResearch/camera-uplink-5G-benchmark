#!/usr/bin/env bash

# simple script to invoke VMAF ffmpeg container.
#
# jonathan.lynam@ericsson.com

#
# tips:
#
#   to just try this out, if you want to just do VMAF scoring 
#   on the first 10 seconds, append the -ss and -to (which pass through to ffmpeg)
#      vmaf ref.mp4 dst.mp4 score.json -ss 0:00 -to 0:10
#
#   VMAF filter will give an error if the resolutions do not match.
#
#   Scaling from 4k -> 2k usually gives a substantial speedup, but this 
#   is not activated.


# relative speeds of the additional filters (PSNR, VIF, CIEDE)
# TODO:

# ffmpeg threads to use (for decoding)
FF_THREADS=${FF_THREADS:=8}

# VMAF threads to use.
THREADS=${THREADS:-8}

# Docker image to use
IMAGE=${IMAGE:-ffmpeg-vmaf2}

# name of score file to write
SCORE_FILE=${SCORE_FILE:-score.json}

# set to only calculate VMAF for every Nth frame, default=1 means no subsampling.
SUBSAMPLE=${SUBSAMPLE:-1}

# score file format
SCORE_FORMAT=${SCORE_FORMAT:-json}

# whether to use the 'phone' model (vs. TV)
PHONE=${PHONE:-0}

# by default scale content to 1080p and use the normal 1080p model.
# NOTE: if 2160p is specified we don't (yet) switch to the 4k model.TODO.
SCALE=${SCALE:-1080p}

PREFIX=${PREFIX:="/opt/t1ptop"}

# VMAF model to use (see inside the container for a list)
# $MODEL

if [[ -z $LOCAL ]]; then
    if [[ -e ${PREFIX}/bin/ffmpeg ]]; then
        LOCAL=1
    else
        LOCAL=0
    fi
fi

# HWACCEL: should be cuda, auto, or none.
HWACCEL=${HWACCEL:-auto}

# add a version number
VERSION=1.0.008

# whether to use the older VMAF, which changes features
if [[ -z $OLD_VMAF ]]; then
    if [[ $LOCAL -eq 1 ]]; then OLD_VMAF=0; else OLD_VMAF=1; fi
fi

# if we are using the old VMAF, set the default $MODEL.
# you can override this in any case.
if [[ $OLD_VMAF = 1 ]] && [[ -z $MODEL ]] ; then
    # VMAF model to use (see inside the container for a list)
    MODEL=${MODEL:-/model/vmaf_v0.6.1.json}
fi

DEBUG_LEVEL=0

function debug_1() {
    if [[ $DEBUG_LEVEL -ge 1 ]]; then
        echo "$1"
    fi
}

function usage() {

   cat <<-HERE
## VMAF helper script (v$VERSION)

 Usage: $(basename $0) <reference_video> <distorted_video> [<score_file>] [ffmpeg args...]

   The score filename is optional. It MUST NOT start with a dash '-'.

   Any arguments (after the score filename) will be passed along 
   to ffmpeg as it invokes the VMAF filter, e.g. -ss and -to can be used 
   so define a segment in the video to compare.

   Any video container format that ffmpeg can interpret can be used, e.g.
         .mp4, .mov, .webm, .y4m  (for raw video)

   And any codec that ffmpeg supports, e.g.:
         h.265 (HEVC), h.264 (AVC), VP9

   This script runs ffmpeg/vmaf from a docker container named ${IMAGE}.
   Set LOCAL=1 in the environment to instead use a local ffmpeg/vmaf 
   installation.

 Examples:

   Run VMAF w/ a reference file ref.mp4 vs. distorted file dst.mp4
   Save the results into vmaf.json

       vmaf ref.mp4 dst.mp4 vmaf.json 

   Same, but only compare the first 10 seconds

       vmaf ref.mp4 dst.mp4 vmaf.json -ss 0.0 -to 10.0

HERE

   exit 0
}

function cleanup() {
    [[ ! -z "$T_SCOREFILE" ]] && [[ -e "$T_SCOREFILE" ]] && rm -f "$T_SCOREFILE"
}

function die() {
    echo "FATAL-ERROR: $1"
    cleanup
    exit 1
}

if [[ $# -lt 2 ]]; then
   usage
fi

REFERENCE_FILE=$1; shift
DISTORTED_FILE=$1; shift

# if the third argument starts with a - then it's an ffmpeg option to 
# pass through. Otherwise it's a score file.
case $1 in 
    -*)
        # echo "it's an option: $1". 
        # it's explicitly marking the end of file arguments.
    ;;
    *)
        # echo "it's a filename: $1"
        if [[ ! -z "$1" ]]; then
            SCORE_FILE="$1"
            shift
        fi
    ;;
esac

if [[ ! -e "$REFERENCE_FILE" ]]; then
    die "Reference video file '$REFERENCE_FILE' doesn't exist" 
fi

if [[ ! -e "$DISTORTED_FILE" ]]; then
    die "Distorted video file '$DISTORTED_FILE' doesn't exist" 
fi

# support function, often missing on MacOS
function my_realpath() {
	path=`eval echo "$1"`
	folder=$(dirname "$path")
	echo $(cd "$folder"; pwd)/$(basename "$path");
}

if [[ -x $(which realpath 2>/dev/null) ]]; then
    # this is a bit tricky. 
    # we want absolute/normalized paths (.e. no '..') but 
    # we do NOT want to expand symlinks into physical paths.
	REALPATH="realpath -L -s -m"
else
	REALPATH=my_realpath
fi

b_ref=$(basename  $REFERENCE_FILE)
b_dst=$(basename  $DISTORTED_FILE)
c_ref=$($REALPATH $REFERENCE_FILE)
c_dst=$($REALPATH $DISTORTED_FILE)

T_SCOREFILE=.vmaf.$$.tmp

# build up the libVMAF args
VMAF_ARGS="$VMAF_ARGS:log_fmt=$SCORE_FORMAT:log_path=$T_SCOREFILE"
VMAF_ARGS="$VMAF_ARGS:n_threads=$THREADS"
VMAF_ARGS="$VMAF_ARGS:n_subsample=$SUBSAMPLE"
if [[ $OLD_VMAF = 1 ]]; then
    VMAF_ARGS="$VMAF_ARGS:psnr=1"
    VMAF_ARGS="$VMAF_ARGS:phone_model=$PHONE"
fi
if [[ ! -z $MODEL ]]; then
    VMAF_ARGS="$VMAF_ARGS:model_path=$MODEL"
fi
debug_1 "VMAF_ARGS: $VMAF_ARGS"

# these could be used for scaling in the future.
OPT_R=""
OPT_D=""

# really we should check our content to see if the resolutions are the same or not.
case $SCALE in
    none)
        # don't re-scale at all. compare as-is. this can give 
        # odd results if not 1080p resolution.
        OPT_D=""
        OPT_R=""
        ;;
    720p)
        OPT_D="scale=720:480:flags=bicubic"
        OPT_R="scale=720:480:flags=bicubic"
        ;;
    1080p)
        OPT_D="scale=1920:1080:flags=bicubic"
        OPT_R="scale=1920:1080:flags=bicubic"
        ;;
    2160p)
        OPT_D="scale=3840:2160:flags=bicubic"
        OPT_R="scale=3840:2160:flags=bicubic"
        ;;
    *)
        die "Invalid scale parameter: $SCALE. Choices: none 720p 1080p 2160p"
        ;;
esac

# vs. 8mbps CBR
#
# -- docker --
#
# 2160p:            86.546      3m26s
#
# 1080p (default):  92.471      1m25s
#      subsample 9  92.429      1m43s
#      subsample 19 92.452      1m38s
#      subsample 19 92.452      1m40s
#
# 1080p (bicubic):  92.260      2m26s
#      subsample 9  92.216      1m49s
#      subsample 19 92.239      1m45s
#
#
# -- local -- 
#
# 1080p (default)
#
# -hwaccel
#   cuda    
#       no sub          92.26       0m51s
#                                   0m51s
#       subsample 2     91.961      0m32s
#       subsample 9     92.216      0m22s
#       subsample 9                 0m22s
#       subsample 10    91.956      0m21s
#       subsample 19    92.239      0m20s
#       subsample 19                0m20s
#       subsample 90    91.797      0m19s
#
#   none    
#       no sub                      1m17s
#                                   1m16s
#       subsample 9     92.216      1m03s
#       subsample 19    92.239      1m02s
#       subsample 90    91.797      1m02s
#
#
# Testing VMAF threads...
#   cuda FF_THREADS=8 ...
#        THREADS=1 SUBSAMPLE=2        2m17s
#        THREADS=2 SUBSAMPLE=2        1m15s
#        THREADS=3 SUBSAMPLE=2        0m55s
#        THREADS=4 SUBSAMPLE=2        0m47s
#        THREADS=5 SUBSAMPLE=2        0m40s
#        THREADS=6 SUBSAMPLE=2        0m37s
#        THREADS=7 SUBSAMPLE=2        0m34s
#        THREADS=8 SUBSAMPLE=2        0m32s
#        THREADS=16 SUBSAMPLE=2  91.961    0m32s
#
#   cuda FF_THREADS=1 ...
#        THREADS=4 SUBSAMPLE=2        0m47s
#        THREADS=8 SUBSAMPLE=2        0m32s
#        THREADS=16 SUBSAMPLE=2       0m30s
#        THREADS=32 SUBSAMPLE=2       0m31s

[[ ! -z "$OPT_R" ]] && OPT_R+=","
[[ ! -z "$OPT_D" ]] && OPT_D+=","

# [1:v]scale=900:600:flags=bicubic,setpts=PTS-STARTPTS[distorted];\

LAVFI="[0:v]${OPT_R}setpts=PTS-STARTPTS[reference];\
       [1:v]${OPT_D}setpts=PTS-STARTPTS[distorted];\
       [distorted][reference]libvmaf=$VMAF_ARGS"

if [[ ${DRY:=0} -eq 0 ]]; then
	EXEC=""
else
	EXEC="echo"
fi

echo "# VMAF Parameters: model: $MODEL phone: $PHONE subsample: $SUBSAMPLE"
echo "# HWACCEL=$HWACCEL FF_THREADS=$FF_THREADS THREADS=$THREADS"

if [[ -e "$SCORE_FILE" ]]; then
    die "Existing score file is in the way: $SCORE_FILE"
fi

Q0=""
Q1="-hide_banner -nostats -loglevel warning"
Q2=""
QUIET="$Q2"

# QUIET="$Q1"

if [[ $LOCAL -eq 0 ]]; then

# Execute via docker

# -it argument for docker connects stdin of the terminal and has the 
# child allocate a tty.
# We only want to do this if we are running interactively at a terminal.
# We need to disable -it if we are running w/ make -j (parallel) since 
# that doesn't allocate a tty.
# So, unless the user has said otherwise, only enable TTYARG=-it if 
# we are running at a terminal.
if [[ -z "$TTYARG" ]] && [[ -t 0 ]]; then
	TTYARG=-it
	debug_1 "# running in a terminal"
else
	debug_1 "# NOT running in a terminal"
fi

# later: use --gpus all for nvidia acceleration
echo "# Executing via docker"
$EXEC docker run --rm $TTYARG -v "$PWD:$PWD" -w "$PWD" \
        --network none \
        -v "$c_ref:/work/$b_ref" \
        -v "$c_dst:/work/$b_dst" \
    $IMAGE \
    ${QUIET} -threads $FF_THREADS -y -nostdin -hwaccel $HWACCEL -fflags +igndts \
    -i "/work/$b_ref" \
    -i "/work/$b_dst" \
       $* \
    -lavfi "$LAVFI" \
    -f null - 

	RES=$?

else

echo "# Executing via local ffmpeg"
FFMPEG=${FFMPEG:=${PREFIX}/bin/ffmpeg}

echo "HERE"
# direct execution on current host.
$EXEC $FFMPEG -threads $FF_THREADS -y -nostdin -hwaccel $HWACCEL -fflags +igndts \
       ${QUIET} \
       -i "$c_ref" \
       -i "$c_dst" \
       -lavfi "$LAVFI" \
       -f null -

    RES="$?"
    # echo "RES: $RES"

fi

if [[ $RES -ne 0 ]]; then
    case $RES in 
        255) echo "Warning: VMAF script exiting due to interruption by user" ;;
        *)   echo "Warning: VMAF script exiting with status $RES" ;;
    esac
    [[ -e "$T_SCOREFILE" ]] && rm "$T_SCOREFILE"
    exit $RES
fi

if [[ ! -e "$T_SCOREFILE" ]]; then
    echo "WARNING: score file was not produced!"
    exit
fi

if [[ -e $SCORE_FILE ]]; then
    die "Score file is in the way: $SCORE_FILE"
fi
   
# we have to do a little dance if we have run this via docker, 
# since the score file will be owned by root.
cp "$T_SCOREFILE" "${T_SCOREFILE}-mv" \
    || die "Can't copy score tempfile"

mv -f "$T_SCOREFILE" "${T_SCOREFILE}.dead" && rm -f "${T_SCOREFILE}.dead" \
    || die "Can't move old score tempfile"

mv -f "${T_SCOREFILE}-mv" "${T_SCOREFILE}" \
    || die "Can't move old score tempfile into place"

mv -f "$T_SCOREFILE" "$SCORE_FILE"  \
    || die "Couldn't move score file into place"

# From FFMPEG's libvmaf filter documentation here:
#   https://ffmpeg.org/ffmpeg-filters.html#libvmaf
#
#
# The filter has following options:
# 
# model
# A ‘|‘ delimited list of vmaf models. Each model can be configured with a number of parameters. Default value: "version=vmaf_v0.6.1"
# 
# model_path
# Deprecated, use model=’path=...’.
# 
# enable_transform
# Deprecated, use model=’enable_transform=true’.
# 
# phone_model
# Deprecated, use model=’enable_transform=true’.
# 
# enable_conf_interval
# Deprecated, use model=’enable_conf_interval=true’.
# 
# feature
# A ‘|‘ delimited list of features. Each feature can be configured with a number of parameters.
# 
# psnr
# Deprecated, use feature=’name=psnr’.
# 
# ssim
# Deprecated, use feature=’name=ssim’.
# 
# ms_ssim
# Deprecated, use feature=’name=ms_ssim’.
# 
# log_path
# Set the file path to be used to store log files.
# 
# log_fmt
# Set the format of the log file (xml, json, csv, or sub).
# 
# n_threads
# Set number of threads to be used when initializing libvmaf. Default value: 0, no threads.
# 
# n_subsample
# Set frame subsampling interval to be used.
# 
# This filter also supports the framesync options.
