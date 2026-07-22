param(
  [string]$Text,
  [string]$Title = "KM-118 Print Tools",
  [string]$Caption = "Scan for README and scripts",
  [string]$PrinterName = "KM-118",
  [int]$LongHeightMm = 185,
  [switch]$NoRotate,
  [switch]$Help
)

if ($Help -or -not $Text) {
@"
KM-118 QR printer

Usage:
  powershell -ExecutionPolicy Bypass -File "$PSCommandPath" `
    -Text "https://github.com/tmzncty/km118_print" `
    -Title "KM-118 Print Tools" `
    -Caption "README + scripts"

Requires Python qrcode[pil].
"@
  exit 0
}

$ErrorActionPreference = 'Stop'
$outDir = Join-Path $env:TEMP 'km118_qr'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$qrPath = Join-Path $outDir 'qr.png'

$py = @'
import sys, qrcode
from PIL import Image
text, out = sys.argv[1], sys.argv[2]
qr = qrcode.QRCode(
    version=None,
    error_correction=qrcode.constants.ERROR_CORRECT_M,
    box_size=10,
    border=4,
)
qr.add_data(text)
qr.make(fit=True)
img = qr.make_image(fill_color="black", back_color="white").convert("1")
img.save(out)
'@
$pyPath = Join-Path $outDir 'make_qr.py'
Set-Content -LiteralPath $pyPath -Value $py -Encoding UTF8
python $pyPath $Text $qrPath

$source = @'
using System;
using System.Drawing;
using System.Drawing.Printing;

public class Km118QrPrint {
  public static void Print(string printerName, string qrPath, string titleText, string caption, string url, int longMm, bool rotate) {
    PrintDocument pd = new PrintDocument();
    pd.PrinterSettings.PrinterName = printerName;
    pd.DocumentName = "KM118 QR " + titleText;
    pd.PrintController = new StandardPrintController();
    int h = (int)Math.Round(longMm / 25.4 * 100.0);
    pd.DefaultPageSettings.PaperSize = new PaperSize("80mm QR", 315, h);
    pd.DefaultPageSettings.Margins = new Margins(0,0,0,0);
    pd.OriginAtMargins = false;

    pd.PrintPage += (sender, e) => {
      Graphics g = e.Graphics;
      g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
      g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
      g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
      float W = e.PageBounds.Width, H = e.PageBounds.Height;
      if (rotate) { g.TranslateTransform(W/2f, H/2f); g.RotateTransform(180f); g.TranslateTransform(-W/2f, -H/2f); }
      using(Font title = new Font("LXGW WenKai Mono Medium", 9, FontStyle.Bold))
      using(Font body = new Font("LXGW WenKai Mono", 5, FontStyle.Regular))
      using(Font small = new Font("LXGW WenKai Mono", 4, FontStyle.Regular))
      using(Pen p = new Pen(Color.Black,1))
      using(Image qr = Image.FromFile(qrPath)) {
        float y = 60;
        float x = 6;
        g.DrawString(titleText, title, Brushes.Black, new PointF(x, y)); y += 22;
        g.DrawString(caption, body, Brushes.Black, new PointF(x, y)); y += 14;
        g.DrawLine(p, x, y, W-8, y); y += 10;

        int qrSize = 210;
        float qx = (W - qrSize) / 2f;
        g.FillRectangle(Brushes.White, qx-6, y-6, qrSize+12, qrSize+12);
        g.DrawImage(qr, qx, y, qrSize, qrSize);
        g.DrawRectangle(p, qx-1, y-1, qrSize+2, qrSize+2);
        y += qrSize + 12;

        g.DrawString("github:", body, Brushes.Black, new PointF(x, y)); y += 10;
        string u = url;
        int chunk = 46;
        for(int i=0; i<u.Length; i+=chunk) {
          string part = u.Substring(i, Math.Min(chunk, u.Length-i));
          g.DrawString(part, small, Brushes.Black, new PointF(x, y));
          y += 9;
        }
        y += 4;
        g.DrawLine(p, x, y, W-8, y); y += 8;
        g.DrawString("KM-118 / USB002 / AutoLong", small, Brushes.Black, new PointF(x, y)); y += 9;
        g.DrawString("=^NET^=", body, Brushes.Black, new PointF(x, y));
      }
      e.HasMorePages = false;
    };
    pd.Print();
  }
}
'@

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing.dll
[Km118QrPrint]::Print($PrinterName, $qrPath, $Title, $Caption, $Text, $LongHeightMm, (-not $NoRotate))
Start-Sleep -Seconds 5
Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue | Format-Table -AutoSize
Write-Host "QR image: $qrPath"
