// ==========================================================================================
// DSH_MOUSE_GUARD_PATCH_V1 —— 鼠标托管闸门（由 tools/mouse-guard/patch-server.mjs 注入）
// ==========================================================================================
// 为什么要插在这里：wincu（dsh-computer-use-win）的 MCP server 是**唯一**所有物理鼠标/键盘
// 调用的必经之路 —— 不管调用者是主 agent、子 agent 还是 workflow 里的无人值守 agent，
// 都要走这个 server 进程。在它内部拦一道，等于给整台机器的鼠标上了一把总锁。
//
// 语义（2026-09-25 用户定稿）：
//   full-session : 「DSH 完全托管 · 本会话」—— sessionId 与当前活跃会话一致才放行
//   full-24h     : 「DSH 完全托管 · 24 小时」—— 24 小时内跨会话放行
//   blocked      : 「用户使用」—— 冷却 10 分钟，期间直接拒绝、不再弹窗打扰
//   其它/无状态  : 弹黄框红字授权窗（预计次数由 agent 先调 mouse_request 声明）
//   弹窗无人应答 : 120 秒后按 full-session 放行（用户选定的策略）
//
// 状态文件都在 <工作区>\.dsh-mouse\ 下，mg.ps1 / 运载窗口（live-monitor.ps1）读同一份。
// 改这里之后必须重跑 patch-server.mjs（server.mjs 里的这份是复制品）。

import { spawn as __mgSpawn } from "node:child_process";
import {
  readFileSync as __mgReadFile, writeFileSync as __mgWriteFile, appendFileSync as __mgAppendFile,
  existsSync as __mgExists, mkdirSync as __mgMkdir, readdirSync as __mgReaddir,
  statSync as __mgStat, renameSync as __mgRename, unlinkSync as __mgUnlink
} from "node:fs";

const __mgWS = process.env.DSH_MOUSE_WS
  || path.join(process.env.USERPROFILE || process.env.HOME || "", "Documents", "deepseek-harness", "默认工作区");
const __mgDir = path.join(__mgWS, ".dsh-mouse");
const __mgStatePath = path.join(__mgDir, "consent.json");
const __mgPlanPath = path.join(__mgDir, "plan.json");
const __mgNoticePath = path.join(__mgDir, "notice.json");
const __mgLogPath = path.join(__mgDir, "guard.log");
/** 定时托管窗口（2026-11-12 加）：window.json + 急停文件 STOP */
const __mgWindowPath = path.join(__mgDir, "window.json");
const __mgStopPath = path.join(__mgDir, "STOP");
const __mgConsentPs1 = path.join(__mgWS, "tools", "mouse-guard", "mouse-consent.ps1");

/** 「用户使用」被选中后，多久之内直接拒绝、不再弹窗打扰（用户可能正忙着） */
const __mgCooldownMs = 10 * 60 * 1000;
/** 弹窗无人应答的时长；到时按「本会话托管」放行 */
const __mgTimeoutSec = Number(process.env.DSH_MOUSE_TIMEOUT_SEC || 120);
/** 会抢鼠标/键盘/前台焦点的工具（只读工具如 snapshot/find/ocr 不在此列，不弹窗）
 *  2026-10-18：把 activate_window / focus 也纳入闸门 —— 它们不动物理指针，但会抢前台焦点，
 *  照样会打断用户打字（本日事故的直接原因）。 */
const __mgPhysicalTools = new Set([
  "windows_computer_use_click",
  "windows_computer_use_double_click",
  "windows_computer_use_move",
  "windows_computer_use_drag",
  "windows_computer_use_scroll",
  "windows_computer_use_type_text",
  "windows_computer_use_keypress",
  "windows_computer_use_activate_window",
  "windows_computer_use_focus"
]);

function __mgLog(msg) {
  try {
    __mgMkdir(__mgDir, { recursive: true });
    const ts = new Date().toLocaleString("zh-CN", { hour12: false });
    __mgAppendFile(__mgLogPath, `${ts}  server  ${msg}\n`, "utf8");
  } catch { /* 日志不该影响工具调用 */ }
}

function __mgReadJson(p) {
  try { return JSON.parse(__mgReadFile(p, "utf8")); } catch { return null; }
}

function __mgWriteJson(p, obj) {
  try {
    __mgMkdir(__mgDir, { recursive: true });
    const tmp = `${p}.tmp`;
    __mgWriteFile(tmp, JSON.stringify(obj), "utf8");
    __mgRename(tmp, p);
  } catch { /* 同上 */ }
}

/** 当前活跃会话 = ~/.dsh/sessions 下 mtime 最新的 session-*（不依赖 hook，会话切换自动跟着变） */
function __mgCurrentSession() {
  const root = path.join(process.env.USERPROFILE || "", ".dsh", "sessions");
  let best = "";
  let bestMs = 0;
  try {
    for (const ws of __mgReaddir(root)) {
      const wsDir = path.join(root, ws);
      let names;
      try { names = __mgReaddir(wsDir); } catch { continue; }
      for (const n of names) {
        if (!n.startsWith("session-")) continue;
        const f = path.join(wsDir, n, "session.v3.jsonl.zstd");
        try {
          const ms = __mgStat(f).mtimeMs;
          if (ms > bestMs) { bestMs = ms; best = n.slice("session-".length); }
        } catch { /* 没有日志文件的会话跳过 */ }
      }
    }
  } catch { /* 会话目录不可读时退化为空会话 id */ }
  return best;
}

/** "HH:MM" → 当日分钟数；非法返回 null */
function __mgMinute(value) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(value || "").trim());
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

/** 定时托管窗口：急停 {stop}；命中 {open,label}；未启用或不在窗口 null */
function __mgWindow() {
  if (__mgExists(__mgStopPath)) return { stop: true };
  const cfg = __mgReadJson(__mgWindowPath);
  if (!cfg || cfg.enabled !== true) return null;
  const a = __mgMinute(cfg.start);
  const b = __mgMinute(cfg.end);
  if (a === null || b === null) return null;
  const now = new Date();
  const minute = now.getHours() * 60 + now.getMinutes();
  // start===end 视为全天；start>end 视为跨午夜（例如 22:00–09:00）
  const open = a === b ? true : a < b ? minute >= a && minute < b : minute >= a || minute < b;
  if (!open) return null;
  const label = `${cfg.start}–${cfg.end}`;
  // 同一个窗口周期只记一条，避免每次点击都刷日志
  try {
    const mark = path.join(__mgDir, "window-logged");
    const key = `${now.toDateString()} ${label}`;
    let last = "";
    try { last = __mgReadFile(mark, "utf8"); } catch { /* 首次 */ }
    if (last !== key) {
      __mgWriteFile(mark, key, "utf8");
      __mgLog(`定时托管窗口生效：${label}（窗口内免授权放行鼠标/键盘）`);
    }
  } catch { /* 记不上也不影响放行 */ }
  return { open: true, label };
}

/** 当前授权是否有效（唯一判定入口） */
function __mgEffective() {
  const win = __mgWindow();
  if (win && win.stop) {
    return { mode: "window-stop", allowed: false, blocked: true, why: "定时托管已被急停文件 .dsh-mouse\\STOP 关闭" };
  }
  if (win && win.open) {
    return { mode: "window", allowed: true, why: `定时托管窗口 ${win.label}（免授权）` };
  }
  const st = __mgReadJson(__mgStatePath);
  if (!st || !st.mode || st.mode === "idle") return { mode: "idle", allowed: false, why: "尚未授权" };
  if (st.mode === "full-24h") {
    if (st.expiresAt && Date.parse(st.expiresAt) > Date.now()) {
      return { mode: "full-24h", allowed: true, why: `24 小时托管中（至 ${new Date(st.expiresAt).toLocaleString("zh-CN", { hour12: false })}）` };
    }
    return { mode: "idle", allowed: false, why: "24 小时托管已过期" };
  }
  if (st.mode === "full-session") {
    if (st.sessionId && st.sessionId === __mgCurrentSession()) return { mode: "full-session", allowed: true, why: "本会话托管中" };
    return { mode: "idle", allowed: false, why: "本会话托管已随会话切换失效" };
  }
  if (st.mode === "blocked") {
    if (st.blockedUntil && Date.parse(st.blockedUntil) > Date.now()) {
      const left = Math.ceil((Date.parse(st.blockedUntil) - Date.now()) / 60000);
      return { mode: "blocked", allowed: false, blocked: true, why: `用户正在用鼠标（冷却中，约剩 ${left} 分钟）` };
    }
    return { mode: "idle", allowed: false, why: "用户使用冷却已过" };
  }
  return { mode: "idle", allowed: false, why: "需要询问" };
}

const __mgDenyText = (why) => [
  `⛔ 用户拒绝了鼠标托管（${why}）。`,
  `请不要调用会抢鼠标/键盘/前台焦点的工具：click / double_click / move / drag / scroll / type_text / keypress / activate_window / focus。`,
  `可以改用的办法：`,
  `  ① 只读感知 + UIA 操作：windows_computer_use_snapshot / find / accessibility_tree / ocr 定位元素，再 invoke / set_value（走 UIA，不动物理指针、不抢前台）；`,
  `  ② 命令行/脚本自动化（pwsh 工具、程序自带 CLI、配置文件）；`,
  `  ③ 直接请用户手动操作，或等用户自己点「DSH 完全托管」后再继续。`
].join("\n");

/** 弹窗「单飞」：并发调用（子 agent / workflow 多路）只弹一个窗，其余等同一份结果，
 *  否则同一时刻会往桌面上叠一堆授权窗，用户点都点不过来。 */
let __mgInflight = null;

/** 弹一次授权窗（黄框红字、置顶），同步等结果文件；返回 { choice, timeout, ... } */
async function __mgAsk(calls, reason, toolName) {
  if (__mgInflight) {
    __mgLog(`已有授权窗在等用户选择，${toolName} 复用同一个结果`);
    return __mgInflight;
  }
  __mgInflight = __mgAskInner(calls, reason, toolName).finally(() => { __mgInflight = null; });
  return __mgInflight;
}

async function __mgAskInner(calls, reason, toolName) {
  __mgMkdir(__mgDir, { recursive: true });
  const session = __mgCurrentSession();
  const outFile = path.join(__mgDir, `result-${process.pid}-${Date.now()}.json`);
  try { __mgUnlink(outFile); } catch { /* 不存在正好 */ }

  // 运载窗口读这条：等着你选的黄红横幅
  __mgWriteJson(__mgNoticePath, {
    kind: "mouse-request",
    text: `鼠标请求：预计 ${calls > 0 ? `${calls} 次` : "次数未声明"} · 等你选择`,
    at: new Date().toISOString(),
    expiresAt: new Date(Date.now() + (__mgTimeoutSec + 90) * 1000).toISOString(),
    session
  });
  __mgLog(`弹窗：预计 ${calls > 0 ? calls + " 次" : "次数未声明"} · 首个工具 ${toolName}${reason ? " · " + reason : ""} · 会话 ${session || "?"}`);

  let child = null;
  try {
    child = __mgSpawn("powershell.exe", [
      "-NoProfile", "-ExecutionPolicy", "Bypass",
      "-File", __mgConsentPs1,
      "-Calls", String(calls || 0),
      "-Reason", String(reason || ""),
      "-ToolName", String(toolName || ""),
      "-TimeoutSec", String(__mgTimeoutSec),
      "-OutFile", outFile,
      "-Session", session
    ], { stdio: "ignore", windowsHide: true });
  } catch (e) {
    __mgLog(`拉起弹窗失败: ${e && e.message ? e.message : e}`);
    return { choice: "session", timeout: true, spawnFailed: true };
  }

  const deadline = Date.now() + (__mgTimeoutSec + 60) * 1000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 300));
    const res = __mgReadJson(outFile);
    if (res) { try { __mgUnlink(outFile); } catch { /* 无所谓 */ } return res; }
    if (child && child.exitCode !== null && !__mgExists(outFile)) {
      // 窗口脚本异常退出（比如 BOM 丢了导致解析失败）：等半秒再确认一次，然后按超时策略走
      await new Promise((r) => setTimeout(r, 500));
      const late = __mgReadJson(outFile);
      if (late) { try { __mgUnlink(outFile); } catch { /* 无所谓 */ } return late; }
      __mgLog(`弹窗进程提前退出（exit=${child.exitCode}）且没有结果文件 —— 按超时策略处理`);
      return { choice: "session", timeout: true, crashed: true };
    }
  }
  __mgLog("等待弹窗结果超时 —— 按超时策略处理");
  return { choice: "session", timeout: true, deadline: true };
}

/** 把用户选择落成状态；返回 null = 放行，否则返回给模型的拒绝结果 */
function __mgApplyChoice(res) {
  const now = new Date();
  const session = __mgCurrentSession();
  const choice = res && res.choice ? res.choice : "session";
  const timedOut = Boolean(res && res.timeout);

  if (choice === "user") {
    __mgWriteJson(__mgStatePath, {
      mode: "blocked", sessionId: session,
      blockedUntil: new Date(now.getTime() + __mgCooldownMs).toISOString(),
      updatedAt: now.toISOString(), source: "user", reason: String(res.reason || "")
    });
    __mgWriteJson(__mgNoticePath, {
      kind: "mouse-blocked", text: "用户使用中：DSH 已停止碰鼠标（10 分钟冷却）", at: now.toISOString()
    });
    __mgLog("用户选择「用户使用」→ 拒绝，进入 10 分钟冷却");
    return { isError: true, content: [{ type: "text", text: __mgDenyText("用户正在用鼠标") }] };
  }

  if (choice === "24h") {
    __mgWriteJson(__mgStatePath, {
      mode: "full-24h", sessionId: session,
      expiresAt: new Date(now.getTime() + 24 * 3600 * 1000).toISOString(),
      updatedAt: now.toISOString(), source: timedOut ? "timeout" : "user"
    });
    __mgWriteJson(__mgNoticePath, {
      kind: "mouse-granted", text: "鼠标完全托管 · 24 小时（不再询问）", at: now.toISOString()
    });
    __mgLog("已授予：「完全托管 · 24 小时」");
    return null;
  }

  __mgWriteJson(__mgStatePath, {
    mode: "full-session", sessionId: session,
    updatedAt: now.toISOString(), source: timedOut ? "timeout" : "user"
  });
  __mgWriteJson(__mgNoticePath, {
    kind: "mouse-granted", text: "鼠标完全托管 · 本会话", at: now.toISOString()
  });
  __mgLog(`已授予：「完全托管 · 本会话」${timedOut ? "（弹窗无人应答，超时自动放行）" : ""}`);
  return null;
}

/** 每次工具调用的闸门：返回 null = 放行；返回对象 = 直接给模型的结果 */
async function __mgGate(name, args) {
  if (!__mgPhysicalTools.has(name)) return null;
  const eff = __mgEffective();
  if (eff.allowed) return null;
  if (eff.blocked) {
    __mgLog(`拦下 ${name}：${eff.why}`);
    return { isError: true, content: [{ type: "text", text: __mgDenyText(eff.why) }] };
  }
  // 未授权：先看 agent 有没有声明过计划（mouse_request 工具或手工写的 plan.json）
  const plan = __mgReadJson(__mgPlanPath);
  const fresh = plan && plan.at && (Date.now() - Date.parse(plan.at) < 10 * 60 * 1000);
  const calls = fresh ? Number(plan.calls || 0) : 0;
  const reason = fresh ? String(plan.reason || "") : "";
  __mgLog(`拦下 ${name}：${eff.why} → 弹窗${fresh ? "" : "（agent 未声明计划次数）"}`);
  const res = await __mgAsk(calls, reason, name);
  return __mgApplyChoice(res);
}
