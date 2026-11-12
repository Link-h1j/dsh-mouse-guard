// 单独校准 window 判定（不依赖 server.mjs）：把人造时间点塞进去，必须逐条对
function minute(v) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(v || "").trim());
  if (!m) return null;
  const h = Number(m[1]), mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}
function isOpen(cfg, hh, mm) {
  if (!cfg || cfg.enabled !== true) return null; // null = 不生效
  const a = minute(cfg.start), b = minute(cfg.end);
  if (a === null || b === null) return null;
  const t = hh * 60 + mm;
  return a === b ? true : a < b ? (t >= a && t < b) : (t >= a || t < b);
}

const cases = [
  ["夜间 00:00-09:00 @ 00:00", { enabled: true, start: "00:00", end: "09:00" }, 0, 0, true],
  ["夜间 00:00-09:00 @ 08:59", { enabled: true, start: "00:00", end: "09:00" }, 8, 59, true],
  ["夜间 00:00-09:00 @ 09:00", { enabled: true, start: "00:00", end: "09:00" }, 9, 0, false],
  ["夜间 00:00-09:00 @ 12:00", { enabled: true, start: "00:00", end: "09:00" }, 12, 0, false],
  ["夜间 00:00-09:00 @ 23:59", { enabled: true, start: "00:00", end: "09:00" }, 23, 59, false],
  ["跨午夜 22:00-09:00 @ 22:00", { enabled: true, start: "22:00", end: "09:00" }, 22, 0, true],
  ["跨午夜 22:00-09:00 @ 23:59", { enabled: true, start: "22:00", end: "09:00" }, 23, 59, true],
  ["跨午夜 22:00-09:00 @ 00:00", { enabled: true, start: "22:00", end: "09:00" }, 0, 0, true],
  ["跨午夜 22:00-09:00 @ 08:59", { enabled: true, start: "22:00", end: "09:00" }, 8, 59, true],
  ["跨午夜 22:00-09:00 @ 09:00", { enabled: true, start: "22:00", end: "09:00" }, 9, 0, false],
  ["跨午夜 22:00-09:00 @ 12:00", { enabled: true, start: "22:00", end: "09:00" }, 12, 0, false],
  ["全天 05:00-05:00 @ 13:00", { enabled: true, start: "05:00", end: "05:00" }, 13, 0, true],
  ["关闭 enabled=false", { enabled: false, start: "00:00", end: "09:00" }, 3, 0, null],
  ["非法时间 25:00", { enabled: true, start: "25:00", end: "09:00" }, 3, 0, null],
  ["缺字段", { enabled: true }, 3, 0, null],
];

let pass = 0, fail = 0;
for (const [name, cfg, hh, mm, want] of cases) {
  const got = isOpen(cfg, hh, mm);
  const ok = got === want;
  if (ok) pass++; else fail++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}  → ${JSON.stringify(got)}${ok ? "" : "  期望 " + JSON.stringify(want)}`);
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
