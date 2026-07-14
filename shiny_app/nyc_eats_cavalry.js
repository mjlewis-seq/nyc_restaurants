// ============================================================
//  NYC EATS — hackathon title animation, built entirely by script
//  For Cavalry (cavalry.scenegroup.co) — requires the JavaScript
//  Editor (a Pro feature): Window ▸ JavaScript Editor ▸ paste ▸ Run.
//
//  Before running: create a Composition that is 1920 x 1080,
//  24 fps, 240 frames (10 seconds), and make it active.
//
//  What it builds:
//   • midnight-blue sky, moon + twinkling stars
//   • a randomized Manhattan-ish skyline with lit windows
//   • a yellow cab driving across the street
//   • a pizza slice bouncing over the skyline
//   • a bagel rolling the other way
//   • DOHMH-style letter-grade cards (A / A / B) dropping onto rooftops
//   • "NYC EATS" title popping in with an overshoot + subtitle fade
//
//  Everything is plain keyframes, so after it runs you can grab any
//  layer and art-direct it by hand. Tweak the constants below first.
// ============================================================

const TITLE      = "NYC EATS";
const SUBTITLE   = "A HACKATHON SERVING THE FIVE BOROUGHS";
const W = 1920, H = 1080;
const GROUND = -H / 2 + 90;          // street level (comp origin is the centre)

// Palette
const SKY       = "#0b1030";
const SKY_GLOW  = "#1b2a5e";
const BUILDING  = "#141b3f";
const WINDOW    = "#ffd166";
const TAXI      = "#ffcc00";
const PIZZA     = "#f4a83c";
const CRUST     = "#c97b2d";
const PEPPERONI = "#c0392b";
const BAGEL     = "#d9a05b";
const CARD_BLUE = "#2b6cb0";
const NEON      = "#ff4d6d";

// Deterministic "random" so the skyline looks the same every run
let seed = 7;
function rnd() { seed = (seed * 9301 + 49297) % 233280; return seed / 233280; }

// ---------- small helpers ----------
function paint(id, hex)      { api.set(id, { "material.materialColor": hex }); }

function rect(name, w, h, x, y, hex) {
  const id = api.primitive("rectangle", name);
  api.set(id, { "generator.dimensions": [w, h], "position.x": x, "position.y": y });
  paint(id, hex);
  return id;
}

function dot(name, rx, ry, x, y, hex) {
  const id = api.primitive("ellipse", name);
  api.set(id, { "generator.radius": [rx, ry], "position.x": x, "position.y": y });
  paint(id, hex);
  return id;
}

// NOTE: alpha here is 0–1. If opacity looks wrong in your Cavalry
// build (some builds expose it as 0–100), multiply these by 100.
function fadeIn(id, from, to) {
  api.keyframe(id, from, { "material.alpha": 0 });
  api.keyframe(id, to,   { "material.alpha": 1 });
}

// ============================================================
// 1. SKY, MOON, STARS
// ============================================================
rect("Sky", W, H, 0, 0, SKY);
rect("Sky Glow", W, H * 0.5, 0, GROUND + H * 0.22, SKY_GLOW); // horizon glow

const moon = dot("Moon", 70, 70, 640, 320, "#f5f0d8");
fadeIn(moon, 6, 40);

const starGrp = api.create("group", "Stars");
for (let i = 0; i < 26; i++) {
  const s = dot("Star " + i, 3, 3, (rnd() - 0.5) * W * 0.95, 120 + rnd() * 380, "#ffffff");
  api.parent(s, starGrp);
  // twinkle: each star pulses on its own offset
  const t0 = Math.floor(rnd() * 40);
  api.keyframe(s, t0,       { "material.alpha": 0.15 });
  api.keyframe(s, t0 + 30,  { "material.alpha": 1 });
  api.keyframe(s, t0 + 60,  { "material.alpha": 0.25 });
  api.keyframe(s, t0 + 90,  { "material.alpha": 1 });
  api.keyframe(s, t0 + 140, { "material.alpha": 0.3 });
}

// ============================================================
// 2. SKYLINE — buildings rise from the street, windows flick on
// ============================================================
const skyline = api.create("group", "Skyline");
const rooftops = [];   // remembered so grade cards can land on them

let cursorX = -W / 2 + 40;
let b = 0;
while (cursorX < W / 2 - 60) {
  const bw = 90 + rnd() * 130;
  const bh = 180 + rnd() * 420;
  const bx = cursorX + bw / 2;
  b++;

  const bld = rect("Building " + b, bw, bh, bx, GROUND + bh / 2, BUILDING);
  api.parent(bld, skyline);
  rooftops.push({ x: bx, topY: GROUND + bh });

  // rise from below the street, staggered left → right
  const start = 2 + b * 2;
  api.keyframe(bld, start,      { "position.y": GROUND - bh / 2 });
  api.keyframe(bld, start + 18, { "position.y": GROUND + bh / 2 });

  // lit windows — every restaurant kitchen still working the late shift
  const cols = Math.floor(bw / 34), rows = Math.floor(bh / 60);
  for (let c = 0; c < cols; c++) {
    for (let r = 0; r < rows; r++) {
      if (rnd() > 0.42) continue;                       // most windows dark
      const wx = bx - bw / 2 + 24 + c * 34;
      const wy = GROUND + 36 + r * 60;
      const win = rect("Win " + b + "-" + c + "-" + r, 14, 20, wx, wy, WINDOW);
      api.parent(win, skyline);
      fadeIn(win, start + 14 + Math.floor(rnd() * 30), start + 26 + Math.floor(rnd() * 30));
    }
  }
  cursorX += bw + 14 + rnd() * 30;
}

// street
rect("Street", W, 90, 0, -H / 2 + 45, "#090c22");
const lane = rect("Lane Line", W, 6, 0, GROUND - 44, "#f5d34f");
api.set(lane, { "material.alpha": 0.5 });

// ============================================================
// 3. YELLOW CAB — drives left → right with a little suspension bounce
// ============================================================
const cab = api.create("group", "Yellow Cab");
api.parent(rect("Cab Body", 220, 60, 0, 0, TAXI), cab);
api.parent(rect("Cab Top", 110, 44, -10, 46, TAXI), cab);
api.parent(rect("Cab Window", 90, 30, -10, 44, "#0b1030"), cab);
api.parent(rect("Checker", 150, 10, 0, 0, "#111111"), cab);
api.parent(dot("Wheel L", 22, 22, -70, -34, "#0a0a0a"), cab);
api.parent(dot("Wheel R", 22, 22, 70, -34, "#0a0a0a"), cab);
api.parent(rect("Roof Light", 40, 14, -10, 74, "#ffffff"), cab);

api.set(cab, { "position.y": GROUND - 10 });
api.keyframe(cab, 24,  { "position.x": -W / 2 - 260 });
api.keyframe(cab, 110, { "position.x":  W / 2 + 260 });
// suspension judder
for (let f = 24; f <= 110; f += 8) {
  api.keyframe(cab, f,     { "rotation": 0 });
  api.keyframe(cab, f + 4, { "rotation": 1.4 });
}

// ============================================================
// 4. PIZZA SLICE — bounces across the rooftops
// ============================================================
const pizza = api.create("group", "Pizza Slice");
const slice = api.primitive("polygon", "Cheese");
api.set(slice, { "generator.sides": 3, "generator.radius": 70, "scale.y": 1.5, "rotation": 180 });
paint(slice, PIZZA);
api.parent(slice, pizza);
api.parent(rect("Crust", 122, 22, 0, 92, CRUST), pizza);
api.parent(dot("Pep 1", 12, 12, -14, 46, PEPPERONI), pizza);
api.parent(dot("Pep 2", 10, 10, 20, 20, PEPPERONI), pizza);
api.parent(dot("Pep 3", 9, 9, -4, -14, PEPPERONI), pizza);

// arc across the sky in 5 bounces, spinning as it goes
const hops = 5, pStart = 48, pEnd = 168;
for (let i = 0; i <= hops * 2; i++) {
  const f = pStart + (pEnd - pStart) * i / (hops * 2);
  const x = -W / 2 - 150 + (W + 300) * i / (hops * 2);
  const y = (i % 2 === 0) ? 40 : 330;                 // low, high, low, high…
  api.keyframe(pizza, Math.round(f), { "position.x": x, "position.y": y });
}
api.keyframe(pizza, pStart, { "rotation": 0 });
api.keyframe(pizza, pEnd,   { "rotation": 720 });

// ============================================================
// 5. BAGEL — rolls the other way along the street
// ============================================================
const bagel = api.create("group", "Bagel");
api.parent(dot("Bagel Body", 60, 60, 0, 0, BAGEL), bagel);
api.parent(dot("Bagel Hole", 22, 22, 0, 0, "#090c22"), bagel);
api.parent(dot("Seed 1", 4, 6, -30, 34, "#f2e2c4"), bagel);
api.parent(dot("Seed 2", 4, 6, 26, 38, "#f2e2c4"), bagel);
api.parent(dot("Seed 3", 4, 6, 0, -46, "#f2e2c4"), bagel);

api.set(bagel, { "position.y": GROUND + 40 });
api.keyframe(bagel, 90,  { "position.x": W / 2 + 160, "rotation": 0 });
api.keyframe(bagel, 190, { "position.x": -W / 2 - 160, "rotation": -1080 });

// ============================================================
// 6. GRADE CARDS — A / A / B drop onto rooftops (a DOHMH classic)
// ============================================================
const grades = ["A", "A", "B"];
grades.forEach((letter, i) => {
  // pick evenly spaced rooftops
  const roof = rooftops[Math.floor((i + 1) * rooftops.length / (grades.length + 1))];
  const grp = api.create("group", "Grade " + letter + " " + (i + 1));

  const card = rect("Card", 90, 110, 0, 0, "#f7fafc");
  api.set(card, { "generator.cornerRadius": 10 });      // harmless if unsupported
  api.parent(card, grp);
  api.parent(rect("Card Border", 90, 24, 0, 43, CARD_BLUE), grp);

  const g = api.create("textShape", "Letter " + letter);
  api.set(g, { "text": letter, "fontSize": 64, "position.y": -26 });
  paint(g, CARD_BLUE);
  api.parent(g, grp);

  // drop in with a squash-free overshoot bounce
  const t = 120 + i * 12, landY = roof.topY + 66;
  api.set(grp, { "position.x": roof.x });
  api.keyframe(grp, t,      { "position.y": H / 2 + 120 });
  api.keyframe(grp, t + 14, { "position.y": landY - 18 });
  api.keyframe(grp, t + 20, { "position.y": landY + 22 });
  api.keyframe(grp, t + 26, { "position.y": landY });
});

// ============================================================
// 7. TITLE — neon pop with overshoot, then subtitle fade
// ============================================================
const title = api.create("textShape", "Title");
api.set(title, { "text": TITLE, "fontSize": 190, "position.y": 150 });
paint(title, NEON);
api.keyframe(title, 150, { "scale.x": 0,    "scale.y": 0 });
api.keyframe(title, 162, { "scale.x": 1.15, "scale.y": 1.15 });
api.keyframe(title, 170, { "scale.x": 1,    "scale.y": 1 });
// neon flicker
api.keyframe(title, 174, { "material.alpha": 1 });
api.keyframe(title, 176, { "material.alpha": 0.35 });
api.keyframe(title, 178, { "material.alpha": 1 });
api.keyframe(title, 181, { "material.alpha": 0.5 });
api.keyframe(title, 184, { "material.alpha": 1 });

const sub = api.create("textShape", "Subtitle");
api.set(sub, { "text": SUBTITLE, "fontSize": 40, "position.y": 40 });
paint(sub, "#e8ecf7");
fadeIn(sub, 176, 196);

console.log("NYC EATS scene built — hit play!");
