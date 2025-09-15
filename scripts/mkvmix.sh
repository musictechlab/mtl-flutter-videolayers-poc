#!/usr/bin/env bash
set -euo pipefail

OUTPUT="output.mkv"

ffmpeg -y \
  -i "media/Big_Buck_Bunny_1080_10s_1MB.mp4" \
  -i "media/Jellyfish_1080_10s_1MB.mp4" \
  -i "media/ES_Indoor, Walla, Deep Voice - Epidemic Sound.mp3" \
  -i "media/ES_When the Ice Melts - Isobelle Walton.mp3" \
  -i "media/subtitle.srt" \
  -loop 1 -framerate 30 -t 10 -i "media/sample_image.jpg" \
  -attach "media/sample_image.jpg" \
  -metadata:s:t mimetype=image/jpeg \
  \
  -filter_complex "[2:a]volume=5.0[a2];[a2][3:a]amix=inputs=2:duration=longest[aout]" \
  \
  -map 0:v -map 1:v -map 5:v \
  -c:v:0 copy \
  -c:v:1 copy \
  -c:v:2 libx264 -pix_fmt yuv420p -r 30 \
  \
  -map "[aout]" -c:a aac \
  -map 4:s -c:s srt \
  \
  -metadata:s:v:0 title="Big Buck Bunny" \
  -metadata:s:v:1 title="Jellyfish" \
  -metadata:s:v:2 title="Image Layer" \
  -metadata:s:a:0 title="Mixed Dialogue + Music" \
  -metadata:s:s:0 title="English Subtitles" \
  -metadata:s:t:0 title="Sample Image (attachment)" \
  "$OUTPUT"