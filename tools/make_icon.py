import math, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops
out = sys.argv[1]
N = 2048                       # render at 2x, downsample for antialiasing
C = N / 2

def radial(size, inner, outer, cx, cy, r):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            d = min(1.0, math.hypot(x - cx, y - cy) / r)
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * d) for i in range(3))
    return img

# Background: deep indigo core fading to near-black
bg = radial(N // 4, (30, 34, 82), (4, 5, 14), N/8*0.95, N/8*0.9, N/8*1.45).resize((N, N), Image.BICUBIC)

# Stars
random.seed(7)
stars = Image.new("RGB", (N, N)); sd = ImageDraw.Draw(stars)
for _ in range(260):
    x, y = random.uniform(0, N), random.uniform(0, N)
    if math.hypot(x - C, y - C) < N * 0.43: continue
    r = random.choice([1.5, 2, 2, 3, 4]); b = random.randint(90, 230)
    sd.ellipse([x - r, y - r, x + r, y + r], fill=(b, b, min(255, b + 20)))
bg = ImageChops.add(bg, stars)

# Earth–Venus 8-year "flower": chord between the two planets every ~3.5 days
rE, rV = N * 0.40, N * 0.40 * 0.723
wE, wV = 2 * math.pi / 365.256, 2 * math.pi / 224.701
lines = Image.new("RGB", (N, N)); ld = ImageDraw.Draw(lines, "RGBA")
phase = -math.pi / 2
steps = 560
for k in range(steps):
    t = k * (8 * 365.256 / steps)
    ex, ey = C + rE * math.cos(wE * t + phase), C + rE * math.sin(wE * t + phase)
    vx, vy = C + rV * math.cos(wV * t + phase), C + rV * math.sin(wV * t + phase)
    ld.line([ex, ey, vx, vy], fill=(255, 196, 110, 34), width=3)
glow = lines.filter(ImageFilter.GaussianBlur(10))
bg = ImageChops.add(bg, ImageChops.add(lines, glow))

# Orbit rings
rings = Image.new("RGB", (N, N)); rd = ImageDraw.Draw(rings)
for r, col in [(rE, (110, 160, 255)), (rV, (255, 170, 90))]:
    rd.ellipse([C - r, C - r, C + r, C + r], outline=col, width=5)
bg = ImageChops.add(bg, ImageChops.multiply(rings, Image.new("RGB", (N, N), (150, 150, 150))))

# Sun with corona
sun = Image.new("RGB", (N, N)); dd = ImageDraw.Draw(sun)
for r, col in [(260, (90, 50, 10)), (190, (170, 100, 25)), (135, (255, 190, 70))]:
    dd.ellipse([C - r, C - r, C + r, C + r], fill=col)
sun = sun.filter(ImageFilter.GaussianBlur(55))
bg = ImageChops.add(bg, sun)
d = ImageDraw.Draw(bg)
R = 108; d.ellipse([C - R, C - R, C + R, C + R], fill=(255, 226, 140))
R = 72;  core = Image.new("L", (N, N)); ImageDraw.Draw(core).ellipse([C - R, C - R, C + R, C + R], fill=255)
bg.paste((255, 250, 225), mask=core.filter(ImageFilter.GaussianBlur(30)))

# Planets on their rings
def planet(cx, cy, r, col, halo):
    h = Image.new("RGB", (N, N)); ImageDraw.Draw(h).ellipse([cx - r*2.4, cy - r*2.4, cx + r*2.4, cy + r*2.4], fill=halo)
    global bg
    bg = ImageChops.add(bg, h.filter(ImageFilter.GaussianBlur(r)))
    ImageDraw.Draw(bg).ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
aE, aV = math.radians(-35), math.radians(200)
planet(C + rE * math.cos(aE), C + rE * math.sin(aE), 46, (90, 155, 255), (20, 45, 110))
planet(C + rV * math.cos(aV), C + rV * math.sin(aV), 40, (255, 205, 140), (100, 60, 20))

art = bg.resize((1024, 1024), Image.LANCZOS)
art.save(f"{out}/AppIcon-iOS.png")
art.convert("L").convert("RGB").save(f"{out}/AppIcon-iOS-tinted.png")

# macOS: Apple's grid — 824pt rounded square centered on a 1024 transparent canvas
inner = bg.resize((1648, 1648), Image.LANCZOS)
mask = Image.new("L", (1648, 1648)); ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1647, 1647], radius=370, fill=255)
mac = Image.new("RGBA", (2048, 2048), (0, 0, 0, 0))
shadow = Image.new("L", (2048, 2048)); ImageDraw.Draw(shadow).rounded_rectangle([200, 220, 1847, 1867], radius=370, fill=110)
mac.paste((0, 0, 0, 255), mask=shadow.filter(ImageFilter.GaussianBlur(24)))
mac.paste(inner, (200, 200), mask)
mac = mac.resize((1024, 1024), Image.LANCZOS)
for s in [16, 32, 64, 128, 256, 512, 1024]:
    mac.resize((s, s), Image.LANCZOS).save(f"{out}/mac-{s}.png")
