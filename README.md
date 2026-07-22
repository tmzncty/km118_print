# km118_print
让AI接上快麦打印机
# KM-118 热敏卷纸打印调试记录

## 最终结论

这台 KM-118 可以在 Windows 下通过厂商驱动稳定打印 80mm 热敏卷纸。它不是普通 ESC/POS 小票机，RAW ESC/POS 文本不会正常出纸，应走 Windows GDI / 打印驱动渲染。

## 稳定配置

- 打印机：KM-118
- 端口：USB002
- 纸型：KM-118 驱动内置小票/连续纸模式 `СƱ`
- 字体：LXGW WenKai Mono（霞鹜文楷等宽）
- 旋转：180°
- 页序：ReversePages
- 长页：AutoLong，单页最大 420mm
- 物理首页起点：y = 60
- 普通页起点：y = 10
- 表格：不特殊解析，按 Markdown 原文打印

## 重要发现

1. Windows 测试页会导致出纸过长甚至黄灯，不适合作为小票机测试。
2. KM-118 不吃 ESC/POS RAW 文本，应使用 Windows 驱动渲染。
3. 自定义长页可用，但最大稳定长度约为 420mm。
4. 超过 420mm 时底部标记不可见，说明驱动/设备存在长页上限。
5. 80×80 页会产生固定分页空白；长页模式可以显著减少页间空白。
6. 首页切纸位置需要单独留安全区，最终 y=60 最合适。
7. 全等宽字体比比例字体更利于估算换行和排版。

## 当前脚本

脚本路径：

```powershell
km118_receipt_print.ps1
```

推荐命令：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.lux\km118_receipt_print.ps1" `
  -File "C:\path\to\document.md" `
  -Title "标题" `
  -ReversePages `
  -AutoLong
```

## 已验证内容

- README_AI_GUIDE.md 完整文档
- merge-to-main-plan.md
- 多页长文档
- Markdown 标题、列表、路径、表格原文
- 420mm 尺子与页长上限测试

## 使用建议

日常打印 Markdown 文档时直接使用 AutoLong。若文档很长，脚本会按 420mm 上限自动分页。尾部有少量空白是正常的；为了稳定性，不建议极限裁短。

喵~ KM-118 已被 NET酱驯服。
