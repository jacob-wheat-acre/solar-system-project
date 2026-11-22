#!/usr/bin/env python3
"""Build the bundled mission data for the Missions view.

    python3 tools/fetch_missions.py            # writes solar-system/solar-system/MissionData/*.json

Robotic missions (Voyager 1 & 2, Cassini, New Horizons) use real trajectories
from NASA/JPL Horizons (https://ssd.jpl.nasa.gov/horizons/), heliocentric,
ecliptic J2000, in AU. The planets each mission visits come from Horizons too,
so flybys line up exactly.

Apollo 11 isn't in Horizons (only its S-IVB third stage), so the CSM "Columbia"
and LM "Eagle" paths are reconstructed from the published flight timeline:
event times are historical, path shapes are approximate. See build_apollo11().

Events defined here are the single source of truth; they're written into each
JSON. For every flyby event the script finds the closest approach in the data
and fails if it's more than a day off.

Output format (per mission):
  { id, name, frame: "heliocentric"|"geocentric", unitKm, start, end,
    bodies: [ {name, radiusKm, t:[unix s...], s:[x,y,z,vx,vy,vz,...]} ],
    craft:  [ same as bodies, plus label ],
    events: [ {t, title, detail, craft?, body?} ] }
Positions are in `unitKm` units; velocities in units per day.
"""
import json, math, os, re, subprocess, sys, time, urllib.parse
from datetime import datetime, timezone, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "solar-system", "solar-system", "MissionData")
AU_KM = 149_597_870.7
DAY = 86_400.0
API = "https://ssd.jpl.nasa.gov/api/horizons.api"

RADII_KM = {"Sun": 695_700, "Venus": 6051.8, "Earth": 6371.0, "Moon": 1737.4,
            "Jupiter": 69_911, "Saturn": 58_232, "Uranus": 25_362, "Neptune": 24_622,
            "Pluto": 1188.3, "Arrokoth": 18}
HORIZONS_ID = {"Venus": "299", "Earth": "399", "Moon": "301", "Jupiter": "599",
               "Saturn": "699", "Uranus": "799", "Neptune": "899", "Pluto": "999",
               "Arrokoth": "486958;"}

# ----------------------------------------------------------------------------- time helpers

def utc(s):
    """'1977-09-05 12:56' or with seconds → aware UTC datetime."""
    fmt = "%Y-%m-%d %H:%M:%S" if s.count(":") == 2 else "%Y-%m-%d %H:%M"
    return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)

def unix(d): return d.timestamp()
def hz(d): return d.strftime("%Y-%m-%d %H:%M:%S")
JD_UNIX0 = 2440587.5
def jd_to_unix(jd): return (jd - JD_UNIX0) * DAY

# ----------------------------------------------------------------------------- Horizons

_MONTHS = {m: i for i, m in enumerate(["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"], 1)}

def _hz_date(txt):
    m = re.search(r"(\d{4})-([A-Z]{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2})", txt)
    if not m: return None
    y, mon, d, H, M, S = m.groups()
    return datetime(int(y), _MONTHS[mon], int(d), int(H), int(M), int(S), tzinfo=timezone.utc)

def horizons(command, start, stop, step, center="500@10", units="AU-D"):
    """Return [(unix, x,y,z, vx,vy,vz)], clipping start/stop to the available span."""
    for attempt in range(4):
        params = {"format": "json", "COMMAND": f"'{command}'", "EPHEM_TYPE": "'VECTORS'",
                  "CENTER": f"'{center}'", "START_TIME": f"'{hz(start)}'", "STOP_TIME": f"'{hz(stop)}'",
                  "STEP_SIZE": f"'{step}'", "REF_PLANE": "'ECLIPTIC'", "REF_SYSTEM": "'ICRF'",
                  "VEC_TABLE": "'2'", "OUT_UNITS": f"'{units}'", "CSV_FORMAT": "'YES'",
                  "TIME_TYPE": "'UT'", "OBJ_DATA": "'NO'", "MAKE_EPHEM": "'YES'"}
        url = API + "?" + urllib.parse.urlencode(params)
        # curl uses the system trust store (python.org builds often lack CA certs)
        raw = subprocess.run(["curl", "-sS", "--fail", "--max-time", "300", url],
                             check=True, capture_output=True).stdout
        res = json.loads(raw)["result"]
        if "$$SOE" in res:
            body = res.split("$$SOE")[1].split("$$EOE")[0]
            rows = []
            for line in body.strip().splitlines():
                f = [x.strip() for x in line.split(",")]
                rows.append((jd_to_unix(float(f[0])), *map(float, f[2:8])))
            return rows
        lo = re.search(r"prior to A\.D\. ([^\n]+)", res)
        hi = re.search(r"after A\.D\. ([^\n]+)", res)
        if lo and _hz_date(lo.group(1)): start = _hz_date(lo.group(1)) + timedelta(minutes=2)
        elif hi and _hz_date(hi.group(1)): stop = _hz_date(hi.group(1)) - timedelta(minutes=2)
        else: raise RuntimeError(f"Horizons error for {command}:\n{res[-1500:]}")
        if start >= stop: return []
    raise RuntimeError(f"Horizons: could not resolve span for {command}")

def fetch_segments(command, segments, **kw):
    """segments: [(start, stop, step)] → merged, de-duplicated, time-sorted rows."""
    rows = {}
    for a, b, step in segments:
        for r in horizons(command, a, b, step, **kw):
            rows[round(r[0])] = r
        time.sleep(0.5)
    return [rows[k] for k in sorted(rows)]

# ----------------------------------------------------------------------------- vector math

def add(a, b): return [a[i] + b[i] for i in range(3)]
def sub(a, b): return [a[i] - b[i] for i in range(3)]
def mul(a, k): return [a[i] * k for i in range(3)]
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def cross(a, b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def norm(a): return math.sqrt(dot(a, a))
def unit(a): n = norm(a); return [x / n for x in a]
def lerp(a, b, w): return [a[i] + (b[i] - a[i]) * w for i in range(3)]
def slerp(a, b, w):
    om = math.acos(max(-1, min(1, dot(a, b))))
    if om < 1e-6: return a
    return add(mul(a, math.sin((1 - w) * om) / math.sin(om)), mul(b, math.sin(w * om) / math.sin(om)))
def smooth(x): x = min(1, max(0, x)); return x * x * (3 - 2 * x)

def hermite(t, t0, p0, v0, t1, p1, v1):
    """Cubic Hermite position at t; velocities in units/second."""
    h = t1 - t0; s = (t - t0) / h
    h00 = 2*s**3 - 3*s**2 + 1; h10 = s**3 - 2*s**2 + s
    h01 = -2*s**3 + 3*s**2;    h11 = s**3 - s**2
    return [h00*p0[i] + h10*h*v0[i] + h01*p1[i] + h11*h*v1[i] for i in range(3)]

class Table:
    """Hermite interpolation over Horizons rows (velocities given per `vel_unit_s` seconds)."""
    def __init__(self, rows, vel_unit_s):
        self.t = [r[0] for r in rows]
        self.p = [list(r[1:4]) for r in rows]
        self.v = [[x / vel_unit_s for x in r[4:7]] for r in rows]
    def __call__(self, t):
        import bisect
        i = max(0, min(len(self.t) - 2, bisect.bisect_right(self.t, t) - 1))
        return hermite(t, self.t[i], self.p[i], self.v[i], self.t[i+1], self.p[i+1], self.v[i+1])
    def vel(self, t, dt=1.0):
        return mul(sub(self(t + dt), self(t - dt)), 1 / (2 * dt))

# ----------------------------------------------------------------------------- output

def pack_rows(name, rows, km_per_unit_in, unit_km, vel_per_day_factor, label=None):
    """rows in input units; convert to output units (positions unit_km, velocities unit/day)."""
    k = km_per_unit_in / unit_km
    t, s = [], []
    for r in rows:
        t.append(int(round(r[0])))
        s += [round(r[1]*k, 9), round(r[2]*k, 9), round(r[3]*k, 9),
              round(r[4]*k*vel_per_day_factor, 9), round(r[5]*k*vel_per_day_factor, 9), round(r[6]*k*vel_per_day_factor, 9)]
    d = {"name": name, "radiusKm": RADII_KM.get(name, 0), "t": t, "s": s}
    if label: d["label"] = label
    return d

def closest_approach(craft_rows, body_rows, center, window_days=5):
    cT, bT = Table(craft_rows, DAY), Table(body_rows, DAY)
    best = (1e99, None)
    t = center - window_days * DAY
    while t <= center + window_days * DAY:
        if cT.t[0] <= t <= cT.t[-1] and bT.t[0] <= t <= bT.t[-1]:
            d = norm(sub(cT(t), bT(t)))
            if d < best[0]: best = (d, t)
        t += 600
    return best

def write(mission):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, mission["id"] + ".json")
    with open(path, "w") as f:
        json.dump(mission, f, separators=(",", ":"))
    print(f"  wrote {os.path.relpath(path, ROOT)} ({os.path.getsize(path) / 1e6:.2f} MB)")

# ----------------------------------------------------------------------------- robotic missions

def robotic(mid, name, craft_specs, bodies, events, end):
    """craft_specs: [(label, horizons_id, launch_str, segments(launch)->list)]"""
    print(f"\n== {name}")
    craft_out, craft_rows = [], {}
    start = None
    for label, cid, launch, segs in craft_specs:
        L = utc(launch)
        rows = fetch_segments(cid, segs(L))
        craft_rows[label] = rows
        start = min(start or rows[0][0], rows[0][0])
        craft_out.append(pack_rows(label, rows, AU_KM, AU_KM, 1.0, label=label))
        print(f"  {label}: {len(rows)} samples {datetime.fromtimestamp(rows[0][0], timezone.utc):%Y-%m-%d} → "
              f"{datetime.fromtimestamp(rows[-1][0], timezone.utc):%Y-%m-%d}")
    t0 = datetime.fromtimestamp(start, timezone.utc) - timedelta(days=2)
    stop = max(r[-1][0] for r in craft_rows.values())
    t1 = datetime.fromtimestamp(stop, timezone.utc) + timedelta(days=2)
    body_out, body_rows = [], {}
    for b in bodies:
        step = "2 d" if b in ("Venus", "Earth") else "10 d"
        segs = [(t0, t1, step)]
        # extra resolution for small bodies near their flyby
        for e in events:
            if e.get("body") == b and b in ("Pluto", "Arrokoth"):
                c = utc(e["when"]); segs.append((c - timedelta(days=5), c + timedelta(days=5), "1 h"))
        rows = fetch_segments(HORIZONS_ID[b], segs)
        body_rows[b] = rows
        body_out.append(pack_rows(b, rows, AU_KM, AU_KM, 1.0))
    body_out.insert(0, {"name": "Sun", "radiusKm": RADII_KM["Sun"], "t": [int(start), int(stop)],
                        "s": [0, 0, 0, 0, 0, 0] * 2})
    ev_out = []
    for e in events:
        t = unix(utc(e["when"]))
        if "body" in e:
            craft = e["craft"]
            d, tc = closest_approach(craft_rows[craft], body_rows[e["body"]], t)
            off_h = (tc - t) / 3600
            print(f"  ✓ {craft} · {e['body']}: closest {d * AU_KM:,.0f} km at "
                  f"{datetime.fromtimestamp(tc, timezone.utc):%Y-%m-%d %H:%M} ({off_h:+.1f} h vs listed)")
            if abs(off_h) > 24: sys.exit(f"  ✗ {e['title']}: listed date is {off_h:.0f} h off the data")
            t = tc  # use the data's actual closest approach
        out = {"t": int(round(t)), "title": e["title"], "detail": e["detail"]}
        for k in ("craft", "body"):
            if k in e: out[k] = e[k]
        ev_out.append(out)
    ev_out.sort(key=lambda e: e["t"])
    mission = {"id": mid, "name": name, "frame": "heliocentric", "unitKm": AU_KM,
               "start": int(start), "end": int(stop), "bodies": body_out, "craft": craft_out, "events": ev_out}
    write(mission)

def flyby_windows(L, flybys, cruise_step="1 d", until=None, late_step="30 d", end=None):
    segs = [(L, until or end, cruise_step)]
    if until and end: segs.append((until, end, late_step))
    for f in flybys:
        c = utc(f); segs.append((c - timedelta(days=3), c + timedelta(days=3), "1 h"))
    return segs

DATA_END = utc("2026-11-01 00:00")

def voyager():
    v1_fly = ["1979-03-05 12:05", "1980-11-12 23:46"]
    v2_fly = ["1979-07-09 22:29", "1981-08-26 03:24", "1986-01-24 17:59", "1989-08-25 03:56"]
    robotic("voyager", "Voyager 1 & 2", [
        ("Voyager 2", "-32", "1977-08-20 14:29",
         lambda L: flyby_windows(L, v2_fly, until=utc("1990-01-01 00:00"), end=DATA_END)),
        ("Voyager 1", "-31", "1977-09-05 12:56",
         lambda L: flyby_windows(L, v1_fly, until=utc("1981-01-01 00:00"), end=DATA_END)),
    ], ["Earth", "Jupiter", "Saturn", "Uranus", "Neptune"], [
        {"when": "1977-08-20 14:29", "title": "Voyager 2 launch", "craft": "Voyager 2",
         "detail": "Launched first, on a slower path that let it visit all four giant planets."},
        {"when": "1977-09-05 12:56", "title": "Voyager 1 launch", "craft": "Voyager 1",
         "detail": "Launched second on a faster path; it overtakes Voyager 2 before Jupiter."},
        {"when": v1_fly[0], "title": "Voyager 1 · Jupiter", "craft": "Voyager 1", "body": "Jupiter",
         "detail": "Discovered active volcanoes on Io, the first seen beyond Earth."},
        {"when": v2_fly[0], "title": "Voyager 2 · Jupiter", "craft": "Voyager 2", "body": "Jupiter",
         "detail": "Jupiter's gravity bends its path toward Saturn."},
        {"when": v1_fly[1], "title": "Voyager 1 · Saturn", "craft": "Voyager 1", "body": "Saturn",
         "detail": "A close pass of Titan flings it up out of the planets' plane."},
        {"when": v2_fly[1], "title": "Voyager 2 · Saturn", "craft": "Voyager 2", "body": "Saturn",
         "detail": "Saturn's gravity sends it on toward Uranus."},
        {"when": v2_fly[2], "title": "Voyager 2 · Uranus", "craft": "Voyager 2", "body": "Uranus",
         "detail": "The only spacecraft ever to visit Uranus: 10 new moons found."},
        {"when": v2_fly[3], "title": "Voyager 2 · Neptune", "craft": "Voyager 2", "body": "Neptune",
         "detail": "The only visit to Neptune: the Great Dark Spot and geysers on Triton."},
        {"when": "1990-02-14 04:48", "title": "Pale Blue Dot", "craft": "Voyager 1",
         "detail": "From 6 billion km, Voyager 1 turns around and photographs Earth."},
        {"when": "2012-08-25 00:00", "title": "Voyager 1 enters interstellar space", "craft": "Voyager 1",
         "detail": "Crosses the heliopause, the edge of the Sun's bubble of solar wind."},
        {"when": "2018-11-05 00:00", "title": "Voyager 2 enters interstellar space", "craft": "Voyager 2",
         "detail": "The second human-made object to leave the heliosphere."},
    ], DATA_END)

def cassini():
    fly = ["1998-04-26 13:45", "1999-06-24 20:30", "1999-08-18 03:28", "2000-12-30 10:05"]
    L = "1997-10-15 08:43"
    def segs(Ld):
        s = flyby_windows(Ld, fly + ["2004-07-01 02:48"], end=utc("2004-06-01 00:00"))
        s.append((utc("2004-06-01 00:00"), utc("2017-04-20 00:00"), "6 h"))
        s.append((utc("2017-04-20 00:00"), utc("2017-09-16 00:00"), "1 h"))
        return s
    robotic("cassini", "Cassini–Huygens", [("Cassini", "-82", L, segs)],
            ["Venus", "Earth", "Jupiter", "Saturn"], [
        {"when": L, "title": "Launch", "craft": "Cassini",
         "detail": "Too heavy to fly straight to Saturn, it borrows speed from four planets."},
        {"when": fly[0], "title": "Venus flyby 1", "craft": "Cassini", "body": "Venus",
         "detail": "First gravity assist: a swing past Venus."},
        {"when": fly[1], "title": "Venus flyby 2", "craft": "Cassini", "body": "Venus",
         "detail": "Back to Venus for a second boost."},
        {"when": fly[2], "title": "Earth flyby", "craft": "Cassini", "body": "Earth",
         "detail": "Whips past Earth at about 1,200 km altitude."},
        {"when": fly[3], "title": "Jupiter flyby", "craft": "Cassini", "body": "Jupiter",
         "detail": "Last boost, and joint observations with the Galileo orbiter."},
        {"when": "2004-07-01 02:48", "title": "Arrives at Saturn", "craft": "Cassini", "body": "Saturn",
         "detail": "Fires its engine through a gap in the rings to enter orbit."},
        {"when": "2004-12-25 02:00", "title": "Huygens released", "craft": "Cassini",
         "detail": "The European Huygens probe separates and heads for Titan."},
        {"when": "2005-01-14 12:43", "title": "Huygens lands on Titan", "craft": "Cassini",
         "detail": "The most distant landing ever, on a moon with methane lakes."},
        {"when": "2017-04-26 09:00", "title": "Grand Finale begins", "craft": "Cassini",
         "detail": "22 dives through the gap between Saturn and its rings."},
        {"when": "2017-09-15 10:31", "title": "Final plunge", "craft": "Cassini",
         "detail": "Cassini dives into Saturn, sending data until the end."},
    ], None)

def new_horizons():
    fly = ["2007-02-28 05:43", "2015-07-14 11:49", "2019-01-01 05:33"]
    L = "2006-01-19 19:00"
    robotic("newhorizons", "New Horizons", [
        ("New Horizons", "-98", L, lambda Ld: flyby_windows(Ld, fly, end=DATA_END, cruise_step="2 d"))],
        ["Earth", "Jupiter", "Pluto", "Arrokoth"], [
        {"when": L, "title": "Launch", "craft": "New Horizons",
         "detail": "The fastest launch ever: past the Moon's orbit in 9 hours."},
        {"when": fly[0], "title": "Jupiter flyby", "craft": "New Horizons", "body": "Jupiter",
         "detail": "A gravity assist cuts three years off the trip to Pluto."},
        {"when": fly[1], "title": "Pluto flyby", "craft": "New Horizons", "body": "Pluto",
         "detail": "First close look at Pluto: the heart-shaped nitrogen glacier."},
        {"when": fly[2], "title": "Arrokoth flyby", "craft": "New Horizons", "body": "Arrokoth",
         "detail": "The most distant object ever explored, a snowman-shaped relic of the early solar system."},
    ], DATA_END)

# ----------------------------------------------------------------------------- Apollo 11

MU_E, MU_M = 398_600.4418, 4_902.800
R_E, R_M = 6378.137, 1737.4

A11 = {k: unix(utc(v)) for k, v in {
    "launch": "1969-07-16 13:32:00", "insertion": "1969-07-16 13:43:49",
    "tli_ign": "1969-07-16 16:16:16", "tli_cut": "1969-07-16 16:22:13",
    "loi": "1969-07-19 17:21:50", "undock": "1969-07-20 17:44:00", "doi": "1969-07-20 19:08:00",
    "pdi": "1969-07-20 20:05:05", "landing": "1969-07-20 20:17:40", "step": "1969-07-21 02:56:15",
    "liftoff": "1969-07-21 17:54:00", "ascent_ins": "1969-07-21 18:01:00", "docking": "1969-07-21 21:35:00",
    "jettison": "1969-07-22 00:01:00", "tei": "1969-07-22 04:55:42", "entry": "1969-07-24 16:35:05",
    "splash": "1969-07-24 16:50:35"}.items()}

def gmst(t):
    """Greenwich mean sidereal time (radians) at unix t."""
    d = (t / DAY + JD_UNIX0) - 2451545.0
    return math.radians((280.46061837 + 360.98564736629 * d) % 360)

EPS = math.radians(23.4392911)
def eq_to_ecl(v): return [v[0], math.cos(EPS)*v[1] + math.sin(EPS)*v[2], -math.sin(EPS)*v[1] + math.cos(EPS)*v[2]]

def earth_surface(t, lat_deg, lon_deg, alt=0.0):
    lat, lon = math.radians(lat_deg), math.radians(lon_deg) + gmst(t)
    r = R_E + alt
    return eq_to_ecl([r*math.cos(lat)*math.cos(lon), r*math.cos(lat)*math.sin(lon), r*math.sin(lat)])

def rk4_path(r, v, t0, t1, moon, dt=20.0):
    """Integrate geocentric motion under Earth + Moon (incl. indirect term). Returns [(t, r)]."""
    def acc(t, r):
        m = moon(t); d = sub(r, m)
        a = mul(r, -MU_E / norm(r)**3)
        a = add(a, mul(d, -MU_M / norm(d)**3))
        return add(a, mul(m, -MU_M / norm(m)**3))
    out, t, h = [(t0, r)], t0, dt if t1 > t0 else -dt
    while (t1 - t) * h > 0:
        step = h if abs(t1 - t) > abs(h) else (t1 - t)
        k1v = acc(t, r);                    k1r = v
        k2v = acc(t+step/2, add(r, mul(k1r, step/2))); k2r = add(v, mul(k1v, step/2))
        k3v = acc(t+step/2, add(r, mul(k2r, step/2))); k3r = add(v, mul(k2v, step/2))
        k4v = acc(t+step, add(r, mul(k3r, step)));     k4r = add(v, mul(k3v, step))
        r = add(r, mul(add(add(k1r, mul(k2r, 2)), add(mul(k3r, 2), k4r)), step/6))
        v = add(v, mul(add(add(k1v, mul(k2v, 2)), add(mul(k3v, 2), k4v)), step/6))
        t += step; out.append((t, r))
        if norm(r) < R_E + 50: break      # don't integrate through Earth
    return out if h > 0 else out[::-1]

def path_fn(samples):
    import bisect
    ts = [s[0] for s in samples]
    def f(t):
        i = max(0, min(len(ts) - 2, bisect.bisect_right(ts, t) - 1))
        w = (t - ts[i]) / (ts[i+1] - ts[i])
        return lerp(samples[i][1], samples[i+1][1], w)
    return f

def solve_conic(rp, R, tof, mu):
    """Eccentricity of a perigee-rp ellipse reaching radius R after `tof` s; returns (e, a, nu)."""
    def t_of(e):
        a = rp / (1 - e); p = a * (1 - e*e)
        c = (p / R - 1) / e
        if c < -1: return None
        nu = math.acos(max(-1, min(1, c)))
        E = 2 * math.atan(math.sqrt((1 - e) / (1 + e)) * math.tan(nu / 2))
        return (E - e * math.sin(E)) / math.sqrt(mu / a**3), a, nu
    lo, hi = 0.90, 0.99995
    for _ in range(200):
        mid = (lo + hi) / 2; r = t_of(mid)
        if r is None or r[0] > tof: lo = mid
        else: hi = mid
    e = (lo + hi) / 2; _, a, nu = t_of(e)
    return e, a, nu

def conic_fn(rp, e, a, t_peri, u_peri, w, mu, direction=1):
    """Earth-centered ellipse with perigee at t_peri along u_peri, moving toward w."""
    n = math.sqrt(mu / a**3)
    def f(t):
        M = n * (t - t_peri)
        E = M
        for _ in range(50): E = E - (E - e*math.sin(E) - M) / (1 - e*math.cos(E))
        nu = 2 * math.atan2(math.sqrt(1+e)*math.sin(E/2), math.sqrt(1-e)*math.cos(E/2))
        r = a * (1 - e*math.cos(E))
        return add(mul(u_peri, r*math.cos(nu)), mul(w, r*math.sin(nu)))
    return f

def build_apollo11():
    print("\n== Apollo 11 (reconstructed from the flight timeline)")
    t_a, t_b = utc("1969-07-16 12:00"), utc("1969-07-25 00:00")
    moon_rows = fetch_segments("301", [(t_a, t_b, "1 h")], center="500@399", units="KM-S")
    moon = Table(moon_rows, 1.0)
    moon_v = lambda t: moon.vel(t, 30)
    try:
        sivb_rows = fetch_segments("-399110", [(utc("1969-07-16 16:22"), utc("1969-07-16 21:00"), "5 m")],
                                   center="500@399", units="KM-S")
    except RuntimeError as e:
        print("  (no S-IVB data:", str(e).splitlines()[0], ")"); sivb_rows = []

    T = A11
    n_hat = unit(cross(moon(T["loi"]), moon_v(T["loi"])))   # Moon orbit normal (prograde)
    r_lo = R_M + 111.0
    w_lo = math.sqrt(MU_M / r_lo**3)                        # lunar-orbit angular rate
    # Inertial basis in the Moon's orbit plane
    ax = unit(moon(T["loi"])); bx = cross(n_hat, ax)

    # Landing site direction (rotates with the tidally locked Moon): 23.47°E, 0.67°N
    def site_dir(t):
        e1 = unit(mul(moon(t), -1)); e2 = cross(n_hat, e1)   # e2 = selenographic east (trailing side)
        L = math.radians(23.47); la = math.radians(0.67)
        d = add(mul(e1, math.cos(L)*math.cos(la)), mul(e2, math.sin(L)*math.cos(la)))
        return add(d, mul(n_hat, math.sin(la)))

    # CSM lunar orbit: retrograde circle θ(t) = θ0 − ω (t − t_land). Choose θ0 so the LM,
    # which decelerates linearly from orbital rate to zero during powered descent, lands on the site.
    pdi_dur = T["landing"] - T["pdi"]
    s_land = site_dir(T["landing"])
    phi_site = math.atan2(dot(s_land, bx), dot(s_land, ax))
    # LM angle at landing = θ(t_pdi) − ω·pdi_dur/2 ; θ(t_pdi) = θ0 + ω·pdi_dur
    theta0 = phi_site - w_lo * pdi_dur / 2
    def csm_theta(t): return theta0 - w_lo * (t - T["landing"])
    def orbit_pos(t, theta, r): return add(moon(t), add(mul(ax, r*math.cos(theta)), mul(bx, r*math.sin(theta))))
    def csm_orbit(t): return orbit_pos(t, csm_theta(t), r_lo)
    def csm_orbit_vel(t):  # inertial velocity: Moon + retrograde circular motion
        th = csm_theta(t); tang = add(mul(ax, math.sin(th)), mul(bx, -math.cos(th)))
        return add(moon_v(t), mul(tang, w_lo * r_lo))

    def far_side_time(t_nom):
        """Time within ±1 h of t_nom when the CSM is on the far side (opposite Earth)."""
        best = (1e99, t_nom); t = t_nom - 3600
        while t <= t_nom + 3600:
            rel = unit(sub(csm_orbit(t), moon(t))); d = -dot(rel, unit(mul(moon(t), -1)))
            if -d < best[0]: best = (-d, t)
            t += 30
        return best[1]

    t_join = far_side_time(T["loi"]); t_dep = far_side_time(T["tei"])

    # Approach: integrate backward from the far-side LOI point with the pre-burn velocity
    # (orbital + 889 m/s along the direction of motion), Earth + Moon gravity.
    v_join = csm_orbit_vel(t_join); rel_v = sub(v_join, moon_v(t_join))
    v_pre = add(moon_v(t_join), mul(unit(rel_v), norm(rel_v) + 0.889))
    back = path_fn(rk4_path(csm_orbit(t_join), v_pre, t_join, T["tli_cut"], moon))
    # Departure: TEI adds ~1.0 km/s along the motion, integrate forward toward Earth.
    v_dep = csm_orbit_vel(t_dep); rel_v = sub(v_dep, moon_v(t_dep))
    v_post = add(moon_v(t_dep), mul(unit(rel_v), norm(rel_v) + 1.0))
    fwd = path_fn(rk4_path(csm_orbit(t_dep), v_post, t_dep, T["entry"], moon))

    # Early trans-lunar coast: S-IVB data when available (CSM stayed with it for hours),
    # else an Earth-centered ellipse that reaches the Moon's distance at LOI.
    rp_out = R_E + 330
    if sivb_rows:
        sivb = Table(sivb_rows, 1.0); sivb_end = sivb.t[-1]; extrapolate = True
        # Carry the S-IVB's last recorded state forward under Earth + Moon gravity so the
        # early coast stays physical all the way to where it blends into the approach.
        coast = path_fn(rk4_path(sivb.p[-1], sivb.v[-1], sivb_end, t_join, moon))
        early = lambda t: sivb(t) if t <= sivb_end else coast(t)
        tli_point = sivb(sivb.t[0]); tli_t = sivb.t[0]
        plane_n = unit(cross(sivb.p[0], sivb.v[0]))
    else:
        e, a, nu = solve_conic(rp_out, norm(moon(t_join)), t_join - T["tli_cut"], MU_E)
        u_t = unit(moon(t_join)); w_t = cross(n_hat, u_t)
        u_p = add(mul(u_t, math.cos(-nu)), mul(w_t, math.sin(-nu))); w_p = cross(n_hat, u_p)
        early = conic_fn(rp_out, e, a, T["tli_cut"], u_p, w_p, MU_E); sivb_end = T["tli_cut"] + 4*3600
        extrapolate = False
        tli_t = T["tli_cut"]; tli_point = early(tli_t); plane_n = n_hat

    # The forward (from TLI) and backward (from LOI) coasts don't meet exactly; blend
    # them over a long stretch of the coast so the difference is spread out smoothly.
    blend_a, blend_b = T["tli_cut"] + 8 * 3600, t_join - 16 * 3600
    gap = max(norm(sub(early(t), back(t))) for t in (blend_a, (blend_a + blend_b) / 2, blend_b))
    print(f"  coast blend: forward/backward paths differ by up to {gap:,.0f} km")

    # Parking orbit (circular, 186 km), phased to meet the TLI point at cutoff.
    r_pk = R_E + 186; w_pk = math.sqrt(MU_E / r_pk**3)
    up = unit(tli_point); wp = cross(plane_n, up)
    def parking(t):
        th = -w_pk * (tli_t - t)     # reaches the TLI point's direction at tli_t
        return add(mul(up, r_pk*math.cos(th)), mul(wp, r_pk*math.sin(th)))

    # Return: blend the integrated path into an ellipse with perigee at entry interface.
    t_b2 = T["entry"] - 30 * 3600
    Pb = fwd(t_b2); rp_ret = R_E + 122
    e2, a2, nu2 = solve_conic(rp_ret, norm(Pb), T["entry"] - t_b2, MU_E)
    ret_n = unit(cross(Pb, sub(fwd(t_b2 + 60), Pb)))
    ub = unit(Pb); wb = cross(ret_n, ub)
    # Pb sits at true anomaly −nu2 (inbound); perigee direction is nu2 ahead of it.
    up2 = add(mul(ub, math.cos(nu2)), mul(wb, math.sin(nu2))); wp2 = cross(ret_n, up2)
    ret_conic = conic_fn(rp_ret, e2, a2, T["entry"], up2, wp2, MU_E)
    splash = lambda t: earth_surface(t, 13.3, -169.15)

    def csm(t):
        if t < T["insertion"]:   # ascent from the pad
            pad = earth_surface(T["launch"], 28.608, -80.604)
            w = smooth((t - T["launch"]) / (T["insertion"] - T["launch"]))
            return mul(slerp(unit(pad), unit(parking(T["insertion"])), w), R_E + (r_pk - R_E) * w)
        if t < T["tli_ign"]: return parking(t)
        if t < tli_t:            # TLI burn: blend parking → early coast
            return lerp(parking(t), early(min(t, tli_t)), smooth((t - T["tli_ign"]) / (tli_t - T["tli_ign"])))
        if t < t_join:           # coast: forward from TLI → backward from LOI, blended mid-way
            w = smooth((t - blend_a) / (blend_b - blend_a))
            return lerp(early(t), back(t), w)
        if t < t_dep: return csm_orbit(t)
        if t < T["entry"]:
            return lerp(fwd(t), ret_conic(t), smooth((t - t_b2) / (T["entry"] - 3*3600 - t_b2)))
        w = smooth((t - T["entry"]) / (T["splash"] - T["entry"]))
        return lerp(ret_conic(T["entry"]), splash(t), w)

    def lm(t):
        # Descent: follow the CSM orbit; descend to 15 km at PDI; powered descent to the site.
        if t < T["doi"]: return csm_orbit(t)
        if t < T["pdi"]:
            w = smooth((t - T["doi"]) / (T["pdi"] - T["doi"]))
            return orbit_pos(t, csm_theta(t), r_lo + (R_M + 15 - r_lo) * w)
        if t < T["landing"]:
            s = (t - T["pdi"]) / pdi_dur
            th = csm_theta(T["pdi"]) - w_lo * pdi_dur * (s - s*s/2)
            r = R_M + 15 * (1 - smooth(s))
            p = orbit_pos(t, th, r)
            # converge exactly onto the rotating site in the last moments
            return lerp(p, add(moon(t), mul(site_dir(t), R_M)), smooth((s - 0.85) / 0.15))
        if t < T["liftoff"]: return add(moon(t), mul(site_dir(t), R_M))
        if t < T["ascent_ins"]:
            s = (t - T["liftoff"]) / (T["ascent_ins"] - T["liftoff"])
            s0 = site_dir(T["liftoff"]); th0 = math.atan2(dot(s0, bx), dot(s0, ax))
            th = th0 - w_lo * (T["ascent_ins"] - T["liftoff"]) * s*s/2
            return orbit_pos(t, th, R_M + 18 * smooth(s))
        if t <= T["jettison"]:
            dur = T["ascent_ins"] - T["liftoff"]
            s0 = site_dir(T["liftoff"]); th_ins = math.atan2(dot(s0, bx), dot(s0, ax)) - w_lo * dur / 2
            lag = (th_ins - csm_theta(T["ascent_ins"]) + math.pi) % (2*math.pi) - math.pi
            w = min(1, (t - T["ascent_ins"]) / (T["docking"] - T["ascent_ins"]))
            return orbit_pos(t, csm_theta(t) + lag * (1 - smooth(w)), R_M + 18 + (r_lo - R_M - 18) * smooth(w))
        return csm_orbit(t)

    def sample(fn, t0, t1, dt=60):
        ts = [t0 + i * dt for i in range(int((t1 - t0) // dt) + 1)]
        if ts[-1] < t1: ts.append(t1)
        rows = []
        for t in ts:
            p = fn(t); a, b = fn(max(t0, t - 5)), fn(min(t1, t + 5))
            dtt = min(t1, t + 5) - max(t0, t - 5)
            v = mul(sub(b, a), DAY / dtt)
            rows.append((t, *p, *v))
        return rows

    csm_rows = sample(csm, T["launch"], T["splash"])
    lm_rows = sample(lm, T["undock"], T["jettison"])

    # ---- checks
    for name, rows, R0, body in [("Columbia", csm_rows, R_M, "Moon"), ("Eagle", lm_rows, R_M, "Moon")]:
        worst = min(norm(sub(r[1:4], moon(r[0]))) - R_M for r in rows)
        print(f"  {name}: lowest altitude above the Moon {worst:,.1f} km")
        if worst < -1: sys.exit(f"  ✗ {name} passes through the Moon")
    alt_e = min(norm(r[1:4]) - R_E for r in csm_rows[:-20])
    print(f"  Columbia: lowest altitude above Earth before splashdown {alt_e:,.0f} km")
    land = lm(T["landing"]); err = norm(sub(land, add(moon(T["landing"]), mul(site_dir(T["landing"]), R_M))))
    print(f"  Eagle: landing point error {err:.2f} km")
    if sivb_rows:
        for h in (1, 2, 3):
            t = sivb_rows[0][0] + h * 3600
            if t <= sivb_rows[-1][0]:
                print(f"  vs S-IVB at TLI+{h} h: {norm(sub(csm(t), Table(sivb_rows, 1.0)(t))):,.0f} km")

    def ev(k, title, detail, craft="Columbia"):
        return {"t": int(round(T[k])), "title": title, "detail": detail, "craft": craft}
    events = [
        ev("launch", "Launch", "Saturn V lifts off from Kennedy Space Center with Armstrong, Aldrin and Collins."),
        ev("insertion", "Earth orbit", "Parking orbit at about 190 km while systems are checked."),
        ev("tli_ign", "Trans-lunar injection", "The third stage fires for 6 minutes, sending them toward the Moon."),
        ev("loi", "Lunar orbit insertion", "Behind the Moon, out of contact, the engine slows them into orbit."),
        ev("undock", "Eagle undocks", "Armstrong and Aldrin separate in the lunar module.", "Eagle"),
        ev("pdi", "Powered descent", "Eagle's engine fires for the final 12½ minutes to the surface.", "Eagle"),
        ev("landing", "“The Eagle has landed”", "Touchdown in the Sea of Tranquility with seconds of fuel margin.", "Eagle"),
        ev("step", "First step", "“That's one small step for man, one giant leap for mankind.”", "Eagle"),
        ev("liftoff", "Lunar liftoff", "Eagle's ascent stage leaves the descent stage behind.", "Eagle"),
        ev("docking", "Docking", "Eagle rejoins Columbia in lunar orbit.", "Eagle"),
        ev("tei", "Trans-Earth injection", "Behind the Moon again, the engine fires to head home."),
        ev("splash", "Splashdown", "Columbia lands in the Pacific, 8 days, 3 hours after launch."),
    ]
    moon_out = pack_rows("Moon", moon_rows, 1.0, 1.0, DAY)
    earth_out = {"name": "Earth", "radiusKm": RADII_KM["Earth"], "t": [int(T["launch"]), int(T["splash"])],
                 "s": [0, 0, 0, 0, 0, 0] * 2}
    sun_dir = horizons("10", utc("1969-07-20 00:00"), utc("1969-07-20 01:00"), "1 h", center="500@399", units="KM-S")[0]
    mission = {"id": "apollo11", "name": "Apollo 11", "frame": "geocentric", "unitKm": 1.0,
               "start": int(T["launch"]), "end": int(T["splash"]),
               "sunDirection": [round(x, 6) for x in unit(sun_dir[1:4])],
               "bodies": [earth_out, moon_out],
               "craft": [pack_rows("Columbia", csm_rows, 1.0, 1.0, 1.0, label="Columbia"),
                         pack_rows("Eagle", lm_rows, 1.0, 1.0, 1.0, label="Eagle")],
               "events": events}
    write(mission)

if __name__ == "__main__":
    which = set(sys.argv[1:]) or {"apollo11", "voyager", "cassini", "newhorizons"}
    if "apollo11" in which: build_apollo11()
    if "voyager" in which: voyager()
    if "cassini" in which: cassini()
    if "newhorizons" in which: new_horizons()
