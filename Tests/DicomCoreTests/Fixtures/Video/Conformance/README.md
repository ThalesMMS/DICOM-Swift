# Video profile and level fixtures (issue #2905)

Four-frame 128×64 `testsrc` streams (the Blu-ray one is two 1280×720 grey frames at 50 frames/s) written by the
local ffmpeg 9.0.1 with libx264, libx265 and the native mpeg2video encoder. Synthetic, no PHI. Regenerate with:

```bash
ff() { ffmpeg -y -f lavfi -i testsrc=size=128x64:rate=25 -frames:v 4 -pix_fmt yuv420p -g 4 -bf 0 "$@"; }
ff -c:v mpeg2video -profile:v 4 -level:v 10 mpeg2-mp-ll.m2v   # Main Profile, Low Level
ff -c:v mpeg2video -profile:v 4 -level:v 8 mpeg2-mp-ml.m2v    # Main Profile, Main Level
ff -c:v mpeg2video -profile:v 4 -level:v 4 mpeg2-mp-hl.m2v    # Main Profile, High Level
ff -c:v mpeg2video -profile:v 1 -level:v 4 mpeg2-hp-hl.m2v    # High Profile, High Level
ff -c:v libx264 -profile:v high -level:v 4.1 h264-high-41.h264
ff -c:v libx264 -profile:v high -level:v 4.2 h264-high-42.h264
ff -c:v libx264 -profile:v high -level:v 5.1 h264-high-51.h264
ff -c:v libx264 -profile:v main -level:v 4.1 h264-main-41.h264
ff -c:v libx265 -profile:v main -x265-params level-idc=5.1 hevc-main-51.hevc
ff -c:v libx265 -profile:v main -x265-params level-idc=6.2 hevc-main-62.hevc
ffmpeg -y -f lavfi -i testsrc=size=128x64:rate=25 -frames:v 4 -pix_fmt yuv420p10le -g 4 -bf 0 \
  -c:v libx265 -profile:v main10 -x265-params level-idc=5.1 hevc-main10-51.hevc
ffmpeg -y -f lavfi -i color=c=gray:size=1280x720:rate=50 -frames:v 2 -pix_fmt yuv420p -g 2 -bf 0 \
  -c:v libx264 -profile:v high -level:v 4.1 h264-bd-720p50.h264
```
