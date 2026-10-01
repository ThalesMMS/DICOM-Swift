#!/usr/bin/env python3
"""Generate a libjxl (cjxl) lossless Modular corpus with djxl reference decodes.

Each case writes <name>.jxl (naked codestream or container as cjxl decides)
and <name>.ref.pnm (djxl output, P5/P6 at the original bit depth).
"""
import json, os, subprocess, sys
import numpy as np

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/isis-2332-jxl-corpus"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(2332)


def pnm(path, a, maxv):
    if a.ndim == 2:
        h = f"P5\n{a.shape[1]} {a.shape[0]}\n{maxv}\n".encode()
    else:
        h = f"P6\n{a.shape[1]} {a.shape[0]}\n{maxv}\n".encode()
    body = a.astype(">u2").tobytes() if maxv > 255 else a.astype("u1").tobytes()
    open(path, "wb").write(h + body)


def smooth(h, w, bits, noise=0.005, seed=0):
    r = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    mx = (1 << bits) - 1
    a = (mx / 2) + (mx * 0.4) * np.sin(x / (7 + w / 40)) * np.cos(y / (5 + h / 33)) + r.normal(0, mx * noise, (h, w))
    return np.rint(a.clip(0, mx)).astype(int)


def smooth_rgb(h, w, bits, seed=0):
    r = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    mx = (1 << bits) - 1
    ch = [
        (mx / 2) + (mx * 0.4) * np.sin(x / 31) * np.cos(y / 17),
        (mx / 2) + (mx * 0.3) * np.cos(x / 23) * np.sin(y / 29),
        (mx / 2) + (mx * 0.45) * np.sin((x + y) / 41),
    ]
    a = np.stack(ch, -1) + r.normal(0, mx * 0.004, (h, w, 3))
    return a.clip(0, mx).astype(int)


cases = []


def add(name, arr, bits, flags):
    cases.append((name, arr, bits, flags))


# Bit depths and sizes (gray).
for bits in (1, 2, 4, 8, 10, 12, 14, 16):
    add(f"gray{bits}_53x37_e7", smooth(37, 53, bits, seed=bits), bits, ["-e", "7"])
for bits in (8, 12, 16):
    add(f"gray{bits}_512x512_e7", smooth(512, 512, bits, seed=100 + bits), bits, ["-e", "7"])
    add(f"gray{bits}_301x277_e3", smooth(277, 301, bits, seed=200 + bits), bits, ["-e", "3"])
add("gray12_1030x17_e5", smooth(17, 1030, 12, seed=7), 12, ["-e", "5"])
add("gray12_17x1030_e5", smooth(1030, 17, 12, seed=8), 12, ["-e", "5"])
add("gray12_700x520_e9", smooth(520, 700, 12, seed=9), 12, ["-e", "9"])
add("gray16_513x257_e7", smooth(257, 513, 16, seed=10), 16, ["-e", "7"])
# Efforts.
for e in (1, 2, 3, 4, 5, 6, 8, 9):
    add(f"gray12_300x300_e{e}", smooth(300, 300, 12, seed=300 + e), 12, ["-e", str(e)])
# Random (incompressible) and constant.
add("gray16_rand_300x300", rng.integers(0, 65536, (300, 300)), 16, ["-e", "7"])
add("gray8_const_300x300", np.full((300, 300), 77), 8, ["-e", "7"])
add("gray12_const_600x600", np.full((600, 600), 2000), 12, ["-e", "7"])
# Palette cases (few distinct values) and delta palette / large palettes.
add("gray8_pal16_300x271", rng.integers(0, 16, (271, 300)) * 17, 8, ["-e", "7"])
add("gray12_pal1024_512x512", (smooth(512, 512, 12, seed=11) // 4) * 4, 12, ["-e", "7"])
add("gray16_pal_mul16_512x512", smooth(512, 512, 12, seed=12) * 16, 16, ["-e", "7"])
add("gray8_pal_e9_300x300", rng.integers(0, 40, (300, 300)) * 6, 8, ["-e", "9"])
# Colour.
add("rgb8_53x37_e7", smooth_rgb(37, 53, 8, seed=1), 8, ["-e", "7"])
add("rgb8_600x520_e7", smooth_rgb(520, 600, 8, seed=2), 8, ["-e", "7"])
add("rgb16_277x301_e7", smooth_rgb(301, 277, 16, seed=3), 16, ["-e", "7"])
add("rgb12_300x300_e5", smooth_rgb(300, 300, 12, seed=4), 12, ["-e", "5"])
add("rgb8_rand_100x100", rng.integers(0, 256, (100, 100, 3)), 8, ["-e", "7"])
add("rgb8_pal_300x300", rng.integers(0, 6, (300, 300, 3)) * 50, 8, ["-e", "7"])
add("rgb8_pal_delta_512x512", (smooth_rgb(512, 512, 8, seed=5) // 8) * 8, 8, ["-e", "7"])
for cs in (0, 1, 2, 3, 6, 7, 10, 13, 20, 25, 31, 37, 41):
    add(f"rgb8_rct{cs}_200x150", smooth_rgb(150, 200, 8, seed=cs), 8, ["-e", "7", "-C", str(cs)])
add("rgb16_rct6_e9_300x300", smooth_rgb(300, 300, 16, seed=6), 16, ["-e", "9", "-C", "6"])
# Predictors.
for p in range(0, 16):
    add(f"gray12_pred{p}_300x271", smooth(271, 300, 12, seed=400 + p), 12, ["-e", "7", "-P", str(p)])
add("rgb8_pred6_300x300", smooth_rgb(300, 300, 8, seed=7), 8, ["-e", "7", "-P", "6"])
add("gray16_pred15_512x512", smooth(512, 512, 16, seed=8), 16, ["-e", "9", "-P", "15"])
# Group sizes and responsive (squeeze) and progressive passes.
for g in (0, 1, 2, 3):
    add(f"gray12_group{g}_600x520", smooth(520, 600, 12, seed=500 + g), 12, ["-e", "7", "-g", str(g)])
add("gray12_resp_512x512", smooth(512, 512, 12, seed=20), 12, ["-e", "7", "-R", "1"])
add("gray8_resp_300x271", smooth(271, 300, 8, seed=21), 8, ["-e", "7", "-R", "1"])
add("rgb8_resp_600x520", smooth_rgb(520, 600, 8, seed=22), 8, ["-e", "7", "-R", "1"])
add("gray16_resp_2100x1100", smooth(1100, 2100, 16, seed=23), 16, ["-e", "5", "-R", "1"])
add("gray12_prog_600x520", smooth(520, 600, 12, seed=24), 12, ["-e", "7", "-p"])
add("gray12_prog_resp_600x520", smooth(520, 600, 12, seed=25), 12, ["-e", "7", "-p", "-R", "1"])
add("rgb8_prog_600x520", smooth_rgb(520, 600, 8, seed=26), 8, ["-e", "7", "-p"])
# Extra properties (previous channels) and MA tree learning.
add("rgb8_prev2_300x300", smooth_rgb(300, 300, 8, seed=27), 8, ["-e", "7", "--modular_nb_prev_channels=2"])
add("rgb16_prev3_e9_300x300", smooth_rgb(300, 300, 16, seed=28), 16, ["-e", "9", "--modular_nb_prev_channels=3"])
add("gray12_iters_300x300", smooth(300, 300, 12, seed=29), 12, ["-e", "7", "-I", "50"])
# Large clinical-like shapes.
add("gray16_2048x2048_e7", smooth(2048, 2048, 16, seed=30, noise=0.002), 16, ["-e", "7"])
add("gray12_1024x1024_e1", smooth(1024, 1024, 12, seed=31), 12, ["-e", "1"])
add("gray12_1024x1024_e2", smooth(1024, 1024, 12, seed=32), 12, ["-e", "2"])
# Container forced.
add("gray12_container_100x100", smooth(100, 100, 12, seed=33), 12, ["-e", "7", "--container=1"])

manifest = []
fails = []
for name, arr, bits, flags in cases:
    src = os.path.join(OUT, name + ".src.pnm")
    jxl = os.path.join(OUT, name + ".jxl")
    ref = os.path.join(OUT, name + ".ref.pnm")
    pnm(src, arr, (1 << bits) - 1)
    cmd = ["cjxl", src, jxl, "-d", "0", "-m", "1", "--quiet"] + flags
    if "--container=1" not in flags:
        cmd += ["--container=0"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        fails.append((name, r.stderr.strip()[:200]))
        continue
    r = subprocess.run(["djxl", jxl, ref, "--quiet"], capture_output=True, text=True)
    if r.returncode != 0:
        fails.append((name, "djxl: " + r.stderr.strip()[:200]))
        continue
    manifest.append({"name": name, "bits": bits, "flags": flags, "channels": 1 if arr.ndim == 2 else 3,
                     "width": int(arr.shape[1]), "height": int(arr.shape[0]), "jxlBytes": os.path.getsize(jxl)})
    os.remove(src)
if fails:
    for failure in fails:
        print("FAILED:", failure, file=sys.stderr)
    sys.exit(1)
json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
print(f"{len(manifest)} cases written to {OUT}")
