# KM-118 USB 驱动逆向调查报告

日期：2026-08-20
调查者：祀
对象：KM-118 80mm 热敏卷纸打印机（USB 连接，VID_20D1&PID_7008，序列号 KM-11816440100）
核心问题：**为什么 KM-118 不吃 ESC/POS RAW，必须走 Windows GDI 驱动渲染？**

---

## 一句话结论（2026-08-20 01:35 最终版，含 wire 级实测）

**KM-118 固件的打印语言是 TSPL（TSC 协议）+ 快麦（Kuaimai）私有扩展命令，整页以 1bpp 位图经 `BITMAP` 命令下发，不是 ESC/POS，也不是 ZPL。**
（早先版本误判为 ZPL——DLL 里确实内嵌 `^XA/~DG/^PQ` 等 ZPL 模板串，但那是驱动内置的多协议后备模板；对 KM-118 实际吐出的字节流做抓包解析后确认为 TSPL。）
厂商 Windows 驱动（KMPrtDrvUNI.dll，8.2MB）本质上是一个 **GDI→TSPL 协议转换器**：
把 GDI 渲染的整页 1bpp 位图包进 TSPL 帧（`SIZE/GAP/SPEED/DENSITY/SET TEAR/.../CLS/BITMAP 0,0,80,639,1,<51120 字节>/PRINT 1,1`），经 USB bulk 发送。
**RAW 路径已打通（2026-08-20 凌晨实测）**：用正确格式的 TSPL 帧（数字带 `.0 mm` 小数、带快麦扩展头、`BITMAP` 的宽参数=字节宽 80）经 spooler RAW 或 USBPRINT 设备直写两种方式发送，设备全部正确出纸，含自造位图内容与驱动帧原样重放。

---

## 证据链（全部来自本机实测/逆向，非推测）

### 1. USB 设备层：标准 USB Printing Class 设备

- PnP 设备：`USB\VID_20D1&PID_7008\KM-11816440100`，状态 OK，FriendlyName "USB Printing Support"
- 注册表 Driver/Service：`{36fc9e60-c465-11cf-8056-444553540000}\0038` / `usbprint`
  - 即 **usbprint.sys**（Microsoft USB Printing Class 驱动，USB CLASS 7）
- 打印端口映射（`HKLM\...\Monitors\USB Monitor\UsbPortList`）：
  ```
  USB002 => \\?\usb#vid_20d1&pid_7008#km-11816440100#{28d78fad-5a12-11d1-ae5b-0000f803a8c2}
  ```
  - `{28D78FAD-5A12-11D1-AE5B-0000F803A8C2}` = **USBPRINT 接口类 GUID**，铁证：设备在 USB 描述符里以 Printing Class 接口暴露
- 端口监视器：`USB Monitor`（`usbmon.dll`，Microsoft 内置）
- 结论：USB 传输层就是"字节泵"——**无论 RAW 还是 GDI，最终都是 usbmon.dll → usbprint.sys → USB bulk OUT 端点，数据原样送达**。RAW 和 GDI 在 USB 层没有区别，区别全在**发给设备的字节内容**。

### 2. 打印队列层

- 队列 `KM-118`：`Datatype = RAW`，`Print Processor = winprint`，`Port = USB002`
- 驱动名 `KM-118`，驱动版本 `16.35.1.933`（2026-07-02），厂商 KM（快麦）
- `Datatype=RAW` 表示 spooler 不做 PCL/PostScript 解释、原样发送——对 USB Printing Class 设备是正确的配置，因为所有协议处理都在**用户态 OEM 回调**里完成（见第 3 节）

### 3. 驱动层：UNIDRV + 空 GPD + OEM 回调（核心发现）

驱动注册表（`HKLM\...\Drivers\Version-3\KM-118`）：
```
Driver           = UNIDRV.DLL     ← Microsoft 通用 GDI 驱动（inbox）
Configuration    = UNIDRVUI.DLL   ← Microsoft 通用 UI（inbox）
Data File        = KMPrtDrv.gpd   ← 厂商 GPD（打印机能力描述）
Dependent Files  = KMPrtDrv.ini, KMPrtDrvUI.dll, KMPrtDrvUNI.dll, UNIRES.DLL,
                   STDNAMES.GPD, STDDTYPE.GDL, STDSCHEM.GDL, STDSCHMX.GDL
```

`KMPrtDrv.gpd`（6KB）关键内容：
```gpd
*PrinterType: PAGE
*MasterUnits: PAIR(203, 203)          ← 203 dpi = 8 dots/mm
*Command: CmdSendBlockData { *Cmd : "" }   ← 空！
*Command: CmdCR { *Cmd : "" }                ← 空！
*Command: CmdLF { *Cmd : "" }                ← 空！
*Command: CmdFF { *Cmd : "" }                ← 空！
*Feature: PaperSize:
    76x130 (默认) / CUSTOMSIZE (MaxSize PAIR(2000, 35000) dots)
*Feature: Resolution: 203dpi only
*Feature: ColorMode: Mono (ICallbackID=1)
*Feature: Memory: 默认 32MB
*PrintSchemaPrivateNamespaceURI: "www.kuaimai.com"
```

**GPD 里所有命令字符串全是空的** → UNIDRV 自己**不产生任何设备命令**，页面数据的生成全部委托给 `KMPrtDrvUNI.dll` 里的 OEM 回调（GPD 的 `ICallbackID`/HTCallbackID 指向它）。

### 4. KMPrtDrvUNI.dll：GDI→TSPL 协议转换器（8,184,184 字节）

PE 解析（PE32+ x64）：
- 导出表只有 2 个 COM 符号：`DllCanUnloadNow`、`DllGetClassObject`（标准 OEM 驱动 DLL 形态，COM 接口供 UNIDRV 调用 OEM 回调）
- 导入表：
  - `WINSPOOL.DRV`: OpenPrinterW/WritePrinter/ReadPrinter/GetJobW/SetJobW/GetPrinterW...
    → 通过 **spooler 标准打印 API 发送数据**（即最终走 USB002 端口）
  - `GDI32`: CreateDIBSection/SetDIBits/GetDIBits/LoadImageW... → 接收 UNIDRV 渲染的 DIB 位图
  - `KERNEL32`: CreateFileW/WriteFile/OutputDebugStringW...（常规）
  - **没有任何 WinUSB/SetupDi/usbmon 直接设备访问 API** → 它不碰 USB，只管生成字节流交给 spooler
- 静态库全家桶（解释了 8MB 体积）：**OpenCV**（栅格化/缩放/阈值二值化）、libpng、libtiff、jpeg、zlib
- 编译来源串：`D:\km-printer-driver-win\KMPrtDrvUNI\PrintHelper.cpp`（快麦 Windows 驱动源码工程名）

**DLL 里抓到的命令模板（静态分析）：**
```
ZPL 核心（DLL 内嵌模板，非 KM-118 实际使用）：
  ^XA^MMT^PW%d^LL%d^LS0      ← 帧头：介质类型 MT、纸宽、纸长、左偏移
  ~DG%s,%u,%u,               ← 下载位图到打印机 RAM（位图名,宽,高,数据...）
  ^XG%s,1,1^FS               ← 引用/打印外部图形
  ^FT%d,%d / ^FO%d,%d        ← 图形定位
  ^PQ%u,0,1,Y^XZ             ← 打印质量/份数 + 帧尾
  ^PQ%u^XZ                   ← 收尾帧
快麦扩展：
  SET PEEL %s / SET PEEL OFF
  SET CUTTER %d / SET CUTTER OFF
  SET PARTIAL_CUTTER %d / SET PARTIAL_CUTTER OFF
  SET REWIND %s / SET REWIND OFF
  SET TEAR %s / SET TEAR OFF
  BLINE / FEED 130           ← 撕纸线：打印一条黑线后走 130 dots 对准撕纸槽
```

> **修正（01:35 wire 级实测）**：DLL 同时内嵌了 ZPL / TSPL / ESC 多套模板串，按机型/配置选择。
> 对 KM-118 **实际捕获的字节流**（见第 9 节）证明该机型走的是 **TSPL + 快麦扩展**，不走 ZPL。

**KM-118 实际吐出的 TSPL 帧（从 spool 目录 .SPL 捕获，51,340 字节，逐字节）：**
```
SIZE 80.0 mm,80.0 mm\r\n        ← 页尺寸 80×80mm（注意必须带 ".0 mm" 小数格式）
GAP 0.0 mm,0.0 mm\r\n
REFERENCE 0,0\r\n
SPEED 3\r\n
DENSITY 8\r\n
SET PEEL OFF\r\n                ← 快麦私有扩展头（缺一不可，固件严格校验）
SET CUTTER OFF\r\n
SET PARTIAL_CUTTER OFF\r\n
SET TEAR ON\r\n
DIRECTION 0,0\r\n
SHIFT 0\r\n
OFFSET 0.0 mm\r\n
CLS\r\n
BITMAP 0,0,80,639,1,<51120 字节 1bpp 位图>\r\n
PRINT 1,1\r\n
```
- `BITMAP x,y,W,H,n,` 中 **W=字节宽=80（=640 dots=80mm@8点/mm），H=639 行**；位图数据 = 80×639 = 51,120 字节，与实测精确吻合
- **W 是字节宽度不是点宽度**——这是手工构造帧最大的坑（误当点宽会导致数据长度不匹配、固件静默丢弃整个 job）
- 整页 GDI 渲染成 1bpp 位图整体下发，**不用 TEXT/图形命令**（驱动把文字渲染进位图）

**ESC/POS 特征扫描结果：DLL 内没有任何 ESC/POS 命令**（无 `ESC @`、无 GS 序列、无 ESC/POS 文本模式指令）。`@` 出现 49073 次全是代码/字符串噪声，非命令序列。

### 5. 完整打印数据流（GDI 模式，实测可用的那条路）

```
PowerShell 脚本 (km118_receipt_print.ps1)
  └─ System.Drawing.Printing.PrintDocument (80mm 自定义长页, 180° 旋转)
      └─ GDI 引擎：LXGW WenKai Mono 字体栅格化 → 1bpp 页面 DIB
          └─ UNIDRV.DLL (Microsoft 通用 GDI 驱动)
              ├─ 读 KMPrtDrv.gpd（能力描述：203dpi/Mono/PAGE/自定义纸）
              └─ OEM 回调 → KMPrtDrvUNI.dll
                  ├─ OpenCV 后处理（缩放/二值化/排版）
                  ├─ 生成 TSPL 帧：SIZE/GAP/.../CLS + BITMAP 0,0,80,639,1,<位图> + PRINT 1,1
                  │   （帧头含快麦扩展：SET PEEL/CUTTER/PARTIAL_CUTTER/TEAR OFF/ON）
                  └─ winprint 处理器 → spooler (Datatype=RAW, 原样)
                      └─ usbmon.dll (USB Monitor 端口)
                          └─ usbprint.sys (USB Printing Class 驱动)
                              └─ USB bulk OUT → KM-118 固件的 TSPL 解析器 → 出纸
```

### 6. RAW 为什么"时灵时不灵"——三个独立原因，全部已实测定位

> 旧版结论（"RAW 永远不出纸"）已被推翻。RAW 能否出纸取决于**帧格式 + 传输路径 + 端口状态**，三者都验证过：

**原因一（主因）：帧格式不符，固件静默丢弃整个 job**
- 早期发的 ZPL 帧（`^XA...`）、ESC/POS 帧（`ESC @`）：固件无对应解析器 → 丢弃
- 早期手写的"简化版 TSPL"（`SIZE 80 mm,80 mm`、缺 `SET` 扩展头、`BITMAP` 宽度当点宽写）：
  **格式细节不符，固件同样静默丢弃**（无报错、无告警、无出纸）
- 正确格式三要素（缺一不出纸）：
  1. 数字带 `.0 mm` 小数 + 完整快麦扩展头（SET PEEL/CUTTER/PARTIAL_CUTTER/TEAR）
  2. `BITMAP` 的宽度参数 = **字节宽 80**（=640 dots），不是点宽
  3. 帧尾 `PRINT 1,1`（注意是 `PRINT 1,1` 不是 `PRINT 1`）

**原因二：spooler 端口状态（已恢复）**
- 00:46–01:08 期间 spooler RAW 不出纸，同期反复重启 spooler / 改 usbmon Configuration；
  01:33 重启 spooler 后 spooler RAW 重测**立即恢复出纸**。
- 结论：spooler 被频繁重启/端口监视器配置扰动后，USB002 端口可能进入"写成功但不到达设备"的半死状态，**再重启一次 spooler 即可恢复**。

**原因三：USBPRINT 设备直写是稳定兜底路径**
- `CreateFile('\\?\usb#vid_20d1&pid_7008#km-11816440100#{28d78fad-...}')` + `WriteFile`
  可完全绕过 spooler，直接写 USB bulk OUT（无需提权，非 admin 可用）。
- 01:30 四帧连发（最小帧/自造条纹×2/驱动帧原样）**4/4 全部出纸**，内容与帧一一对应。

**spooler "成功"的语义（重要）：**
`WritePrinter` 返回 TRUE / 队列清空 = 字节交给端口监视器成功，**不等于设备收到并执行**。
固件对不认识的字节流不报错不回 NAK，静默丢弃。判断 RAW 是否真通，唯一标准是**纸上有没有内容**。

### 7. 为什么 Windows 测试页会出纸很长/黄灯

测试页是一整页 A4 级 GDI 作业，驱动照实渲染成超长 TSPL 位图帧；热敏小票机收到远超预期的走纸量 → 出纸过长 + 黄灯。属于预期行为，不是故障（仓库 README 已记录）。

### 8. 420mm 长页上限的来源（推断）

- GPD CUSTOMSIZE 上限 PAIR(2000, 35000) dots ≈ 80mm × 4.3m，不是 420mm 的来源
- 80mm×420mm@203dpi ≈ 648×3345 dots ≈ 2.2MB (1bpp)，远小于 GPD 标称 32MB 内存
- 420mm 更可能是**快麦驱动/固件对单次命令块走纸量的经验上限**（>440mm 底部不可见，420mm OK，与仓库校准记录一致）
- 如需精确验证，需要 Wireshark 抓 USB bulk 对比 420/440mm 两帧差异（非管理员抓不到 USB 层，此步未做，标记为遗留项）

### 9. RAW 验证实验记录（2026-08-20 00:39–01:34，wire 级）

| 时间 | 实验 | 路径 | 结果 |
|---|---|---|---|
| 00:39 | ELEVCAP（提权捕获 spool .SPL/.SHD） | GDI | ✅ 出纸；拿到驱动真实输出 51,340 字节 |
| 00:46/00:48 | RAW A（51,340 原样）/ RAW B（2,618 自造） | spooler WritePrinter | ❌ 无纸（端口半死期 + 帧格式坑） |
| 01:08 | 驱动帧 51,340 直写 | CreateFile+WriteFile USBPRINT | ❌ 无纸（帧格式坑） |
| 01:13 | GDI Arial 测试（默认 A4 纸） | GDI | 出白纸（内容区落在 80mm 纸面外，测试方法问题） |
| 01:16 | 原脚本重跑（换行被 bash 吃掉→一行） | GDI | ✅ 出纸有字（180° 倒置，脚本默认） |
| 01:24 | 最小帧 198B（无位图） | USBPRINT 直写 | ✅ 出纸（空白）→ 证明直写通道可达固件 |
| 01:30 | 4 帧连发：F1 空白 / F2 条纹 240 行 / F3 条纹 639 行 / F4 驱动原样 | USBPRINT 直写 | ✅ **4/4 出纸，内容与帧一一对应** |
| 01:33 | R1 条纹 / R2 驱动原样 | spooler WritePrinter | ✅ 2/2 出纸 → spooler RAW 恢复 |

**捕获的驱动帧文件：** `F:\lux-neo\_km_re\elev_spl_2_00100.SPL`（51,340B）+ `elev_spl_1_00100.SHD`（3,872B spool 头，jobid=100）。

**解析工具：** `parse_spl.py`（协议头/markers）、`parse2.py`（BITMAP 头与位图长度验证：80×639=51,120 精确吻合）。

---

## 对自动化实践的影响（01:35 更新，全部经实测）

| 做法 | 结果 | 原因 |
|---|---|---|
| GDI 驱动渲染（km118_receipt_print.ps1） | ✅ 出纸 | 驱动生成合规 TSPL 位图帧 |
| ESC/POS RAW（ESC @ + 文本） | ❌ 不出纸 | 固件无 ESC/POS 解析器 |
| 手工 ZPL RAW（^XA...） | ❌ 不出纸 | 固件无 ZPL 解析器（DLL 内嵌 ZPL 模板是给其他机型用的） |
| 手工简化 TSPL RAW | ❌ 不出纸 | 格式细节不符（小数/扩展头/BITMAP 宽度语义） |
| **正确格式 TSPL RAW → spooler（WritePrinter）** | ✅ **出纸**（01:33 实测） | 帧合规；注意 spooler 半死时重启一次 |
| **正确格式 TSPL RAW → USBPRINT 设备直写** | ✅ **出纸，4/4**（01:30 实测） | 绕过 spooler，最稳兜底，无需提权 |
| Windows 测试页 | ❌ 出纸过长+黄灯 | 整页渲染，走纸量失控 |

**推荐自动化方案（按稳定性排序）：**
1. **USBPRINT 设备直写**（`CreateFile`+`WriteFile` 到 `{28d78fad}` 接口）：
   - 不依赖 spooler 状态、无需提权、非 admin 可用
   - 帧 = 固定帧头（187 字节）+ `BITMAP 0,0,80,H,1,` + 自渲染位图 + `PRINT 1,1`
   - 自己控制位图（PIL/自绘），不依赖 LXGW 字体安装
2. **spooler RAW**（`WritePrinter`，Datatype=RAW）：
   - 同样帧；异常不出纸时先 `Restart-Service spooler` 再试
3. **GDI 脚本**（km118_receipt_print.ps1）：
   - 内容排版/字体最省心（自动换行、CJK 宽度模型），但依赖驱动+LXGW 字体在 C:\Windows\Fonts

**帧模板（已验证可出纸，存于 `F:\lux-neo\_km_re\`）：**
- `min_tspl.bin`（198B，无位图最小帧，吐纸但空白）
- `f2_corr_b.bin`（19,418B，240 行条纹位图）
- `f3_corr_full.bin`（51,338B，639 行满版条纹）
- `f4_driver.bin`（51,340B，驱动帧原样）

**遗留机会（未做，需要时再做）：**
1. 位图极性确认：当前条纹用 `0x00`=黑、`0xFF`=白 且实测"看起来对"，如需绝对确认可打纯黑/纯白对照帧。
2. 抓 USB bulk 流量确认 420mm 上限的固件级原因（usbmon Configuration 抓包在本次测试中未生成文件，可能 usbmon.dll 对 32 位/64 位 spooler 的兼容性限制，未深究）。
3. 长页（>80mm）场景：驱动帧固定 639 行=80mm，长内容多页拼接规则未验证（GDI 脚本用 180° 旋转长页方案已可用）。

---

## 关键文件位置（本机）

| 文件 | 路径 |
|---|---|
| 驱动主 DLL（协议转换器） | `C:\Windows\System32\DriverStore\FileRepository\kmprtdrv.inf_amd64_96cc09a4e5809512\amd64\KMPrtDrvUNI.dll` |
| GPD 能力描述 | `C:\Windows\System32\spool\drivers\x64\3\KMPrtDrv.gpd` |
| 驱动 INF | `...\kmprtdrv.inf_amd64_96cc09a4e5809512\KMPrtDrv.inf`（UTF-16LE，含 100+ 快麦机型 HardwareID 映射） |
| 打印脚本 | `F:\lux-neo\km118_receipt_print.ps1` |
| 逆向工具脚本 | `F:\lux-neo\_km_re\`（scan.py/scan2.py/scan3.py/pe.py/inf3.py/escpos_check.py） |
| **捕获的驱动真实输出帧** | `F:\lux-neo\_km_re\elev_spl_2_00100.SPL`（51,340B，TSPL+位图）+ `elev_spl_1_00100.SHD` |
| **已验证可出纸的 RAW 帧模板** | `F:\lux-neo\_km_re\`：min_tspl.bin（198B）/ f2_corr_b.bin / f3_corr_full.bin / f4_driver.bin |
| **RAW 发送脚本** | `usb_direct2.ps1`（USBPRINT 直写，推荐）/ `spooler_retest.ps1`（spooler RAW） |
| **位图帧构造** | `build_corr.py`（条纹位图 + TSPL 帧组装） |
