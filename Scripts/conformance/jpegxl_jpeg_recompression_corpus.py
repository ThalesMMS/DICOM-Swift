#!/usr/bin/env python3
"""Generate an external JPEG corpus for JPEG XL JPEG recompression (`.111`, issue #2334).

Sources come from three independent encoders (Pillow, libjpeg-turbo cjpeg, jpegtran): 4:4:4/4:2:2/4:2:0/4:4:0 and grey,
quality 50..100 and custom table pairs, optimised and default Huffman tables, restart intervals (MCU and row based),
progressive and non-interleaved scan scripts, COM/Exif/ICC segments, odd sizes down to 1x1, a 2048-px frame, lossless
rotations and re-optimisation. Files libjxl refuses (4:1:1, arithmetic coding, 12-bit) stay in the corpus as refusal
cases. Every accepted JPEG also gets its `cjxl --lossless_jpeg=1` counterpart (`<name>.cjxl.jxl`) and manifest.json
records whether djxl reproduces the source bytes. `JPEGXLRecompressionCodecTests` consumes the directory through
DICOM_JPEG_RECOMPRESSION_CORPUS_DIRECTORY.
"""
import json, os, subprocess, sys, io
import numpy as np
from PIL import Image
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/isis-2334-jpeg-corpus"
os.makedirs(OUT, exist_ok=True)
def photo(h, w, seed, gray=False):
    r = np.random.default_rng(seed); y, x = np.mgrid[0:h, 0:w]
    ch = [127 + 100 * np.sin(x / 31) * np.cos(y / 17), 127 + 80 * np.cos(x / 23) * np.sin(y / 29), 127 + 110 * np.sin((x + y) / 41)]
    a = np.stack(ch, -1) + r.normal(0, 4, (h, w, 3)); a[(x // 40 + y // 40) % 2 == 0] *= 0.8
    a = a.clip(0, 255).astype("u1")
    return Image.fromarray(a[..., 0], "L") if gray else Image.fromarray(a, "RGB")
def pil(name, img, **kw):
    p = f"{OUT}/{name}.jpg"; img.save(p, "JPEG", **kw); return p
def cjpeg(name, img, args, optional=False):
    src = f"{OUT}/{name}.ppm"; img.save(src); p = f"{OUT}/{name}.jpg"
    try:
        subprocess.run(["cjpeg", *args, "-outfile", p, src], check=True)
        return p
    except subprocess.CalledProcessError as error:
        if not optional:
            raise
        print(f"SKIP optional refusal fixture {name}: cjpeg exited {error.returncode}")
        return None
    finally:
        os.remove(src)
def jpegtran(name, src, args):
    p = f"{OUT}/{name}.jpg"; subprocess.run(["jpegtran", *args, "-outfile", p, src], check=True); return p
cases = []
rgb = photo(277, 301, 1); g = photo(277, 301, 2, gray=True)
cases.append(pil("pil_rgb_q75_420", rgb, quality=75))
cases.append(pil("pil_rgb_q95_444", rgb, quality=95, subsampling=0))
cases.append(pil("pil_rgb_q85_422", rgb, quality=85, subsampling=1))
cases.append(pil("pil_gray_q90", g, quality=90))
cases.append(pil("pil_rgb_optimize", rgb, quality=80, optimize=True))
cases.append(pil("pil_rgb_progressive", rgb, quality=80, progressive=True))
cases.append(pil("pil_rgb_q100", rgb, quality=100, subsampling=0))
cases.append(pil("pil_rgb_comment_exif", rgb, quality=80, comment=b"DICOM bridge corpus comment", exif=Image.Exif().tobytes()))
try:
    from PIL import ImageCms
    icc = ImageCms.createProfile("sRGB"); icc_bytes = ImageCms.ImageCmsProfile(icc).tobytes()
    cases.append(pil("pil_rgb_icc", rgb, quality=80, icc_profile=icc_bytes))
except Exception as e: print("icc skipped", e)
cases.append(cjpeg("cjpeg_restart2", rgb, ["-quality", "80", "-restart", "2"]))
cases.append(cjpeg("cjpeg_restart1B", rgb, ["-quality", "80", "-restart", "1B"]))
cases.append(cjpeg("cjpeg_gray_restart", g, ["-quality", "70", "-restart", "3"]))
cases.append(cjpeg("cjpeg_411", rgb, ["-quality", "80", "-sample", "4x1"]))
cases.append(cjpeg("cjpeg_440", rgb, ["-quality", "80", "-sample", "1x2"]))
cases.append(cjpeg("cjpeg_odd_1x1", photo(1, 1, 3), ["-quality", "80"]))
cases.append(cjpeg("cjpeg_odd_17x9", photo(9, 17, 4), ["-quality", "80"]))
cases.append(cjpeg("cjpeg_big_2048", photo(2048, 2048, 5), ["-quality", "85"]))
cases.append(cjpeg("cjpeg_baseline_opt", rgb, ["-quality", "80", "-optimize", "-baseline"]))
cases.append(cjpeg("cjpeg_prog_default", rgb, ["-quality", "80", "-progressive"]))
cases.append(cjpeg("cjpeg_arith", rgb, ["-quality", "80", "-arithmetic"], optional=True))
cases.append(cjpeg("cjpeg_12bit", rgb, ["-quality", "80", "-precision", "12"], optional=True))
cases.append(cjpeg("cjpeg_dct_float", rgb, ["-quality", "80", "-dct", "float"]))
cases.append(cjpeg("cjpeg_quality_tables", rgb, ["-quality", "50,30"]))
cases.append(cjpeg("cjpeg_smooth", rgb, ["-quality", "80", "-smooth", "20"]))
open(f"{OUT}/scans.txt", "w").write("0: 0-63 0 0;\n1: 0-63 0 0;\n2: 0-63 0 0;\n")
cases.append(cjpeg("cjpeg_noninterleaved", rgb, ["-quality", "80", "-scans", f"{OUT}/scans.txt"]))
cases.append(jpegtran("jpegtran_copyall_prog", f"{OUT}/pil_rgb_comment_exif.jpg", ["-copy", "all", "-progressive"]))
cases.append(jpegtran("jpegtran_optimize", f"{OUT}/pil_rgb_q75_420.jpg", ["-copy", "none", "-optimize"]))
cases.append(jpegtran("jpegtran_rot90", f"{OUT}/pil_rgb_q75_420.jpg", ["-rotate", "90"]))
manifest = []
cases = [path for path in cases if path is not None]
for p in cases:
    name = os.path.basename(p)[:-4]; jxl = f"{OUT}/{name}.cjxl.jxl"
    r = subprocess.run(["cjxl", p, jxl, "--lossless_jpeg=1", "--quiet"], capture_output=True, text=True)
    ok = r.returncode == 0
    back = None
    if ok:
        r2 = subprocess.run(["djxl", jxl, f"{OUT}/{name}.djxl.jpg", "--quiet"], capture_output=True, text=True)
        back = r2.returncode == 0 and open(f"{OUT}/{name}.djxl.jpg", "rb").read() == open(p, "rb").read()
    manifest.append({"name": name, "bytes": os.path.getsize(p), "cjxlAccepts": ok, "cjxlRoundTrip": back, "cjxlError": r.stderr.strip()[-120:] if not ok else ""})
    print(name, os.path.getsize(p), "cjxl", ok, "roundtrip", back, "" if ok else r.stderr.strip()[-100:])
json.dump(manifest, open(f"{OUT}/manifest.json", "w"), indent=1)
