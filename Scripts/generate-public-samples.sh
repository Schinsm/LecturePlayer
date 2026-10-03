#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Samples
ffmpeg -y -v error -f lavfi -i testsrc2=size=640x360:rate=30 -t 12 -c:v libx264 -pix_fmt yuv420p -map_metadata -1 Samples/Synthetic.mp4
ffmpeg -y -v error -i Samples/Synthetic.mp4 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=12 -c:v copy -c:a aac -shortest -map_metadata -1 Samples/SyntheticAudio.mp4
