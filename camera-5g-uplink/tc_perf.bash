#!/usr/bin/env bash

VERSION=1.0.012

DEBUG=${DEBUG:=1}
AGG_DATA=${AGG_DATA:=1}

# whether to run disk transfer speed test using 'dd' to ensure our local SSD / caching 
# can keep up with requirements. Note that this will log the speeds but won't 
# prevent testing or throw an error.
DISK_TEST=${DISK_TEST:=1}

# 2024-09-10 <jonathan.lynam@ericsson.com>
#
# This script compares encoding performance between codecs. 
# so far it supports libx265 and hevc_qsv
# it runs through various presets (e.g. veryfast) as well as bitrates and resolutions.

# TODO:
#
#   the null/null/null problem. debug this...
#
#   /scratch/tmp/qsv/clip1-ss17_t10.1080.y4m, clip1-ss17_t10.1080.libx265.cbr_br5M_pre1.mp4, null, null, yuv420p/bt709/tv, null/null/null, 6093kB, 6239630, 86, 88.874311, 88.952784, 106.09, 4.65, 0:07.11, 1556
#   - play with -benchmark and -benchmark_all (see man ffmpeg)
#
#   - run with -re on the input and test the effects
#       (generally, more work to test realtime encoding performance and 
#        ensure it is realistic)
#       - run the input in realtime (source frame rate) 
#       - measure user & system time, extrapolate # of sessions possible
#
#   - David's HDR->SDR tonemap
#       @ implemented, 
#         just need to confirm it
#
#  @  - use 'dd' to measure read performance of the raw files from drive.
#   
#   - interesting white paper:
#       Why does 10-bit save bandwidth (even when content is 8-bit)?
#       (search online for it)

#
# This program attempts to perform a large number of video transcodes with different 
# parameters, and collect metrics about runtime performance and encoding efficiency.
#
# The script pre-decodes source clips to YUV (as .y4m files) so that decoding doesn't 
# affect runtime performance measurement. In so doing, the user can also choose to 
# modify resolution, frame rate, start/stop time, chroma subsampling, etc.
#
# This program automatically applies a naming format to the transcoded files
# and their related files, based on the source videos they are based on and the ffmpeg 
# parameters used to encode them.
#
# Some important considerations:
#   
# # Drive IO speed
#
#     Use an NVMe SSD. For raw 4K yuv420p 60fps video, you will need to transfer 
#     746,496,000 bytes/sec from the drive, at the same time as writing the output
#     encoded video. Here's the math:
#
#     Pixels [4K]           = 3840x2160 = 8,294,400 pixels
#     Pix_Format[YUV420p]   = 1.5 Bytes/pixel
#     Frames/sec            = 60
#
#     FYI: 
#       YUV420p = 1.5 Bytes/pixel
#       YUV422p =   2 Bytes/pixel
#       YUV444p =   3 Bytes/pixel
#
#     8,294,400 * 1.5 * 60 = 746,496,000 bytes/sec.
#
#     No known single HDDs can keep up with that speed. RAID arrays with 5+ drives might
#     be able to keep up. Even SATA SSDs max out at around 6Gbps = 750MB/sec 
#     in the best case.
#
#     Really the only options are 
#       1. NVMe SSD
#       2. in-memory filesystem (tmpfs)
#       3. get a machine with a lot of RAM and pray that the disk cache works well.
#
#     In case 2 or 3, figure on 1GB RAM per 1sec of video.
#
# parameters:
#
#   source:
#    -r     frame rate
#    -s     resolution
#    (complex) color mapping (hdr->sdr tonemap)
#
#   encode:
#    -preset   preset
#    -b:v      bitrate
#
#   <base>{_ss<ss>}{_t<duration>}{_r<num>}{.<reso>}{.<<encparam>>}.<extension>
#
#   encparam : {_br<bitrate>}
#            | {_crf<crf>}
#            ; {_pre<preset>}  (we put a - before preset if it's a string not a number)
#

# PRESET="veryfast faster fast medium slow slower veryslow"

# Considerations:
#  - we convert to RAW for the source of the encoding, so that decode time isn't important.
#  - source videos are all 2160
#  - we scale the video to 1080 / 720 when we convert to RAW so that it doesn't use CPU
#    (otherwise it will)
#  - you MUST run this on an SSD that can easily keep up w/ 250MB/sec transfer rate
#  - all VMAF scoring is done at the 1080p scale! So videos are up/down scaled for that.
#
#  - the presets are ordered inconsistently between encoders.
#
#                <-- Faster ----- Slower -->
#    hevc_qsv    7   6   5   4   3   2   1
#    libx265     0   1   2   3   4   5   6   7
#    hevc_nvenc  p1  p2  p3  p4  p5  p6  p7 
#
#      NVENC also has: slow(1) / medium(2) / fast(3) / hp(4)
#                      hq(5) / bd(6) / ll(7) / llhq(8) / llhp(9)
#                      lossless(10) / losslesshp(11)
#
#  - NYI: we don't care about the effect of fast vs. slow presets in the lossless 
#         encoding used for VMAF. when scored against a few clips, no VMAF 
#         score difference was noted.
#
# TODO:
#
#   - decide about whether to do
#       HDR => raw:HDR ref:HDR out:SDR, vmaf ref out 
#       vs. 
#       HDR => raw:HDR ref:SDR out:SDR, vmaf ref out
#
#   - probably need more generic way to handle the HDR / SDR questions. 
#     this will need some investigation and testing.
#
#   - it's not clear that all of the presets actually make any difference.
#     determine which presets are equivalent (with current HW/SW)
#
#   - doublecheck that 
#        (source => raw) (source => ll) (raw => transcode) (vmaf ll transcode)
#     gives the same result as
#        (source => ll) (source => transcode) (vmaf ll transcode)
#
#   - here's how to play a video on the fly:
#        ffmpeg -i rockCtr.mov -c:v hevc_nvenc -b:v 8M -f matroska pipe:1 | ffplay -i -

# NOTE:
# for decoding, this command line uses just 20% CPU for ffmpeg (instead of 1200%)
# ffmpeg -vsync 0 -hwaccel cuda -hwaccel_output_format cuda -c:v hevc_cuvid -i c1.mp4 -an -ss 0 -t 60 -c:v hevc_nvenc -b:v 10M o.mp4


######################################################################
######################################################################
#
# User Configurable Parameters 
# 
# The user can set (in their environment):
#
# $CODEC_LIST  - list of codecs to use
# $RESO_LIST   - list of resolutions to encode to
# $BR_LIST     - list of bitrates to encode at (for CBR rate control)
# $CRF_LIST    - list of CRF values to use (w/ CRF rate control)
#
# $RESULTS     - results CSV file where to collect output data.
#
# Note that any codecs that are not supported by ffmpeg or hardware 
# are skipped with a warning.
#

# output result .csv filename
RESULTS=${RESULTS:=results.csv}

# user can override the list of codecs
CODEC_LIST=${CODEC_LIST:=hevc_nvenc h264_nvenc hevc_qsv h264_qsv libx265}

# this is the list of resolutions we will iterate over.
RESO_LIST=${RESO_LIST:=1280:720 1920:1080 3840:2160}

# this is the list of bitrates we will iterate over for CBR encodes
BR_LIST=${BR_LIST:=1M 2M 5M 10M 15M 20M}

# this is a much smaller set of transcodes to do.
# this is just for quicker testing.
#
#    BR_LIST="5M"
#    RESO_LIST="1920:1080"

# the PRESET array will be used to define the presets that are
# available to each codec.
declare -A PRESET

# user can edit these presets if useful. this turns into the -preset option
PRESET[libx265]="0 1 2 3 4 5"
PRESET[h264_qsv]="7 6 5 4 3 2 1"
PRESET[hevc_qsv]="7 6 5 4 3 2 1"
PRESET[hevc_nvenc]="p1 p3 p7"
PRESET[h264_nvenc]="p1 p3 p7"

declare -A SUPPORTS_CRF
SUPPORTS_CRF[libx264]=1
SUPPORTS_CRF[libx265]=1

# only libx265 (or libx264) supports CRF encodes right now. 
# but this is the list of the ones that will be done if 
# libx265 is included.
CRF_LIST=${CRF_LIST:="8 12 16 20 24 28 32"}

######################################################################
######################################################################


######################################################################
#
# HDR -> SDR conversion filter.
#
# You can change this if you really know what you are doing. 
# When we have HDR source clips but want to transcode and compare 
# as SDR, we apply this filter to produce the raw YUV source file 
# before encoding and VMAF.
#
# the input videos we have are Apple HDR.
# after playing around with the settings for 15 minutes I came up with these.

VF_HDR_SDR="zscale=transfer=linear,tonemap=hable:peak=6:desat=1.2,zscale=transfer=bt709,format=yuv420p,colorspace=all=bt709"

######################################################################


function usage() {
cat << EOF
$(basename $0) - run batch encoding performance and efficiency tests.
Version: ${VERSION}

Note: this program is constructed such that to control it, you should edit 
certain test definition functions towards the bottom of this file. 
There are no useful command line parameters.

EOF
}

if [[ ! -z "$1" ]]; then
    case $1 in 
        -h|--help) 
            usage
            exit
        ;;
        *)
            echo "Unknown parameter: $1"
            exit
        ;;
    esac
fi

# from here there are various bash helper functions defined

if [[ -z ${TMPDIR} ]]; then
    for tdname in /scratch/tmp /tmp; do
        if [[ -d "$tdname" ]] && [[ -w "$tdname" ]]; then
            TMPDIR=${tdname}
            break
        fi
    done
fi
[[ ! -d $TMPDIR ]]  && die "Could not determine a temp directory. Please set \$TMPDIR correctly"

# we can use this prefix to make the 'temporary' version of any file that
# we want to write. This gives us a consistent naming pattern
T_PREFIX="$TMPDIR/.tc-perf-${VERSION}.$$"

# this is the temporary directory where all transcode files will be stored
# this will typically need hundreds of gigabytes of storage. 
# You probably don't want to put them on a filesystem that gets backed up, etc.
TMPDIR=${TMPDIR}/tc-perf_tmp
mkdir -p $TMPDIR
[[ ! -d $TMPDIR ]]  && die "Could not write to $TMPDIR"

# it only really works with this linux time program, NOT bash's builtin 'time'
TIME_PROG=/usr/bin/time

# are we running in a terminal / interactively?
function is_terminal() {
    [ -t 1 ];
}

function do_colors() {
    if is_terminal; then
        local colors=$(tput colors)
        if [[ ! -z "$colors" ]] && [[ "$colors" -ge 8 ]]; then
            true
            return
        fi
    fi
    false
}

function print_color() {
    local FG=4
    [[ ! -z "$2" ]] && FG="$2"

    if [[ ! -z "$1" ]]; then
        if do_colors; then
            FMT_B="$(tput bold)$(tput setaf $FG)$(tput setab 0)"
            FMT_E="$(tput sgr0)"
        else
            FMT_B="": FMT_E=""
        fi
        echo "${FMT_B}$1${FMT_E}"
    fi
}

function die() {
    print_color "# FATAL-ERROR: $1" 1 >&2
    exit 1
}

function debug_ex() {
    if [[ $DEBUG -ge $1 ]]; then
        print_color "## DEBUG-$1: $2" 4
    fi
}

function warn() {
    print_color "## WARNING: $1" 1
}

function debug_1() {
    debug_ex 1 "$1"
}

function debug_2() {
    debug_ex 2 "$1"
}

function info() {
    print_color "# INFO: $1" 2
}

function prompt() {
   echo "### Hit <Enter> to continue"
   read
}

# not used, but here for reference. 
# This will remove existing data files in the current directory.
function wipe_data() {
    rm *.size *.time *.vmaf.json *.encdata *.params *.xfer *.vmaf.json.gz
}

# use $FFMPEG if specified, else find the best one to use.
if [[ -z "${FFMPEG}" ]]; then
    l_path=/opt/t1ptop/bin:$PATH
    if FFMPEG=$(PATH=$l_path which ffmpeg 2>/dev/null); then
        debug_1 "Found ffmpeg at $FFMPEG"
    else
        die "Could not locate a working ffmpeg binary"
    fi
fi

which jq 1>/dev/null 2>/dev/null || die "This program requires the 'jq' tool to be installed."

# global FFMPEG options
# be careful when setting this.
FFMPEG_G_OPTS="-hide_banner"

# run the ffmpeg tool after logging the parameters. 
# note that $FFMPEG_G_OPTS should be added by the CALLER of this 
# function.
function ffmpeg() {
    debug_1 "about to run ffmpeg $*"
    ${FFMPEG} "$@"
}

# run_vmaf()
#
# run a vmaf computation and produce a score file in JSON format
# $1 : reference clip
# $2 : distorted clip
# $3 : JSON score output file
function run_vmaf() {
    # TODO:
    # really we should get it from the current tree where this 
    # script is located or installed to.
    for vmaf in /home/jlynam/bin/vmaf \
                /home/jlynam/trees/cloudgaming/sw/vmaf/docker/vmaf \
                none; do
        if [[ -x $vmaf ]]; then
            break
        fi
    done
    [[ vmaf == "none" ]] && die "Could not find VMAF tool to run"
    $vmaf "$1" "$2" "$3"
}

# probably any version would be ok. 
# but maybe in the future we should pick up the ffprobe from the same 
# place as the ffmpeg binary.
FFPROBE=${FFPROBE:=ffprobe}

# die with message $2 if $1 is empty.
function error_if_unset() {
    [[ -z "$1" ]] && die "$2"
}

# echo a filename prefixed by the $TMPDIR
function in_tmpdir() {
    [[ -d "$TMPDIR" ]] || die "\$TMPDIR is not set!"
    [[ -w "$TMPDIR" ]] || die "\$TMPDIR is not writable!"

    echo "$TMPDIR/$1"
}

# join a list of words (as args from $2) by the delimiter in $1
function join_by() {
    local delimiter="$1"; shift
    local joined="$1"; shift
    for element in "$@"; do
        joined+="${delimiter}${element}"
    done
    echo "$joined"
}

# Add a row to a CSV result file, automatically adding a header 
# row if this is a new or empty file.
#
# $1 : <filename>
# $* : {-<key> <value>}...
#
function add_row() {
    local out_fn="$1"; shift;
    local header=""
    local data=""
    local delim=", "
    local append=0

    if [[ -s "$out_fn" ]]; then
        append=1
    fi

    while [[ $# -gt 0 ]]; do
        local key="$1"
        local val="$2"
        local sh_amt=2

        case ${key} in 
            -*)
                key=${key:1}
                [[ ! -z "$header" ]] && header+="${delim}"
                header+="${key}"

                [[ ! -z "$data" ]] && data+="${delim}"
                data+="${val}"
            ;;
            *)
                die "Column name should be specified with leading '-'"
            ;;
        esac

        shift $sh_amt

    done

    # if the file doesn't exist or is empty...
    if [[ $append -eq 0 ]]; then
        # ... add the header row 
        echo "#${header}" >> "$out_fn" || die "Can't add header to output file: ${out_fn}"
    fi
    echo "${data}" >> "$out_fn" || die "Can't add row to output file ${out_fn}"
}

# Array to hold files to clean up when we exit
CLEANUP_FILES=()

# Function to add a file to the cleanup list
# dedup on insert
function cleanup_later() {
    while [[ $# -gt 0 ]]; do 
        found=0
        for fname in "${CLEANUP_FILES[@]}"; do
            if [[ "$fname" == "$1"  ]]; then
                found=1
                break
            fi
        done
        if [[ $found == 0 ]]; then
            CLEANUP_FILES+=("$1")
        fi
        shift
    done
}

# Function to clean up files at exit
function cleanup() {
    debug_1 "Cleaning up files..."

    for fname in "${CLEANUP_FILES[@]}"; do
        echo $fname
        if [[ -e $fname ]]; then
            debug_1 "  Removing $fname"
            # rm -f "$fname"
        fi
    done
    CLEANUP_FILES=()
}

# Trap EXIT signal to invoke cleanup function
trap cleanup EXIT

######################################################################
# From here we have the main processing functions of this script.

# clip_info() 
#
# Run ffprobe against the video stream of $1, output to JSON, then filter using jq 
# for the specified key, etc.
function clip_info() {
    ${FFPROBE} -show_streams -select_streams v -print_format json "$1" 2>/dev/null | jq -r ".streams[0].$2"
}

# parse_video_extension()
#
# separate the extension (like .mp4) of a video file from its base name.
# we could be more clever but we actually want to give an error for video
# files that we don't know how to work with.
function parse_video_extension() {
    local full="$1"
    local b_vn="$2"
    local e_vn="$3"
    local _local_ext=""

    case $full in
        *.mov) _local_base=${full%.mov}; _local_ext="mov" ;;
        *.mp4) _local_base=${full%.mp4}; _local_ext="mp4" ;;
        *.y4m) _local_base=${full%.y4m}; _local_ext="y4m" ;;
        *)
            die "Don't recognize the extension for: $full"
            ;;
    esac
    eval ${b_vn}=\"${_local_base}\"
    eval ${e_vn}=\"${_local_ext}\"
}

# ensure_sources()
#
# this is used to create the REF and RAW source files on-demand, so 
# we don't end up producing them while scanning through existing results.
# $RAW is a raw frame source, used for measuring performance of ffmpeg transcoding
# $REF is a lossless HEVC encode, used for VMAF comparison
#
# We have a little special handling for HDR clips (10-bit/12-bit bt2020, etc.)
# Again, we do this while producing the source clip as a raw file, so that we 
# don't spend CPU time to do this during the encode, since we are measuring 
# CPU execution time.
#
# TODO: take -sdr and -hdr "meta-parameters" to control whether to 
# convert an HDR clip to sdr (or check that a source is indeed HDR).
function ensure_sources() {
    local clip="$1"
    shift
    local src_opts

    if [[ ! -z "$*" ]]; then
        src_opts="$@"
    else
        src_opts=""
    fi

    # set -x
    # set -e

    # detect if the input clip needs color space conversion
    local color_space=$(clip_info "$clip" color_space)
    local     pix_fmt=$(clip_info "$clip" pix_fmt)

    local extra_conv=""

    debug_2 "Source color_space: $color_space pix_fmt: $pix_fmt"
    # debug_2 "Source options: $src_opts"

    case $pix_fmt in
        yuv420p)
            # regular 8-bit color / YUV420 subsampling
            true
            ;;
        yuv420p10le)
            # 10-bit color. It should also be bt2020nc color space
            case $color_space in
                bt2020nc)
                    extra_conv="-vf $VF_HDR_SDR"
                    extra_msg="(convert to SDR)"
                    #echo "Got here, want extra_conv: $extra_conv"
                ;;
                *)
                    die "I don't know how to handle pix_fmt $pix_fmt with color space $color_space"
            esac
            ;;
        *)
            die "Unknown/unhandled pixel format: '$pix_fmt'"
            ;;
    esac

    # TODO: get ${VF_HDR_SDR} filtering working again.
    if [[ ! -z "$REF" ]]; then
        if [[ ! -e "$REF" ]]; then
            info "Producing REF copy: $REF $extra_msg"
            local t_ref="${T_PREFIX}.REF.mp4"
            ffmpeg ${FFMPEG_G_OPTS} -i ${clip} ${src_opts} ${extra_conv} -an \
                    -c:v libx265 -x265-params lossless=1 -preset 0 $t_ref \
                    || die "Failed to produce $REF"
            mv $t_ref "$REF"
        else
            debug_2 "REF copy already exists: $REF"
        fi
    fi

    # due to some technical problems, we can't pass regular RAW files for VMAF comparison in 
    # docker. But we can instead transcode using RAW but compare using lossless.
    # Unfortunately, 'yuv420p10le' is not an official yuv4mpegpipe pixel format. 
    # Use '-strict -1' to encode to this pixel format.
    if [[ ! -z "$RAW" ]]; then
        if [[ ! -e "$RAW" ]]; then
            info "Producing RAW copy: $RAW $extra_msg"
            local t_raw="${T_PREFIX}.RAW.y4m"
            ffmpeg ${FFMPEG_G_OPTS} -i ${clip} ${src_opts} ${extra_conv} -an \
                    -strict -1 $t_raw \
                    || die "Failed to produce $RAW"
            mv $t_raw "$RAW"
        else
            debug_2 "RAW copy already exists: $RAW"
        fi
    fi

    set +x
    set +e
}

# ffmpeg_video_filename()
#
# based on a base name (prefix) and the encoding paramters, figure out an 
# appropriate name for a transcoded clip. It also parses some info into the
# arrays enc_params / src_params / sel_params.
#
# file name joining precedence:
# _ - .
#
function ffmpeg_video_filename() {
    local base="$1"; shift
    local codec; local rc; local reso

    unset enc_params; unset src_params; unset sel_params; unset pic_params

    declare -A enc_params src_params sel_params pic_params

    while [[ $# -gt 0 ]]; do
        opt="$1"; arg="$2"
        opt_f=${opt:1}

        case "$opt" in
            -s|\
            -vf)
                if [[ "$opt" = "-vf" ]]; then
                    case $arg in
                        scale=*)
                        reso=${arg:6}
                        abbr=""
                    esac
                else
                    reso=$arg
                fi
                case $reso in
                    3840:2160) abbr=2160;;
                    1920:1080) abbr=1080;;
                    1280:720)  abbr=720;;
                    *)
                      # any other 
                      die "Don't know abbreviation for resolution: $reso"
                esac
                src_params[reso]="$abbr"
                shift
                ;;
            -r)      src_params[fr]="fr$arg";  shift ;;

            -t)      sel_params[t]="t$arg" ;   shift ;;
            -ss)     sel_params[ss]="ss$arg" ; shift ;;

            -c:v)    codec="$arg"; shift ;;

            -b:v)     enc_params[br]=$(printf "br%s" $arg);     rc="cbr"; shift ;;
            -qp)      enc_params[qp]=$(printf "qp%02u"  $arg);  rc="cqp"; shift ;;
            -crf)    enc_params[crf]=$(printf "crf%02u" $arg);  rc="crf"; shift ;;

            -preset) 
                # if it starts with a p, trim it off.
                if [[ ${arg:0:1} == "p" ]]; then
                    arg=${arg:1}
                fi
                enc_params[pre]="pre$arg";  shift ;;

            -x265-params)
                # careful with this one, if we set something important to the output
                case $arg in
                    lossless=1) rc="ll"; shift ;;
                    *) die "Unknown option: $arg";;
                esac
                ;;
            -s)      src_params[res]="res-$arg"; shift ;;

            -colorspace|\
            -pix_fmt) 
                pic_params[$opt_f]="$arg"; shift ;;

            -strict|\
            -an)
            ;;
            *)  die "Warning: Unknown option $opt" ;;
        esac

        shift
    done

    # we'll just define HDR at bt2020 with yuv420p10le

    parts=""
    for key in reso fr; do
        parts+=" ${src_params[$key]}"
    done
    src_part=$(join_by _ $parts)

    parts=""
    for key in ss t; do
        parts+=" ${sel_params[$key]}"
    done
    sel_part=$(join_by _ $parts)

    parts="$rc"
    for key in ll br qp crf pre; do
        parts+=" ${enc_params[$key]}"
    done
    enc_part=$(join_by _ $parts)

    pic_part=""
    case ${pic_params[colorspace]} in
        bt709)   pic_part="sdr" ;;
        bt2020*) pic_part="hdr" ;;
        "")      
            info "colorspace not specified" >&2;
            ;;
        *)       pic_part="" 
            die "Unknown pic part; '${pic_params[colorspace]}'"
            ;; # unspecified, usually same as src
    esac
    # info pic_part=$pic_part >&2

    local root=$(join_by - $base $sel_part)

    local X=$(join_by . $root $src_part $codec $enc_part $pic_part)

    echo "$X"
}

# process_clip()
#
# transcode and VMAF score a clip and record VMAF score and execution time
#
# -src <file> : source (input) video
# -out <file> : output (transcoded) filename
# -ref <file> : file for VMAF reference (defaults to -src file)
# -id  <text> : ID field to add to the output
#
# This does the main work of 
#   - reading in the source clip, hoping it stays in the filesystem cache.
#     (and we test the performance to ensure the disk isn't too slow)
#
#   - transcoding the video using specified encoding parameters into the
#     <out> file.
#
#   - capture execution performance info using /usr/bin/time
#
#   - run VMAF with <ref> as reference, <out> as distorted.
#     If -ref wasn't specified, it will be the source. Note that 
#     running VMAF in docker there is a docker limitation that blocks us 
#     from using YUV raw files as reference. It's ugly.
#
#   - write a row to the $RESULTS file.
#
# Most/all of these steps are skipped if they have already run before.
# There is /some/ checking to see if some parameters have changed, just 
# for a sanity check.
#
function process_clip() {
    [[ -d "$TMPDIR" ]] || die "\$TMPDIR is not set!"
    [[ -w "$TMPDIR" ]] || die "\$TMPDIR is not writable!"

    local id_val="\"\""

    while [[ $# -gt 0 ]]; do
        local opt="$1"
        local arg="$2"
        case $opt in 
            -id)
                id_val="$arg"; shift
            ;;
            -src) 
                ivid="$arg"; shift
            ;;
            -ref) 
                rvid="$arg"; shift
            ;;
            -out)
                ovid="$arg"; shift
            ;;
            --)
                # what follows are ffmpeg encoding options...
                shift
                # echo "remaining params: $@"
                o_params="$@"
                break
                ;;
            *)
                die "Unrecognized option: $opt"
                ;;
        esac
        shift
    done

    [[   -z "$ivid" ]] && die "Source clip wasn't specified (use -src)"
    [[ ! -e "$ivid" ]] && die "Source clip $CLIP doesn't exist"
    [[ ! -r "$ivid" ]] && die "Source clip $CLIP is not readable"

    # use the source video as reference if not specified.
    [[ -z "$rvid" ]]  && rvid="$ivid"

    debug_2 "ID:  $id_val"
    debug_2 "encode params: $o_params"
    debug_2 "src: $ivid"
    debug_2 "ref: $rvid"
    debug_2 "out: $ovid"
    # prompt

    local do_conversion=false

    # ivf - input video file to be used for performance-timed encoding.
    local ivf

    # ovf - output video file produced by encoding the input file.
    local ovf
    local rvf=$rvid

    # name of video clip w/o extension
    parse_video_extension $ivid ivid_base ivid_ext

    parse_video_extension $ovid ovid_base ovid_ext
    ovid_base=$(basename $ovid_base)

    # base name for output files

    if $do_conversion; then
        # echo "o_params: $o_params"
        src_opts=$(source_options $o_params)
        # echo "src_opts: $src_opts"

        local ref_prefix=$(ffmpeg_video_filename "$ivid_base" $src_opts)

        REF="$TMPDIR/${ref_prefix}-src.ll_pre0.mp4"
        RAW="$TMPDIR/${ref_prefix}-src.y4m"

        # info "$ivid RAW = $RAW"
        # info "$ivid REF = $REF"

        ensure_sources "$ivid" $o_params
        ivf="$RAW"
    else
        ivf="$ivid"
    fi

    # actual video output filename
    ovf="${ovid}"

    local pfile="${ovid_base}.params"   ; # parameters
    local rfile="${ovid_base}.time"     ; # output from /bin/time
    local sfile="${ovid_base}.encdata"  ; # ffmpeg encoding log
    local zfile="${ovid_base}.size"     ; # file size
   local vgfile="${ovid_base}.vmaf.json.gz"  ; # VMAF score, gzipped
    local xfile="${ovid_base}.xfer"     ; # time to load from disk
    local yfile="${ovid_base}.ffprog"   ; # ffmpeg progress file

    # for many of these, we need tempfiles first, then move into place.
    local t_rfile="$T_PREFIX.${rfile}"
    local t_sfile="$T_PREFIX.${sfile}"
    local t_vfile="$T_PREFIX.${ovid_base}.vmaf"
    local t_xfile="$T_PREFIX.${xfile}"
    local t_yfile="$T_PREFIX.${yfile}"
    local   t_ovf="$T_PREFIX.$(basename $ovid)"

    # prompt

      # this is insurance against producing the same file with different sets of parameters.
      # we will save the parameter data and source file path. If the contents of this file
      # differs from a previous run, we know we would need to re-run. But we'll just
      # give the user a fatal error so they clean up the old file(s).
      # It also acts as a 'sentinel' telling us the work has been done before, so we 
      # can skip it the next time we run.
param_data="version=1
source=$ivf
output=$ovf
parameters=$o_params"

    if [[ -e "$pfile" ]]; then
        # if the parameter file exists, it better have the same options!
        ex_param_data=$(cat $pfile)
        if [[ "$ex_param_data" != "$param_data" ]]; then
            die "Existing parameters for this file differ from current run! File: $pfile"
        fi
    fi

    if [[ ! -e "$pfile" ]]; then
        local redo

        if [[ ! -e $ovf ]]; then
            debug_2 "Initial encode of $ovf"
            redo=1
        else
            redo=0
            # main output file already exists, but,
            # if any of these files are missing, we will re-do.
            for fname in $ovf $rfile $sfile $vgfile $xfile; do
                if [[ ! -e $fname ]]; then
                    debug_1 "Missing $fname, will re-encode"
                    redo=1
                    break
                fi
            done
        fi

        if [[ ${redo} -eq 1 ]]; then

            # since we are doing performance testing, we want to first 
            # put the source video into cache. as much as possible.
            # so, we will use 'dd' to read all the data...
            if [[ $DISK_TEST -eq 1 ]]; then
                debug_2 "About to read source file from disk... "
                # do it twice so that we can see the 2nd one is all cache...
                dd bs=10M of=/dev/null if=${ivf} 2>&1 | tail -n 1 >  ${t_xfile}
                dd bs=10M of=/dev/null if=${ivf} 2>&1 | tail -n 1 >> ${t_xfile}
                local xfer_speed=$(cat ${t_xfile} | cut -d ' ' -f 10-11)
                debug_1 "Transfer rate: $(echo $xfer_speed)"
            else
                echo "Skipped" > ${t_xfile}
            fi

            export FFREPORT=file=$t_sfile:level=40

            local fullopt="${FFMPEG_G_OPTS} -nostats -progress ${t_yfile} -i ${ivf} ${o_params} ${t_ovf}"

            info "Encoding: $ovf"
            debug_1 "RUN ffmpeg ${fullopt}"

            # X=${fullopt}
            # P="$T_PREFIX." /scratch"; NP=${P/\//\\/}; echo "$NP"; echo ${X/$NP/}
            # echo "New X: ${X/$NP/}"
            
            # unfortunately running /usr/bin/time means that ffmpeg can't 
            # just be a simple bash function (which would take care of logging, etc.)

            # /usr/bin/time format specifiers:
            #  %e - real time
            #  %U - user time
            #  %S - sys time
            #  %P - percentage of CPU (user + sys)/real
            ${TIME_PROG} -o ${t_rfile} \
                       -f "%e, %U, %S, %P" \
                ${FFMPEG} ${fullopt} || \
                    die "ffmpeg exited with code $?"

            [[ -e $t_sfile ]] || die "FFMPEG report file wasn't produced: $t_sfile"
            [[ -e $t_rfile ]] || die "run time file wasn't produced: $t_rfile"

            mv "$t_sfile" "$sfile"
            mv "$t_rfile" "$rfile"
            mv "$t_xfile" "$xfile"
            mv "$t_yfile" "$yfile"
            mv "$t_ovf"   "$ovf"

            du --apparent-size -b "$ovf" | cut -f 1 > ${zfile}
        fi

        if [[ ! -e $vgfile ]]; then
            # NOTE: we are doing all scoring vs. a theoretical 1080p source.
            # so this will normally up/down scale both the ref and dst to 1080p
            SCALE=1080p run_vmaf $rvid $ovf $t_vfile || die "VMAF failed"
            [[ -e $t_vfile ]] || die "VMAF didn't produce score file. Expected $t_vfile"
            cat "$t_vfile" | gzip > $vgfile || die "Can't gzip VMAF score to $vgfile"
        fi
        [[ -e $vgfile ]] || die "VMAF (gzipped) score file is not present!"

        echo "$param_data" > $pfile
    fi
    local b_ovf=$(basename $ovf)

  if [[ $AGG_DATA -eq 1 ]]; then
    # only write results into the output file if $AGG_DATA is enabled

    # basics about the output video stream
     local reso_h=$(clip_info "$ovf" height)
     # local reso_w=$(clip_info "$ovf" width) ; # not used
     local frame_cnt=$(clip_info "$ovf" nb_frames)
     local frame_rat=$(clip_info "$ovf" avg_frame_rate); frame_rat=${frame_rat/\/*/}
     local duration=$(clip_info "$ovf" duration)

     if [[ $frame_rat -ne 60 ]]; then
        die "Invalid frame rate for '$ovf'. $frame_rat"
     fi

    # color and pixel format info.
     local sf_color=$(clip_info $rvf pix_fmt)/$(clip_info $rvf color_space)/$(clip_info $rvf color_range)
     local of_color=$(clip_info $ovf pix_fmt)/$(clip_info $ovf color_space)/$(clip_info $ovf color_range)

    # extract VMAF statistics by parsing the JSON output
     local vmaf_hmean=$(zcat "$vgfile" | jq '.pooled_metrics.vmaf.harmonic_mean')
     local  vmaf_mean=$(zcat "$vgfile" | jq '.pooled_metrics.vmaf.mean')

     # local encfps=$(cat $sfile | grep fps= | sed 's/\(.*\)fps=\([ 0-9]\+\)\(.*\)/\2/' | tail -n 1)
     
     # this doesn't work on fast machines. The last update goes to fps=0.0
     # local encfps=$(cat $sfile | grep fps= | tail -n 1 | sed 's/\(.*\)fps= *\([0-9\.]\+\) \(.*\)/\2/')
     # local encfps=$(echo $encfps) ; # remove padding

     # NEW: get the fps from the progress file.
     # argh. even this way still ends up with fps=0.0. We can get speed= instead.
     local encfps=$(cat ${yfile} | grep 'fps='   | tail -n 1 | sed 's/^fps= *\([0-9\.]\+\)/\1/')
     local encspd=$(cat ${yfile} | grep 'speed=' | tail -n 1 | sed 's/^speed= *\([0-9\.]\+\)/\1/')
     local encfps2=$(echo "${encspd/x/} * ${frame_rat}" | bc -l)

     # encoded file size in bytes.
     local size_B=$(cat $zfile)
     # note in ffmpeg/video rate terms, a kilobit is 1000 bits.
     local rate_kbps=$(echo "(($size_B * 8) / $duration) / 1000" | bc -l)
     rate_kbps=$(printf %.2f $rate_kbps)

     # echo "size_B = ${size_B} , duration=${duration}"
     # echo "RATE: ${rate_kbps}kbps"

     # this was for human-readable size reported by ffmpeg encoding output.
     # it doesn't differ in any interesting way from the byte count.
     # size=$(cat $sfile | grep Lsize= | sed 's/.*Lsize= *//' | sed 's/ .*//g')
     # local size=$(stat -c %s $ovf)

     # execution performance
     # time info is already Real(%e), User($%U), Sys(%S), Cpu%(%P)
     # this uses a 'here string' to stay in the same shell so we can access the variables.
     r_info=$(cat $rfile)
     # get rid of the inline commas
     read time_w time_u time_s cpu <<< ${r_info//,/}

     info "Result: [Id] ${id_val}"
     info "        [file] ${b_ovf}"
     info "        [Perf] user: $time_u sys: $time_s wall: $time_w cpu: $cpu"
     info "               FPS: ${encfps} (${encspd} of ${frame_rat}) VMAF: ${vmaf_hmean}"
    
     # info "[$b_ovf] $codec-$pre $br ($reso_w:$reso_h) => size=$size_B encfps=$encfps vmaf=$vmaf_mean"

     add_row "$RESULTS" \
        -id "$id_val" \
        -src_vid_file "$ivid" -dst_vid_file "$b_ovf" \
        -resolution "$reso_h" -frame_cnt "$frame_cnt" \
        -src_color "$sf_color" -dst_color "$of_color" \
        -size_B "$size_B" -rate_kbps "${rate_kbps}" \
        -enc_fps "$encfps" -enc_fps2 "$encfps2" -enc_speed "$encspd" \
        -vmaf_h "$vmaf_hmean" -vmaf_m "$vmaf_mean" \
        -time_usr "$time_u" -time_sys "$time_s" -time_wall "$time_w" \
        -cpu_load "$cpu"

  fi
  # sync
  # exit

}

# avail_codecs()
#
# test what codecs are supported in the ffmpeg build as well as the hardware.
# filter out the ones that are not available.
function avail_codecs() {
    local n_codec_list=""

    for codec in $*; do
        supported=1

        # check if it's supported in this ffmpeg build...
        if ${FFMPEG} -codecs 2>/dev/null | grep -q $codec; then
            debug_2 "Codec $codec supported in ffmpeg ($FFMPEG)"
        else
            warn "Codec $codec not supported inthis ffmpeg ($FFMPEG)"
            supported=0
        fi

        if [[ $supported == 1 ]]; then
            # check if it is supported in this system's hardware
            case $codec in
                *qsv*)
                    debug_2 "QSV codec: $codec"
                    # ensure that this codec is present and HW device supports it.
                    if ${FFMPEG} -init_hw_device qsv:hw 2>&1 | grep -q "Device creation failed" ; then
                        supported=0
                        warn "Codec $codec not supported in this system's hardware"
                    fi
                ;;
                *nvenc*)
                    debug_2 "NVEnc codec: $codec"
                    # ensure that this codec is present and HW device supports it.
                    if ${FFMPEG} -init_hw_device cuda:0 2>&1 | grep -q "Device creation failed" ; then
                        supported=0
                        warn "Codec $codec not supported in this system's hardware"
                    fi
                ;;
                *)
                    debug_2 "other codec: $codec" 
                ;;
            esac
        fi

        # see if it's in the ffmpeg build.
        if [[ $supported == 1 ]]; then
            debug_1 "Codec $codec is supported"
            n_codec_list="$n_codec_list $codec"
        else
            # warn "Codec $codec is NOT supported"
            false
        fi
    done
    CODEC_LIST="$n_codec_list"
}
avail_codecs $CODEC_LIST

# old technique for checking codec support: just look at the hostname...
#   case $(hostname) in
#       tugboat|\
#       trireme)
#           echo "Can't run QSV on $(hostname)"
#           CODEC_LIST="hevc_nvenc libx265 h264_nvenc"
#           ;;
#   esac

# encode_clip()
#
# Usage: <clip> <source-options>... '--' <encode-options>...
#
# This prepares the source clip for transcoding. Usually this means 
# dumping to a raw YUV format (so that we don't need to decode during 
# a performance test) also applying the "source options" (e.g. -ss / -to, etc.)
# which control what does into the source video segment.
#
# Note we separate the source options from the encode options using --
#
function encode_clip() {
    local clip="$1"; shift

    # echo "Input clip: $clip"
    local base ext;

    local source_opts=""
    local encode_opts=""
    local state=0
    local id_val="E"

    # separate the <source-options> before the -- vs. 
    # <encode-options> after it.
    while [[ $# -gt 0 ]]; do
        # debug_2 "encode opt: $1 arg $2"
        if [[ "$1" = "--" ]]; then
            state=1
        elif [[ "$1" == "-id" ]]; then
            id_val="$2"
            shift 2
            continue
        else
            case $state in
                0) source_opts="$source_opts $1" ;;
                1) encode_opts="$encode_opts $1" ;;
            esac
        fi
        shift
    done

    parse_video_extension $clip base ext


    # here we figure out about HDR vs. SDR and set the colorspace 
    # explicitly.
    # likely, we could do any of the following
    #   src-HDR => ref-HDR dst-HDR 
    #   src-HDR => ref-HDR dst-SDR (if VMAF supports this?)
    #   src-HDR => ref-SDR dst-SDR
    #
    # for this minute, we're only doing HDR => SDR or keeping as SDR.
    #
    source_opts="$source_opts -pix_fmt yuv420p -colorspace bt709"
    encode_opts="$encode_opts -pix_fmt yuv420p -colorspace bt709"

    # we will produce the RAW and REF clips used as the source
    # for the encoding performance and VMAF testing in process_clip().
    local subc=$(ffmpeg_video_filename $base $source_opts)
    [[ -z $subc ]] && die "Couldn't produce filename for source video file"

    RAW=$(in_tmpdir ${subc}.y4m)
    REF=$(in_tmpdir ${subc}.ll.mp4)

    local ofn=$(ffmpeg_video_filename $subc $encode_opts)
    [[ -z $ofn ]] && die "Couldn't produce filename for encoded output file"
    OUT=$(in_tmpdir ${ofn}.mp4)

    info "##################################################"
    info "[clip: $clip] "
    info "  source options: $source_opts"
    info "  encode options: $encode_opts"
    debug_1 "REF: $REF"
    debug_1 "RAW: $RAW"
    debug_1 "OUT: $OUT"

    cleanup_later $RAW $REF

    ensure_sources $clip $source_opts

    process_clip -id "${id_val}" -src "$RAW" -ref "$REF" -out "$OUT" -- $encode_opts 
}

# TODO: probably don't need this anymore.
# take all options and only return the ones that relate to the source video.
# e.g., -ss ... -t ... -r ... -vf scale=1920:1080
function source_options() {
    local src_options=""
    local add;

    while [[ $# -gt 0 ]]; do
        opt="$1"; arg="$2"
        add=0;
        # echo "SO opt: $opt arg: $arg" >&2

        case $opt in
            -vf|\
            -ss|\
             -r|\
             -s|\
             -t)
                src_options+=" ${opt} ${arg}"
                shift
                ;;
            *)
                # echo "unknown option" >/dev/stderr
                shift
            ;;
        esac
        shift
    done
    echo "$src_options"
}

# perf_test()
#
# this function exists just to add any extra needed hacks around
# processing a clip. it also cleans up tempfiles relevant to only
# one source segment.
# Here we handle automatic cleanup of tempfiles per clip.
function perf_test() {
    clip="$1"
    shift

    [[ -r "$clip" ]] || die "Clip $clip is not readable"

    run_encoding_tests "$clip" "$@"

    cleanup
}

# run_encoding_tests()
#
# This function specifies the encoding & scoring work to be done at a 
# high level. The input is always a real original source file and 
# (usually) some additional selection parameters for specifying a segment 
# to process from within the file, e.g. -ss / -t / -to  (etc.). 
#
# In principle, you could also add filters, etc. though it might not 
# all work out at the moment.
#
# Users can customize this function as needed to add new types of tests.
#
function run_encoding_tests() {
    # these would define the input clip...
    # CLIP
    # SS
    # T

    # now all of the standard transcodes to run.

    local reso
    local clip="$1"; shift
    [[ -z "$clip" ]] && die "Clip not specified"
    local src_opts="$@" ; # other ffmpeg options to apply to input clip
                          # to create the source video.

    for reso in $RESO_LIST; do
        # CBR encodes first.
        for br in $BR_LIST; do
            for codec in $CODEC_LIST; do
                for pre in ${PRESET[$codec]}; do
                    encode_clip "${clip}" -id "${codec}-${pre}-${br}" -s $reso ${src_opts} -- -c:v ${codec} -b:v ${br} -preset ${pre}
                done
            done
        done

        # CRF encodes
        for codec in $CODEC_LIST; do
            local support="${SUPPORTS_CRF[$codec]}"
            # echo "SUPPORT crf: $codec $support"
            [[ "$support" == "1" ]] || continue
            info "### $codec supports CRF"
            for crf in $CRF_LIST; do
                [[ "$crf" == "none" ]] && break
                # JAL: TODO: iterate libx265 presets w/ CRF.
                encode_clip "${clip}" -id "${codec}-crf-${crf}" -s $reso ${src_opts} -- -c:v ${codec} -crf ${crf}
            done
        done
    done

}

# main() 
#
# runs execution performance and VMAF scoring against specified sources
function main() {

    # clear out results file. 
    # For any job that has already been run, it's pretty cheap to re-write the data 
    # since we save the results.
    echo -n "" > $RESULTS

    # CLIPS TO PROCESS
    #
    # this runs 'perf_test' (which executes all encoding and VMAF jobs) agaist the 
    # specified clips (with optional sub-segments specified using -t and -ss, etc.)

    # perf_test  clip2.mov
    # perf_test  clip3.mov
    # perf_test  clip4.mov

  if false; then
    # this grouping is used for testing how much performance increases 
    # for longer clips. With some codecs there is a very noticeable effect.

    perf_test  clip1.mov -t  5 -ss 0
    perf_test  clip1.mov -t 10 -ss 0
    perf_test  clip1.mov -t 15 -ss 0
    perf_test  clip1.mov -t 20 -ss 0
    perf_test  clip1.mov -t 25 -ss 0
    perf_test  clip1.mov -t 30 -ss 0

    perf_test  clip1.mov

  fi

  if true; then
    perf_test  clip1.mov -t 10 -ss 0
    perf_test  clip1.mov -t 10 -ss 10
    perf_test  clip1.mov -t 10 -ss 17

    perf_test  clip2.mov -t 10 -ss 0
    perf_test  clip2.mov -t 10 -ss 10
    perf_test  clip2.mov -t 10 -ss 20

    perf_test  clip3.mov -t 10 -ss 0
    perf_test  clip3.mov -t 10 -ss 10
    perf_test  clip3.mov -t 10 -ss 20

    perf_test  clip4.mov -t 10 -ss 0
    perf_test  clip4.mov -t 10 -ss 10
    perf_test  clip4.mov -t 10 -ss 20
    perf_test  clip4.mov -t 10 -ss 30
  fi

}

main
