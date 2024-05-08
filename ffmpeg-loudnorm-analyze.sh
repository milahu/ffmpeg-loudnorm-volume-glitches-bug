#! /usr/bin/env bash

# ffmpeg-loudnorm-analyze.sh

# first pass of ffmpeg loudnorm filter

# analyze loudness of audio streams
# write result to stdout in json format
# keyed by loudnorm result ID
# {"0":{"input_i":"-33.04",...},"1":{...}}

# note: you may want to downmix first to 2ch audio
# to use the final volume of the center channel
# example ffmpeg args:
# -c ac3 -b:a 192k -vol 425 -strict -2 -af "pan=stereo|FL=0.8*FC+0.6*FL+0.6*BL+0.6*SL+0.5*LFE|FR=0.8*FC+0.6*FR+0.6*BR+0.6*SR+0.5*LFE"
# https://superuser.com/a/1420109/951886

# note: multiple similar files can have different volumes
# to normalize all files in a directory
# get the volume profile of all files
#   # printf "file %q\n" *.mp3 >000.mp3.list && ffmpeg -f concat -i 000.mp3.list -c copy 000.mp3
#   cat *.mp3 >all-mp3-joined && mv all-mp3-joined 000.mp3
#   ffmpeg-loudnorm-analyze.sh 000.mp3

# TODO verify ffmpeg output format: Parsed_loudnorm_([0-9]+)

# TODO when is normalization not needed?
# is this good or bad:
# "target_offset" : "0.18"

set -e
set -u

input_file="$1"
shift

output_base="${input_file#.*}"

# extra args. examples:
# -map 0:a:0 # process only the first audio stream
# -to 10 # process only the first 10 seconds
#extra_args=("$@")

# parse extra args
audio_track= # all audio streams
ffprobe_streams=a # all audio streams
while [ $# != 0 ]; do case "$1" in
  -map)
    if ! echo "$2" | grep -q -E -x '0:a:[0-9]+'; then
      echo "error: unrecognized map argument: ${2@Q}. expected something like 0:a:0 or 0:a:1"
      exit 1
    fi
    ffprobe_streams="${2:2}" # 0:a:0 -> a:0
    audio_track="${2:4}" # 0:a:0 -> 0
    shift 2
    continue
    ;;
  *)
    echo "error: unrecognized argument: ${1@Q}"
    exit 1
    continue
    ;;
esac; done



# https://ffmpeg.org/ffmpeg-filters.html#loudnorm

# ffmpeg-normalize/ffmpeg_normalize/_media_file.py
# _first_pass

# ffmpeg-normalize/ffmpeg_normalize/_ffmpeg_normalize.py
#         target_level: float = -23.0,
#         loudness_range_target: float = 7.0,
#         true_peak: float = -2.0,
#         offset: float = 0.0,

# ffmpeg-normalize/ffmpeg_normalize/_streams.py
#         opts = {
#             "i": self.media_file.ffmpeg_normalize.target_level,
#             "lra": self.media_file.ffmpeg_normalize.loudness_range_target,
#             "tp": self.media_file.ffmpeg_normalize.true_peak,
#             "offset": self.media_file.ffmpeg_normalize.offset,
#             "print_format": "json",
#         }

loudnorm_i=-14.0 # max integrated
loudnorm_lra=7.0 # loudness range. Range is 1.0 - 50.0. Default value is 7.0
loudnorm_tp=-2.0 # true peak

loudnorm_offset=0.0
loudnorm_linear=true

# TODO verify extra_args for ffprobe

channel_layout_list=($(
  #ffprobe -loglevel error -select_streams $ffprobe_streams -show_entries stream=channel_layout -of default=nw=1:nk=1 "$input_file"
  ffprobe -loglevel error -select_streams a -show_entries stream=channel_layout -of default=nw=1:nk=1 "$input_file"
))

if [ ${#channel_layout_list[@]} = 0 ]; then
  echo "error: no audio streams"
  exit 1
fi

#if [ ${#channel_layout_list[@]} = 1 ]; then
#  has_multiple_audio_tracks=false
#else
#  has_multiple_audio_tracks=true
#fi
has_multiple_audio_tracks=true # always add the ".a0" extension for single audio stream

if [ -n "$audio_track" ]; then
  # use one audio track
  audio_track_list=("$audio_track")
else
  # use all audio tracks
  audio_track_list=(${!channel_layout_list[@]})
fi

echo "audio_track_list: $audio_track_list"

#for (( audio_track = 0; audio_track < ${#channel_layout_list[@]}; audio_track++ )); do
for audio_track in "${audio_track_list[@]}"; do

  channel_layout="${channel_layout_list[$audio_track]}"

  echo "audio stream $audio_track: channel layout $channel_layout"

  s=""
  if [ "$channel_layout" != "stereo" ] && [ "$channel_layout" != "mono" ]; then
    downmix_filter=$(~/src/milahu/random/ffmpeg/downmix-audio-to-stereo-rfc7845.py "$channel_layout")
    if [ -z "$downmix_filter" ]; then
      echo "error: no downmix filter for channel layout $channel_layout"
      continue
    fi
    s+="$downmix_filter",
  fi

  s+="loudnorm="
  s+="i=$loudnorm_i:"
  #s+="I=$max_integrated:"
  s+="lra=$loudnorm_lra:"
  #s+="LRA=$loudnorm_LRA:"
  s+="tp=$loudnorm_tp:"
  s+="offset=$loudnorm_offset:"
  s+="linear=$loudnorm_linear:"
  s+="print_format=json:"
  filter_a="${s:0: -1}"
  echo "filter_a: $filter_a" >&2

  volume_json="$(
    #ffmpeg -hide_banner -loglevel error -i "$input_file" -pass 1 "${extra_args[@]}" \
    ffmpeg -hide_banner -i "$input_file" -pass 1 "${extra_args[@]}" \
      -filter:a "$filter_a" -vn -sn -f null -y /dev/null 2>&1 |
    tee -a /dev/stderr |
    grep -E '^\[Parsed_loudnorm_([0-9]+) @ 0x[0-9a-f]+\]' -A12 |
    sed 's/\t/    /g' |
    perl -0777 -pe 's/}\s+\[Parsed_loudnorm_([0-9]+) @ 0x[0-9a-f]+\]\s+/  },\n  "$1": /g' |
    perl -0777 -pe 's/\[Parsed_loudnorm_([0-9]+) @ 0x[0-9a-f]+\]\s+/  "$1": /g' |
    sed 's/^}/  }/' |
    sed '1 i\{'
    printf '}\n';
  )"

  if $has_multiple_audio_tracks; then
    volume_json_path="$output_base.a$audio_track.volume.json"
  else
    volume_json_path="$output_base.volume.json"
  fi

  echo "$volume_json" > "$volume_json_path"

done
