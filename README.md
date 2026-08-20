# km118_print

让 AI 接上快麦 / KM-118 USB 热敏卷纸打印机。

本仓库固化了两套在 Windows 下使用 **KM-118 80mm 热敏卷纸打印机** 的方案，
目标是让 AI agent、脚本、自动化流程直接把内容打到纸带上，而不是每次人工调打印设置。

| 路线 | 入口 | 原理 | 适合 |
|---|---|---|---|
| **GDI 驱动渲染** | `km118_receipt_print.ps1` / `km118_print_qr.ps1` | 驱动把 GDI 页面渲染成 TSPL 位图帧 | 打 Markdown 文档、二维码、一次性文件 |
| **RAW 协议直发** | `km118_tty.py` | 直接构造固件协议（TSPL + 快麦扩展）位图帧 | 流式输出、交互终端、逐行打印（电传打字机） |

两条路都经 wire 级实测验证。GDI 路线是"官方正门"，RAW 路线是逆向出来的"直通道"，
后者不依赖 GDI 渲染，任何进程都能把任意字节流变成纸带。

---

## 适用设备

- 打印机：KM-118（快麦，USB 连接，80mm 热敏卷纸，8 dots/mm）
- 系统：Windows（驱动已安装，打印机名 `KM-118`，端口 `USB002`）
- 字体：[LXGW WenKai Mono](https://github.com/lxgw/LxgwWenKai)（霞鹜文楷等宽，RAW 路线硬依赖）

---

## Quick Start

```powershell
# 1. 打一份 Markdown / 文本文档 (GDI 路线)
powershell -ExecutionPolicy Bypass -File ".\km118_receipt_print.ps1" -File doc.md -AutoLong

# 2. 打二维码 (GDI 路线)
powershell -ExecutionPolicy Bypass -File ".\km118_print_qr.ps1" -Text "https://github.com/tmzncty/km118_print"

# 3. 自检样张 (RAW 路线, 先 pip install pillow)
python km118_tty.py --selftest

# 4. 把任何东西打到纸带上 (RAW 路线)
python km118_tty.py --text "你好,纸带"
git log --oneline | python km118_tty.py
```

---

## RAW 路线：固件协议（逆向结论，wire 级实证）

**KM-118 固件既不吃普通 ESC/POS 文本，也不是 ZPL——它吃的是 TSPL + 快麦扩展。**

驱动 `KMPrtDrvUNI.dll` 内部嵌有 ZPL / TSPL / ESC 三套模板，按机型选择；
对 KM-118 抓到的真实输出字节流是完整的 TSPL 帧：

```text
SIZE 80.0 mm,80.0 mm
GAP 0.0 mm,0.0 mm
REFERENCE 0,0
SPEED 3
DENSITY 8
SET PEEL OFF
SET CUTTER OFF
SET PARTIAL_CUTTER OFF
SET TEAR ON
DIRECTION 0,0
SHIFT 0
OFFSET 0.0 mm
CLS
BITMAP 0,0,80,639,1,<51120 字节 1bpp 位图>
PRINT 1,1
```

完整逆向过程（驱动结构、数据流、每个坑的实测记录）见
[`docs/driver_reverse_engineering.md`](docs/driver_reverse_engineering.md)。

### 帧格式要点（每一条都是踩出来的）

1. **数字必须带 `.0 mm`**——`SIZE 80 mm,80 mm` 会被静默丢弃，`80.0 mm` 才认。
2. **BITMAP 的宽是字节宽不是点宽**——80 点 @8dots/mm 写 `80`，不是 `640`。
3. **极性：`bit=0` 出墨**——背景 `0xFF`、墨点 `0x00`，从 GDI 习惯的 1=黑要整体取反。
4. **缺完整 `SET …` 扩展头会被静默丢弃**——固件对格式不符的帧不报错、不报错、不出纸。
5. **帧尾必须 `PRINT 1,1`**。
6. **整份内容必须一个 spooler job / 一条字节流**。逐行小 job 连发会被
   spooler/USB 栈重排（17 行自检实测乱序）；单 job 字节流物理保序
   （706KB 大 job 实测顺序完美）。
7. **固件"正向"打印是 180° 倒置**，且驱动不替你纠正——内容要预旋 180° 再发。
   注意是**每行位图块预旋**，不是整页旋（整页旋会把行序一起反转）。
8. **作业结束时最后 4 行（12mm）留在热敏头与出纸口之间**——不是卡纸，是暂存区。
   结尾必须垫 ≥4 行空白（trail）把正文拽出来；下一份打印会自动把它顶出，
   所以 trail 留长一点（默认 6 行）无害。

### 写入通道（均免提权，自动选择）

- **spooler RAW**：winspool `WritePrinter`，`Datatype=RAW`。
- **USBPRINT 直写**：`CreateFile` + `WriteFile` 到 USB 打印接口
  （设备类 `{28d78fad-5a12-11d1-ae5b-0000f803a8c2}`），完全绕开 spooler。

---

## Teletype：古法电传打字机（`km118_tty.py`）

敲什么，纸带上就出现什么。每行文字栅格化为 640bit × 24px 的 1bpp 条
（3.0mm/行），攒页后整页一个 TSPL 帧、一个 job 发出。

```powershell
pip install pillow
```

| 用法 | 命令 |
|---|---|
| 交互模式：敲一行、回车、立即打一行 | `python km118_tty.py` |
| 管道模式：任何命令输出整段上纸带 | `git log \| python km118_tty.py` |
| 一次性打印 | `python km118_tty.py --text "HI"` |
| 自检样张（13 行单 job：lead 4 + 正文 7 + trail 6） | `python km118_tty.py --selftest` |

交互命令：`:q` 退出 / `:feed` 送一行空白 / `:banner` 重打横幅。

参数：`--lead N`（正文前垫 N 行空白作撕纸余量，默认 4）、
`--trail N`（正文后垫 N 行空白把内容拽出机器，默认 6，标定值 ≥4）。

自动换行按**实际像素宽度**（`font.getlength`）切，中英文均按字宽计算，
不是数字符；一条逻辑行折出的所有片段保证在同一个 job 内，不会乱序。

---

## 标定方法（可复用）

固件打印方向、行序、卡纸深度这类"纸带上的方向问题"，**不要猜，打编号**：

`calibrate.py` 发一个单 job 的 13 行标定纸带，每行标注 `ROW NN`
（NN = 缓冲区行号）：

```powershell
python calibrate.py
```

拍一张**整条纸带 + 出纸口**的照片，一次性锁定：

1. **行序方向**——沿纸带读 ROW 编号是 `00→12` 还是 `12→00`；
2. **作业间顺序**——spooler 是 FIFO 还是 LIFO；
3. **卡纸深度**——贴出纸口的最大 ROW 编号，比它大的行还留在机内，
   差几行 trail 就至少给几行。

本机的标定结论：行序 `00→12` 正确（buffer 第 0 行最先吐出）、作业间 FIFO、
卡纸深度 4 行 / 12mm。教训：多轮对着旋转/垂挂的纸带照片目测方向，
误判了至少三次；编号纸带一次锁定。

---

## GDI 路线：文档 / 二维码打印

`km118_receipt_print.ps1`（Markdown/文本）和 `km118_print_qr.ps1`（二维码）
走 Windows 驱动渲染。完整的稳定配置（纸型 `СƱ`、180° 旋转、`ReversePages`、
AutoLong、420mm 长页上限）、参数说明和故障排查：

→ [`docs/gdi_route.md`](docs/gdi_route.md)

---

## 文件布局

```text
km118_print/
├── README.md
├── km118_tty.py                    # 古法电传打字机引擎 (RAW 路线, 自包含)
├── calibrate.py                    # 编号标定纸带 (方向/行序/卡纸深度一次锁定)
├── km118_receipt_print.ps1         # GDI 路线: Markdown / 文本文档
├── km118_print_qr.ps1              # GDI 路线: 二维码
├── qr.png                          # 示例二维码
└── docs/
    ├── driver_reverse_engineering.md   # 驱动逆向调查报告 (完整证据链)
    ├── gdi_route.md                      # GDI 路线详细文档
    └── images/                           # 纸带照片 (selftest / 标定)
```

## 依赖汇总

| 路线 | 依赖 |
|---|---|
| GDI | Windows + KM-118 驱动 + PowerShell + LXGW WenKai Mono 字体 |
| RAW / Teletype | Windows + KM-118 驱动 + Python 3 + Pillow + LXGW WenKai Mono 字体 |

## 故障排查（跨路线）

### RAW 发送成功但不出纸

预期之外的行为。固件对格式不符的帧**静默丢弃**。逐条对照上文"帧格式要点"：
数字带 `.0 mm`？BITMAP 宽是字节宽？有完整 `SET …` 头？尾 `PRINT 1,1`？
位图取反了？内容预旋 180° 了？一个 job 整条发的？

### spooler 半死

频繁重启打印机后队列可能处于半死状态，重启一次 spooler / 打印机恢复。

### 打印很长、黄灯闪烁

别用 Windows 测试页验证小票机。清队列：

```powershell
Get-PrintJob -PrinterName "KM-118" | Remove-PrintJob
```

### 内容方向反了

- RAW 路线：内容没预旋 180°（`km118_tty.py` 已内置，勿手动再旋）。
- GDI 路线：`-ReversePages` + 默认 180° 旋转。

### 最后一行卡在机器里

不是卡纸，是热敏头到出纸口 12mm 暂存区。结尾加 `--trail 6`（默认已开），
或继续打印下一份，会被自动顶出。

---

## License

MIT

---

喵~ KM-118 已被 NET酱驯服。
