#!/usr/bin/env python3
"""Generate a libjxl (cjxl 0.12) lossy corpus with djxl reference decodes (issue #2333).

Every case writes <name>.jxl (naked codestream) and <name>.ref.pnm (djxl, single thread, at the source bit depth) plus
manifest.json (bit depth, cjxl flags, channels, bytes, djxl wall time). The cases walk the VarDCT feature space the own
decoder implements: distances 0.1..25, efforts 1..10, every EPF/Gaborish setting, group sizes, progressive AC/DC (levels
1 and 2, qprogressive), resampling 2/4/8 with odd sizes, photon noise (also with resampling and progressive DC), patch
dictionaries (repeated glyphs and --dots), lossy Modular (XYB), custom intensity target, group order/centre, tiny and
2048-px frames, 8/12/16-bit grey and RGB8. `JPEGXLVarDCTCodecTests` consumes it through DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY.
"""
import json, os, subprocess, sys
import numpy as np

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/isis-2333-jxl-lossy-corpus"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(2333)


def pnm(path, a, maxv):
    h = (f"P5\n{a.shape[1]} {a.shape[0]}\n{maxv}\n" if a.ndim == 2 else f"P6\n{a.shape[1]} {a.shape[0]}\n{maxv}\n").encode()
    open(path, "wb").write(h + (a.astype(">u2") if maxv > 255 else a.astype("u1")).tobytes())


def smooth(h, w, bits, seed=0, noise=0.01):
    r = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    mx = (1 << bits) - 1
    a = (mx / 2) + (mx * 0.4) * np.sin(x / (7 + w / 40)) * np.cos(y / (5 + h / 33)) + r.normal(0, mx * noise, (h, w))
    return a.clip(0, mx).astype(int)


def photo_rgb(h, w, bits, seed=0):
    r = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    mx = (1 << bits) - 1
    ch = [(mx / 2) + (mx * 0.4) * np.sin(x / 31) * np.cos(y / 17), (mx / 2) + (mx * 0.3) * np.cos(x / 23) * np.sin(y / 29),
          (mx / 2) + (mx * 0.45) * np.sin((x + y) / 41)]
    a = np.stack(ch, -1) + r.normal(0, mx * 0.01, (h, w, 3))
    # add edges / texture
    a[(x // 40 + y // 40) % 2 == 0] *= 0.8
    return a.clip(0, mx).astype(int)


cases = []
def add(name, arr, bits, flags): cases.append((name, arr, bits, flags))

for d in (0.5, 1, 2, 4, 8):
    add(f"gray8_256_d{d}", smooth(256, 256, 8, seed=1), 8, ["-d", str(d)])
    add(f"rgb8_256_d{d}", photo_rgb(256, 256, 8, seed=2), 8, ["-d", str(d)])
add("gray16_256_d1", smooth(256, 256, 16, seed=3), 16, ["-d", "1"])
add("gray12_512_d1", smooth(512, 512, 12, seed=4), 12, ["-d", "1"])
add("rgb8_600x520_d1", photo_rgb(520, 600, 8, seed=5), 8, ["-d", "1"])
add("rgb8_53x37_d1", photo_rgb(37, 53, 8, seed=6), 8, ["-d", "1"])
add("rgb8_1030x17_d1", photo_rgb(17, 1030, 8, seed=7), 8, ["-d", "1"])
for e in (1, 3, 5, 7, 9):
    add(f"rgb8_300_d1_e{e}", photo_rgb(300, 300, 8, seed=8), 8, ["-d", "1", "-e", str(e)])
add("rgb8_300_d1_prog", photo_rgb(300, 300, 8, seed=9), 8, ["-d", "1", "-p"])
add("rgb8_300_d1_g1", photo_rgb(300, 300, 8, seed=10), 8, ["-d", "1", "-g", "1"])
add("rgb8_300_d1_noepf", photo_rgb(300, 300, 8, seed=11), 8, ["-d", "1", "--epf=0"])
add("rgb8_300_d1_nogab", photo_rgb(300, 300, 8, seed=12), 8, ["-d", "1", "--gaborish=0"])
add("rgb8_300_d1_epf3", photo_rgb(300, 300, 8, seed=13), 8, ["-d", "1", "--epf=3"])
add("rgb8_300_d3_resample2", photo_rgb(300, 300, 8, seed=14), 8, ["-d", "3", "--resampling=2"])
add("rgb8_2048_d1", photo_rgb(2048, 2048, 8, seed=15), 8, ["-d", "1", "-e", "5"])
add("gray8_300_q90", smooth(300, 300, 8, seed=16), 8, ["-q", "90"])
add("rgb8_300_d1_vardct_forced", photo_rgb(300, 300, 8, seed=17), 8, ["-d", "1", "-m", "0"])
add("rgb8_300_d1_photon", photo_rgb(300, 300, 8, seed=18), 8, ["-d", "1", "--photon_noise_iso=3200"])
add("rgb8_300_d1_patches", photo_rgb(300, 300, 8, seed=19), 8, ["-d", "1", "--patches=1"])

def repeated_rgb(h, w, bits, seed=0):
    # repeated glyph-like shapes so cjxl's patch dictionary triggers
    r = np.random.default_rng(seed)
    mx = (1 << bits) - 1
    a = np.full((h, w, 3), mx * 0.85)
    glyph = (r.random((9, 7, 3)) * mx * 0.6).astype(int)
    for y in range(4, h - 12, 14):
        for x in range(4, w - 10, 12):
            a[y:y + 9, x:x + 7] = glyph
    return a.clip(0, mx).astype(int)

def add2(name, arr, bits, flags): cases.append((name, arr, bits, flags))
add2("rgb8_300_d3_resample4", photo_rgb(300, 300, 8, seed=20), 8, ["-d", "3", "--resampling=4"])
add2("rgb8_301x299_d2_resample2", photo_rgb(299, 301, 8, seed=21), 8, ["-d", "2", "--resampling=2"])
add2("rgb8_517x263_d4_resample8", photo_rgb(263, 517, 8, seed=22), 8, ["-d", "4", "--resampling=8"])
add2("gray12_300_d1_resample2", smooth(300, 300, 12, seed=23), 12, ["-d", "1", "--resampling=2"])
add2("rgb8_300_d1_prog_dc2", photo_rgb(300, 300, 8, seed=24), 8, ["-d", "1", "--progressive_dc=2"])
add2("rgb8_300_d1_progac", photo_rgb(300, 300, 8, seed=25), 8, ["-d", "1", "--progressive_ac"])
add2("rgb8_300_d1_qprogac", photo_rgb(300, 300, 8, seed=26), 8, ["-d", "1", "--qprogressive_ac"])
add2("rgb8_700_d1_prog_e9", photo_rgb(700, 700, 8, seed=27), 8, ["-d", "1", "-p", "-e", "9"])
add2("rgb8_300_d1_photon_resample2", photo_rgb(300, 300, 8, seed=28), 8, ["-d", "1", "--photon_noise_iso=6400", "--resampling=2"])
add2("gray8_300_d1_photon", smooth(300, 300, 8, seed=29), 8, ["-d", "1", "--photon_noise_iso=1600"])
add2("rgb8_300_d1_photon_prog", photo_rgb(300, 300, 8, seed=30), 8, ["-d", "1", "--photon_noise_iso=3200", "-p"])
add2("rgb8_300_d1_modular_lossy", photo_rgb(300, 300, 8, seed=31), 8, ["-d", "1", "-m", "1"])
add2("gray8_300_d2_modular_lossy", smooth(300, 300, 8, seed=32), 8, ["-d", "2", "-m", "1"])
add2("rgb8_300_d1_epf1", photo_rgb(300, 300, 8, seed=33), 8, ["-d", "1", "--epf=1"])
add2("rgb8_300_d1_epf2", photo_rgb(300, 300, 8, seed=34), 8, ["-d", "1", "--epf=2"])
add2("rgb8_300_d1_e10", photo_rgb(300, 300, 8, seed=35), 8, ["-d", "1", "-e", "10"])
add2("rgb8_300_d1_e2", photo_rgb(300, 300, 8, seed=36), 8, ["-d", "1", "-e", "2"])
add2("rgb8_300_d1_e4", photo_rgb(300, 300, 8, seed=37), 8, ["-d", "1", "-e", "4"])
add2("rgb8_300_d1_e6", photo_rgb(300, 300, 8, seed=38), 8, ["-d", "1", "-e", "6"])
add2("rgb8_300_d1_e8", photo_rgb(300, 300, 8, seed=39), 8, ["-d", "1", "-e", "8"])
add2("rgb8_300_d15", photo_rgb(300, 300, 8, seed=40), 8, ["-d", "15"])
add2("rgb8_300_d25", photo_rgb(300, 300, 8, seed=41), 8, ["-d", "25"])
add2("rgb8_300_d0.1", photo_rgb(300, 300, 8, seed=42), 8, ["-d", "0.1"])
add2("rgb8_400_d1_patches_real", repeated_rgb(400, 400, 8, seed=43), 8, ["-d", "1", "--patches=1", "-e", "7"])
add2("rgb8_400_d1_dots", photo_rgb(400, 400, 8, seed=44), 8, ["-d", "1", "--dots=1"])
add2("rgb8_300_d1_g2", photo_rgb(300, 300, 8, seed=45), 8, ["-d", "1", "-g", "2"])
add2("rgb8_1100x900_d1_g0", photo_rgb(900, 1100, 8, seed=46), 8, ["-d", "1", "-g", "0"])
add2("rgb8_300_d1_center", photo_rgb(300, 300, 8, seed=47), 8, ["-d", "1", "--group_order=1", "--center_x=100", "--center_y=50"])
add2("rgb8_300_d1_order", photo_rgb(300, 300, 8, seed=48), 8, ["-d", "1", "--group_order=1"])
add2("gray16_300_d1_resample2", smooth(300, 300, 16, seed=49), 16, ["-d", "1", "--resampling=2"])
add2("rgb8_300_d1_intensity", photo_rgb(300, 300, 8, seed=50), 8, ["-d", "1", "--intensity_target=400"])
add2("rgb8_300_d1_faster", photo_rgb(300, 300, 8, seed=51), 8, ["-d", "1", "--faster_decoding=4"])
add2("rgb8_300_d1_nogab_noepf", photo_rgb(300, 300, 8, seed=52), 8, ["-d", "1", "--gaborish=0", "--epf=0"])
add2("gray8_2048_d1", smooth(2048, 2048, 8, seed=53), 8, ["-d", "1"])
add2("rgb8_1x1_d1", photo_rgb(1, 1, 8, seed=54), 8, ["-d", "1"])
add2("rgb8_7x3_d1", photo_rgb(3, 7, 8, seed=55), 8, ["-d", "1"])
add2("rgb8_9x9_d3_resample2", photo_rgb(9, 9, 8, seed=56), 8, ["-d", "3", "--resampling=2"])

manifest, fails = [], []
for name, arr, bits, flags in cases:
    src = os.path.join(OUT, name + ".src.pnm"); jxl = os.path.join(OUT, name + ".jxl"); ref = os.path.join(OUT, name + ".ref.pnm")
    pnm(src, arr, (1 << bits) - 1)
    r = subprocess.run(["cjxl", src, jxl, "--container=0", "--quiet"] + flags, capture_output=True, text=True)
    if r.returncode != 0: fails.append((name, r.stderr.strip()[:200])); continue
    import time; t0 = time.time()
    r = subprocess.run(["djxl", jxl, ref, "--quiet", f"--bits_per_sample={bits}", "--num_threads=1"], capture_output=True, text=True)
    djxl_ms = (time.time() - t0) * 1000
    if r.returncode != 0: fails.append((name, "djxl: " + r.stderr.strip()[:200])); continue
    manifest.append({"name": name, "bits": bits, "flags": flags, "channels": 1 if arr.ndim == 2 else 3, "jxlBytes": os.path.getsize(jxl), "djxlMs": round(djxl_ms)})
    if os.environ.get("DICOM_JPEGXL_KEEP_SOURCE") != "1": os.remove(src)
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
print(f"{len(manifest)} cases written to {OUT}")
for f in fails: print("FAILED:", f)
