import fs from 'node:fs';
import path from 'node:path';

// md → 80mm 热敏打印适配转换器
// 规则：
//   1. 表格块 → 加粗列表（2/3/4 列自适应模板）
//   2. 字体缺字形 emoji → 有字形替代（🟡🟠🔴→【黄】【橙】【红】，✅→✓，❌→✗，⟹→→）
//   3. 其余内容原样

const SRC = [
  ['X:/GPT/repos/The-Paper-Cosmos/docs/study/print/2026-10-05', 'PC'],
  ['X:/GPT/repos/kaoyan-english-training-ledger/print/2026-10-05', 'KE']
];
const OUT = 'C:/Users/Administrator/.lux/km118/print_ready';

const EMOJI_MAP = [
  [/🟡/g, '【黄】'], [/🟠/g, '【橙】'], [/🔴/g, '【红】'],
  [/✅/g, '✓'], [/❌/g, '✗'], [/⟹/g, '→'],
  [/🟢/g, '【绿】'], [/🔵/g, '【蓝】'], [/🟣/g, '【紫】']
];

function fixEmoji(s) {
  for (const [re, to] of EMOJI_MAP) s = s.replace(re, to);
  return s;
}

function splitRow(line) {
  let t = line.trim();
  if (t.startsWith('|')) t = t.slice(1);
  if (t.endsWith('|')) t = t.slice(0, -1);
  return t.split('|').map(c => c.trim());
}

function isSep(line) {
  const t = line.trim().replace(/\|/g, '').replace(/:/g, '').replace(/-/g, '').trim();
  return t.length === 0 && line.includes('|');
}

function isRow(line) { return /^\s*\|.*\|\s*$/.test(line) || /^\s*\|/.test(line); }

function renderRow(cells) {
  const c = cells.map(x => x || '');
  if (c.length <= 2) return `- **${c[0]}** — ${c[1] || ''}`.replace(/ — $/, '');
  if (c.length === 3) return `- **${c[0]}**：${c[1]} — ${c[2]}`;
  // 4 列及以上：前两列合并，末列用 — 接出
  const head = c.slice(0, c.length - 1).join('，');
  return `- **${head}** — ${c[c.length - 1]}`;
}

function convert(text) {
  const lines = text.split('\n');
  const out = [];
  let i = 0;
  while (i < lines.length) {
    if (isRow(lines[i]) && i + 1 < lines.length && isSep(lines[i + 1])) {
      // 表格块：表头行 + 分隔行 + 数据行
      const header = splitRow(lines[i]);
      out.push(`> 列：${header.join(' · ')}`);
      i += 2;
      while (i < lines.length && isRow(lines[i])) {
        if (!isSep(lines[i])) out.push(renderRow(splitRow(lines[i])));
        i++;
      }
      continue;
    }
    out.push(lines[i]);
    i++;
  }
  return fixEmoji(out.join('\n'));
}

fs.mkdirSync(OUT, { recursive: true });
let n = 0;
for (const [dir, tag] of SRC) {
  for (const f of fs.readdirSync(dir).sort()) {
    if (!f.endsWith('.md') || f.startsWith('PRINTABLE') || f.startsWith('PRINT_SOURCE')) continue;
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    const conv = convert(src);
    const dst = path.join(OUT, f);
    fs.writeFileSync(dst, '\uFEFF' + conv, 'utf8');
    n++;
    const tableRows = src.split('\n').filter(l => isRow(l) && !isSep(l)).length;
    console.log(`${tag} ${f} -> print_ready/  (表格数据行 ${tableRows})`);
  }
}
console.log(`\n转换完成 ${n} 册 → ${OUT}`);
