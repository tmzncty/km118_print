#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""calibrate.py — KM-118 行序/卡纸深度标定
单 job, 13 行, 每行 = 'ROW NN' (NN = 缓冲区行号)。
打印后拍照: 看 ROW 编号顺序 + 最靠近出纸口的 ROW 编号。
"""
import ctypes, ctypes.wintypes as wt, time
from PIL import Image, ImageDraw, ImageFont

W_BITS, W_BYTES = 640, 80
STRIDE, FONT_PX, PAD_TOP = 24, 14, 4
FONT = r'C:\Windows\Fonts\LXGWWenKaiMono-Regular.ttf'
PRINTER = 'KM-118'
N_ROWS = 13

font = ImageFont.truetype(FONT, FONT_PX)
rows = []
for i in range(N_ROWS):
    label = 'ROW %02d' % i
    if i == 0:
        label += '  <<< first in buffer'
    if i == N_ROWS - 1:
        label += '  >>> last in buffer'
    box = Image.new('L', (W_BITS, STRIDE), 0)
    d = ImageDraw.Draw(box)
    d.text((8, PAD_TOP - 1), label, font=font, fill=255)
    box = box.rotate(180)
    rows.append(box.convert('1').tobytes())

mm = N_ROWS * 3.0
bmp = b''.join(rows)
bmp = bytes(0xFF ^ b for b in bmp)   # bit=0 出墨
hdr = (
    f'SIZE 80.0 mm,{mm:.1f} mm\r\n'
    'GAP 0.0 mm,0.0 mm\r\n'
    'REFERENCE 0,0\r\n'
    'SPEED 3\r\n'
    'DENSITY 8\r\n'
    'SET PEEL OFF\r\n'
    'SET CUTTER OFF\r\n'
    'SET PARTIAL_CUTTER OFF\r\n'
    'SET TEAR ON\r\n'
    'DIRECTION 0,0\r\n'
    'SHIFT 0\r\n'
    'OFFSET 0.0 mm\r\n'
    'CLS\r\n'
    f'BITMAP 0,0,80,{N_ROWS*STRIDE},1,'
)
frame = hdr.encode('ascii') + bmp + b'PRINT 1,1\r\n'
print('frame =', len(frame), 'bytes, sending as ONE job ...')

ws = ctypes.WinDLL('winspool.drv', use_last_error=True)
class DOCINFOW(ctypes.Structure):
    _fields_ = [('pDocName', wt.LPCWSTR), ('pOutputFile', wt.LPCWSTR),
                ('pDatatype', wt.LPCWSTR)]
ws.OpenPrinterW.argtypes = [wt.LPCWSTR, ctypes.POINTER(wt.HANDLE), ctypes.c_void_p]
ws.StartDocPrinterW.argtypes = [wt.HANDLE, wt.DWORD, ctypes.POINTER(DOCINFOW)]
ws.WritePrinter.argtypes = [wt.HANDLE, ctypes.c_void_p, wt.DWORD, ctypes.POINTER(wt.DWORD)]
ws.EndPagePrinter.argtypes = [wt.HANDLE]
ws.EndDocPrinter.argtypes = [wt.HANDLE]
ws.ClosePrinter.argtypes = [wt.HANDLE]

h = wt.HANDLE()
assert ws.OpenPrinterW(PRINTER, ctypes.byref(h), None), 'OpenPrinterW'
di = DOCINFOW('calibrate-row-order', None, 'RAW')
assert ws.StartDocPrinterW(h, 1, ctypes.byref(di)), 'StartDocPrinterW'
n = wt.DWORD(0)
assert ws.WritePrinter(h, frame, len(frame), ctypes.byref(n)), 'WritePrinter'
assert n.value == len(frame), (n.value, len(frame))
ws.EndPagePrinter(h)
ws.EndDocPrinter(h)
ws.ClosePrinter(h)
print('sent. paper will come out now.')
