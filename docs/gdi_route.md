# GDI 驱动渲染路线（文档 / 二维码打印）

本路线通过 Windows 打印驱动（UNIDRV + KMPrtDrvUNI.dll 的 GDI 渲染路径）打印
Markdown / 文本文档 / 二维码，适合"打一份文件"的场景。

与 RAW 协议路线（见根目录 `km118_tty.py`）的关系：

| | GDI 路线 | RAW 路线 |
|---|---|---|
| 脚本 | `km118_receipt_print.ps1` / `km118_print_qr.ps1` | `km118_tty.py` |
| 原理 | 驱动把 GDI 页面渲染成 TSPL 位图帧 | 直接构造 TSPL 位图帧 |
| 依赖 | 驱动 + PowerShell | 驱动（spooler 通道）或 USB 设备直写 + Python/Pillow |
| 适合 | 长文档、二维码、一次性打印 | 流式输出、交互终端、逐行打印 |

---

## 适用设备

当前验证设备：

- 打印机：KM-118
- 连接方式：USB
- Windows 端口：USB002
- 驱动：KM-118 官方 / 厂商驱动
- 纸张：80mm 热敏卷纸
- 打印模式：Windows GDI / 驱动渲染

---

## 最终稳定配置

经过多轮测试，当前稳定配置如下：

| 项目 | 配置 |
|---|---|
| 打印机名称 | `KM-118` |
| USB 端口 | `USB002` |
| 纸型 | KM-118 驱动内置小票 / 连续纸模式 `СƱ` |
| 字体 | `LXGW WenKai Mono`，霞鹜文楷等宽 |
| 渲染方式 | Windows GDI |
| 页面旋转 | 180° |
| 页序 | `ReversePages` |
| 长页模式 | `AutoLong` |
| 单页最大长度 | 420mm |
| 首页切纸安全起点 | `y = 60` |
| 普通页起点 | `y = 10` |
| 表格处理 | 不特殊解析，按 Markdown 原文输出 |

---

## 为什么需要这些设置？

### 1. Windows 测试页不适合热敏小票机

Windows 测试页会被当成完整页面任务，导致：

- 出纸很长；
- 黄灯 / 红灯；
- 打印队列 retained；
- KM-118 状态异常。

所以不要用 Windows 测试页验证小票打印。

### 2. 80×80 页会产生固定分页空白

驱动内置 `СƱ` 纸型实际是 80mm × 80mm。
如果按 80×80 分页打印，页与页之间会出现固定分页空白。

解决方式：

> 使用自定义长页，把多页内容渲染到更长的虚拟纸上。

### 3. 自定义长页最大约为 420mm

测试过多个长度：

| 长度 | 结果 |
|---|---|
| 250mm | OK |
| 280mm | OK |
| 300mm | OK |
| 350mm | OK |
| 400mm | OK |
| 420mm | OK |
| 440mm | 底部不可见 |
| 500mm | 底部不可见 |

最终结论：

> KM-118 在当前驱动下，自定义 80mm 长页的稳定上限约为 **420mm**。

因此 `AutoLong` 会以 420mm 作为单页上限，超出后自动分页。

（420mm 上限的来源分析见 `docs/driver_reverse_engineering.md` 第 8 节。）

---

## 依赖

### 必需

- Windows
- PowerShell
- 已安装 KM-118 打印机驱动
- 打印机名称为 `KM-118`

### 推荐字体

- [LXGW WenKai / 霞鹜文楷](https://github.com/lxgw/LxgwWenKai)
- 重点使用：
  - `LXGW WenKai Mono`
  - `LXGW WenKai Mono Medium`

如果没有该字体，Windows 可能 fallback 到其他字体，排版效果会变化。

### 二维码打印依赖

二维码脚本使用 Python 本地生成 QR 图片：

```powershell
pip install qrcode[pil]
```

---

## 文档打印脚本

脚本：`km118_receipt_print.ps1`

### 推荐用法

```powershell
powershell -ExecutionPolicy Bypass -File ".\km118_receipt_print.ps1" `
  -File "C:\path\to\document.md" `
  -Title "文档标题" `
  -ReversePages `
  -AutoLong
```

### 打印一段文本

```powershell
powershell -ExecutionPolicy Bypass -File ".\km118_receipt_print.ps1" `
  -Text "# 标题`n这是一段测试文本。" `
  -Title "Text Test" `
  -ReversePages `
  -AutoLong
```

### 参数说明

| 参数 | 说明 |
|---|---|
| `-File` | 要打印的文本 / Markdown 文件路径 |
| `-Text` | 直接打印传入的文本 |
| `-Title` | 打印任务标题，也会打印在文档开头 |
| `-PrinterName` | 打印机名称，默认 `KM-118` |
| `-PaperName` | 驱动纸型，默认 `СƱ` |
| `-ReversePages` | 反向页序，适配当前出纸 / 阅读方向 |
| `-AutoLong` | 自动估算长页高度，最大 420mm |
| `-LongHeightMm` | 手动指定自定义长页高度 |
| `-MaxPages` | 最大打印页数 |
| `-Box` | 打印边框，默认关闭 |
| `-NoRotate` | 禁用 180° 旋转，通常不要用 |

### AutoLong 机制

`AutoLong` 会根据内容估算所需高度：

1. 统计文本行数；
2. 粗略估算换行后的视觉行数；
3. 换算为 GDI 打印高度；
4. 自动设置 `LongHeightMm`；
5. 单页最大限制为 420mm；
6. 超出 420mm 自动分页。

这样可以避免 80×80 固定分页产生的大量空白。

---

## 二维码打印脚本

脚本：`km118_print_qr.ps1`

### 打印 GitHub 仓库二维码

```powershell
powershell -ExecutionPolicy Bypass -File ".\km118_print_qr.ps1" `
  -Text "https://github.com/tmzncty/km118_print" `
  -Title "KM-118 Print Tools" `
  -Caption "README + scripts on GitHub" `
  -LongHeightMm 185
```

二维码会本地生成，不依赖在线 QR API。

---

## AI Agent 调用示例

如果你是 AI agent，要打印一份 Markdown 文档，可以直接调用：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.lux\km118_receipt_print.ps1" `
  -File "C:\Users\tmzn\Downloads\README_AI_GUIDE.md" `
  -Title "README_AI_GUIDE" `
  -ReversePages `
  -AutoLong
```

如果要打印当前回答，可以先写入临时文件：

```powershell
$path = "$env:TEMP\ai_output.md"
@"
# AI 输出
这里是要打印的内容。
"@ | Set-Content -Encoding UTF8 $path

powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.lux\km118_receipt_print.ps1" `
  -File $path `
  -Title "AI Output" `
  -ReversePages `
  -AutoLong
```

---

## 故障排查（GDI 路线）

### 打印很长、黄灯闪烁

原因：

- 使用了 Windows 测试页；
- 或者使用了错误纸型；
- 或者队列 retained。

处理：

```powershell
Get-PrintJob -PrinterName "KM-118" | Remove-PrintJob
```

必要时重启打印机。

### 页尾空白略多

正常。
为了稳定，脚本不会极限裁纸。KM-118 在自定义长页上存在驱动边界，过度压缩可能导致截断或 retained。

### 内容方向反了

使用：

```powershell
-ReversePages
```

并保持默认 180° 旋转。

### 首页切纸位置不对

当前经验值：

```text
首页 y = 60
普通页 y = 10
```

如果换机器、换驱动、换安装方向，可能需要重新校准。
