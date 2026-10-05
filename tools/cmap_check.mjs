import fs from 'node:fs';

const buf = fs.readFileSync('C:/Windows/Fonts/LXGWWenKaiMono-Regular.ttf');
// sfnt 表目录：version(4) numTables(2) searchRange(2) entrySelector(2) rangeShift(2)，然后每条 16 字节
const numTables = buf.readUInt16BE(4);
let cmapOff = -1;
for (let i = 0; i < numTables; i++) {
  const off = 12 + i * 16;
  const tag = buf.toString('latin1', off, off + 4);
  if (tag === 'cmap') { cmapOff = buf.readUInt32BE(off + 8); break; }
}
console.log('cmap 表偏移:', cmapOff);
// cmap 头：version(2) numTables(2)，子表条目 8 字节：platformID(2) encodingID(2) offset(4)
const subCount = buf.readUInt16BE(cmapOff + 2);
let best = -1;
for (let i = 0; i < subCount; i++) {
  const off = cmapOff + 4 + i * 8;
  const platform = buf.readUInt16BE(off);
  const encoding = buf.readUInt16BE(off + 2);
  const offset = buf.readUInt32BE(off + 4);
  const fmt = buf.readUInt16BE(cmapOff + offset);
  console.log(`  子表${i}: platform=${platform} encoding=${encoding} offset=${offset} format=${fmt}`);
  if ((platform === 3 && encoding === 10) || (platform === 0 && best === -1)) best = cmapOff + offset;
}
const cm = best;
const format = buf.readUInt16BE(cm);
let has;
if (format === 12) {
  const nGroups = buf.readUInt32BE(cm + 12);
  const groups = [];
  for (let i = 0; i < nGroups; i++) {
    const o = cm + 16 + i * 12;
    groups.push([buf.readUInt32BE(o), buf.readUInt32BE(o + 4), buf.readUInt32BE(o + 8)]);
  }
  has = cp => { for (const [s, e, g] of groups) if (cp >= s && cp <= e) return g + (cp - s) > 0; return false; };
} else if (format === 4) {
  const segCountX2 = buf.readUInt16BE(cm + 6);
  const segCount = segCountX2 / 2;
  const endOff = cm + 14, startOff = endOff + segCountX2 + 2, idDeltaOff = startOff + segCountX2, idRangeOff = idDeltaOff + segCountX2;
  const segs = [];
  for (let i = 0; i < segCount; i++) {
    segs.push({ end: buf.readUInt16BE(endOff + i * 2), start: buf.readUInt16BE(startOff + i * 2), delta: buf.readInt16BE(idDeltaOff + i * 2), ro: buf.readUInt16BE(idRangeOff + i * 2) });
  }
  has = cp => {
    for (const s of segs) {
      if (cp >= s.start && cp <= s.end) {
        if (s.start === 0xFFFF) return false;
        if (s.ro === 0) return ((cp + s.delta) & 0xFFFF) !== 0;
        const gi = buf.readUInt16BE(idRangeOff + (cp - s.start) * 2 + s.ro);
        return gi !== 0;
      }
    }
    return false;
  };
} else { console.log('未处理的 format:', format); process.exit(1); }

const cands = {
  '★(2605)': 0x2605, '☆(2606)': 0x2606, '✓(2713)': 0x2713, '✗(2717)': 0x2717,
  '√(221A)': 0x221A, '×(00D7)': 0x00D7, '｜(FF5C)': 0xFF5C, '·(00B7)': 0x00B7,
  '→(2192)': 0x2192, '—(2014)': 0x2014, '〔(3014)': 0x3014, '〕(3015)': 0x3015,
  '✱(2731)': 0x2731, '◆(25C6)': 0x25C6, '▲(25B2)': 0x25B2, '●(25CF)': 0x25CF,
  '✅(2705)': 0x2705, '❌(274C)': 0x274C, '🟠(1F7E0)': 0x1F7E0, '🔴(1F534)': 0x1F534, '🟡(1F7E1)': 0x1F7E1
};
console.log('\n符号覆盖:');
for (const [name, cp] of Object.entries(cands)) console.log(`  ${name} : ${has(cp) ? '有' : '无(豆腐块)'}`);

const dirs = [
  'X:/GPT/repos/The-Paper-Cosmos/docs/study/print/2026-10-05',
  'X:/GPT/repos/kaoyan-english-training-ledger/print/2026-10-05'
];
const missing = new Map();
let scanned = 0;
for (const d of dirs) {
  for (const f of fs.readdirSync(d)) {
    if (!f.endsWith('.md') || f.startsWith('PRINTABLE') || f.startsWith('PRINT_SOURCE')) continue;
    scanned++;
    const text = fs.readFileSync(d + '/' + f, 'utf8');
    for (const ch of text) {
      const cp = ch.codePointAt(0);
      if (cp < 0x2000) continue;
      if (cp >= 0x4E00 && cp <= 0x9FFF) continue;
      if (cp >= 0x3000 && cp <= 0x303F) continue;
      if (cp >= 0xFF00 && cp <= 0xFFEF) continue;
      if (/\s/.test(ch)) continue;
      if (!has(cp)) {
        const key = ch + '(U+' + cp.toString(16).toUpperCase() + ')';
        missing.set(key, (missing.get(key) || 0) + 1);
      }
    }
  }
}
console.log('\n扫描', scanned, '册，缺字形字符:');
if (missing.size === 0) console.log('  无');
for (const [k, v] of [...missing.entries()].sort((a, b) => b[1] - a[1])) console.log(`  ${k} ×${v}`);
