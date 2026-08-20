#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
km118_tty.py — KM-118 古法电传打字机 (Teletype)
================================================
敲什么, 纸带上就出现什么。所有输出都在打印机纸带上。

原理: 每一行 -> LXGW 字体栅格化 -> 640bit(80mm) x 24px 1bpp 条
     (20px 字 + 4px 行距 = 3.0mm)
     多行攒页 -> 一个 TSPL 帧 (SIZE/CLS/BITMAP/PRINT, 整页一个 BITMAP)
     -> 一个 spooler job / 一次 USB 直写

关键设计 (wire 级实证):
  * 一页一 job: 驱动真实行为=整页一个 BITMAP、一个 job。
    逐行小 job 连发会被 spooler/USB 栈重排 (17 行自检实测乱序),
    单 job 字节流保序 (706KB GDI 大 job 实测顺序完美)。
  * 位图极性: bit=0 出墨 (驱动帧实证 bg=0xFF/字=0x00) -> 整体取反。
  * 方向: 固件"正向"打印是 180° 倒置 (GDI+RAW 均证实, 驱动不纠正)
    -> 每行 24px 块预旋 180° 再堆叠 (先旋块再堆叠, 不能整页旋,
    整页旋会把行序也反转)。
  * 页内布局: 块0=首行=纸带先导端 (与驱动行0=文档顶端同构)。
  * 卡纸深度: 标定实锤作业尾 4 行(12mm) 留在头与出纸口之间
    -> trail 与正文同 job, 默认 6 行(18mm)。

写入通道 (自动选择, 自愈, 均免提权):
  [usb]     USBPRINT 设备直写 (启动时自动枚举 {28d78fad} 接口)
  [spooler] spooler RAW (winspool WritePrinter, Datatype=RAW)

用法:
  python km118_tty.py                 交互模式: 敲一行, 回车, 立即打一行
  cmd  | python km118_tty.py          管道模式: 命令输出整段上纸带
  python km118_tty.py --text "HI"     一次性打印
  python km118_tty.py --selftest      自检样张
  python km118_tty.py --lead N        正文前垫 N 行空白顶出纸带 (默认 6)
交互命令: :q 退出 / :banner 重打横幅 / :clear 只清屏
"""
import sys, time, ctypes, datetime
import ctypes.wintypes as wt

DEVCLASS_GUID = '28d78fad-5a12-11d1-ae5b-0000f803a8c2'  # USBPRINT 接口类
FONT = r'C:\Windows\Fonts\LXGWWenKaiMono-Regular.ttf'
PRINTER = 'KM-118'

W_BITS = 640        # 80mm * 8 dots/mm
W_BYTES = W_BITS // 8
CONTENT_PX = 20     # 字高 20px = 2.5mm
GAP_PX = 4          # 行距 4px = 0.5mm
STRIDE_PX = CONTENT_PX + GAP_PX   # 24px = 3.0mm/行
FONT_PX = 14
PAD_TOP = 4
MM_PER_LINE = 3.0
PAGE_MAX_LINES = 26 # 26 行 = 78mm < 80mm 页上限

# ================= USB 直写 =================
k32 = ctypes.WinDLL('kernel32', use_last_error=True)
k32.CreateFileW.restype = ctypes.c_void_p
k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ctypes.c_void_p,
                            wt.DWORD, wt.DWORD, ctypes.c_void_p]
k32.WriteFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p, wt.DWORD,
                          ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
k32.WriteFile.restype = wt.BOOL
k32.CloseHandle.argtypes = [ctypes.c_void_p]
GEN_RW = 0x80000000 | 0x40000000
INVALID_HANDLE = (1 << 64) - 1

# ================= SetupAPI 枚举 =================
su = ctypes.WinDLL('setupapi.dll', use_last_error=True)

class GUID(ctypes.Structure):
    _fields_ = [('Data1', wt.DWORD), ('Data2', wt.WORD),
                ('Data3', wt.WORD), ('Data4', wt.BYTE * 8)]

class SP_DEVICE_INTERFACE_DATA(ctypes.Structure):
    _fields_ = [('cbSize', wt.DWORD), ('InterfaceClassGuid', GUID),
                ('Flags', wt.DWORD), ('Reserved', ctypes.c_ulonglong)]

su.SetupDiGetClassDevsW.argtypes = [ctypes.POINTER(GUID), ctypes.c_void_p,
                                    ctypes.c_void_p, wt.DWORD]
su.SetupDiGetClassDevsW.restype = ctypes.c_void_p
su.SetupDiEnumDeviceInterfaces.argtypes = [ctypes.c_void_p, wt.INT,
                                           ctypes.POINTER(GUID), wt.DWORD,
                                           ctypes.POINTER(SP_DEVICE_INTERFACE_DATA)]
su.SetupDiEnumDeviceInterfaces.restype = wt.BOOL
su.SetupDiGetDeviceInterfaceDetailW.argtypes = [ctypes.c_void_p,
    ctypes.POINTER(SP_DEVICE_INTERFACE_DATA), ctypes.c_void_p, wt.DWORD,
    ctypes.POINTER(wt.DWORD), ctypes.c_void_p]
su.SetupDiGetDeviceInterfaceDetailW.restype = wt.BOOL
su.SetupDiDestroyDeviceInfoList.argtypes = [ctypes.c_void_p]

def find_usbprint_iface():
    fields = DEVCLASS_GUID.strip('{}').split('-')
    d4 = (ctypes.c_ubyte * 8).from_buffer_copy(
        bytes.fromhex(fields[3] + fields[4]))
    g = GUID(int(fields[0], 16), int(fields[1], 16), int(fields[2], 16), d4)
    h = su.SetupDiGetClassDevsW(ctypes.byref(g), None, None, 9)
    if not h:
        return None
    try:
        data = SP_DEVICE_INTERFACE_DATA()
        data.cbSize = ctypes.sizeof(SP_DEVICE_INTERFACE_DATA)
        i = 0
        while su.SetupDiEnumDeviceInterfaces(h, i, ctypes.byref(g), 0,
                                             ctypes.byref(data)):
            req = wt.DWORD(0)
            su.SetupDiGetDeviceInterfaceDetailW(h, ctypes.byref(data),
                                                None, 0, ctypes.byref(req), None)
            if req.value > 4:
                buf = ctypes.create_string_buffer(req.value)
                ctypes.memmove(buf, b'\x04\x00\x00\x00', 4)
                if su.SetupDiGetDeviceInterfaceDetailW(h, ctypes.byref(data),
                        buf, req.value, ctypes.byref(req), None):
                    path = buf[4:].decode('utf-16-le').split('\x00')[0]
                    pl = path.lower()
                    if 'vid_20d1' in pl and 'pid_7008' in pl:
                        return path
            i += 1
    finally:
        su.SetupDiDestroyDeviceInfoList(h)
    return None

# ================= winspool spooler RAW =================
ws = ctypes.WinDLL('winspool.drv', use_last_error=True)

class DOCINFOW(ctypes.Structure):
    _fields_ = [('pDocName', wt.LPCWSTR), ('pOutputFile', wt.LPCWSTR),
                ('pDatatype', wt.LPCWSTR)]

ws.OpenPrinterW.argtypes = [wt.LPCWSTR, ctypes.POINTER(wt.HANDLE),
                            ctypes.c_void_p]
ws.OpenPrinterW.restype = wt.BOOL
ws.StartDocPrinterW.argtypes = [wt.HANDLE, wt.DWORD,
                                ctypes.POINTER(DOCINFOW)]
ws.StartDocPrinterW.restype = wt.BOOL
ws.WritePrinter.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD,
                            ctypes.POINTER(wt.DWORD)]
ws.WritePrinter.restype = wt.BOOL
ws.EndPagePrinter.argtypes = [wt.HANDLE]
ws.EndDocPrinter.argtypes = [wt.HANDLE]
ws.ClosePrinter.argtypes = [wt.HANDLE]
# BOOL EnumJobsW(HANDLE h, DWORD FirstJob, DWORD cJobs, DWORD Level,
#                LPBYTE pJobs, DWORD cbBuf, LPDWORD pcbNeeded, LPDWORD pcReturned)
ws.EnumJobsW.argtypes = [wt.HANDLE, wt.DWORD, wt.DWORD, wt.DWORD,
                         ctypes.c_void_p, wt.DWORD,
                         ctypes.POINTER(wt.DWORD),
                         ctypes.POINTER(wt.DWORD)]
ws.EnumJobsW.restype = wt.BOOL   # x64: 不设 restype 默认 c_int 截断, 必设

def drain_spooler(handle, timeout=30.0):
    """等 spooler 队列清空。
    实证: 同时堆在队列里的 job 会被 spooler LIFO 倒排 (尾部送料页
    先于正文页打印, 实测照片对账确认) -> 交互模式每 job 发完必须
    等队列清空再发下一个, 串行化后 LIFO 无发作机会。
    查询姿势: cJobs=0xFFFF, cbBuf=0 -> TRUE 且 pcReturned=0 即空。"""
    bytes_needed = wt.DWORD(0)
    count = wt.DWORD(0)
    t0 = time.time()
    while time.time() - t0 < timeout:
        count.value = 0
        ok = ws.EnumJobsW(handle, 0, 0xFFFF, 1, None, 0,
                          ctypes.byref(bytes_needed), ctypes.byref(count))
        if ok:
            if count.value == 0:
                return True
        else:
            gle = ctypes.get_last_error()
            if gle == 122:      # ERROR_INSUFFICIENT_BUFFER = 队列非空
                pass
            else:
                # 真正的错误 (handle 已关等) 不阻塞, 放行
                return False
        time.sleep(0.2)
    return False

# ================= TTY =================
class TTY:
    def __init__(self):
        from PIL import ImageFont, Image, ImageDraw
        self.Image, self.ImageDraw = Image, ImageDraw
        self.font = ImageFont.truetype(FONT, FONT_PX)
        self.mode = None
        self.h = None
        self.sph = None
        self.lines = 0
        self.pages = 0
        self.job_n = 0
        self.fallbacks = 0
        self._rows = []          # 当前页已渲染行 (未取反的 1bpp 行)
        self._buf = bytearray()  # 已封帧的页 (commit 时合成一个 job)

    # ---------- 通道 ----------
    def open(self):
        dev = find_usbprint_iface()
        if dev:
            h = k32.CreateFileW(dev, GEN_RW, 0, None, 3, 0x80, None)
            if h and h != INVALID_HANDLE:
                self.h = h
                self.mode = 'usb'
                return
        sph = wt.HANDLE()
        if not ws.OpenPrinterW(PRINTER, ctypes.byref(sph), None):
            raise RuntimeError('OpenPrinterW 失败 GLE=%d'
                               % ctypes.get_last_error())
        self.sph = sph
        self.mode = 'spooler'

    def close(self):
        self.flush_page()        # 收尾: 未封帧的行封帧
        self.commit()            # 缓冲里的页合成最后一个 job
        if self.h:
            k32.CloseHandle(self.h); self.h = None
        if self.sph:
            ws.ClosePrinter(self.sph); self.sph = None

    def _open_spooler(self):
        sph = wt.HANDLE()
        if not ws.OpenPrinterW(PRINTER, ctypes.byref(sph), None):
            raise RuntimeError('spooler 重开失败 GLE=%d'
                               % ctypes.get_last_error())
        self.sph = sph
        self.mode = 'spooler'

    def _send(self, frame: bytes):
        """把一页帧攒进待发缓冲 (整份内容最终 = 一个 job)"""
        self._buf.extend(frame)
        self.pages += 1

    def commit(self, wait=False):
        """把整份缓冲作为【一个】 job 发出去。
        单 job 内部字节流物理保序 -> 根治 spooler 多 job LIFO 倒排。
        wait=True: 发完等打印机吃干净 (交互模式, 防连续 job 再堆队列)。"""
        if not self._buf:
            return
        data = bytes(self._buf)
        self._buf = bytearray()
        sent_via = self.mode
        if self.mode == 'usb':
            n = wt.DWORD(0)
            if k32.WriteFile(self.h, data, len(data),
                             ctypes.byref(n), None) and n.value == len(data):
                return
            gle = ctypes.get_last_error()
            self.fallbacks += 1
            sys.stderr.write(f'[tty] usb 写失败 GLE={gle}, 降级 spooler RAW\n')
            if self.h:
                k32.CloseHandle(self.h); self.h = None
            self._open_spooler()
        di = DOCINFOW(f'tty-job-{self.job_n:04d}', None, 'RAW')
        if not ws.StartDocPrinterW(self.sph, 1, ctypes.byref(di)):
            raise RuntimeError('StartDocPrinterW 失败 GLE=%d (spooler 半死? '
                               '需提权重启)' % ctypes.get_last_error())
        n = wt.DWORD(0)
        try:
            if not ws.WritePrinter(self.sph, data, len(data),
                                   ctypes.byref(n)) \
                    or n.value != len(data):
                raise RuntimeError('WritePrinter 失败 GLE=%d wrote=%d/%d'
                                   % (ctypes.get_last_error(), n.value,
                                      len(data)))
            ws.EndPagePrinter(self.sph)
        except BaseException:
            ws.EndDocPrinter(self.sph)
            raise
        ws.EndDocPrinter(self.sph)
        self.job_n += 1
        if wait and sent_via == 'spooler':
            if not drain_spooler(self.sph):
                sys.stderr.write(
                    '[tty] 警告: 等队列清空超时, 继续 (顺序可能受损)\n')

    # ---------- 栅格化 ----------
    def _measure(self, text: str) -> int:
        return self.font.getlength(text)

    def wrap(self, text: str):
        limit = W_BITS - 8
        out, cur = [], ''
        for ch in text:
            if ch == '\n':
                out.append(cur); cur = ''
                continue
            if self._measure(cur + ch) > limit:
                out.append(cur); cur = ch
            else:
                cur += ch
        out.append(cur)
        return [s.rstrip() for s in out]

    def _render_row(self, text: str) -> bytes:
        """一行 -> 640x24 1bpp (字在上 20px, 下 4px 行距; 已预旋 180°)"""
        box = self.Image.new('L', (W_BITS, STRIDE_PX), 0)
        d = self.ImageDraw.Draw(box)
        d.text((8, PAD_TOP - 1), text, font=self.font, fill=255)
        box = box.rotate(180)    # 先旋块: 只翻字, 不翻行序
        return box.convert('1').tobytes()

    @staticmethod
    def _frame(rows, n_lines) -> bytes:
        px = n_lines * STRIDE_PX
        mm = n_lines * MM_PER_LINE
        bmp = b''.join(rows)
        # 固件极性: bit=0 出墨 -> 整体取反 (驱动帧: bg=0xFF, 字=0x00)
        bmp = bytes(0xFF ^ b for b in bmp)
        hdr = (
            f'SIZE 80.0 mm,{mm:.1f} mm\r\n'
            f'GAP 0.0 mm,0.0 mm\r\n'
            f'REFERENCE 0,0\r\n'
            f'SPEED 3\r\n'
            f'DENSITY 8\r\n'
            f'SET PEEL OFF\r\n'
            f'SET CUTTER OFF\r\n'
            f'SET PARTIAL_CUTTER OFF\r\n'
            f'SET TEAR ON\r\n'
            f'DIRECTION 0,0\r\n'
            f'SHIFT 0\r\n'
            f'OFFSET 0.0 mm\r\n'
            f'CLS\r\n'
            f'BITMAP 0,0,80,{px},1,'
        )
        return hdr.encode('ascii') + bmp + b'PRINT 1,1\r\n'

    # ---------- 打印 ----------
    def flush_page(self):
        """当前页 -> 一个 job 发出去"""
        if not self._rows:
            return
        rows, n = self._rows, len(self._rows)
        self._rows = []
        self._send(self._frame(rows, n))

    def print_line(self, text: str, flush: bool = False):
        for seg in (self.wrap(text) if text else ['']):
            self._rows.append(self._render_row(seg))
            self.lines += 1
            if len(self._rows) >= PAGE_MAX_LINES:
                self.flush_page()       # 整页自动 flush (wrap 片段必须同页)
        if flush and self._rows:
            self.flush_page()           # 整条逻辑行入页后才发, 防小 job 重排

    def banner(self):
        now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        self.print_line(f'KM-118 TELETYPE ONLINE  {now}')
        self.print_line(f'channel: {self.mode}  page: {PAGE_MAX_LINES} lines')
        self.print_line('========================================')
        self.print_line('Type a line, press ENTER, it is on paper.')
        self.flush_page()

# ================= 入口 =================
def main():
    import argparse
    ap = argparse.ArgumentParser(description='KM-118 teletype')
    ap.add_argument('--text', action='append', default=None)
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--no-banner', action='store_true')
    ap.add_argument('--lead', type=int, default=4,
                    help='正文前垫 N 行空白作撕纸余量 (默认 4); 0 关闭')
    ap.add_argument('--trail', type=int, default=6,
                    help='正文后跟 N 行空白把内容拽出机器 (默认 6 = 18mm; '
                         '标定: 作业尾 4 行/12mm 留在头与出纸口之间, 必须 >= 4); 0 关闭')
    args = ap.parse_args()

    def lead(tty):
        for _ in range(args.lead):
            tty.print_line('')

    def trail(tty):
        # trail 并入正文页同一 job (物理保序; 小 job 连发有被 spooler 重排的实测记录)。
        # 卡纸深度标定: 作业结束时最后 4 行(12mm)留在头与出纸口之间,
        # trail 取 6 行 -> 正文全部吐出, 最后 4 行空白留在机内(下次打印被顶出)。
        if len(tty._rows) >= PAGE_MAX_LINES:
            tty.flush_page()
        for _ in range(args.trail):
            tty._rows.append(tty._render_row(''))
        tty.flush_page()

    tty = TTY()
    tty.open()
    print(f'[tty] channel = {tty.mode}', file=sys.stderr)
    try:
        if args.lead > 0:
            lead(tty)                       # 攒进首页, 不单独发 job
        if args.selftest:
            for ln in [
                'SELFTEST 0123456789',
                'abcdefghijklmnopqrstuvwxyz',
                'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                'The quick brown fox jumps over the lazy dog',
                '你好,纸带。电传打字机,古法终端。',
                '========================================',
                'SELFTEST OK - 8 dots/mm, 80mm',
            ]:
                tty.print_line(ln)
            trail(tty)                      # 正文+trail 同一 job, 物理保序
            return 0

        if args.text:
            for t in args.text:
                tty.print_line(t)
            trail(tty)
            return 0

        interactive = sys.stdin.isatty()
        if not args.no_banner:
            tty.banner()

        if interactive:
            # 交互: 每行立即 flush (电传打字机手感; 人速连发无竞态)
            print('KM-118 teletype ready. Type lines; :q to quit.')
            while True:
                try:
                    line = input('\u00bb ')
                except (EOFError, KeyboardInterrupt):
                    print()
                    break
                s = line.strip()
                if s in (':q', ':quit', ':q!'):
                    break
                if s == ':feed':
                    tty.print_line('', flush=True); continue
                if s == ':banner':
                    tty.print_line(f'KM-118 TELETYPE  {datetime.datetime.now().strftime("%H:%M:%S")}', flush=True)
                    continue
                if s == ':clear':
                    continue
                try:
                    tty.print_line(line, flush=True)
                    tty.commit(wait=True)     # 交互: 每行一个 job, 发完等吃完
                    print(f'  [line {tty.lines}]')
                except Exception as e:
                    print(f'  [ERROR] {e}  (等 2s, 可重试)')
                    time.sleep(2)
            trail(tty)                      # 退出前把正文拽出机器
        else:
            # 管道: 整段攒页, 逐页发 (每页一个 job, 保序)
            for raw in sys.stdin:
                try:
                    tty.print_line(raw.rstrip('\r\n'))
                except Exception as e:
                    sys.stderr.write(f'[tty] 行失败: {e}\n')
                    time.sleep(1)
            # 管道: 整段(引导+正文+尾部送料) = 一条字节流 = 一个 job
            trail(tty)
            tty.commit()
    finally:
        tty.close()
        if tty.fallbacks:
            sys.stderr.write(f'[tty] 共降级 {tty.fallbacks} 次\n')
        sys.stderr.write(f'[tty] 共 {tty.lines} 行 / {tty.pages} 页\n')
    return 0

if __name__ == '__main__':
    sys.exit(main())
