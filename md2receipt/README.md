# md2receipt — Markdown 到 80mm 热敏小票的打印适配层

把任意 Markdown 文档打印成 KM-118 80mm 热敏小票。2026-10-05 在 19 册考研复习快照（13.1 米、约 43 页、19 个打印任务）上全量验证。

## 为什么需要这一层

`km118_receipt_print.ps1` 的渲染引擎（V5）本身直接吃 Markdown，但有三类内容在 80mm 纸上会出问题：

1. **表格**：引擎的表格解析被有意禁用（`IsTableRow` 直接 `return false`），Markdown 表格按原文打印，`|` 竖线全带出来，折行后接近天书（实测 E4 词汇册 72 行表格）。
2. **emoji**：LXGW WenKai Mono 字体缺 🟡🟠🔴✅❌ 等字形（cmap 实测），热敏纸也没有彩色，会印成豆腐块。
3. **中文文件名**：session 2 管道传递中文路径会碎（实测编码断裂），需要 ASCII 副本。

## 工具集

| 文件 | 用途 |
|---|---|
| `tools/md2receipt.mjs` | 转换器：表格→加粗列表、emoji→安全字符，批量处理目录 |
| `tools/cmap_check.mjs` | 解析 LXGW WenKai Mono 的 cmap（format 4/12），检测任意文档的缺字形字符 |
| `tools/km_wrapper.ps1` | 打印 wrapper：自动解析 `KM-118*` 队列名、进程内 splatting 传参 |
| `tools/session2_print.ps1` | session 2 注入打印（ SYSTEM 起 shell 时 GDI 打不开跨会话重定向打印机） |
| `tools/batch_print.ps1` | 批量打印：读队列文件逐册打印，日志落盘 |
| `tools/print_queue.example.txt` | 队列文件示例 |

## 转换规则

### 表格 → 加粗列表

表格块转换为「表头引用行 + 数据列表」，全宽度自动换行：

```markdown
| 词 | 义 | 备注 |          （原表格）
|---|---|---|
| grasp | 抓住；理解 | grasp the argument |
```

转换为：

```markdown
> 列：词 · 义 · 备注
- **grasp**：抓住；理解 — grasp the argument
```

列数自适应：2 列用 `**A** — B`；3 列用 `**A**：B — C`；4 列及以上前段合并、末列 `—` 接出。

### emoji → 安全字符

基于 cmap 实测（LXGW WenKai Mono，2026-10-05 版本）：

| 有字形（原样保留） | 缺字形（替换） |
|---|---|
| ★ ☆ ✓ ✗ √ × ｜ · → — 〔 〕 ◆ ▲ ● | 🟡→【黄】 🟠→【橙】 🔴→【红】 ✅→✓ ❌→✗ ⟹→→ |

颜色 emoji 语义用文字标签保真：状态表的 🟠→【橙】 在黑白热敏纸上反而比灰色圆块更可读。

### 排版纪律

- **不要手动预断行**：渲染引擎按可视宽度（CJK = 1.88 单位）自动折行，段落和列表项写成完整长行。手动预断行导致右边参差不齐 + 纸面浪费（实测同内容 366mm → 267mm，差 27%）。
- 中文文件名在入队列前复制为 ASCII 副本。

## 打印链路

```
md 源文件
  → md2receipt.mjs（表格/emoji 适配）
  → print_ready/ 目录（ASCII 名）
  → batch_print.ps1（读 print_queue.txt）
  → session2_print.ps1（计划任务注入 session 2）
  → km_wrapper.ps1 → km118_receipt_print.ps1（V5 引擎渲染）
  → RDP Easy Print → KM-118
```

### 前置条件

- KM-118 经 RDP 重定向到本机（队列名 `KM-118 (重定向 N)`，N 随会话变，wrapper 用通配符解析）
- 打印进程跑在持有重定向打印机的用户会话内（session 2）；SYSTEM 服务会话里 GDI OpenPrinter 报 InvalidPrinterException
- 字体：`C:\Windows\Fonts\LXGWWenKaiMono-{Regular,Medium}.ttf`
- Node.js（转换器与 cmap 检查用）

### 验证方法

每次批量打印后核对三点：每册 exit 0、本地队列排空（`Get-PrintJob -PrinterName 'KM-118*'`）、打印主机 spool\PRINTERS 目录 mtime 跳到触发时刻（无滞留即任务穿通道完成）。

## 实测数据（2026-10-05）

- 19 册 / 265KB Markdown → 13.1 米纸 / 43 页 / 19 任务，14:14:25 → 14:17:29 全部完成，零滞留
- 单册最长：01_文学理论 2105mm（5 页）；单页上限 420mm，超出自动分页
- 转换后内容量：表格数据行 125 行（E4×70、PC05×19、PC07×13、E3×13、PC01×8、E7×2）
- 估算器与引擎实测误差：00 册估算 274mm = 实打 274mm（校准一致）

## License

与仓库一致（Apache-2.0 / MIT 双许可）。
