#!/usr/bin/env python3
"""Generate anonymous, numbered H.264 fixtures; requires ffmpeg with libx264."""
import pathlib
import subprocess
import sys

directory = pathlib.Path(__file__).resolve().parent
raw = bytearray()
for frame in range(96):
    for row in range(64):
        for column in range(128):
            value = 235 if (frame >> (column // 16)) & 1 else 16
            raw.extend([value] * 3)

base = (
    "bframes=2:b-adapt=0:b-pyramid=none:keyint=48:min-keyint=48:scenecut=0:"
    "ref=1:weightp=0:weightb=0:open-gop=0:aud=1:repeat-headers=1:slices=1"
)
variants = {
    "known-bframes": ("main", ""),
    "known-high-bframes": ("high", ""),
    "known-pframes": ("main", ":bframes=0"),
    "unsupported-b-pyramid": ("main", ":b-pyramid=normal"),
    "unsupported-weighted": ("main", ":weightp=2:weightb=1"),
    "unsupported-interlaced": ("main", ":tff=1"),
    "unsupported-multislice": ("main", ":slices=2"),
    "unsupported-open-gop": ("main", ":open-gop=1"),
}
for name, (profile, extra) in ({} if "--video-only" in sys.argv else variants).items():
    path = directory / f"{name}.h264"
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "128x64",
        "-framerate", "12", "-i", "pipe:0", "-frames:v", "96",
        "-c:v", "libx264", "-profile:v", profile, "-pix_fmt", "yuv420p",
        "-crf", "10", "-x264-params", base + extra, "-f", "h264", str(path),
    ], input=raw, check=True)
    decoded = subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path),
        "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1",
    ], check=True, capture_output=True).stdout
    assert len(decoded) == 96 * 128 * 64, name
    identifiers = [sum(
        (1 << bit) if decoded[frame * 128 * 64 + 32 * 128 + bit * 16 + 8] > 128 else 0
        for bit in range(8)
    ) for frame in range(96)]
    assert identifiers == list(range(96)), (name, identifiers)
    print(f"{name}: {path.stat().st_size} bytes; decoded IDs 0...95 verified")

# Lot A2: checked-in elementary streams for the pure Swift inspector and independent oracle.
video_directory = directory.parent.parent / "DicomCoreTests" / "Fixtures" / "Video"
video_directory.mkdir(parents=True, exist_ok=True)
for name in ("known-pframes", "known-bframes", "known-high-bframes", "unsupported-open-gop"):
    (video_directory / (name + ".h264")).write_bytes((directory / (name + ".h264")).read_bytes())
for name, encoder, rate, options, format_name in [
    ("known-hevc.hevc", "libx265", "12", ["-x265-params", "bframes=0:keyint=48:min-keyint=48:scenecut=0:open-gop=0:repeat-headers=1:aud=1:log-level=error"], "hevc"),
    ("known-mpeg2.m2v", "mpeg2video", "25", ["-g", "48", "-bf", "0", "-flags", "+cgop", "-sc_threshold", "1000000000"], "mpeg2video"),
]:
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "128x64",
        "-framerate", rate, "-i", "pipe:0", "-frames:v", "96", "-c:v", encoder,
        "-pix_fmt", "yuv420p", *options, "-f", format_name, str(video_directory / name),
    ], input=raw, check=True)
