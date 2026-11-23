#!/usr/bin/env python3
"""Build the bundled nearby-star catalogue for the Star Map.

    python3 tools/fetch_stars.py            # writes solar-system/solar-system/StarData/nearby_stars.json

Positions, magnitudes and spectral types come from the HYG database v4.1
(https://github.com/astronexus/HYG-Database), which merges Hipparcos, Yale
Bright Star and Gliese. HYG is licensed CC BY-SA 4.0, so this JSON is too.
Every star within MAX_LY light-years is kept. A few famous planet hosts too
faint for those catalogues (TRAPPIST-1, Teegarden's Star) are added by hand
from their discovery papers.

Known planets are written by hand below (NASA Exoplanet Archive, as of 2025).
Candidates are labelled as such.

Output: { source, license, stars: [ {name, cat, d, eq:[x,y,z], sp, absmag, lum, bv,
          group, planets?, sandbox?} ] }
  d: distance in light-years; eq: equatorial J2000 cartesian, light-years
  (x toward RA 0, z toward the north celestial pole); group: shared by the
  members of a multiple-star system.
"""
import csv, gzip, io, json, math, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "solar-system", "solar-system", "StarData", "nearby_stars.json")
URL = "https://raw.githubusercontent.com/astronexus/HYG-Database/main/hyg/CURRENT/hygdata_v41.csv"
LY_PER_PC = 3.261_563_777
MAX_LY = 50

GREEK = {"Alp": "α", "Bet": "β", "Gam": "γ", "Del": "δ", "Eps": "ε", "Zet": "ζ", "Eta": "η", "The": "θ",
         "Iot": "ι", "Kap": "κ", "Lam": "λ", "Mu": "μ", "Nu": "ν", "Xi": "ξ", "Omi": "ο", "Pi": "π",
         "Rho": "ρ", "Sig": "σ", "Tau": "τ", "Ups": "υ", "Phi": "φ", "Chi": "χ", "Psi": "ψ", "Ome": "ω"}

# Known planets, keyed by Gliese id (HYG's `gl` column).
PLANETS = {
    "Gl 551": "2 planets: Proxima b (≥1.07 Earths, in the habitable zone) and Proxima d",
    "Gl 699": "4 small rocky planets, all closer in than Mercury (confirmed 2025)",
    "Gl 411": "2 planets (b and c), super-Earths",
    "Gl 144": "1 giant planet (ε Eridani b) and debris belts",
    "Gl 447": "1 temperate Earth-mass planet (Ross 128 b)",
    "Gl 273": "2 planets (b in the habitable zone, c), plus 2 candidates",
    "GJ 1061": "3 Earth-mass planets (d in the habitable zone)",
    "Gl 628": "3 planets (Wolf 1061 c near the habitable zone)",
    "Gl 876": "4 planets, two giants locked in a 2:1 resonance",
    "Gl 832": "1 giant planet (Gliese 832 b)",
    "Gl 581": "3 planets (b, c, e)",
    "Gl 667C": "at least 2 planets (b, c), more candidates",
    "Gl 506": "3 planets (61 Virginis b, c, d)",
    "Gl 892": "at least 5 planets, some transiting",
    "Gl 436": "1 Neptune-size planet with an evaporating tail",
    "Gl 803": "2 planets (b, c) in a young debris disk",
    "Gl 61": "3 giant planets (υ Andromedae b, c, d)",
    "Gl 71": "4 candidate planets (unconfirmed) and a heavy debris disk",
    "Gl 845": "1 giant planet, directly imaged by JWST (2024)",
    "GJ 1214": "1 mini-Neptune (GJ 1214 b) with a hazy atmosphere",
    "Gl 674": "1 Neptune-mass planet",
    "Gl 324A": "5 planets, including the lava world 55 Cancri e",
    "Gl 407": "2 giant planets and a candidate third",
    "Gl 486": "1 hot rocky planet (Gliese 486 b)",
    "Gl 367": "an ultra-short-period rocky planet (b) and 2 more",
    "Gl 302": "3 Neptune-mass planets and an asteroid belt",
}

# Sandbox presets for these stars (SandboxScenarios ids).
SANDBOX = {"Sol": "solar", "Gl 559A": "alpha-cen", "Gl 559B": "alpha-cen", "TRAPPIST-1": "trappist"}

# Too faint for HYG's catalogues: (name, RA hours, Dec degrees, parsecs, spectral type, abs V mag, L☉)
EXTRA = [
    ("TRAPPIST-1", 23.108_29, -5.041_4, 12.47, "M8V", 18.4, 0.000_553,
     "7 Earth-size planets, 3 or 4 in the habitable zone"),        # Gillon et al. 2017, Agol et al. 2021
    ("Teegarden's Star", 2.883_58, 16.881_3, 3.832, "M7V", 17.2, 0.000_73,
     "3 Earth-mass planets (b and c in the habitable zone)"),       # Zechmeister et al. 2019, Dreizler et al. 2024
]


def fetch():
    print("downloading HYG v4.1 …", file=sys.stderr)
    # curl, not urllib: python.org builds often lack the system certificates.
    data = subprocess.run(["curl", "-sSfL", URL], check=True, capture_output=True).stdout
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    return list(csv.DictReader(io.StringIO(data.decode("utf-8"))))


def name_of(row):
    if row["proper"]:
        return row["proper"]
    con = row["con"]
    if row["bayer"]:
        base, _, num = row["bayer"].partition("-")
        letter = GREEK.get(base, base)
        sup = {"1": "¹", "2": "²", "3": "³"}.get(num, "")
        return f"{letter}{sup} {con}"
    if row["flam"]:
        return f"{row['flam']} {con}"
    if row["gl"]:
        return row["gl"].replace("Gl ", "Gliese ").replace("GJ ", "GJ ")
    if row["hip"]:
        return f"HIP {row['hip']}"
    return f"HYG {row['id']}"


def unit_scaled(v, d):
    # HYG's x/y/z can disagree slightly with `dist`; keep the direction, use `dist`.
    n = math.sqrt(sum(c * c for c in v)) or 1
    return [round(c / n * d, 4) for c in v]


def bv_from_spectral(sp):
    # Typical main-sequence B−V by class, for stars with no measured colour.
    return {"O": -0.3, "B": -0.15, "A": 0.1, "F": 0.45, "G": 0.65, "K": 1.0, "M": 1.6, "D": 0.0}.get(sp[:1].upper(), 1.4)


def main():
    rows = fetch()
    stars = []
    for r in rows:
        if not r["dist"]:
            continue
        d = float(r["dist"]) * LY_PER_PC
        if r["proper"] != "Sol" and not (0 < d <= MAX_LY):
            continue
        sp = r["spect"].strip()
        star = {
            "name": name_of(r),
            "cat": r["gl"] or (f"HIP {r['hip']}" if r["hip"] else f"HYG {r['id']}"),
            "d": round(d, 3),
            "eq": unit_scaled([float(r[k]) for k in ("x", "y", "z")], d),
            "sp": sp,
            "absmag": round(float(r["absmag"]), 2) if r["absmag"] else None,
            "lum": float(f"{float(r['lum']):.4g}") if r["lum"] else None,
            "bv": round(float(r["ci"]), 3) if r["ci"] else bv_from_spectral(sp),
            "group": r["base"] or r["gl"] or r["id"],
        }
        if r["gl"] in PLANETS:
            star["planets"] = PLANETS[r["gl"]]
        key = "Sol" if r["proper"] == "Sol" else r["gl"]
        if key in SANDBOX:
            star["sandbox"] = SANDBOX[key]
        stars.append(star)

    for name, ra, dec, pc, sp, absmag, lum, planets in EXTRA:
        d = pc * LY_PER_PC
        a, b = math.radians(ra * 15), math.radians(dec)
        s = {"name": name, "cat": name, "d": round(d, 3),
             "eq": [round(d * math.cos(b) * math.cos(a), 4), round(d * math.cos(b) * math.sin(a), 4), round(d * math.sin(b), 4)],
             "sp": sp, "absmag": absmag, "lum": lum, "bv": bv_from_spectral(sp), "group": name, "planets": planets}
        if name in SANDBOX:
            s["sandbox"] = SANDBOX[name]
        stars.append(s)

    # Companions: "Sirius B" rather than "Gliese 244B"; split duplicate names into A/B.
    groups = {}
    for st in stars:
        groups.setdefault(st["group"], []).append(st)
    for members in groups.values():
        if len(members) < 2:
            continue
        members.sort(key=lambda st: st["absmag"] if st["absmag"] is not None else 99)
        primary = members[0]["name"]
        for end in (" A", "A"):
            if primary.endswith(end) and members[0]["cat"].endswith("A"):
                primary = primary[: -len(end)]
                break
        names = [m["name"] for m in members]
        for k, st in enumerate(members):
            suffix = st["cat"][-1] if st["cat"][-1:].isalpha() and st["cat"][-1:].isupper() else "ABCDEFG"[k]
            generic = st["name"].startswith(("Gliese ", "GJ ", "HIP ", "HYG "))
            if k > 0 and generic:
                st["name"] = f"{primary} {suffix}"
            elif names.count(names[k]) > 1:
                st["name"] = f"{names[k]} {suffix}"

    stars.sort(key=lambda s: s["d"])
    for key in PLANETS:
        if not any(s["cat"] == key for s in stars):
            sys.exit(f"planet host {key} not found")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({"source": "HYG database v4.1 (astronexus/HYG-Database), plus TRAPPIST-1 and Teegarden's Star",
                   "license": "CC BY-SA 4.0", "stars": stars}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(stars)} stars → {OUT}", file=sys.stderr)
    for s in stars[:8]:
        print(f"  {s['d']:6.2f} ly  {s['name']}", file=sys.stderr)


if __name__ == "__main__":
    main()
