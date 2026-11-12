// patch-server.mjs —— 给 wincu 的 MCP server 注入「鼠标托管闸门」
//
// 为什么需要打补丁：wincu（dsh-computer-use-win）是第三方 npm 包，升级会覆盖 server.mjs。
// 这个脚本把 tools/mouse-guard/guard-inline.mjs 里的闸门代码注入进去，并且：
//   · 幂等         —— 已经打过就报告「已是最新」，不重复插入（--force 会先删旧块再插新块）
//   · 锚点校验     —— 四处锚点任一处没命中就报错并**不写盘**（上游改了结构要人来看）
//   · 语法自检     —— 写盘前跑 `node --check`，语法不过不写
//   · 自动备份     —— 每个目标文件首次改动前存 <name>.bak-mouseguard-<时间戳>
//   · 可回滚       —— --revert 精确移除所有受标记区块
//
// 用法：
//   node tools/mouse-guard/patch-server.mjs            # 打补丁（幂等，默认 web profile）
//   node tools/mouse-guard/patch-server.mjs --force    # 强制重打（换 guard-inline 内容后）
//   node tools/mouse-guard/patch-server.mjs --revert   # 卸下闸门，恢复上游原样
//   node tools/mouse-guard/patch-server.mjs --dry-run  # 只看会改什么，不写盘
//   node tools/mouse-guard/patch-server.mjs --target <server.mjs 路径>   # 指定别的 profile（如 desktop）
//
// 2026-09-28：加 --target。桌面版（profiles\desktop）是独立的 wincu 副本，闸门要各打一份；
//   闸门自身的状态目录基于工作区（DSH_MOUSE_WS），所以两个 profile 共用同一份授权状态。
//
// 打完补丁后要重启 MCP server 进程才会生效（它在启动时把 server.mjs 读进内存）：
//   Stop-Process -Id <server.mjs 的 node pid>   →  dsh-mcp-client 会自动重连并重新同步工具表

import { readFileSync, writeFileSync, existsSync, copyFileSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GUARD_INLINE = path.join(HERE, "guard-inline.mjs");
const DEFAULT_TARGET = path.join(process.env.USERPROFILE || process.env.HOME || "", ".dsh", "profiles", "web",
  "node_modules", "dsh-computer-use-win", "mcp", "server.mjs");

const S = "// >>> DSH_MOUSE_GUARD_PATCH_V1 START";
const E = "// <<< DSH_MOUSE_GUARD_PATCH_V1 END";
const GS = "  // >>> DSH_MOUSE_GUARD_GATE START";
const GE = "  // <<< DSH_MOUSE_GUARD_GATE END";
const TS = "  // >>> DSH_MOUSE_GUARD_TOOL START";
const TE = "  // <<< DSH_MOUSE_GUARD_TOOL END";
const CS = "    // >>> DSH_MOUSE_GUARD_CASE START";
const CE = "    // <<< DSH_MOUSE_GUARD_CASE END";

const args = process.argv.slice(2);
const force = args.includes("--force");
const revert = args.includes("--revert");
const dryRun = args.includes("--dry-run");

// --target <路径>：给另一个 profile 的 wincu 副本打同一份闸门；不传则用默认（web profile）。
const targetFlag = args.indexOf("--target");
const TARGET = targetFlag >= 0 && args[targetFlag + 1] ? args[targetFlag + 1] : DEFAULT_TARGET;

/** 删掉夹在 start/end 之间的整块（含首尾标记行），返回 {text, count} */
function stripBlock(text, start, end) {
  let count = 0;
  let out = text;
  for (;;) {
    const i = out.indexOf(start);
    if (i < 0) break;
    const j = out.indexOf(end, i);
    if (j < 0) throw new Error(`发现 ${start} 但找不到对应的结束标记 —— 文件被手工改坏了，请人工检查`);
    const after = out.indexOf("\n", j);
    out = out.slice(0, i) + out.slice(after < 0 ? out.length : after + 1);
    count++;
  }
  return { text: out, count };
}

function stripAll(text) {
  let n = 0;
  for (const [s, e] of [[S, E], [GS, GE], [TS, TE], [CS, CE]]) {
    const r = stripBlock(text, s, e);
    text = r.text;
    n += r.count;
  }
  return { text, count: n };
}

if (!existsSync(TARGET)) {
  console.error(`✗ 找不到目标：${TARGET}`);
  process.exit(1);
}

const before = readFileSync(TARGET, "utf8");
const had = before.includes(S);

if (revert) {
  const { text, count } = stripAll(before);
  if (count === 0) { console.log("没有发现闸门区块，无需回滚"); process.exit(0); }
  if (dryRun) { console.log(`[dry-run] 会移除 ${count} 个区块`); process.exit(0); }
  copyFileSync(TARGET, `${TARGET}.bak-mouseguard-revert-${Date.now()}`);
  writeFileSync(TARGET, text, "utf8");
  console.log(`✓ 已移除 ${count} 个闸门区块并恢复上游原样`);
  process.exit(0);
}

if (had && !force && !dryRun) {
  const guardNow = readFileSync(GUARD_INLINE, "utf8").trim();
  console.log("⚠ server.mjs 已打过闸门补丁（幂等跳过）。要换 guard-inline 内容请用 --force。");
  console.log(`  当前注入块长度 ${(before.length)} 字节；guard-inline.mjs 长度 ${guardNow.length} 字节`);
  process.exit(0);
}

let text = before;
if (had) {
  const r = stripAll(text);
  text = r.text;
  console.log(`· 已移除旧区块 ${r.count} 处，准备重新注入`);
}

// guard-inline 用了 path.join —— 上游若删掉这行 import，闸门会在运行时炸，这里先卡住
if (!text.includes('import path from "node:path"')) {
  console.error("✗ 目标文件里没有 `import path from \"node:path\"` —— 闸门依赖它，请人工核对后再打补丁");
  process.exit(1);
}

const guardBody = readFileSync(GUARD_INLINE, "utf8").replace(/\s+$/, "");
const guardBlock = `${S}\n${guardBody}\n${E}\n`;

const gateBlock = `${GS}
  const __mgGateResult = await __mgGate(name, args);
  if (__mgGateResult) return __mgGateResult;
${GE}
`;

const toolBlock = `${TS}
  {
    name: "windows_computer_use_mouse_request",
    description: "在动手用鼠标/键盘/抢前台焦点之前，先向真人申请授权：弹出深色确认窗，写明你预计要调用多少次。规则（请遵守）：在一次会话里第一次调用会抢鼠标/键盘/前台焦点的工具（click / double_click / move / drag / scroll / type_text / keypress / activate_window / focus）之前，先调用本工具一次。返回值 choice=session（本会话完全托管，可以开始）|24h（24 小时托管）|user（被拒绝：用户正在用鼠标，绝对不要调用上述工具，改用只读 UIA 工具 + invoke/set_value、命令行脚本，或直接请用户操作）。若跳过本工具直接调用上述工具，闸门会自动替你弹同一个窗，但次数会显示为「未声明」。弹窗 120 秒无人应答时按 session 自动放行。",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["calls"],
      properties: {
        calls: { type: "integer", minimum: 1, maximum: 500, description: "预计需要多少次鼠标/键盘操作（1-500），会显示在确认窗上。" },
        reason: { type: "string", description: "一句话说明你要用鼠标做什么（中文），会显示在确认窗上。" }
      }
    }
  },
${TE}
`;

// 注意：注入的代码里本身含反引号模板串，所以这里用数组拼接而不是模板字面量
// （模板字面量里再嵌套反引号会在解析期就崩）。
const caseBlock = [
  CS,
  '    case "windows_computer_use_mouse_request": {',
  '      const calls = Math.max(0, Number(args?.calls || 0));',
  '      const reason = String(args?.reason || "");',
  '      __mgWriteJson(__mgPlanPath, { calls, reason, at: new Date().toISOString() });',
  '      const eff0 = __mgEffective();',
  '      if (eff0.allowed) {',
  '        return { content: [{ type: "text", text: `✅ 鼠标已授权：${eff0.why}。可以直接调用鼠标/键盘工具（预计 ${calls} 次）。` }] };',
  '      }',
  '      const res = await __mgAsk(calls, reason, "windows_computer_use_mouse_request");',
  '      const denied = __mgApplyChoice(res);',
  '      if (denied) return denied;',
  '      const label = res.choice === "24h" ? "完全托管 · 24 小时" : "完全托管 · 本会话";',
  '      const head = res.timeout ? `⚠ 授权窗 ${__mgTimeoutSec} 秒无人应答，已按「${label}」自动放行` : `✅ 用户选择「${label}」`;',
  '      return { content: [{ type: "text", text: `${head}。你可以开始调用鼠标/键盘工具了（预计 ${calls} 次）；运载窗口里会显示「鼠标完全托管」横幅，用户可随时收回。` }] };',
  '    }',
  CE,
  ''
].join("\n");

// ---- 四处锚点，逐处校验后插入（未命中就整体不写盘）----
const anchors = [];

// ① tools 数组末尾追加 mouse_request（锚点取 move_window 的收尾，避免撞上 wikiResources 的 `];`）。
//    注意用正则并把逗号设为可选：首打时这里是 `}` 紧跟 `];`，重打（--force 先拆旧区块）时
//    会剩成 `},`，写死字符串会在重打时失配 —— 实测踩过。
const reTool = /(        y: \{ type: "integer" \}\n      \}\n    \}\n  \}),?\n\];\n/;
if (!reTool.test(text)) anchors.push("tools 数组末尾（move_window 收尾 + ];）");
else text = text.replace(reTool, `$1,\n${toolBlock}];\n`);

// ② 闸门函数块插在 safeJson 之前（模块顶层，函数声明提升，callTool 运行时已就绪）
const aGuard = "\nfunction safeJson(value) {\n";
if (!text.includes(aGuard)) anchors.push("function safeJson 定义处");
else text = text.replace(aGuard, `\n${guardBlock}\nfunction safeJson(value) {\n`);

// ③ callTool 入口插闸门
const aGate = "async function callTool(name, args) {\n  switch (name) {\n";
if (!text.includes(aGate)) anchors.push("async function callTool 入口");
else text = text.replace(aGate, `async function callTool(name, args) {\n${gateBlock}  switch (name) {\n`);

// ④ switch 里加 case（插在 default 之前）
const aCase = "    default:\n      throw new Error(`Unknown tool: ${name}`);\n";
if (!text.includes(aCase)) anchors.push("callTool 的 default 分支");
else text = text.replace(aCase, `${caseBlock}${aCase}`);

if (anchors.length) {
  console.error("✗ 锚点未命中，未写盘（上游 server.mjs 结构变了，请人工核对）：");
  for (const a of anchors) console.error(`   - ${a}`);
  process.exit(1);
}

if (dryRun) {
  console.log(`[dry-run] 四处锚点全部命中，将写入 ${text.length} 字节（原 ${before.length}）`);
  process.exit(0);
}

// ---- 语法自检：不过就不写盘 ----
const tmp = `${TARGET}.patchcheck.mjs`;
writeFileSync(tmp, text, "utf8");
const chk = spawnSync(process.execPath, ["--check", tmp], { encoding: "utf8" });
if (chk.status !== 0) {
  try { writeFileSync(tmp.replace(/\.patchcheck\.mjs$/, ".patchcheck-failed.txt"), text, "utf8"); } catch { /* 留证失败就算了 */ }
  console.error("✗ 语法自检失败，未写盘：\n" + (chk.stderr || chk.stdout));
  process.exit(1);
}

if (!had) copyFileSync(TARGET, `${TARGET}.bak-mouseguard-${Date.now()}`);
writeFileSync(TARGET, text, "utf8");
try { unlinkSync(tmp); } catch { /* 校验副本，删不掉也不影响 */ }
console.log(`✓ 闸门已注入 ${TARGET}`);
console.log(`  会抢鼠标/键盘/前台焦点的工具 ${9} 个受拦（含 activate_window / focus）；新增工具 windows_computer_use_mouse_request`);
console.log("  生效方式：杀掉 MCP server 的 node 进程，dsh-mcp-client 会自动重连并加载新代码。");
