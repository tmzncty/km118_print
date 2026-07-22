param(
  [string]$Text,
  [string]$File,
  [string]$Title = "KM-118 Receipt",
  [string]$PrinterName = "KM-118",
  [string]$PaperName = "СƱ",
  [switch]$NoRotate,
  [switch]$ReversePages,
  [switch]$Box,
  [int]$MaxPages = 20,
  [int]$LongHeightMm = 0,
  [switch]$AutoLong,
  [switch]$Help
)

if ($Help) {
@"
KM-118 80mm receipt printer helper V4

Usage:
  powershell -ExecutionPolicy Bypass -File "$PSCommandPath" -File "C:\path\note.md" -Title "My Note" -ReversePages

Defaults:
  Printer      : KM-118
  Paper        : СƱ  (KM-118 receipt/continuous 80x80 mode)
  Rotate       : 180 degrees unless -NoRotate
  Page order   : normal unless -ReversePages
  Box          : off by default; use -Box if you want border
  Long page    : use -LongHeightMm 240 for custom 80x240mm virtual paper
  Font         : LXGW WenKai Mono

Markdown:
  headings, bullets, quotes, inline **bold**, `code`, and markdown tables.
  Tables are rendered as compact ASCII tables when possible.
"@
  exit 0
}

if (-not $Text -and -not $File) {
  Write-Error "Provide -Text or -File. Use -Help for usage."
  exit 1
}

if ($File) {
  if (-not (Test-Path -LiteralPath $File)) { Write-Error "File not found: $File"; exit 1 }
  $Text = Get-Content -LiteralPath $File -Raw -Encoding UTF8
}

if ($AutoLong) {
  # Estimate content height: count chars, approx visual lines, convert to mm
  $visual = 0
  foreach ($l in ($Text -split "`n")) {
    $t = $l.TrimEnd()
    if ($t.Length -eq 0) { $visual += 0.6; continue }
    if ($t -match '^# ') { $visual += 2; continue }
    if ($t -match '^#{2,6} ') { $visual += 1.5; continue }
    $visual += [Math]::Max(1, [Math]::Ceiling($t.Length / 40.0))
  }
  $units = $visual * 9 + 130
  $estMm = [Math]::Ceiling($units / 3.937)
  if ($estMm -lt 120) { $estMm = 120 }
  $MAX_MM = 420
  if ($estMm -le $MAX_MM) {
    $LongHeightMm = $estMm
  } else {
    $LongHeightMm = $MAX_MM
    $pagesNeeded = [Math]::Ceiling($estMm / $MAX_MM)
    if ($pagesNeeded -gt $MaxPages) { $MaxPages = $pagesNeeded }
  }
  Write-Host "AutoLong: visual=$visual units=$units estMm=$estMm capMm=$MAX_MM finalMm=$LongHeightMm MaxPages=$MaxPages"
}

$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Printing;
using System.Text;
using System.Text.RegularExpressions;

public class Km118ReceiptRuntimeV4 {
  class Segment {
    public string Kind;
    public string Text;
    public Segment(string kind, string text) { Kind = kind; Text = text; }
  }

  static List<List<Segment>> pages;
  static int pageIndex;
  static string title;
  static bool rotate;
  static bool reversePages;
  static bool drawBox;
  static int maxPages;
  static float pageBudget;
  static bool longPageMode;
  static List<float> pageBudgets;

  // East Asian and fullwidth chars occupy double the width of ASCII.
  // Ranges: CJK Unified, CJK Ext A/B, Hiragana, Katakana, CJK punct,
  // Fullwidth forms, CJK Compatibility, CJK Radicals, Kangxi, etc.
  static int CharWidth(char c) {
    int u = (int)c;
    if (u >= 0x1100 && (
        u <= 0x115F ||                              // Hangul Jamo
        (u >= 0x2E80 && u <= 0x303E) ||             // CJK Radicals / Kangxi
        (u >= 0x3040 && u <= 0x33BF) ||             // Hiragana, Katakana, CJK punct, compat
        (u >= 0x3400 && u <= 0x4DBF) ||             // CJK Ext A
        (u >= 0x4E00 && u <= 0x9FFF) ||             // CJK Unified Ideographs
        (u >= 0xA000 && u <= 0xA4CF) ||             // Yi
        (u >= 0xAC00 && u <= 0xD7AF) ||             // Hangul Syllables
        (u >= 0xF900 && u <= 0xFAFF) ||             // CJK Compatibility Ideographs
        (u >= 0xFE30 && u <= 0xFE4F) ||             // CJK Compatibility Forms
        (u >= 0xFF00 && u <= 0xFF60) ||             // Fullwidth Forms
        (u >= 0xFFE0 && u <= 0xFFE6) ||             // Fullwidth signs
        (u >= 0x20000 && u <= 0x2FFFD) ||           // CJK Ext B-F
        (u >= 0x30000 && u <= 0x3FFFD)              // CJK Ext G+
       ))
      return 2;
    return 1;
  }
  static int VWidth(string s) { int n = 0; foreach (char c in s) n += CharWidth(c); return n; }

  static string Fit(string s, int width) {
    if (s == null) return "";
    StringBuilder sb = new StringBuilder();
    int n = 0;
    foreach (char c in s) {
      int w = CharWidth(c);
      if (n + w > width) break;
      sb.Append(c); n += w;
    }
    return sb.ToString();
  }

  static string PadRightV(string s, int width) {
    s = Fit(s ?? "", width);
    int n = VWidth(s);
    if (n < width) return s + new string(' ', width - n);
    return s;
  }

  static bool IsGoodBreakChar(char c) {
    int u = (int)c;
    return c == ' ' || c == ',' || c == '.' || c == ';' || c == ':' ||
           c == ')' || c == ']' || c == '}' || c == '/' || c == '\\' ||
           u == 0xFF0C || u == 0x3002 || u == 0xFF1B || u == 0xFF1A ||
           u == 0x3001 || u == 0xFF09 || u == 0x3011 || u == 0x300B;
  }

  static bool IsBadBreakChar(char c) {
    return Char.IsLetterOrDigit(c) || c == '_' || c == '-' || c == '.';
  }

  static List<string> Wrap(string s, int width) {
    List<string> r = new List<string>();
    if (String.IsNullOrWhiteSpace(s)) { r.Add(""); return r; }
    string input = s.TrimEnd();
    StringBuilder line = new StringBuilder();
    int n = 0;
    int lastBreak = -1;
    int lastBreakWidth = 0;

    Action flushAll = () => {
      string outLine = line.ToString().TrimEnd();
      if (outLine.Length > 0) r.Add(outLine);
      line.Clear(); n = 0; lastBreak = -1; lastBreakWidth = 0;
    };

    for (int i = 0; i < input.Length; i++) {
      char c = input[i];
      if (c == '\r') continue;
      if (c == '\n') { flushAll(); continue; }
      int w = CharWidth(c);
      if (n + w > width && line.Length > 0) {
        if (lastBreak > 0 && lastBreak >= line.Length / 3) {
          string first = line.ToString(0, lastBreak + 1).TrimEnd();
          string rest = line.ToString(lastBreak + 1, line.Length - lastBreak - 1).TrimStart();
          if (first.Length > 0) r.Add(first);
          line.Clear(); line.Append(rest);
          n = VWidth(rest);
        } else {
          // Hard wrap, but try not to leave a single dangling digit/letter.
          if (line.Length > 1 && IsBadBreakChar(line[line.Length - 1]) && IsBadBreakChar(c)) {
            int cut = line.Length - 1;
            string first = line.ToString(0, cut).TrimEnd();
            string rest = line.ToString(cut, line.Length - cut);
            if (first.Length > 0) r.Add(first);
            line.Clear(); line.Append(rest);
            n = VWidth(rest);
          } else {
            flushAll();
          }
        }
        lastBreak = -1; lastBreakWidth = 0;
      }
      line.Append(c); n += w;
      if (IsGoodBreakChar(c)) { lastBreak = line.Length - 1; lastBreakWidth = n; }
    }
    if (line.Length > 0) r.Add(line.ToString().TrimEnd());
    return r;
  }

  static string CleanInline(string s) {
    if (s == null) return "";
    s = Regex.Replace(s, @"!\[([^\]]*)\]\([^\)]*\)", "$1");
    s = Regex.Replace(s, @"\[([^\]]+)\]\([^\)]*\)", "$1");
    s = s.Replace("**", "").Replace("__", "").Replace("`", "");
    s = Regex.Replace(s, @"<[^>]+>", "");
    return s.Trim();
  }

  static bool IsTableSep(string line) {
    string t = line.Trim();
    if (!t.Contains("|")) return false;
    t = t.Replace("|", "").Replace(":", "").Replace("-", "").Trim();
    return t.Length == 0;
  }

  static bool IsTableRow(string line) {
    string t = line.Trim();
    return false; // table parsing disabled: print markdown table as normal text
  }

  static List<string> SplitRow(string line) {
    string t = line.Trim();
    if (t.StartsWith("|")) t = t.Substring(1);
    if (t.EndsWith("|")) t = t.Substring(0, t.Length - 1);
    string[] arr = t.Split('|');
    List<string> cells = new List<string>();
    foreach (string c in arr) cells.Add(CleanInline(c.Trim()));
    return cells;
  }

  static void Add(List<Segment> all, string kind, string text) {
    // Measured char widths (avg px) at 100dpi, available width ~301px:
    //   body(5pt)=3.66  title(9pt)=6.83  heading(6pt)=4.55  small/mono(4pt)=2.92
    // Use 88% of theoretical max for safety margin.
    int width = 72;                         // body: 82*0.88≈72
    if (kind == "title") width = 38;        // title: 44*0.88≈38
    else if (kind == "heading") width = 58; // heading: 66*0.88≈58
    else if (kind == "mono") width = 89;    // mono: 102*0.88≈89
    else if (kind == "small") width = 89;   // small: 102*0.88≈89
    else if (kind == "quote") width = 72;   // quote: same as body
    foreach (string w in Wrap(text, width)) all.Add(new Segment(kind, w));
  }

  static string TableLine3(List<string> cells, int a, int b, int c) {
    string c0 = cells.Count > 0 ? cells[0] : "";
    string c1 = cells.Count > 1 ? cells[1] : "";
    string c2 = cells.Count > 2 ? cells[2] : "";
    return "|" + PadRightV(c0, a) + "|" + PadRightV(c1, b) + "|" + PadRightV(c2, c) + "|";
  }

  static void AddTable(List<Segment> all, List<string> headers, List<List<string>> rows) {
    if (headers == null || headers.Count == 0 || rows.Count == 0) return;
    all.Add(new Segment("small", "table"));
    int cols = headers.Count;
    if (cols >= 3) {
      string h0 = headers.Count > 0 ? headers[0] : "c1";
      string h1 = headers.Count > 1 ? headers[1] : "c2";
      string h2 = headers.Count > 2 ? headers[2] : "c3";
      all.Add(new Segment("mono", Fit(h0, 18) + " | " + Fit(h1, 8)));
      all.Add(new Segment("mono", "---------------------------"));
      foreach (List<string> row in rows) {
        string c0 = row.Count > 0 ? row[0] : "";
        string c1 = row.Count > 1 ? row[1] : "";
        string c2 = row.Count > 2 ? row[2] : "";
        all.Add(new Segment("mono", Fit(c0, 18) + " | " + Fit(c1, 8)));
        if (!String.IsNullOrWhiteSpace(c2)) Add(all, "small", "  " + h2 + ": " + c2);
      }
    } else if (cols == 2) {
      foreach (List<string> row in rows) {
        string k = row.Count > 0 ? row[0] : "";
        string v = row.Count > 1 ? row[1] : "";
        Add(all, "mono", Fit(k, 14) + ": " + v);
      }
    } else {
      foreach (List<string> row in rows) Add(all, "mono", String.Join(" / ", row.ToArray()));
    }
  }

  static string KindOf(string line) {
    string t = line.TrimStart();
    if (Regex.IsMatch(t, @"^#\s+")) return "title";
    if (Regex.IsMatch(t, @"^#{2,6}\s+")) return "heading";
    if (t.StartsWith("> ")) return "quote";
    if (t.StartsWith("- ") || t.StartsWith("* ")) return "body";
    if (line.StartsWith("    ") || line.StartsWith("\t")) return "mono";
    if (Regex.IsMatch(t, @"^[A-Za-z]:\\|^/|^NET>|^PS>")) return "mono";
    return "body";
  }

  static string Strip(string line, string kind) {
    string t = line.Trim();
    if (kind == "title") return CleanInline(Regex.Replace(t, @"^#+\s*", ""));
    if (kind == "heading") return CleanInline(Regex.Replace(t, @"^#+\s*", ""));
    if (kind == "quote") return "> " + CleanInline(t.Substring(1).Trim());
    if (t.StartsWith("- ") || t.StartsWith("* ")) return "- " + CleanInline(t.Substring(2).Trim());
    if (kind == "mono") return t.TrimEnd();
    return CleanInline(t);
  }

  static void Build(string text) {
    List<Segment> all = new List<Segment>();
    Add(all, "title", title);
    Add(all, "small", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
    all.Add(new Segment("hr", ""));

    string[] lines = text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
    List<string> headers = null;
    List<List<string>> tableRows = new List<List<string>>();

    Action flushTable = () => {
      if (headers != null && tableRows.Count > 0) AddTable(all, headers, tableRows);
      headers = null; tableRows = new List<List<string>>();
    };

    foreach (string raw0 in lines) {
      string raw = raw0.TrimEnd();
      if (IsTableSep(raw)) continue;
      if (IsTableRow(raw)) {
        List<string> cells = SplitRow(raw);
        if (headers == null) headers = cells;
        else tableRows.Add(cells);
        continue;
      }
      flushTable();
      string kind = KindOf(raw);
      string clean = Strip(raw, kind);
      if (clean.Length == 0) all.Add(new Segment("blank", ""));
      else if (clean == "---" || clean == "***") all.Add(new Segment("hr", ""));
      else Add(all, kind, clean);
    }
    flushTable();

    pages = new List<List<Segment>>();
    List<Segment> page = new List<Segment>();
    float used = 0;
    pageBudgets = new List<float>();
    foreach (Segment s in all) {
      float h = H(s.Kind);
      if (used + h > pageBudget && page.Count > 0) {
        pages.Add(page);
        pageBudgets.Add(used);
        if (pages.Count >= maxPages) break;
        page = new List<Segment>(); used = 0;
      }
      page.Add(s); used += h;
    }
    if (page.Count > 0 && pages.Count < maxPages) { pages.Add(page); pageBudgets.Add(used); }
    if (pages.Count == 0) { pages.Add(new List<Segment>{ new Segment("body", "") }); pageBudgets.Add(0f); }
    if (reversePages) { pages.Reverse(); pageBudgets.Reverse(); }
  }

  static float H(string kind) {
    if (kind == "title") return 16;
    if (kind == "heading") return 12;
    if (kind == "small" || kind == "mono") return 8;
    if (kind == "hr") return 7;
    if (kind == "blank") return 5;
    return 9;
  }

  public static void Print(string printerName, string paperName, string docTitle, string text, bool rotate180, bool reverse, bool box, int maxPageCount, int longHeightMm) {
    title = docTitle; rotate = rotate180; reversePages = reverse; drawBox = box; maxPages = maxPageCount;
    pageBudget = longHeightMm > 0 ? (float)(longHeightMm * 3.5) : 282f;
    longPageMode = longHeightMm > 0;
    Build(text); pageIndex = 0;

    PrintDocument pd = new PrintDocument();
    pd.PrinterSettings.PrinterName = printerName;
    pd.DocumentName = docTitle;
    pd.PrintController = new StandardPrintController();
    if (longHeightMm > 0) {
      int h = (int)Math.Round(longHeightMm / 25.4 * 100.0);
      pd.DefaultPageSettings.PaperSize = new PaperSize("80mm custom long", 315, h);
    } else {
      foreach (PaperSize p in pd.PrinterSettings.PaperSizes) if (p.PaperName == paperName) { pd.DefaultPageSettings.PaperSize = p; break; }
    }
    pd.DefaultPageSettings.Margins = new Margins(0,0,0,0);
    pd.OriginAtMargins = false;

    pd.QueryPageSettings += (psender, pe) => {
      if (pageIndex < pages.Count && longHeightMm > 0) {
        float used = pageIndex < pageBudgets.Count ? pageBudgets[pageIndex] : pageBudgets[pageBudgets.Count - 1];
        bool isFirst = reversePages ? (pageIndex == pages.Count - 1) : (pageIndex == 0);
        float neededUnits = used + (isFirst ? 90 : 40);
        float mm = (float)Math.Ceiling(neededUnits / 3.937);
        if (mm < 120) mm = 120;
        if (mm > 420) mm = 420;
        int hun = (int)Math.Round(mm / 25.4 * 100.0);
        pe.PageSettings.PaperSize = new PaperSize("80mm pg"+(pageIndex+1), 315, hun);
        pe.PageSettings.Margins = new Margins(0,0,0,0);
      }
    };

    pd.PrintPage += (sender, e) => {
      Graphics g = e.Graphics;
      g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
      float W = e.PageBounds.Width, Hh = e.PageBounds.Height;
      if (rotate) { g.TranslateTransform(W/2f, Hh/2f); g.RotateTransform(180f); g.TranslateTransform(-W/2f, -Hh/2f); }
      using (Pen pen = new Pen(Color.Black, 1))
      using (Font fTitle = new Font("LXGW WenKai Mono Medium", 9, FontStyle.Bold))
      using (Font fHeading = new Font("LXGW WenKai Mono Medium", 6, FontStyle.Bold))
      using (Font fBody = new Font("LXGW WenKai Mono", 5, FontStyle.Regular))
      using (Font fSmall = new Font("LXGW WenKai Mono", 4, FontStyle.Regular))
      using (Font fMono = new Font("LXGW WenKai Mono", 4, FontStyle.Regular)) {
        float x = drawBox ? 18 : 6;
        bool readingFirstPage = reversePages ? (pageIndex == pages.Count - 1) : (pageIndex == 0);
        float y = readingFirstPage ? (longHeightMm > 0 ? 60 : 76) : 10;
        if (drawBox) g.DrawRectangle(pen, 10, 4, W-28, Hh-18);
        string pageNo = reversePages ? ("p." + (pages.Count - pageIndex).ToString() + "/" + pages.Count.ToString()) : ("p." + (pageIndex+1).ToString() + "/" + pages.Count.ToString());
        g.DrawString(pageNo, fMono, Brushes.Black, new PointF(W-42, readingFirstPage ? (longHeightMm > 0 ? 60 : 76) : 10));
        // normal drawing for all pages (the special long-page reverse branch removed)
          foreach (Segment s in pages[pageIndex]) {
            if (y > Hh - 20) break;
            if (s.Kind == "hr") { g.DrawLine(pen, x, y+3, W-8, y+3); y += H(s.Kind); continue; }
            if (s.Kind == "blank") { y += H(s.Kind); continue; }
            Font f = fBody;
            if (s.Kind == "title") f = fTitle;
            else if (s.Kind == "heading") f = fHeading;
            else if (s.Kind == "small") f = fSmall;
            else if (s.Kind == "mono") f = fMono;
            g.DrawString(s.Text, f, Brushes.Black, new PointF(x, y));
            y += H(s.Kind);
          }
      }
      pageIndex++;
      e.HasMorePages = pageIndex < pages.Count;
    };
    pd.Print();
  }
}
'@

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing.dll
[Km118ReceiptRuntimeV4]::Print($PrinterName, $PaperName, $Title, $Text, (-not $NoRotate), ([bool]$ReversePages), ([bool]$Box), $MaxPages, $LongHeightMm)
Start-Sleep -Seconds 2
Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue | Select-Object ID,DocumentName,JobStatus,SubmittedTime,Size | Format-Table -AutoSize
