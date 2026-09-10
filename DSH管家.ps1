# =====================================================================
#  DSH 管家  v3.0
#  DeepSeek Harness Web 服务的图形化「启动 / 停止 / 重启」工具
#  环境要求：Windows 10/11 + 系统自带 PowerShell 5.1 / .NET Framework 4.x
#
#  v3.0 主要能力：
#    · 环境自适应：自动探测 DSH 工作目录，启动命令自动识别 pnpm / npm / 全局 dsh
#    · 首次运行有引导，找不到环境会弹出设置面板让你选一次
#    · 主界面浏览器横排图标条：点图标即换浏览器，宽度按名字自适应
#    · 底部「对话 / 用量 / 退出」：两个小鲸鱼按钮直达 DeepSeek 网页版和平台用量页
#    · 系统托盘常驻 + 开机自启 + 守护模式 + 关闭窗口 = 缩到托盘
#    · 双主题（白天米黄 / 夜间石墨）+ 1.1 秒缓动渐变 + 可跟随时间
#
#  一路怎么走过来的：
#    v2.1 双主题 + 日夜开关渐变      v2.2 代码整理 + 出错兜底日志
#    v2.3 运行时长 + 设置面板        v2.4 图标体系 + 时长徽章 + 卡片重排
#    v2.5 托盘常驻 + 开机自启 + 设置面板重做 + 守护模式
#    v2.6 浏览器图标条 + 底部改版 + 文字粗细整理 + 日夜开关改矢量绘制
#    v3.0 面向开源：环境自适应 + 启动器源码 + README/协议 + 目录整理
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- 单实例保护 ------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\DshConsoleGui_SingleInstance')
if (-not $mutex.WaitOne(0)) {
  [void][System.Windows.Forms.MessageBox]::Show('DSH 管家已经在运行了，请查看任务栏。', 'DSH 管家', 'OK', 'Information')
  exit
}

# ---- 高 DPI 感知 ------------------------------------------------
try {
  Add-Type -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name 'DpiHelper' -Namespace 'Win32' -ErrorAction Stop | Out-Null
  [void][Win32.DpiHelper]::SetProcessDPIAware()
} catch { }

# ---- 自身诊断日志 + 全局出错保护 ------------------------------
# 因为现在是无窗口启动，脚本一旦出错用户什么都看不到，所以必须有兜底
$script:SelfLog = Join-Path $env:TEMP 'dsh-butler.log'
function Write-SelfLog {
  param([string]$Text)
  try {
    Add-Content -LiteralPath $script:SelfLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Text) -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
}
trap {
  $err = ($_ | Out-String).Trim()
  Write-SelfLog ('致命错误: ' + $err)
  try { [void][System.Windows.Forms.MessageBox]::Show($err, 'DSH 管家 出错了', 'OK', 'Error') } catch { }
  exit 1
}
Write-SelfLog '--- 启动 ---'

# ================== 自绘控件（卡片按钮 / 状态卡片） =================
$uiSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class FlatCardButton : Control
{
    public Color BaseColor { get; set; }
    public Color HoverColor { get; set; }
    public Color PressColor { get; set; }
    public Color BorderColor { get; set; }
    public Color GlyphColor { get; set; }
    public Color DisabledBlend { get; set; }
    public float BorderWidth { get; set; }
    public int CornerRadius { get; set; }
    public string Glyph { get; set; }
    public Image IconImage { get; set; }
    private bool hover, press;

    public FlatCardButton()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BaseColor    = Color.FromArgb(220, 235, 223);
        HoverColor   = Color.FromArgb(200, 224, 206);
        PressColor   = Color.FromArgb(186, 214, 194);
        BorderColor  = Color.FromArgb(127, 169, 140);
        GlyphColor   = Color.FromArgb(47, 86, 64);
        DisabledBlend = Color.FromArgb(150, 150, 150);
        BorderWidth  = 2f;
        CornerRadius = 18;
        Glyph        = "";
        Cursor       = Cursors.Hand;
        Font         = new Font("Microsoft YaHei UI", 9.5f);
        ForeColor    = Color.FromArgb(47, 86, 64);
    }

    protected override void OnMouseEnter(EventArgs e) { hover = true;  Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; press = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { press = true;  Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e)   { press = false; Invalidate(); base.OnMouseUp(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        Color fill = press ? PressColor : (hover ? HoverColor : BaseColor);
        if (!Enabled) fill = Blend(fill, DisabledBlend, 0.15);

        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath path = Rounded(r, CornerRadius))
        using (SolidBrush brush = new SolidBrush(fill))
        {
            g.FillPath(brush, path);
        }

        if (BorderWidth > 0.2f)
        {
            float hw = BorderWidth / 2f;
            Rectangle br = new Rectangle((int)Math.Ceiling(hw), (int)Math.Ceiling(hw),
                                         Width - 1 - (int)Math.Ceiling(hw * 2), Height - 1 - (int)Math.Ceiling(hw * 2));
            Color bc = Enabled ? BorderColor : Blend(BorderColor, DisabledBlend, 0.28);
            using (GraphicsPath bp = Rounded(br, Math.Max(2, CornerRadius - 1)))
            using (Pen pen = new Pen(bc, BorderWidth))
            {
                g.DrawPath(pen, bp);
            }
        }

        Color gcol = Enabled ? GlyphColor : Blend(GlyphColor, DisabledBlend, 0.28);
        Color tcol = Enabled ? ForeColor : Blend(ForeColor, DisabledBlend, 0.28);

        // 图片图标（比如 DeepSeek 的小鲸鱼）：「图标 + 文字」整体居中；没文字就只居中图标
        if (IconImage != null)
        {
            int iw = 22, ih = 22;
            bool hasText = !string.IsNullOrEmpty(Text);
            int iy = (Height - ih) / 2 + (press ? 1 : 0);
            InterpolationMode oldIm = g.InterpolationMode;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            if (!hasText)
            {
                g.DrawImage(IconImage, new Rectangle((Width - iw) / 2, iy, iw, ih));
            }
            else
            {
                using (Font lf = new Font(Font, FontStyle.Bold))
                {
                    int tw = TextRenderer.MeasureText(g, Text, lf, new Size(1000, 100), TextFormatFlags.NoPadding).Width;
                    int content = iw + 6 + tw;
                    int sx = (Width - content) / 2;
                    if (sx < 6) { sx = 6; }
                    g.DrawImage(IconImage, new Rectangle(sx, iy, iw, ih));
                    Rectangle itr = new Rectangle(sx + iw + 6, 0, tw + 12, Height);
                    TextRenderer.DrawText(g, Text, lf, itr, tcol,
                        TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
                }
            }
            g.InterpolationMode = oldIm;
            return;
        }

        if (!string.IsNullOrEmpty(Glyph) && Height >= 56)
        {
            using (Font gf = new Font("Segoe UI Symbol", Height * 0.23f))
            {
                Rectangle gr = new Rectangle(0, (int)(Height * 0.10), Width, (int)(Height * 0.44));
                TextRenderer.DrawText(g, Glyph, gf, gr, gcol,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
        else if (!string.IsNullOrEmpty(Glyph))
        {
            Rectangle gr = new Rectangle(12, 0, 22, Height);
            TextRenderer.DrawText(g, Glyph, Font, gr, gcol,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
        }

        int top = (Height >= 56) ? (int)(Height * 0.54) : 0;
        Rectangle tr = new Rectangle(0, top, Width, Height - top);
        // 主界面的胶囊按钮文字统一加粗（4 个主按钮 + 底部三个胶囊）
        using (Font lf = new Font(Font, FontStyle.Bold))
        {
            TextRenderer.DrawText(g, Text, lf, tr, tcol,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }

    private static Color Blend(Color a, Color b, double t)
    {
        return Color.FromArgb(
            (int)(a.R + (b.R - a.R) * t),
            (int)(a.G + (b.G - a.G) * t),
            (int)(a.B + (b.B - a.B) * t));
    }

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        if (d <= 0 || d > r.Width || d > r.Height) { path.AddRectangle(r); return path; }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public class ThemedMenuRenderer : ToolStripProfessionalRenderer
{
    public Color MenuBg { get; set; }
    public Color MenuFg { get; set; }
    public Color HoverBg { get; set; }
    public Color SepColor { get; set; }

    public ThemedMenuRenderer()
    {
        MenuBg   = Color.White;
        MenuFg   = Color.FromArgb(31, 41, 55);
        HoverBg  = Color.FromArgb(242, 242, 242);
        SepColor = Color.FromArgb(230, 230, 230);
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        using (SolidBrush b = new SolidBrush(MenuBg)) { e.Graphics.FillRectangle(b, e.AffectedBounds); }
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        Rectangle r = new Rectangle(Point.Empty, e.Item.Size);
        Color c = e.Item.Selected ? HoverBg : MenuBg;
        using (SolidBrush b = new SolidBrush(c)) { e.Graphics.FillRectangle(b, r); }
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? MenuFg : Color.FromArgb(150, MenuFg);
        base.OnRenderItemText(e);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        Rectangle r = new Rectangle(10, e.Item.Height / 2, e.Item.Width - 20, 1);
        using (SolidBrush b = new SolidBrush(SepColor)) { e.Graphics.FillRectangle(b, r); }
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        using (Pen p = new Pen(SepColor))
        {
            e.Graphics.DrawRectangle(p, new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1));
        }
    }
}

public class BrowserStrip : Control
{
    public List<string> Names = new List<string>();
    public List<Image> Icons = new List<Image>();
    private int sel = 0;
    public int Selected { get { return sel; } set { sel = value; EnsureVisible(); Invalidate(); } }
    public int ItemH = 48, Gap = 12, Radius = 14;
    public int MinW = 86, MaxW = 212;
    private List<int> widths = new List<int>();
    private const int Pad = 2;   // 胶囊四周内缩，给边框留地方

    public Color CardBg { get; set; }
    public Color BorderCol { get; set; }
    public Color SelBorderCol { get; set; }
    public Color SelBg { get; set; }
    public Color TextCol { get; set; }
    public Color SelTextCol { get; set; }
    public Color TrackCol { get; set; }
    public Color ThumbCol { get; set; }

    public event EventHandler SelectionChanged;
    private int scroll = 0;
    private bool dragThumb = false;
    private int dragX = 0, dragScroll = 0;

    public BrowserStrip()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        CardBg       = Color.FromArgb(255, 253, 247);
        BorderCol    = Color.FromArgb(232, 221, 201);
        SelBorderCol = Color.FromArgb(77, 124, 90);
        SelBg        = Color.FromArgb(232, 241, 234);
        TextCol      = Color.FromArgb(74, 63, 53);
        SelTextCol   = Color.FromArgb(47, 86, 64);
        TrackCol     = Color.FromArgb(232, 221, 201);
        ThumbCol     = Color.FromArgb(77, 124, 90);
        Cursor = Cursors.Hand;
        Font = new Font("Microsoft YaHei UI", 12f, GraphicsUnit.Pixel);
    }

    private int TotalW
    {
        get
        {
            int t = 0;
            for (int i = 0; i < widths.Count; i++) { t += widths[i] + Gap; }
            return t > 0 ? t - Gap : 0;
        }
    }
    private int WAt(int i)
    {
        if (i < 0 || i >= widths.Count) { return MinW; }
        return widths[i];
    }
    private int XAt(int i)
    {
        int x = 0;
        for (int k = 0; k < i && k < widths.Count; k++) { x += widths[k] + Gap; }
        return x;
    }
    private int MaxScroll
    {
        get { int m = TotalW - Width; return m > 0 ? m : 0; }
    }
    private int SliderH { get { return 14; } }
    private int SliderTop { get { return Height - SliderH; } }
    private int ThumbW
    {
        get { int w = (int)((double)Width * Width / (TotalW > 0 ? TotalW : 1)); return w < 48 ? 48 : w; }
    }

    // 把选中项滚进可视区（换浏览器后不用自己去拖滑块）
    public void EnsureVisible()
    {
        if (Width <= 0 || Names.Count == 0) { return; }
        int x = XAt(sel), w = WAt(sel);
        if (x < scroll) { scroll = x; }
        else if (x + w > scroll + Width) { scroll = x + w - Width; }
    }

    // 每个胶囊按自己的名字算宽度：豆包 / 千问 这种短名字就不会被撑得很宽
    public void AutoFit()
    {
        List<int> w = new List<int>();
        try
        {
            using (Graphics g = CreateGraphics())
            {
                foreach (string n in Names)
                {
                    int tw = 0;
                    if (!string.IsNullOrEmpty(n))
                    {
                        // 按粗体量：选中的那个名字是粗体，按常规量会刚好被截掉
                        using (Font bf = new Font(Font, FontStyle.Bold))
                        {
                            tw = TextRenderer.MeasureText(g, n, bf, new Size(1000, 100), TextFormatFlags.NoPadding).Width;
                        }
                    }
                    int one = 40 + tw + 30;   // 左距+图标+间距+文字+右距（含 2px 内缩和 DrawText 的内边距）
                    if (one < MinW) { one = MinW; }
                    if (one > MaxW) { one = MaxW; }
                    w.Add(one);
                }
            }
        }
        catch
        {
            w.Clear();
            for (int i = 0; i < Names.Count; i++) { w.Add(140); }
        }
        widths = w;
        EnsureVisible();
        Invalidate();
    }

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        if (d <= 0 || d > r.Width || d > r.Height) { path.AddRectangle(r); return path; }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (scroll > MaxScroll) { scroll = MaxScroll; }
        if (scroll < 0) { scroll = 0; }

        int x = -scroll;
        for (int i = 0; i < Names.Count; i++)
        {
            int w = WAt(i);
            if (x + w < 0 || x > Width) { x += w + Gap; continue; }
            bool sel = (i == Selected);
            // 四周留 2px 内缩：选中态边框 3px，贴边画会被控件边缘切掉一两个像素
            Rectangle r = new Rectangle(x + Pad, Pad, w - Pad * 2 - 1, ItemH - Pad * 2 - 1);
            using (GraphicsPath p = Rounded(r, Radius))
            {
                using (SolidBrush b = new SolidBrush(sel ? SelBg : CardBg)) { g.FillPath(b, p); }
                using (Pen pen = new Pen(sel ? SelBorderCol : BorderCol, sel ? 3.0f : 1.8f)) { g.DrawPath(pen, p); }
            }
            if (i < Icons.Count && Icons[i] != null)
            {
                g.DrawImage(Icons[i], x + Pad + 10, Pad + (r.Height - 22) / 2, 22, 22);
            }
            else
            {
                // 没有图标（比如「系统默认」）：画个小地球顶上
                int cx = x + Pad + 10 + 11, cy = Pad + r.Height / 2;
                using (Pen gp = new Pen(sel ? SelBorderCol : BorderCol, 1.6f))
                {
                    g.DrawEllipse(gp, cx - 9, cy - 9, 18, 18);
                    g.DrawEllipse(gp, cx - 4, cy - 9, 8, 18);
                    g.DrawLine(gp, cx - 9, cy, cx + 9, cy);
                }
            }
            Rectangle tr = new Rectangle(x + Pad + 38, Pad, r.Width - 50, r.Height);
            Font nf = Font;
            if (sel) { nf = new Font(Font, FontStyle.Bold); }   // 选中的名字加粗
            TextRenderer.DrawText(g, Names[i], nf, tr, sel ? SelTextCol : TextCol,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            if (sel) { nf.Dispose(); }

            x += w + Gap;   // 往右挪到下一格（漏了这行所有胶囊会叠在一起）
        }

        if (MaxScroll > 0)
        {
            Rectangle track = new Rectangle(0, SliderTop, Width, SliderH);
            using (GraphicsPath p = Rounded(track, SliderH / 2))
            using (SolidBrush b = new SolidBrush(TrackCol)) { g.FillPath(b, p); }
            int tw = ThumbW;
            int tx = (int)((double)scroll / MaxScroll * (Width - tw));
            Rectangle thumb = new Rectangle(tx, SliderTop, tw, SliderH);
            using (GraphicsPath p = Rounded(thumb, SliderH / 2))
            using (SolidBrush b = new SolidBrush(ThumbCol)) { g.FillPath(b, p); }
        }
    }

    private int IndexAt(int x)
    {
        int cx = -scroll;
        for (int i = 0; i < Names.Count; i++)
        {
            int w = WAt(i);
            if (x >= cx && x <= cx + w) { return i; }
            cx += w + Gap;
        }
        return -1;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (MaxScroll > 0 && e.Y >= SliderTop - 6)
        {
            int tw = ThumbW;
            int tx = (int)((double)scroll / MaxScroll * (Width - tw));
            if (e.X >= tx && e.X <= tx + tw)
            {
                dragThumb = true; dragX = e.X; dragScroll = scroll;
            }
            else
            {
                scroll += (e.X < tx) ? -(Width / 2) : (Width / 2);
                Invalidate();
            }
            return;
        }
        int idx = IndexAt(e.X);
        if (idx >= 0 && idx != Selected)
        {
            Selected = idx;
            Invalidate();
            if (SelectionChanged != null) { SelectionChanged(this, EventArgs.Empty); }
        }
        base.OnMouseDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (dragThumb && MaxScroll > 0)
        {
            int tw = ThumbW;
            int span = Width - tw;
            if (span < 1) { span = 1; }
            scroll = dragScroll + (int)((double)(e.X - dragX) / span * MaxScroll);
            Invalidate();
        }
        base.OnMouseMove(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        dragThumb = false;
        base.OnMouseUp(e);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        if (MaxScroll > 0)
        {
            scroll -= Math.Sign(e.Delta) * 140;
            Invalidate();
        }
        base.OnMouseWheel(e);
    }
}

public class StatusCard : Control
{
    public Color Accent { get; set; }
    public Color CardFg { get; set; }
    public string StatusText { get; set; }
    public string DetailText { get; set; }
    public string VersionText { get; set; }
    public string UptimeText { get; set; }
    public double Blend { get; set; }
    public event EventHandler ThemeToggled;
    public event EventHandler SettingsClicked;
    private bool overToggle;
    private bool overGear;

    public StatusCard()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Accent      = Color.FromArgb(77, 124, 90);
        CardFg      = Color.FromArgb(255, 248, 238);
        StatusText  = "--";
        DetailText  = "";
        VersionText = "v3.0";
        UptimeText  = "";
        Font        = new Font("Microsoft YaHei UI", 22f, FontStyle.Bold, GraphicsUnit.Pixel);
        Cursor      = Cursors.Default;
    }

    public Rectangle ToggleRect()
    {
        int w = 70, h = 34;
        return new Rectangle(Width - 18 - w, (Height - h) / 2, w, h);
    }

    // 设置胶囊（齿轮图标 + "设置"），右边距 100px
    public Rectangle GearRect()
    {
        int tw;
        using (Font f = new Font("Microsoft YaHei UI", 13f, GraphicsUnit.Pixel))
        {
            tw = TextRenderer.MeasureText("设置", f).Width;
        }
        int w = 10 + 16 + 6 + tw + 14;
        return new Rectangle(Width - 108 - w, (Height - 32) / 2, w, 32);
    }

    // 运行时长徽章，右边距 180px
    public Rectangle UptimeRect()
    {
        int tw = 0;
        if (!string.IsNullOrEmpty(UptimeText))
        {
            using (Font f = new Font("Microsoft YaHei UI", 12.5f, GraphicsUnit.Pixel))
            {
                tw = TextRenderer.MeasureText(UptimeText, f).Width;
            }
        }
        int w = 13 + 14 + 6 + tw + 13;
        if (w < 96) { w = 96; }
        return new Rectangle(Width - 208 - w, (Height - 30) / 2, w, 30);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        bool oT = ToggleRect().Contains(e.Location);
        bool oG = GearRect().Contains(e.Location);
        if (oT != overToggle || oG != overGear)
        {
            overToggle = oT; overGear = oG;
            Cursor = (oT || oG) ? Cursors.Hand : Cursors.Default;
            Invalidate();
        }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        overToggle = false; overGear = false; Cursor = Cursors.Default;
        Invalidate();
        base.OnMouseLeave(e);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            if (ToggleRect().Contains(e.Location) && ThemeToggled != null) { ThemeToggled(this, EventArgs.Empty); }
            else if (GearRect().Contains(e.Location) && SettingsClicked != null) { SettingsClicked(this, EventArgs.Empty); }
        }
        base.OnMouseUp(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        Color c1 = Accent;
        Color c2 = Color.FromArgb((int)(c1.R * 0.62), (int)(c1.G * 0.62), (int)(c1.B * 0.62));
        using (GraphicsPath path = Rounded(r, 16))
        using (LinearGradientBrush br = new LinearGradientBrush(r, c1, c2, 0f))
        {
            g.FillPath(br, path);
        }

        using (SolidBrush dot = new SolidBrush(Color.FromArgb(235, 255, 255, 255)))
        {
            g.FillEllipse(dot, 22, Height / 2 - 11, 22, 22);
        }

        int sw = TextRenderer.MeasureText(StatusText, Font).Width;
        Rectangle sr = new Rectangle(58, 12, sw + 20, 42);
        TextRenderer.DrawText(g, StatusText, Font, sr, CardFg, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);

        // 版本号紧跟在状态文字后面（小一号、半透明）
        using (Font vf = new Font("Microsoft YaHei UI", 13f, GraphicsUnit.Pixel))
        {
            Rectangle vr = new Rectangle(58 + sw + 10, 16, 90, 40);
            TextRenderer.DrawText(g, VersionText, vf, vr, Color.FromArgb(190, CardFg),
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
        }

        using (Font df = new Font("Microsoft YaHei UI", 12.5f, GraphicsUnit.Pixel))
        {
            Rectangle dr = new Rectangle(60, 52, Width - 340, 26);
            TextRenderer.DrawText(g, DetailText, df, dr, CardFg, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
        }

        DrawUptimeBadge(g);
        DrawGearCapsule(g);
        DrawToggle(g);
    }

    // 真正的齿轮：齿数 / 齿顶半径 / 齿根半径 / 齿宽 参数化生成轮廓
    private static PointF[] GearPoints(float cx, float cy, int teeth, float rOut, float rIn, float toothRatio)
    {
        List<PointF> pts = new List<PointF>();
        double step = Math.PI * 2 / teeth;
        for (int i = 0; i < teeth; i++)
        {
            double a0 = i * step - Math.PI / 2;
            double w1 = 0.09 * step;
            double w2 = (0.09 + toothRatio * 0.5) * step;
            double w3 = (0.09 + toothRatio * 0.5 + 0.09) * step;
            pts.Add(Rad(cx, cy, a0, rIn));
            pts.Add(Rad(cx, cy, a0 + w1, rOut));
            pts.Add(Rad(cx, cy, a0 + w2, rOut));
            pts.Add(Rad(cx, cy, a0 + w3, rIn));
        }
        return pts.ToArray();
    }

    private static PointF Rad(float cx, float cy, double a, float r)
    {
        return new PointF((float)(cx + Math.Cos(a) * r), (float)(cy + Math.Sin(a) * r));
    }

    private void DrawGearCapsule(Graphics g)
    {
        Rectangle rect = GearRect();
        using (GraphicsPath cp = Rounded(rect, 16))
        using (SolidBrush cb = new SolidBrush(Color.FromArgb(overGear ? 82 : 56, 255, 255, 255)))
        {
            g.FillPath(cb, cp);
        }

        float size = 16f;
        float cx = rect.X + 10 + size / 2f;
        float cy = rect.Y + rect.Height / 2f;
        float u = size / 24f;
        using (GraphicsPath gp = new GraphicsPath())
        {
            gp.FillMode = FillMode.Alternate;
            gp.AddPolygon(GearPoints(cx, cy, 8, 10.6f * u, 8.0f * u, 0.52f));
            float hole = 3.4f * u;
            gp.AddEllipse(cx - hole, cy - hole, hole * 2, hole * 2);
            using (SolidBrush gb = new SolidBrush(CardFg))
            {
                g.FillPath(gb, gp);
            }
        }

        using (Font f = new Font("Microsoft YaHei UI", 13f, GraphicsUnit.Pixel))
        {
            Rectangle tr = new Rectangle(rect.X + 10 + (int)size + 6, rect.Y, rect.Width - 10 - (int)size - 6 - 14, rect.Height);
            TextRenderer.DrawText(g, "设置", f, tr, CardFg, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
        }
    }

    private void DrawUptimeBadge(Graphics g)
    {
        if (string.IsNullOrEmpty(UptimeText)) { return; }
        Rectangle rect = UptimeRect();
        using (GraphicsPath bp = Rounded(rect, 15))
        using (SolidBrush bb = new SolidBrush(Color.FromArgb(56, 0, 0, 0)))
        {
            g.FillPath(bb, bp);
        }

        float d = 14f;
        float cx = rect.X + 13 + d / 2f;
        float cy = rect.Y + rect.Height / 2f;
        using (Pen p = new Pen(CardFg, 1.5f))
        {
            p.StartCap = LineCap.Round;
            p.EndCap = LineCap.Round;
            g.DrawEllipse(p, cx - d / 2f, cy - d / 2f, d, d);
            g.DrawLine(p, cx, cy, cx, cy - d * 0.30f);
            g.DrawLine(p, cx, cy, cx + d * 0.26f, cy + d * 0.18f);
        }

        using (Font f = new Font("Microsoft YaHei UI", 12.5f, GraphicsUnit.Pixel))
        {
            Rectangle tr = new Rectangle(rect.X + 13 + (int)d + 6, rect.Y, rect.Width - 13 - (int)d - 6 - 13, rect.Height);
            TextRenderer.DrawText(g, UptimeText, f, tr, CardFg, TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
        }
    }

    private void DrawToggle(Graphics g)
    {
        Rectangle t = ToggleRect();
        int alpha = overToggle ? 62 : 40;
        using (GraphicsPath tp = Rounded(t, t.Height / 2))
        using (SolidBrush tb = new SolidBrush(Color.FromArgb(alpha, 0, 0, 0)))
        {
            g.FillPath(tb, tp);
        }

        int knob = 26;
        int travel = t.Width - knob - 8;
        int kx = t.X + 4 + (int)Math.Round(travel * Blend);
        Rectangle kr = new Rectangle(kx, t.Y + 4, knob, knob);

        using (SolidBrush sh = new SolidBrush(Color.FromArgb(60, 0, 0, 0)))
        {
            g.FillEllipse(sh, kr.X, kr.Y + 2, knob, knob);
        }
        using (GraphicsPath kp = new GraphicsPath())
        {
            kp.AddEllipse(kr);
            using (PathGradientBrush pgb = new PathGradientBrush(kp))
            {
                pgb.CenterColor = Color.White;
                pgb.SurroundColors = new Color[] { Color.FromArgb(226, 232, 240) };
                g.FillPath(pgb, kp);
            }
        }

        // 太阳 / 月亮都用矢量画：用字体的话 Windows 会给 ☀ 换成彩色 emoji，跟界面不搭
        int sunA = (int)((1.0 - Blend) * 245);
        int moonA = (int)(Blend * 245);
        if (sunA > 3)
        {
            Color sc = Color.FromArgb(sunA, 255, 255, 255);
            int scx = t.Right - 17, scy = t.Y + t.Height / 2;
            using (SolidBrush sb = new SolidBrush(sc)) { g.FillEllipse(sb, scx - 4, scy - 4, 9, 9); }
            using (Pen sp = new Pen(sc, 1.6f))
            {
                for (int k = 0; k < 8; k++)
                {
                    double ang = k * Math.PI / 4.0;
                    int x1 = scx + (int)Math.Round(Math.Cos(ang) * 7);
                    int y1 = scy + (int)Math.Round(Math.Sin(ang) * 7);
                    int x2 = scx + (int)Math.Round(Math.Cos(ang) * 10.5);
                    int y2 = scy + (int)Math.Round(Math.Sin(ang) * 10.5);
                    g.DrawLine(sp, x1, y1, x2, y2);
                }
            }
        }
        if (moonA > 3)
        {
            Color mc = Color.FromArgb(moonA, 255, 255, 255);
            // 月牙 = 外圆的一段弧 + 挖掉那半的一段弧，两个圆做 Alternate 填充会变成「缺口的环」
            float mcx = t.X + 17f, mcy = t.Y + t.Height / 2f;
            float R = 8.5f, ratio = 0.62f;      // ratio 越大月牙越饱满；0.62 在 16px 下最清楚
            float d = R * ratio;                // 挖掉的那个圆往右偏多少
            float ix = d / 2f;
            float iy = (float)Math.Sqrt(R * R - ix * ix);
            double aOut = Math.Atan2(iy, ix) * 180.0 / Math.PI;
            double aIn  = Math.Atan2(iy, ix - d) * 180.0 / Math.PI;
            using (GraphicsPath mp = new GraphicsPath())
            {
                mp.AddArc(mcx - R, mcy - R, R * 2f, R * 2f, (float)aOut, (float)(360 - 2 * aOut));
                mp.AddArc(mcx + d - R, mcy - R, R * 2f, R * 2f, (float)(-aIn), (float)(2 * aIn - 360));
                mp.CloseFigure();
                using (Matrix mm = new Matrix())
                {
                    mm.RotateAt(-30f, new PointF(mcx, mcy));   // 斜一点才像月亮
                    mp.Transform(mm);
                }
                using (SolidBrush mb = new SolidBrush(mc)) { g.FillPath(mb, mp); }
            }
        }
    }

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        GraphicsPath path = new GraphicsPath();
        int d = radius * 2;
        if (d <= 0 || d > r.Width || d > r.Height) { path.AddRectangle(r); return path; }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
'@
try { Add-Type -TypeDefinition $uiSource -ReferencedAssemblies System.Drawing, System.Windows.Forms -ErrorAction Stop }
catch { }

function HexColor { param([string]$Hex) return [System.Drawing.ColorTranslator]::FromHtml($Hex) }
function Shift-Color {
  param([System.Drawing.Color]$Color, [int]$Delta)
  $r = [Math]::Max(0, [Math]::Min(255, $Color.R + $Delta))
  $g = [Math]::Max(0, [Math]::Min(255, $Color.G + $Delta))
  $b = [Math]::Max(0, [Math]::Min(255, $Color.B + $Delta))
  return [System.Drawing.Color]::FromArgb($r, $g, $b)
}
function Mix-Color {
  param([System.Drawing.Color]$A, [System.Drawing.Color]$B, [double]$T)
  return [System.Drawing.Color]::FromArgb(
    [int]($A.R + ($B.R - $A.R) * $T),
    [int]($A.G + ($B.G - $A.G) * $T),
    [int]($A.B + ($B.B - $A.B) * $T))
}

# ============================ 配置区 =============================
$script:Cfg = @{
  Port        = 3080
  # DSH 源码目录（含 package.json、平时敲 pnpm dsh web 的那个文件夹）
  # 留空 = 启动时自动探测（管家旁边、桌面/文档/下载、各盘根目录）；全局安装的 DSH 也可以留空
  CheckoutDir = ''
  # 启动命令。留空 = 自动识别：源码目录走 pnpm / npm，全局安装走 dsh
  # 想自定义就写完整命令，例如：dsh web --no-open 或 "C:\nodejs\npx.cmd" dsh web
  StartCmd    = ''
  LogFile     = Join-Path $env:TEMP 'dsh-web.log'
  SettingsDir = Join-Path $env:LOCALAPPDATA 'dsh-console'
  IconFile    = (Join-Path $PSScriptRoot 'DSH管家.ico')
  Browser     = ''          # 打开页面用哪个浏览器；空 = 系统默认
  Version     = 'v3.0'      # ← 版本号只在这里改，其它地方自动跟随
  AnimMs      = 1100
  # ---- 常驻 / 浏览器 / 主题等可配置项 ----
  AutoStart        = $false   # 开机自动启动管家
  AutoStartService = $false   # 开机顺便启动 DSH 服务
  CloseToTray      = $true    # 关闭窗口时最小化到托盘
  StopOnExit       = $false   # 退出时同时停止服务
  ThemeMode        = 'manual' # manual = 手动；time = 跟随时间
  AutoOpenBrowser  = $true    # 启动成功后自动打开浏览器
  GuardMode        = $false   # 守护模式：服务挂了自动重启
  StartMenuLink    = $false   # 在开始菜单中显示
}
$script:Cfg.Url = 'http://127.0.0.1:' + $script:Cfg.Port
$script:Cfg.Title = 'DSH 管家 ' + $script:Cfg.Version
$script:Busy      = $false
$script:NeedSetup = $false   # 首次运行没找到 DSH 目录，需要引导去设置
$script:LastState = ''
$script:CachedPid = 0
$NL               = [Environment]::NewLine
$script:Blend     = 0.0      # 0 = 白天, 1 = 夜间
$script:StatusKind = 'stopped'
$script:CurTh      = $null
$script:IsNight   = $false

# ---- 两套主题（白天 = H2 米黄淡彩描边 / 夜间 = NT1 石墨原味） ----
$script:Themes = @{
  day = @{
    Bg = (HexColor '#FAF4E8'); Card = (HexColor '#4D7C5A'); CardFg = (HexColor '#FFF8EE')
    Chk = (HexColor '#4A3F35'); Muted = (HexColor '#A79A88'); BorderW = 2.0
    AccentRun = (HexColor '#4D7C5A'); AccentStop = (HexColor '#A85D4E'); AccentProg = (HexColor '#B07A21')
    SysFill = (HexColor '#FFFDF7'); SysBd = (HexColor '#E8DDC9'); SysFg = (HexColor '#4A3F35')
    Btns = @(
      @{ Fill = (HexColor '#DCEBDF'); Fg = (HexColor '#2F5640'); Bd = (HexColor '#7FA98C'); Glyph = (HexColor '#2F5640') },
      @{ Fill = (HexColor '#F2D8D0'); Fg = (HexColor '#7E3F33'); Bd = (HexColor '#C98C7C'); Glyph = (HexColor '#7E3F33') },
      @{ Fill = (HexColor '#D9E3F3'); Fg = (HexColor '#374A6E'); Bd = (HexColor '#8FA3C7'); Glyph = (HexColor '#374A6E') },
      @{ Fill = (HexColor '#E9E2D5'); Fg = (HexColor '#554F45'); Bd = (HexColor '#B5A894'); Glyph = (HexColor '#554F45') }
    )
  }
  night = @{
    Bg = (HexColor '#121417'); Card = (HexColor '#1F7A50'); CardFg = (HexColor '#FFFFFF')
    Chk = (HexColor '#D5DCE6'); Muted = (HexColor '#77808F'); BorderW = 0.0
    AccentRun = (HexColor '#1F7A50'); AccentStop = (HexColor '#8A3F3F'); AccentProg = (HexColor '#C08A1E')
    SysFill = (HexColor '#1E242C'); SysBd = (HexColor '#2A313B'); SysFg = (HexColor '#9AA5B5')
    Btns = @(
      @{ Fill = (HexColor '#1E242C'); Fg = (HexColor '#4ADE80'); Bd = (HexColor '#1E242C'); Glyph = (HexColor '#4ADE80') },
      @{ Fill = (HexColor '#1E242C'); Fg = (HexColor '#F87171'); Bd = (HexColor '#1E242C'); Glyph = (HexColor '#F87171') },
      @{ Fill = (HexColor '#1E242C'); Fg = (HexColor '#60A5FA'); Bd = (HexColor '#1E242C'); Glyph = (HexColor '#60A5FA') },
      @{ Fill = (HexColor '#1E242C'); Fg = (HexColor '#94A3B8'); Bd = (HexColor '#1E242C'); Glyph = (HexColor '#94A3B8') }
    )
  }
}

function Get-BlendedTheme {
  param([double]$T)
  $d = $script:Themes.day
  $n = $script:Themes.night
  $r = @{}
  $r.Bg      = Mix-Color $d.Bg      $n.Bg      $T
  $r.Card    = Mix-Color $d.Card    $n.Card    $T
  $r.CardFg  = Mix-Color $d.CardFg  $n.CardFg  $T
  $r.Chk     = Mix-Color $d.Chk     $n.Chk     $T
  $r.Muted   = Mix-Color $d.Muted   $n.Muted   $T
  $r.AccentRun  = Mix-Color $d.AccentRun  $n.AccentRun  $T
  $r.AccentStop = Mix-Color $d.AccentStop $n.AccentStop $T
  $r.AccentProg = Mix-Color $d.AccentProg $n.AccentProg $T
  $r.BorderW = $d.BorderW + ($n.BorderW - $d.BorderW) * $T
  $r.SysFill = Mix-Color $d.SysFill $n.SysFill $T
  $r.SysBd   = Mix-Color $d.SysBd   $n.SysBd   $T
  $r.SysFg   = Mix-Color $d.SysFg   $n.SysFg   $T
  $r.Btns = @()
  for ($i = 0; $i -lt 4; $i++) {
    $r.Btns += @{
      Fill  = (Mix-Color $d.Btns[$i].Fill  $n.Btns[$i].Fill  $T)
      Fg    = (Mix-Color $d.Btns[$i].Fg    $n.Btns[$i].Fg    $T)
      Bd    = (Mix-Color $d.Btns[$i].Bd    $n.Btns[$i].Bd    $T)
      Glyph = (Mix-Color $d.Btns[$i].Glyph $n.Btns[$i].Glyph $T)
    }
  }
  return $r
}

# ============================ 检测函数 ===========================
function Test-PortListening {
  try {
    $eps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    foreach ($ep in $eps) { if ($ep.Port -eq $script:Cfg.Port) { return $true } }
  } catch { }
  return $false
}

function Get-PortOwnerPid {
  try {
    $lines   = & netstat.exe -ano -p tcp 2>$null
    $pattern = ':' + $script:Cfg.Port + '\s+.*LISTENING\s+(\d+)'
    foreach ($l in $lines) { if ($l -match $pattern) { return [int]$Matches[1] } }
  } catch { }
  return 0
}

function Get-ServerInfo {
  if (-not (Test-PortListening)) {
    $script:CachedPid = 0
    return [pscustomobject]@{ Running = $false; ProcessId = 0 }
  }
  if ($script:CachedPid -gt 0) {
    $p = Get-Process -Id $script:CachedPid -ErrorAction SilentlyContinue
    if ($p) {
      $st = $null
      try { $st = $p.StartTime } catch { }
      return [pscustomobject]@{ Running = $true; ProcessId = $script:CachedPid; StartTime = $st }
    }
  }
  $script:CachedPid = Get-PortOwnerPid
  $st2 = $null
  $p2 = Get-Process -Id $script:CachedPid -ErrorAction SilentlyContinue
  if ($p2) { try { $st2 = $p2.StartTime } catch { } }
  return [pscustomobject]@{ Running = $true; ProcessId = $script:CachedPid; StartTime = $st2 }
}

function Format-Uptime {
  param($StartTime)
  if (-not $StartTime) { return '' }
  try {
    $d = (Get-Date) - $StartTime
    if ($d.TotalSeconds -lt 0) { return '' }
    if ($d.TotalMinutes -lt 1) { return '刚刚启动' }
    if ($d.TotalHours -lt 1)   { return ([string][int]$d.TotalMinutes + ' 分钟') }
    if ($d.TotalDays -lt 1) {
      if ($d.Minutes -gt 0) { return ([string][int]$d.TotalHours + ' 小时 ' + [string]$d.Minutes + ' 分') }
      return ([string][int]$d.TotalHours + ' 小时')
    }
    return ([string][int]$d.TotalDays + ' 天 ' + [string]$d.Hours + ' 小时')
  } catch { return '' }
}

function Get-BrowserList {
  $list = New-Object System.Collections.ArrayList
  [void]$list.Add([pscustomobject]@{ Name = '（系统默认浏览器）'; Path = '' })
  $roots = @(
    'HKLM:\SOFTWARE\Clients\StartMenuInternet',
    'HKCU:\SOFTWARE\Clients\StartMenuInternet',
    'HKLM:\SOFTWARE\WOW6432Node\Clients\StartMenuInternet'
  )
  $seen = @{}
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
      $cmdPath = [string]$k.PSPath + '\shell\open\command'
      if (-not (Test-Path -LiteralPath $cmdPath)) { continue }
      $cmd = ''
      try { $cmd = [string](Get-ItemProperty -LiteralPath $cmdPath -ErrorAction Stop).'(default)' } catch { continue }
      if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
      $exe = $cmd.Trim()
      if ($exe.StartsWith('"')) {
        $end = $exe.IndexOf('"', 1)
        if ($end -gt 1) { $exe = $exe.Substring(1, $end - 1) }
      } else {
        $exe = ($exe -split ' ')[0]
      }
      if (-not (Test-Path -LiteralPath $exe)) { continue }
      $key = $exe.ToLower()
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $name = ''
      try { $name = [string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop).'(default)' } catch { }
      if ([string]::IsNullOrWhiteSpace($name)) { $name = (Split-Path $exe -Leaf) }
      if ($name -match 'pdf|云盘|clouddrive|编辑器|阅读器') { continue }
      [void]$list.Add([pscustomobject]@{ Name = $name; Path = $exe })
    }
  }
  # 再补一个：系统默认浏览器（有些浏览器不注册在 StartMenuInternet 下，比如 QQ 浏览器）
  try {
    $progId = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction SilentlyContinue).ProgId
    if ($progId) {
      $cmd2 = $null
      foreach ($hive in @('HKCU:\Software\Classes', 'HKLM:\Software\Classes')) {
        $k2 = Join-Path $hive ($progId + '\shell\open\command')
        if (Test-Path $k2) { $cmd2 = (Get-ItemProperty -Path $k2 -ErrorAction SilentlyContinue).'(default)'; break }
      }
      if ($cmd2) {
        $exe2 = $cmd2.Trim()
        if ($exe2.StartsWith('"')) { $e3 = $exe2.IndexOf('"', 1); if ($e3 -gt 1) { $exe2 = $exe2.Substring(1, $e3 - 1) } }
        else { $exe2 = ($exe2 -split ' ')[0] }
        if ((Test-Path -LiteralPath $exe2) -and (-not $seen.ContainsKey($exe2.ToLower()))) {
          $nm2 = [System.IO.Path]::GetFileNameWithoutExtension($exe2)
          [void]$list.Add([pscustomobject]@{ Name = ($nm2 + '（系统默认）'); Path = $exe2 })
        }
      }
    }
  } catch { }
  # 排个序：第一项「系统默认浏览器」固定在最前，其余按名字排，看着整齐
  $head = $list[0]
  $rest = @($list | Select-Object -Skip 1 | Sort-Object -Property Name)
  return @($head) + $rest
}

# ---- 工作目录 / 启动命令的自动识别 -----------------------------
# 判断一个目录像不像 DSH 源码目录（看 package.json 里有没有 dsh 的痕迹）
function Test-DshDir {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $pj = Join-Path $Path 'package.json'
  if (-not (Test-Path -LiteralPath $pj)) { return $false }
  try {
    $txt = Get-Content -LiteralPath $pj -Raw -Encoding UTF8
    return ($txt -match 'dsh-root|deepseek-harness|"dsh"\s*:')
  } catch { return $false }
}

# 自动找 DSH 源码目录：先看管家自己周围（工具通常就放在 DSH 旁边），
# 再看桌面/文档/下载，最后扫各盘根目录下面一层。找不到返回空字符串。
function Find-CheckoutDir {
  $dirs = New-Object System.Collections.ArrayList
  $self = $PSScriptRoot
  foreach ($up in 0..2) {
    $base = $self
    for ($i = 0; $i -lt $up; $i++) { if ($base) { $base = Split-Path $base -Parent } }
    if ($base -and -not $dirs.Contains($base)) { [void]$dirs.Add($base) }
  }
  foreach ($d in @($env:USERPROFILE, (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Downloads'))) {
    if ($d -and -not $dirs.Contains($d)) { [void]$dirs.Add($d) }
  }
  foreach ($drv in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    if ($drv.Root -match '^[A-Za-z]:\\$') { [void]$dirs.Add($drv.Root) }
  }
  foreach ($base in $dirs) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    $subs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like '*dsh*' -or $_.Name -like '*deepseek*' })
    foreach ($sub in $subs) { if (Test-DshDir $sub.FullName) { return $sub.FullName } }
  }
  return ''
}

# 启动命令：配置了就用配置的；没配置就按环境自动挑一个
function Resolve-StartCmd {
  if (-not [string]::IsNullOrWhiteSpace($script:Cfg.StartCmd)) { return $script:Cfg.StartCmd.Trim() }
  $hasPnpm = ($null -ne (Get-Command 'pnpm' -ErrorAction SilentlyContinue)) -or (Test-Path (Join-Path $env:APPDATA 'npm\pnpm.cmd'))
  if (Test-DshDir $script:Cfg.CheckoutDir) {
    if ($hasPnpm) { return 'pnpm dsh web --no-open' }
    if (Get-Command 'npm' -ErrorAction SilentlyContinue) { return 'npm run dsh -- web --no-open' }
  }
  if (Get-Command 'dsh' -ErrorAction SilentlyContinue) { return 'dsh web --no-open' }
  if ($hasPnpm) { return 'pnpm dsh web --no-open' }
  return 'dsh web --no-open'
}

function Read-LastLines {
  param([string]$Path, [int]$Lines = 15, [int]$MaxBytes = 65536)
  $fs = $null
  try {
    $fs    = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $len   = $fs.Length
    $start = [Math]::Max(0, $len - $MaxBytes)
    [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
    $count = [int]($len - $start)
    $buf   = New-Object byte[] $count
    [void]$fs.Read($buf, 0, $count)
    $text  = [System.Text.Encoding]::Default.GetString($buf)
    $text  = [regex]::Replace($text, '\x1B\[[0-9;]*[A-Za-z]', '')
    $arr   = $text -split '\r?\n'
    if ($arr.Count -gt $Lines) { $arr = $arr[($arr.Count - $Lines)..($arr.Count - 1)] }
    $out = ($arr -join $NL).Trim()
    if ([string]::IsNullOrWhiteSpace($out)) { return '（日志目前是空的）' }
    return $out
  } catch {
    return '（读取日志失败：' + $_.Exception.Message + '）'
  } finally {
    if ($fs) { $fs.Dispose() }
  }
}

function Get-WebUrl {
  $file = $script:Cfg.LogFile
  if (-not (Test-Path $file)) { return $null }
  $pat = [regex]::Escape($script:Cfg.Url) + '/\?token=[A-Za-z0-9\-_]+'
  $fs  = $null
  try {
    $fs    = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $count = [int][Math]::Min(131072, $fs.Length)
    $buf   = New-Object byte[] $count
    [void]$fs.Read($buf, 0, $count)
    $txt   = [System.Text.Encoding]::Default.GetString($buf)
    $m     = [regex]::Matches($txt, $pat)
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Value }
  } catch { } finally { if ($fs) { $fs.Dispose() } }
  try {
    $txt = Get-Content -LiteralPath $file -Raw -Encoding Default -ErrorAction SilentlyContinue
    if ($txt) {
      $m = [regex]::Matches($txt, $pat)
      if ($m.Count -gt 0) { return $m[$m.Count - 1].Value }
    }
  } catch { }
  return $null
}

function Open-Url {
  param([string]$Url)
  if (-not $Url) { return }
  $exe = $script:Cfg.Browser
  if ($exe -and (Test-Path $exe)) {
    try {
      Start-Process -FilePath $exe -ArgumentList ('"' + $Url + '"')
      return
    } catch {
      Write-SelfLog ('指定浏览器打开失败，改用默认: ' + $_.Exception.Message)
    }
  }
  Start-Process $Url
}

function Open-Web {
  $u = Get-WebUrl
  if (-not $u) { $u = $script:Cfg.Url }
  Open-Url $u
}

function Read-Settings {
  $file = Join-Path $script:Cfg.SettingsDir 'settings.json'
  if (-not (Test-Path $file)) { return $null }
  try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-Settings {
  param($Form, [bool]$StopOnExit)
  try {
    if (-not (Test-Path $script:Cfg.SettingsDir)) { New-Item -ItemType Directory -Path $script:Cfg.SettingsDir -Force | Out-Null }
    $data = [ordered]@{
      X = $Form.Location.X; Y = $Form.Location.Y; StopOnExit = [bool]$script:Cfg.StopOnExit
      Theme = $(if ($script:IsNight) { 'night' } else { 'day' })
      Browser = $script:Cfg.Browser
      CheckoutDir = $script:Cfg.CheckoutDir
      StartCmd = $script:Cfg.StartCmd
      AutoStart = [bool]$script:Cfg.AutoStart
      AutoStartService = [bool]$script:Cfg.AutoStartService
      CloseToTray = [bool]$script:Cfg.CloseToTray
      ThemeMode = [string]$script:Cfg.ThemeMode
      AutoOpenBrowser = [bool]$script:Cfg.AutoOpenBrowser
      GuardMode = [bool]$script:Cfg.GuardMode
      StartMenuLink = [bool]$script:Cfg.StartMenuLink
      Port = [int]$script:Cfg.Port
    }
    ($data | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $script:Cfg.SettingsDir 'settings.json') -Encoding UTF8
  } catch { }
}

# ======================= 开机自启 / 开始菜单 ======================
function Test-AutoStart {
  try {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $v = (Get-ItemProperty -Path $key -Name 'DSH管家' -ErrorAction SilentlyContinue).'DSH管家'
    return [bool]$v
  } catch { return $false }
}

function Set-AutoStart {
  param([bool]$Enable)
  try {
    $key  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $exe  = Join-Path $PSScriptRoot 'DSH管家.exe'
    if (-not (Test-Path $exe)) { $exe = Join-Path $PSScriptRoot 'DSH管家.ps1' }
    if ($Enable) {
      if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
      Set-ItemProperty -Path $key -Name 'DSH管家' -Value ('"' + $exe + '"') -ErrorAction Stop
      Write-SelfLog ('开机自启已开启 → ' + $exe)
    } else {
      Remove-ItemProperty -Path $key -Name 'DSH管家' -ErrorAction SilentlyContinue
      Write-SelfLog '开机自启已关闭'
    }
    return $true
  } catch {
    Write-SelfLog ('设置开机自启失败: ' + $_.Exception.Message)
    return $false
  }
}

function Test-StartMenuLink {
  $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DSH 管家.lnk'
  return (Test-Path $lnk)
}

function Set-StartMenuLink {
  param([bool]$Enable)
  try {
    $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\DSH 管家.lnk'
    if ($Enable) {
      $ws = New-Object -ComObject WScript.Shell
      $sc = $ws.CreateShortcut($lnk)
      $sc.TargetPath       = (Join-Path $PSScriptRoot 'DSH管家.exe')
      $sc.WorkingDirectory = $PSScriptRoot
      $sc.IconLocation     = (Join-Path $PSScriptRoot 'DSH管家.ico')
      $sc.Description      = 'DSH 管家'
      $sc.Save()
      Write-SelfLog '已创建开始菜单快捷方式'
    } else {
      if (Test-Path $lnk) { Remove-Item -LiteralPath $lnk -Force }
      Write-SelfLog '已删除开始菜单快捷方式'
    }
    return $true
  } catch {
    Write-SelfLog ('开始菜单快捷方式失败: ' + $_.Exception.Message)
    return $false
  }
}

# ============================ 启停流程 ===========================
function Start-Server {
  if (Test-PortListening) { return @{ Ok = $true; Already = $true; Url = (Get-WebUrl) } }

  if (-not (Test-Path $script:Cfg.CheckoutDir)) {
    $m = @('找不到工作目录：', $script:Cfg.CheckoutDir, '', '请用记事本打开本脚本，修改配置区的 CheckoutDir。') -join $NL
    [void][System.Windows.Forms.MessageBox]::Show($m, $script:Cfg.Title, 'OK', 'Error')
    return @{ Ok = $false; Already = $false; Url = $null }
  }

  try {
    if (Test-Path $script:Cfg.LogFile) {
      Move-Item -LiteralPath $script:Cfg.LogFile -Destination ($script:Cfg.LogFile + '.prev') -Force -ErrorAction SilentlyContinue
    }
  } catch { }
  try {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Set-Content -LiteralPath $script:Cfg.LogFile -Value ('===== dsh web started at ' + $stamp + ' =====') -Encoding Default -ErrorAction SilentlyContinue
  } catch { }

  $startCmd = Resolve-StartCmd
  Write-SelfLog ('启动命令: ' + $startCmd)
  # 工作目录不存在（比如全局安装的 DSH）就退回到管家自己所在目录
  $workDir = $script:Cfg.CheckoutDir
  if (-not (Test-Path -LiteralPath $workDir)) { $workDir = $PSScriptRoot }
  # 写法说明：cmd /c 后面这一串，cmd 会砍掉最外层的一对引号（见 cmd /? 的引号规则），
  # 所以这里只包一层就对了，而且自带引号的命令（路径含空格）也正好能work：
  #   pnpm dsh web --no-open      -> pnpm dsh web --no-open
  #   "C:\...含空格\npx.cmd" dsh web -> "C:\...含空格\npx.cmd" dsh web
  $argLine = '/c "' + $startCmd + ' >> "' + $script:Cfg.LogFile + '" 2>&1"'
  Start-Process -FilePath 'cmd.exe' -ArgumentList $argLine -WorkingDirectory $workDir -WindowStyle Hidden

  $portUp = $false
  for ($i = 1; $i -le 120; $i++) {
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.Application]::DoEvents()
    Set-StatusCard 'progress' ('正在启动... 已等待 ' + [string]([int]($i * 0.5)) + ' 秒')
    if (Test-PortListening) { $portUp = $true; break }
  }
  if (-not $portUp) { return @{ Ok = $false; Already = $false; Url = $null } }

  for ($i = 1; $i -le 30; $i++) {
    $u = Get-WebUrl
    if ($u) { return @{ Ok = $true; Already = $false; Url = $u } }
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.Application]::DoEvents()
  }
  return @{ Ok = $true; Already = $false; Url = $null }
}

function Stop-Server {
  $info = Get-ServerInfo
  if (-not $info.Running) { return $true }

  $m = @('确定要停止 DSH 服务吗？', '', ('进程 PID：' + $info.ProcessId), '', '注意：停止后，当前打开的 DSH 网页会断开连接。', '（聊天记录保存在硬盘上，不会丢失）') -join $NL
  $r = [System.Windows.Forms.MessageBox]::Show($m, '确认停止', 'YesNo', 'Warning')
  if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

  Set-StatusCard 'progress' '正在停止服务...'
  & taskkill.exe /PID $info.ProcessId /T /F 2>$null | Out-Null
  for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.Application]::DoEvents()
    if (-not (Test-PortListening)) { return $true }
  }
  return $true
}


# 程序图标：直接用文件夹里那张 DSH管家.ico（不再自动生成兜底图标）
$formIcon = $null
try {
  if (Test-Path $script:Cfg.IconFile) { $formIcon = New-Object System.Drawing.Icon($script:Cfg.IconFile) }
  else { Write-SelfLog ('找不到图标文件，用系统默认图标: ' + $script:Cfg.IconFile) }
} catch { Write-SelfLog ('图标加载失败: ' + $_.Exception.Message) }

# 启动时枚举一次系统已安装的浏览器
$script:Browsers = Get-BrowserList
Write-SelfLog ('探测到浏览器 ' + ($script:Browsers.Count - 1) + ' 个')

# =============================== 界面 ============================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = $script:Cfg.Title
$form.ClientSize      = New-Object System.Drawing.Size(700, 450)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
if ($formIcon) { $form.Icon = $formIcon }

$statusCard           = New-Object StatusCard
$statusCard.Location  = New-Object System.Drawing.Point(20, 18)
$statusCard.Size      = New-Object System.Drawing.Size(660, 104)
$statusCard.VersionText = $script:Cfg.Version
$form.Controls.Add($statusCard)

function New-CardBtn {
  param([string]$Text, [string]$Glyph, [int]$X, [int]$Y, [int]$W, [int]$H, [double]$FontSize = 9.5)
  $b            = New-Object FlatCardButton
  $b.Text       = $Text
  $b.Glyph      = $Glyph
  $b.Location   = New-Object System.Drawing.Point($X, $Y)
  $b.Size       = New-Object System.Drawing.Size($W, $H)
  $b.Font       = New-Object System.Drawing.Font('Microsoft YaHei UI', $FontSize)
  $form.Controls.Add($b)
  return $b
}

# 按钮加高到 112、图标比例调小一点（0.27 → 0.23），留出呼吸空间
$btnStart   = New-CardBtn '启动服务' '▶' 20  140 154 112 10.5
$btnStop    = New-CardBtn '停止服务' '■' 188 140 154 112 10.5
$btnRestart = New-CardBtn '重启服务' '↻' 356 140 154 112 10.5
$btnOpen    = New-CardBtn '打开页面' '↗' 524 140 154 112 10.5
$script:MainBtns = @($btnStart, $btnStop, $btnRestart, $btnOpen)

# ---------------- 浏览器选择条 ----------------
$lblBsTitle           = New-Object System.Windows.Forms.Label
$lblBsTitle.Text      = '「打开页面」使用哪个浏览器（点图标切换）'
$lblBsTitle.Font      = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblBsTitle.Location  = New-Object System.Drawing.Point(22, 262)
$lblBsTitle.AutoSize  = $true
$lblBsTitle.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($lblBsTitle)

$strip            = New-Object BrowserStrip
$strip.Location   = New-Object System.Drawing.Point(20, 286)
$strip.Size       = New-Object System.Drawing.Size(660, 68)
$form.Controls.Add($strip)
$script:Strip = $strip


$script:BrowserPaths = @()
$script:BrowserNames = @()
foreach ($b in $script:Browsers) {
  $img = $null
  if ($b.Path -and (Test-Path -LiteralPath $b.Path)) {
    try {
      $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($b.Path)
      if ($ic) { $img = $ic.ToBitmap() }
    } catch { }
  }
  $script:BrowserPaths += [string]$b.Path
  $script:BrowserNames += [string]$b.Name
  # 胶囊里放短名（完整名字显示在下面那行），不然会被截成「Microso...」
  $dn = [string]$b.Name
  if ([string]::IsNullOrEmpty($b.Path)) { $dn = '系统默认' }
  $dn = $dn -replace '（系统默认）$', '' -replace '\s*\(系统默认\)$', ''
  [void]$strip.Names.Add($dn)
  [void]$strip.Icons.Add($img)
}
$strip.AutoFit()

$selIdx = 0
for ($i = 0; $i -lt $script:BrowserPaths.Count; $i++) {
  if ($script:Cfg.Browser -and ($script:BrowserPaths[$i] -eq $script:Cfg.Browser)) { $selIdx = $i; break }
  elseif ((-not $script:Cfg.Browser) -and ($script:BrowserNames[$i] -like '*系统默认*')) { $selIdx = $i; break }
}
$strip.Selected = $selIdx


# 换浏览器（.NET 事件在 PowerShell 里要用 add_ 访问器）
$strip.add_SelectionChanged({
  try {
    $i = $script:Strip.Selected
    if ($i -ge 0 -and $i -lt $script:BrowserPaths.Count) {
      $script:Cfg.Browser = [string]$script:BrowserPaths[$i]
      Write-SelfLog ('浏览器切换为: ' + $script:BrowserNames[$i])
      Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
    }
  } catch { Write-SelfLog ('切换浏览器出错: ' + $_.Exception.Message) }
})

# 底部：左边两个 DeepSeek 外链胶囊（小鲸鱼图标），右下角一个退出
# （日志那几个操作都在设置面板里：打开服务日志 / 打开管家日志 / 清空服务日志）
$script:WhaleIcon = $null
try {
  $whalePath = Join-Path $PSScriptRoot 'assets\deepseek-whale.png'
  if (Test-Path -LiteralPath $whalePath) { $script:WhaleIcon = [System.Drawing.Image]::FromFile($whalePath) }
  else { Write-SelfLog '找不到 assets\deepseek-whale.png，外链按钮将只显示文字' }
} catch { Write-SelfLog ('鲸鱼图标加载失败: ' + $_.Exception.Message) }

$btnChat  = New-CardBtn '对话' '' 20  388 88 40 9.5
$btnUsage = New-CardBtn '用量' '' 118 388 88 40 9.5
$btnExit  = New-CardBtn '退 出' '' 558 388 122 40 9.5
foreach ($b in @($btnChat, $btnUsage)) {
  $b.IconImage  = $script:WhaleIcon
  $b.CornerRadius = 13
}
$btnExit.CornerRadius = 13
$script:SysBtns = @($btnChat, $btnUsage, $btnExit)

$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.InitialDelay = 400
$script:Tip.SetToolTip($btnChat,  '打开 DeepSeek 网页版 · 免费对话（chat.deepseek.com）')
$script:Tip.SetToolTip($btnUsage, '打开 DeepSeek 平台 · API 用量页（platform.deepseek.com/usage）')
$script:Tip.SetToolTip($btnExit,  '退出管家（点 × 只是缩到托盘）')

# ============================ 主题应用 ===========================
function Get-AccentFor {
  param($Th, [string]$Kind)
  switch ($Kind) {
    'running'  { return $Th.AccentRun }
    'progress' { return $Th.AccentProg }
    default    { return $Th.AccentStop }
  }
}

function Apply-Theme {
  param($Th)
  $script:CurTh = $Th
  $form.BackColor = $Th.Bg

  $statusCard.Accent  = (Get-AccentFor $Th $script:StatusKind)
  $statusCard.CardFg  = $Th.CardFg
  $statusCard.Blend   = $script:Blend
  $statusCard.Invalidate()

  for ($i = 0; $i -lt 4; $i++) {
    $b  = $script:MainBtns[$i]
    $bt = $Th.Btns[$i]
    $b.BaseColor   = $bt.Fill
    $b.HoverColor  = (Shift-Color $bt.Fill 18)
    $b.PressColor  = (Shift-Color $bt.Fill -16)
    $b.BorderColor = $bt.Bd
    $b.BorderWidth = [float]$Th.BorderW
    $b.GlyphColor  = $bt.Glyph
    $b.ForeColor   = $bt.Fg
    $b.DisabledBlend = $Th.Bg
    $b.Invalidate()
  }
  if ($script:Strip) {
    $script:Strip.CardBg       = $Th.SysFill
    $script:Strip.BorderCol    = $Th.SysBd
    $script:Strip.SelBorderCol = $Th.Card
    $script:Strip.SelBg        = (Mix-Color $Th.SysFill $Th.Card 0.32)
    $script:Strip.TextCol      = $Th.SysFg
    $script:Strip.SelTextCol   = $Th.Btns[0].Fg
    $script:Strip.TrackCol     = $Th.SysBd
    $script:Strip.ThumbCol     = $Th.Card
    $script:Strip.Invalidate()
  }
  $lblBsTitle.ForeColor = $Th.Muted

  foreach ($b in $script:SysBtns) {
    $b.BaseColor   = $Th.SysFill
    $b.HoverColor  = (Shift-Color $Th.SysFill 14)
    $b.PressColor  = (Shift-Color $Th.SysFill -14)
    $b.BorderColor = $Th.SysBd
    $b.BorderWidth = 1.0
    $b.GlyphColor  = $Th.SysFg
    $b.ForeColor   = $Th.SysFg
    $b.DisabledBlend = $Th.Bg
    $b.Invalidate()
  }
}

# ============================ 过渡动画 ===========================
$script:AnimTimer = New-Object System.Windows.Forms.Timer
$script:AnimTimer.Interval = 16
$script:AnimFrom  = 0.0
$script:AnimTo    = 0.0
$script:AnimStart = [DateTime]::Now

function Ease-InOutCubic {
  param([double]$P)
  if ($P -lt 0.5) { return 4 * $P * $P * $P }
  $q = -2 * $P + 2
  return 1 - ($q * $q * $q) / 2
}

$script:AnimTimer.Add_Tick({
  $elapsed = ([DateTime]::Now - $script:AnimStart).TotalMilliseconds
  $p = [Math]::Min(1.0, $elapsed / $script:Cfg.AnimMs)
  $e = Ease-InOutCubic $p
  $script:Blend = $script:AnimFrom + ($script:AnimTo - $script:AnimFrom) * $e
  Apply-Theme (Get-BlendedTheme $script:Blend)
  if ($p -ge 1) {
    $script:Blend = $script:AnimTo
    Apply-Theme (Get-BlendedTheme $script:Blend)
    $script:AnimTimer.Stop()
  }
})

function Set-Theme {
  param([string]$Name, [switch]$Immediate)
  $script:IsNight = ($Name -eq 'night')
  $to = 0.0
  if ($script:IsNight) { $to = 1.0 }
  if ($Immediate) {
    $script:Blend = $to
    Apply-Theme (Get-BlendedTheme $script:Blend)
    return
  }
  if ([Math]::Abs($script:Blend - $to) -lt 0.001) { return }
  $script:AnimFrom  = $script:Blend
  $script:AnimTo    = $to
  $script:AnimStart = [DateTime]::Now
  $script:AnimTimer.Start()
  if (Get-Command Update-TrayTheme -ErrorAction SilentlyContinue) { Update-TrayTheme }
}

$statusCard.Add_ThemeToggled({
  $target = 'night'
  if ($script:IsNight) { $target = 'day' }
  Set-Theme -Name $target
  Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
})

$statusCard.Add_SettingsClicked({ Show-SettingsDialog })

# ============================ 状态刷新 ===========================
function Set-StatusCard {
  param([string]$Kind, [string]$Text)
  switch ($Kind) {
    'running'  { $script:StatusKind = 'running' }
    'progress' { $script:StatusKind = 'progress' }
    default    { $script:StatusKind = 'stopped' }
  }
  $statusCard.StatusText = $Text
  if ($script:CurTh) { $statusCard.Accent = (Get-AccentFor $script:CurTh $script:StatusKind) }
  $statusCard.Invalidate()
}

function Set-StatusDetail {
  param([string]$Text)
  if ($statusCard.DetailText -ne $Text) {
    $statusCard.DetailText = $Text
    $statusCard.Invalidate()
  }
}

function Set-Uptime {
  param([string]$Text)
  $t = ''
  if ($Text) { $t = '已运行 ' + $Text }
  if ($statusCard.UptimeText -ne $t) {
    $statusCard.UptimeText = $t
    $statusCard.Invalidate()
  }
}

function Update-Ui {
  $running = Test-PortListening
  $key     = $(if ($running) { 'running' } else { 'stopped' })

  if ((-not $script:Busy) -and ($key -ne $script:LastState)) {
    $script:LastState = $key
    if ($running) {
      $info = Get-ServerInfo
      Set-StatusCard 'running' '运行中'
      Set-StatusDetail ('端口 ' + $script:Cfg.Port + '  ·  PID ' + $info.ProcessId)
    } else {
      Set-StatusCard 'stopped' '已停止'
      Set-StatusDetail ('端口 ' + $script:Cfg.Port + ' 上没有服务在监听')
      Set-Uptime ''
    }
  }

  # 运行中时，每次都刷新"运行时长"徽章
  if ($running -and (-not $script:Busy)) {
    $info = Get-ServerInfo
    Set-Uptime (Format-Uptime $info.StartTime)
  }

  $btnStart.Enabled   = (-not $running) -and (-not $script:Busy)
  $btnStop.Enabled    = $running -and (-not $script:Busy)
  $btnRestart.Enabled = (-not $script:Busy)
  $btnOpen.Enabled    = $running

  if (Get-Command Update-Tray -ErrorAction SilentlyContinue) { Update-Tray }

  # 守护模式：服务掉线就自动拉起
  if ($script:Cfg.GuardMode -and (-not $script:Busy)) {
    if ($running) { $script:GuardSawRunning = $true }
    elseif ($script:GuardSawRunning) {
      $script:GuardSawRunning = $false
      Write-SelfLog '守护模式：检测到服务已停止，正在自动重启...'
      $script:Busy = $true
      $r = Start-Server
      $script:Busy = $false
      $script:LastState = 'force'
      Write-SelfLog ('守护重启' + $(if ($r.Ok) { '成功' } else { '失败' }))
    }
  }
}

function Show-StartFailure {
  $m = @('启动超时，服务没有起来。', '', '日志的最后几行：', '', (Read-LastLines -Path $script:Cfg.LogFile -Lines 12)) -join $NL
  [void][System.Windows.Forms.MessageBox]::Show($m, $script:Cfg.Title, 'OK', 'Warning')
}

function Show-SettingsDialog {
  $bg    = [System.Drawing.Color]::FromArgb(250, 244, 232)
  $card  = [System.Drawing.Color]::FromArgb(255, 253, 247)
  $bd    = [System.Drawing.Color]::FromArgb(232, 221, 201)
  $fg    = [System.Drawing.Color]::FromArgb(74, 63, 53)
  $muted = [System.Drawing.Color]::FromArgb(167, 154, 136)
  $acc   = [System.Drawing.Color]::FromArgb(77, 124, 90)
  if ($script:IsNight) {
    $bg    = [System.Drawing.Color]::FromArgb(18, 20, 23)
    $card  = [System.Drawing.Color]::FromArgb(30, 36, 44)
    $bd    = [System.Drawing.Color]::FromArgb(42, 49, 59)
    $fg    = [System.Drawing.Color]::FromArgb(213, 220, 230)
    $muted = [System.Drawing.Color]::FromArgb(119, 128, 143)
    $acc   = [System.Drawing.Color]::FromArgb(74, 222, 128)
  }
  $fontS = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
  $fontB = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
  $fontT = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)

  $dlg                 = New-Object System.Windows.Forms.Form
  $dlg.Text            = 'DSH 管家 · 设置'
  $dlg.ClientSize      = New-Object System.Drawing.Size(560, 620)
  $dlg.StartPosition   = 'CenterParent'
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.MaximizeBox     = $false
  $dlg.MinimizeBox     = $false
  $dlg.Font            = $fontS
  $dlg.BackColor       = $bg
  $dlg.ForeColor       = $fg
  if ($formIcon) { $dlg.Icon = $formIcon }

  function Add-Group {
    param([string]$Title, [int]$Y, [int]$H)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Title; $l.Font = $fontB; $l.ForeColor = $acc
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Location = New-Object System.Drawing.Point(20, $Y)
    $l.AutoSize = $true
    $dlg.Controls.Add($l)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location  = New-Object System.Drawing.Point(18, ($Y + 22))
    $p.Size      = New-Object System.Drawing.Size(524, ($H - 22))
    $p.BackColor = $card
    $dlg.Controls.Add($p)
    return $p
  }
  function Add-Check {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [bool]$On)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.Checked = $On
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.AutoSize = $true
    $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $c.BackColor = $card; $c.ForeColor = $fg; $c.Font = $fontS
    $Parent.Controls.Add($c)
    return $c
  }
  function Add-Radio {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [bool]$On)
    $c = New-Object System.Windows.Forms.RadioButton
    $c.Text = $Text; $c.Checked = $On
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.AutoSize = $true
    $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $c.BackColor = $card; $c.ForeColor = $fg; $c.Font = $fontS
    $Parent.Controls.Add($c)
    return $c
  }
  function Add-Lbl {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [bool]$Dim)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $true
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($Dim) { $l.ForeColor = $muted; $l.Font = $fontT } else { $l.ForeColor = $fg; $l.Font = $fontS }
    $Parent.Controls.Add($l)
    return $l
  }
  function Add-Text {
    param($Parent, [string]$Val, [int]$X, [int]$Y, [int]$W)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Val
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($W, 24)
    $t.BackColor = $bg; $t.ForeColor = $fg; $t.BorderStyle = 'FixedSingle'
    $Parent.Controls.Add($t)
    return $t
  }
  function Add-Btn {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.BackColor = $bg; $b.ForeColor = $fg
    $b.FlatAppearance.BorderColor = $bd
    $Parent.Controls.Add($b)
    return $b
  }

  $p1 = Add-Group '启动与常驻' 12 168
  $cbAuto    = Add-Check $p1 '开机时自动启动管家' 16 12 (Test-AutoStart)
  $cbAutoSvc = Add-Check $p1 '开机时顺便把 DSH 服务也启动起来' 16 40 $script:Cfg.AutoStartService
  [void](Add-Lbl $p1 '关闭窗口时：' 16 74 $false)
  $rbTray = Add-Radio $p1 '最小化到系统托盘' 106 72 $script:Cfg.CloseToTray
  $rbExit = Add-Radio $p1 '直接退出' 250 72 (-not $script:Cfg.CloseToTray)
  $cbStopOnExit = Add-Check $p1 '退出时同时停止 DSH 服务' 16 98 $script:Cfg.StopOnExit
  [void](Add-Lbl $p1 '选「最小化到托盘」后点 × 只是收起来，服务继续跑；要真退出请用托盘菜单的「退出」' 16 124 $true)

  $p2 = Add-Group '界面' 186 90
  [void](Add-Lbl $p2 '主题：' 16 16 $false)
  $rbDay   = Add-Radio $p2 '白天' 66 14 ((-not $script:IsNight) -and ($script:Cfg.ThemeMode -ne 'time'))
  $rbNight = Add-Radio $p2 '夜间' 132 14 ($script:IsNight -and ($script:Cfg.ThemeMode -ne 'time'))
  $rbTime  = Add-Radio $p2 '跟随时间' 198 14 ($script:Cfg.ThemeMode -eq 'time')
  [void](Add-Lbl $p2 '「跟随时间」= 7:00-19:00 用白天配色，其余时间自动切夜间' 16 40 $true)

  $p3 = Add-Group '服务' 282 168
  [void](Add-Lbl $p3 '端口' 16 18 $false)
  $txtPort = Add-Text $p3 ([string]$script:Cfg.Port) 62 15 84
  [void](Add-Lbl $p3 '启动命令' 170 18 $false)
  $txtCmd  = Add-Text $p3 ([string]$script:Cfg.StartCmd) 238 15 270
  [void](Add-Lbl $p3 '工作目录' 16 52 $false)
  $txtDir = Add-Text $p3 $script:Cfg.CheckoutDir 82 49 330
  $btnBrowse  = Add-Btn $p3 '浏览…' 420 48 88 26
  [void](Add-Lbl $p3 '启动命令留空 = 自动识别（pnpm / npm / 全局 dsh）；工作目录留空 = 用全局安装的 DSH' 16 80 $true)
  $cbAutoOpen = Add-Check $p3 '启动成功后自动打开浏览器' 16 104 $script:Cfg.AutoOpenBrowser
  $cbGuard    = Add-Check $p3 '服务异常退出时自动重启（守护模式，每 30 秒检查）' 16 130 $script:Cfg.GuardMode

  $p5 = Add-Group '其它' 458 100
  $cbStartMenu    = Add-Check $p5 '在开始菜单中显示（之后可右键固定到任务栏）' 16 12 (Test-StartMenuLink)
  $btnLogButler   = Add-Btn $p5 '打开管家日志' 16 40 108 26
  $btnLogSvc      = Add-Btn $p5 '打开服务日志' 132 40 108 26
  $btnLogClearSvc = Add-Btn $p5 '清空服务日志' 248 40 108 26
  $btnReset       = Add-Btn $p5 '恢复默认设置' 364 40 108 26

  [void](Add-Lbl $dlg '换浏览器：回主界面点图标即可' 20 576 $true)
  $btnOk     = Add-Btn $dlg '保存' 336 566 90 34
  $btnCancel = Add-Btn $dlg '取消' 436 566 90 34
  $btnOk.FlatAppearance.BorderColor = $acc
  $btnOk.BackColor = $acc
  $btnOk.ForeColor = [System.Drawing.Color]::White
  $btnOk.Font = $fontB

  $btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = '选择 DSH 的源码目录'
    if (Test-Path $txtDir.Text) { $fb.SelectedPath = $txtDir.Text }
    if ($fb.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { $txtDir.Text = $fb.SelectedPath }
  })
  $btnLogButler.Add_Click({ if (Test-Path $script:SelfLog) { Start-Process notepad.exe -ArgumentList ('"' + $script:SelfLog + '"') } })
  $btnLogClearSvc.Add_Click({
    if (-not (Test-Path $script:Cfg.LogFile)) { return }
    $r2 = [System.Windows.Forms.MessageBox]::Show('确定要清空服务日志吗？', '确认', 'YesNo', 'Question')
    if ($r2 -eq [System.Windows.Forms.DialogResult]::Yes) {
      try { Set-Content -LiteralPath $script:Cfg.LogFile -Value '' -Encoding Default -ErrorAction Stop } catch { }
    }
  })
  $btnLogSvc.Add_Click({
    if (Test-Path $script:Cfg.LogFile) { Start-Process notepad.exe -ArgumentList ('"' + $script:Cfg.LogFile + '"') }
    else { [void][System.Windows.Forms.MessageBox]::Show('还没有服务日志文件。', 'DSH 管家', 'OK', 'Information') }
  })
  $btnReset.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show('确定要把所有设置恢复成默认值吗？', '恢复默认', 'YesNo', 'Question')
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
      $script:Cfg.AutoStart        = $false
      $script:Cfg.AutoStartService = $false
      $script:Cfg.CloseToTray      = $true
      $script:Cfg.StopOnExit       = $false
      $script:Cfg.ThemeMode        = 'manual'
      $script:Cfg.AutoOpenBrowser  = $true
      $script:Cfg.GuardMode        = $false
      $script:Cfg.StartMenuLink    = $false
      $script:Cfg.Browser          = ''
      $script:Cfg.StartCmd         = ''
      $script:Cfg.Port             = 3080
      $script:Cfg.Url              = 'http://127.0.0.1:3080'
      [void](Set-AutoStart $false)
      [void](Set-StartMenuLink $false)
      Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
      Write-SelfLog '设置已恢复默认'
      [void][System.Windows.Forms.MessageBox]::Show('已恢复默认设置（端口等下次打开程序时生效）。', 'DSH 管家', 'OK', 'Information')
      $dlg.Tag = 'ok'
      $dlg.Close()
    }
  })
  $btnCancel.Add_Click({ $dlg.Tag = ''; $dlg.Close() })

  $btnOk.Add_Click({
    $script:Cfg.AutoStart = $cbAuto.Checked
    [void](Set-AutoStart $cbAuto.Checked)
    $script:Cfg.AutoStartService = $cbAutoSvc.Checked
    $script:Cfg.CloseToTray = $rbTray.Checked
    if ($rbTime.Checked) { $script:Cfg.ThemeMode = 'time' }
    else {
      $script:Cfg.ThemeMode = 'manual'
      if ($rbDay.Checked)   { Set-Theme -Name 'day';   Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit }
      if ($rbNight.Checked) { Set-Theme -Name 'night'; Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit }
    }
    $pv = 0
    if ([int]::TryParse($txtPort.Text.Trim(), [ref]$pv) -and $pv -gt 0 -and $pv -lt 65536) {
      if ($pv -ne $script:Cfg.Port) {
        $script:Cfg.Port = $pv
        $script:Cfg.Url = 'http://127.0.0.1:' + $pv
        Write-SelfLog ('端口已改为 ' + $pv)
      }
    }
    $dv = $txtDir.Text.Trim()
    if ($dv) { $script:Cfg.CheckoutDir = $dv }
    $script:Cfg.StartCmd = $txtCmd.Text.Trim()
    $script:Cfg.AutoOpenBrowser = $cbAutoOpen.Checked
    $script:Cfg.GuardMode = $cbGuard.Checked
    $script:Cfg.StopOnExit = $cbStopOnExit.Checked
    $script:Cfg.StartMenuLink = $cbStartMenu.Checked
    [void](Set-StartMenuLink $cbStartMenu.Checked)
    Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
    Write-SelfLog ('设置已保存: 自启=' + $script:Cfg.AutoStart + ' 自启服务=' + $script:Cfg.AutoStartService + ' 托盘=' + $script:Cfg.CloseToTray + ' 主题=' + $script:Cfg.ThemeMode + ' 守护=' + $script:Cfg.GuardMode + ' 端口=' + $script:Cfg.Port)
    $dlg.Tag = 'ok'
    $dlg.Close()
  })

  [void]$dlg.ShowDialog($form)
  if ($dlg.Tag -eq 'ok') {
    $script:LastState = 'force'
    Update-Ui
  }
  $dlg.Dispose()
}

# ============================ 事件绑定 ===========================
# 统一处理「忙碌状态 + 异常兜底」，三个按钮共用
function Invoke-Busy {
  param([scriptblock]$Body)
  $script:Busy = $true
  $script:LastState = 'force'
  Update-Ui
  try {
    & $Body
  } catch {
    $msg = ($_ | Out-String).Trim()
    Write-SelfLog ('操作出错: ' + $msg)
    [void][System.Windows.Forms.MessageBox]::Show($msg, $script:Cfg.Title, 'OK', 'Error')
  } finally {
    $script:Busy = $false
    $script:LastState = 'force'
    Update-Ui
  }
}

function Show-StartResult {
  param($Result)
  if ($Result.Ok) {
    Write-SelfLog $(if ($Result.Already) { '服务已在运行' } else { '服务启动成功' })
    if ($script:Cfg.AutoOpenBrowser) {
      if ($Result.Url) { Start-Process $Result.Url } else { Open-Web }
    }
  } else {
    Write-SelfLog '服务启动失败'
    Show-StartFailure
  }
}

$btnStart.Add_Click({ Invoke-Busy { Show-StartResult (Start-Server) } })

$btnStop.Add_Click({ Invoke-Busy { [void](Stop-Server); Write-SelfLog '服务已停止' } })

$btnRestart.Add_Click({
  Invoke-Busy {
    if (-not (Stop-Server)) { Write-SelfLog '用户取消了重启'; return }
    Start-Sleep -Milliseconds 400
    Show-StartResult (Start-Server)
  }
})

$btnOpen.Add_Click({ Open-Web })



# 退出胶囊：真的退出程序（点 × 才是缩到托盘）；勾了「退出时同时停止服务」就顺手把服务停掉
# 两个外链按钮：走和「打开页面」同一套浏览器设置（没指定就用系统默认）
$btnChat.Add_Click({
  try { Open-Url 'https://chat.deepseek.com/'; Write-SelfLog '打开 DeepSeek 网页版' }
  catch { Write-SelfLog ('打开 DeepSeek 网页版失败: ' + $_.Exception.Message) }
})
$btnUsage.Add_Click({
  try { Open-Url 'https://platform.deepseek.com/usage'; Write-SelfLog '打开 DeepSeek 用量页' }
  catch { Write-SelfLog ('打开 DeepSeek 用量页失败: ' + $_.Exception.Message) }
})

$btnExit.Add_Click({
  $script:ReallyExit = $true
  $form.Close()
})

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({ Update-Ui })
$timer.Start()

$form.Add_FormClosing({
  param($sender, $e)
  # 「关闭到托盘」：不是真退出，只是把窗口收起来
  if ((-not $script:ReallyExit) -and $script:Cfg.CloseToTray) {
    $e.Cancel = $true
    $form.Hide()
    Write-SelfLog '窗口已最小化到托盘'
    if (-not $script:TrayTipShown) {
      $script:TrayTipShown = $true
      try {
        $script:Tray.BalloonTipTitle = 'DSH 管家还在运行'
        $script:Tray.BalloonTipText  = '程序已最小化到托盘，双击托盘图标可以重新打开。'
        $script:Tray.ShowBalloonTip(3000)
      } catch { }
    }
    return
  }
  if ($script:Cfg.StopOnExit) {
    $info = Get-ServerInfo
    if ($info.Running) { & taskkill.exe /PID $info.ProcessId /T /F 2>$null | Out-Null }
  }
  Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
  if ($script:Tray) { try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { } }
})

# ============================ 系统托盘 ============================
function New-TrayIconImage {
  param([System.Drawing.Color]$DotColor)
  $bmp = New-Object System.Drawing.Bitmap(32, 32)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  try { if ($formIcon) { $g.DrawIcon($formIcon, (New-Object System.Drawing.Rectangle(0, 0, 25, 25))) } } catch { }
  $ring = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 252, 252, 252), 2.2)
  $dot  = New-Object System.Drawing.SolidBrush($DotColor)
  $g.FillEllipse($dot, 18, 18, 13, 13)
  $g.DrawEllipse($ring, 18, 18, 13, 13)
  $dot.Dispose(); $ring.Dispose(); $g.Dispose()
  return $bmp
}

$script:ReallyExit      = $false
$script:TrayTipShown    = $false
$script:GuardSawRunning = $false
$script:TrayIconOn      = $null
$script:TrayIconOff     = $null
try {
  $b1 = New-TrayIconImage ([System.Drawing.Color]::FromArgb(34, 197, 94))
  $script:TrayIconOn = [System.Drawing.Icon]::FromHandle($b1.GetHicon())
  $b1.Dispose()
  $b2 = New-TrayIconImage ([System.Drawing.Color]::FromArgb(239, 68, 68))
  $script:TrayIconOff = [System.Drawing.Icon]::FromHandle($b2.GetHicon())
  $b2.Dispose()
} catch { Write-SelfLog ('托盘图标生成失败: ' + $_.Exception.Message) }

function Show-ConsoleWindow {
  try {
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
  } catch { }
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
if ($script:TrayIconOff) { $script:Tray.Icon = $script:TrayIconOff }
elseif ($formIcon) { $script:Tray.Icon = $formIcon }
$script:Tray.Text = 'DSH 管家'
$script:Tray.Visible = $true

$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:TrayMenu.ShowImageMargin = $false
try { $script:TrayMenu.Renderer = New-Object ThemedMenuRenderer } catch { }

function Add-TrayItem {
  param([string]$Text, $Action, [switch]$Disabled)
  $it = $script:TrayMenu.Items.Add($Text)
  if ($Disabled) { $it.Enabled = $false }
  elseif ($Action) { [void]$it.Add_Click($Action) }
  return $it
}

$script:TrayStatus = Add-TrayItem '正在检查服务状态...' $null -Disabled
[void]$script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-TrayItem '打开控制台'   { Show-ConsoleWindow })
[void](Add-TrayItem '打开服务页面' { Open-Web })
[void]$script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-TrayItem '启动服务' { Invoke-Busy { Show-StartResult (Start-Server) } })
[void](Add-TrayItem '停止服务' { Invoke-Busy { [void](Stop-Server); Write-SelfLog '服务已停止' } })
[void](Add-TrayItem '重启服务' { Invoke-Busy { if (-not (Stop-Server)) { return }; Start-Sleep -Milliseconds 400; Show-StartResult (Start-Server) } })
[void]$script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-TrayItem '切换白天/夜间' {
  $t = 'night'
  if ($script:IsNight) { $t = 'day' }
  Set-Theme -Name $t
  Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
})
[void](Add-TrayItem '设置…' { Show-SettingsDialog })
[void]$script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-TrayItem '退出（停止服务并关闭）' {
  $script:ReallyExit = $true
  $script:Cfg.StopOnExit = $true
  $form.Close()
})

$script:Tray.ContextMenuStrip = $script:TrayMenu
$script:Tray.Add_DoubleClick({ Open-Web })
$script:Tray.Add_MouseClick({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-ConsoleWindow }
})

function Update-TrayTheme {
  try {
    $r = $script:TrayMenu.Renderer
    if (-not $r) { return }
    if ($script:IsNight) {
      $r.MenuBg   = [System.Drawing.Color]::FromArgb(38, 38, 43)
      $r.MenuFg   = [System.Drawing.Color]::FromArgb(229, 231, 235)
      $r.HoverBg  = [System.Drawing.Color]::FromArgb(53, 53, 60)
      $r.SepColor = [System.Drawing.Color]::FromArgb(51, 51, 58)
    } else {
      $r.MenuBg   = [System.Drawing.Color]::FromArgb(255, 255, 255)
      $r.MenuFg   = [System.Drawing.Color]::FromArgb(31, 41, 55)
      $r.HoverBg  = [System.Drawing.Color]::FromArgb(242, 242, 242)
      $r.SepColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    }
  } catch { }
}

function Update-Tray {
  if (-not $script:Tray) { return }
  $running = Test-PortListening
  $txt = 'DSH 管家 · 已停止'
  if ($running) {
    $info = Get-ServerInfo
    $up = Format-Uptime $info.StartTime
    $txt = 'DSH 管家 · 运行中'
    if ($up) { $txt = $txt + ' ' + $up }
  }
  if ($txt.Length -gt 62) { $txt = $txt.Substring(0, 62) }
  if ($script:Tray.Text -ne $txt) { $script:Tray.Text = $txt }
  if ($script:TrayStatus.Text -ne $txt) { $script:TrayStatus.Text = $txt }
  $ic = $script:TrayIconOff
  if ($running) { $ic = $script:TrayIconOn }
  if ($ic -and ($script:Tray.Icon -ne $ic)) { $script:Tray.Icon = $ic }
}

# ============================ 恢复上次设置 =======================
$saved = Read-Settings
$startTheme = 'day'
if ($saved) {
  try {
    $x    = [int]$saved.X
    $y    = [int]$saved.Y
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($x -ge 0 -and $y -ge 0 -and $x -lt ($area.Width - 120) -and $y -lt ($area.Height - 120)) {
      $form.StartPosition = 'Manual'
      $form.Location      = New-Object System.Drawing.Point($x, $y)
    }
    if ($saved.StopOnExit) { $script:Cfg.StopOnExit = $true }
    if ($saved.Theme -eq 'night') { $startTheme = 'night' }
    if ($saved.Browser) { $script:Cfg.Browser = [string]$saved.Browser }
    if ($saved.CheckoutDir) { $script:Cfg.CheckoutDir = [string]$saved.CheckoutDir }
if ($saved.StartCmd)    { $script:Cfg.StartCmd    = [string]$saved.StartCmd }
    if ($saved.PSObject.Properties['AutoStart'])        { $script:Cfg.AutoStart        = [bool]$saved.AutoStart }
    if ($saved.PSObject.Properties['AutoStartService']) { $script:Cfg.AutoStartService = [bool]$saved.AutoStartService }
    if ($saved.PSObject.Properties['CloseToTray'])      { $script:Cfg.CloseToTray      = [bool]$saved.CloseToTray }
    if ($saved.PSObject.Properties['ThemeMode'])        { $script:Cfg.ThemeMode        = [string]$saved.ThemeMode }
    if ($saved.PSObject.Properties['AutoOpenBrowser'])  { $script:Cfg.AutoOpenBrowser  = [bool]$saved.AutoOpenBrowser }
    if ($saved.PSObject.Properties['GuardMode'])        { $script:Cfg.GuardMode        = [bool]$saved.GuardMode }
    if ($saved.PSObject.Properties['StartMenuLink'])    { $script:Cfg.StartMenuLink    = [bool]$saved.StartMenuLink }
    if ($saved.PSObject.Properties['Port'])             { $script:Cfg.Port             = [int]$saved.Port }
    $script:Cfg.Url = 'http://127.0.0.1:' + $script:Cfg.Port
  } catch { }
}

# 跟随时间：7:00-19:00 白天，其余夜间
if ($script:Cfg.ThemeMode -eq 'time') {
  $hh = (Get-Date).Hour
  if ($hh -ge 7 -and $hh -lt 19) { $startTheme = 'day' } else { $startTheme = 'night' }
  Write-SelfLog ('跟随时间模式 → ' + $startTheme)
}

# ============================== 启动 ============================
Set-Theme -Name $startTheme -Immediate
Update-Ui

# 开机自启服务：直接拉起来
if ($script:Cfg.AutoStartService) {
  Write-SelfLog '开机自启：正在自动启动 DSH 服务...'
  Show-StartResult (Start-Server)
  $script:LastState = 'force'
  Update-Ui
}

# 工作目录：没配 / 配的路径没了 → 自动找一遍；找不到再决定要不要引导去设置
$dirExists = ($script:Cfg.CheckoutDir -and (Test-Path -LiteralPath $script:Cfg.CheckoutDir))
if (-not $dirExists) {
  if ($script:Cfg.CheckoutDir) { Write-SelfLog ('工作目录不可用: ' + $script:Cfg.CheckoutDir) }
  $found = Find-CheckoutDir
  if ($found) {
    $script:Cfg.CheckoutDir = $found
    Write-SelfLog ('自动找到 DSH 工作目录: ' + $found)
    Save-Settings -Form $form -StopOnExit $script:Cfg.StopOnExit
  } elseif (Get-Command 'dsh' -ErrorAction SilentlyContinue) {
    Write-SelfLog '没配工作目录，但检测到全局 dsh，启动时直接用全局的'
  } else {
    $script:NeedSetup = $true
    Write-SelfLog '没找到 DSH 工作目录，等窗口出来后引导去设置'
  }
} elseif (-not (Test-DshDir $script:Cfg.CheckoutDir)) {
  Write-SelfLog ('工作目录存在但不像 DSH 源码目录，仍按它启动: ' + $script:Cfg.CheckoutDir)
}
Write-SelfLog ('启动命令=' + (Resolve-StartCmd))

# 首次运行：窗口一出来就弹说明 + 打开设置面板（只弹一次，用户关掉就不再烦他）
if ($script:NeedSetup) {
  $form.Add_Shown({
    $m = @('第一次使用，先告诉管家 DSH 装在哪儿：', '', '  1. 点「浏览…」选出 DSH 源码目录', '     （就是含 package.json、平时敲 pnpm dsh web 的那个文件夹）', '  2. 「启动命令」留空即可，管家会自动识别 pnpm / npm / 全局 dsh', '  3. 点「保存」，然后就能用「启动服务」了', '', '  如果 DSH 是全局安装的，工作目录可以留空。') -join $NL
    [void][System.Windows.Forms.MessageBox]::Show($m, $script:Cfg.Title, 'OK', 'Information')
    Show-SettingsDialog
  })
}
Write-SelfLog ('主题=' + $startTheme + '  端口=' + $script:Cfg.Port)
# 主窗口必须用 Application.Run，不能用 ShowDialog：
# ShowDialog 是模态循环，窗体一旦 Hide() 循环就结束 —— 会让"缩到托盘"直接变成退出程序
[System.Windows.Forms.Application]::Run($form)
$timer.Stop(); $timer.Dispose()
$script:AnimTimer.Stop(); $script:AnimTimer.Dispose()
$form.Dispose()
Write-SelfLog '--- 退出 ---'
try { $mutex.ReleaseMutex() } catch { }
