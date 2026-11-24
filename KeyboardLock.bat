<# : Keyboard Lock
@echo off
rem Double-click to lock the keyboard while you clean it.
rem Optional: "KeyboardLock.bat 60" locks for 60 seconds.
set "KEYLOCK_FILE=%~f0"
set "KEYLOCK_ARG=%~1"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "iex (Get-Content -LiteralPath $env:KEYLOCK_FILE -Raw)"
exit /b
#>

# ================= Settings (edit these) =================
$lockSeconds   = 120      # auto-unlock after this many seconds (10 to 3600)
$blockTouchpad = $false   # start with touchpad / mouse clicks blocked too
$playSound     = $true    # play a short sound when the timer unlocks
$theme         = 'auto'   # 'auto' (follow Windows), 'dark' or 'light'
# =========================================================

if ($env:KEYLOCK_ARG -match '^\d+$') { $lockSeconds = [int]$env:KEYLOCK_ARG }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

try {
    if (-not ('KeyLock.App' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace KeyLock {

static class Native {
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")]
    public static extern bool CloseDesktop(IntPtr desk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetUserObjectInformation(IntPtr obj, int index, StringBuilder buf, int len, out int needed);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    public static extern bool PlaySound(string sound, IntPtr mod, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public int X; public int Y; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    // True while the normal desktop has input. False on the Ctrl+Alt+Del screen,
    // the lock screen or a UAC prompt (those desktops can't be opened by us).
    public static bool OnNormalDesktop() {
        IntPtr d = OpenInputDesktop(0, false, 0x0001);
        if (d == IntPtr.Zero) return false;
        try {
            StringBuilder sb = new StringBuilder(256);
            int needed;
            if (!GetUserObjectInformation(d, 2, sb, 512, out needed)) return true;
            return string.Equals(sb.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
        } finally { CloseDesktop(d); }
    }
}

// Low-level keyboard and mouse hooks. Windows removes both automatically
// if this process ends for any reason, so the keyboard can't stay locked.
public static class Hooks {
    static readonly Native.HookProc kbProc = KeyboardCallback;
    static readonly Native.HookProc msProc = MouseCallback;
    static IntPtr kbHook = IntPtr.Zero;
    static IntPtr msHook = IntPtr.Zero;
    static readonly bool[] keyDown = new bool[256];
    static readonly bool[] swallowedDown = new bool[4];

    public static int KeysBlocked;
    public static bool BlockClicks;
    public static Rectangle AllowRect;
    public static int LastError;

    public static bool KeyboardLocked { get { return kbHook != IntPtr.Zero; } }
    public static bool MouseHookOk { get { return msHook != IntPtr.Zero; } }

    public static bool Start() {
        IntPtr mod = Native.GetModuleHandle(null);
        kbHook = Native.SetWindowsHookEx(13, kbProc, mod, 0);
        if (kbHook == IntPtr.Zero) { LastError = Marshal.GetLastWin32Error(); return false; }
        msHook = Native.SetWindowsHookEx(14, msProc, mod, 0);
        return true;
    }

    public static void Stop() {
        BlockClicks = false;
        if (kbHook != IntPtr.Zero) { Native.UnhookWindowsHookEx(kbHook); kbHook = IntPtr.Zero; }
        if (msHook != IntPtr.Zero) { Native.UnhookWindowsHookEx(msHook); msHook = IntPtr.Zero; }
    }

    static IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            int vk = Marshal.ReadInt32(lParam) & 0xFF;
            if (msg == 0x100 || msg == 0x104) {
                if (!keyDown[vk]) { keyDown[vk] = true; KeysBlocked++; }
            } else {
                keyDown[vk] = false;
            }
            return (IntPtr)1;   // swallow every key
        }
        return Native.CallNextHookEx(kbHook, nCode, wParam, lParam);
    }

    static int ButtonIndex(int msg) {
        switch (msg) {
            case 0x201: case 0x202: return 0;   // left
            case 0x204: case 0x205: return 1;   // right
            case 0x207: case 0x208: return 2;   // middle
            case 0x20B: case 0x20C: return 3;   // side buttons
        }
        return -1;
    }

    static IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            int msg = wParam.ToInt32();
            int b = ButtonIndex(msg);
            bool isUp = msg == 0x202 || msg == 0x205 || msg == 0x208 || msg == 0x20C;
            if (isUp && b >= 0 && swallowedDown[b]) { swallowedDown[b] = false; return (IntPtr)1; }
            bool isDownOrWheel = (b >= 0 && !isUp) || msg == 0x20A || msg == 0x20E;
            if (BlockClicks && isDownOrWheel) {
                Native.MSLLHOOKSTRUCT s = (Native.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.MSLLHOOKSTRUCT));
                if (!AllowRect.Contains(s.X, s.Y)) {
                    if (b >= 0) swallowedDown[b] = true;
                    return (IntPtr)1;
                }
            }
        }
        return Native.CallNextHookEx(msHook, nCode, wParam, lParam);
    }
}

public class LockForm : Form {
    const int W = 360, H = 528;
    const int MinSeconds = 10, MaxSeconds = 3600, Step = 30;
    const double HoldMs = 1000;

    readonly int startSeconds;
    readonly bool startBlock, sound, dark;
    Color cBg, cSurface, cSurfaceHover, cText, cSub, cAccent, cAccentHover, cAccentPressed, cOnAccent, cTrack, cBorder;
    float scale = 1f;
    Font fTitle, fSub, fBig, fSmall, fPill, fBody, fButton, fIcon;
    string uiFont = "Segoe UI", iconFont = "Segoe MDL2 Assets";
    string hot, pressed;
    DateTime endTime, holdStart;
    double totalMs;
    bool holding, done, desktopSeen;
    int tick;
    readonly System.Windows.Forms.Timer timer;

    public LockForm(int seconds, bool blockClicks, bool playSound, bool darkTheme) {
        startSeconds = seconds; startBlock = blockClicks; sound = playSound; dark = darkTheme;
        if (dark) {
            cBg = Rgb(0x202024); cSurface = Rgb(0x2C2C32); cSurfaceHover = Rgb(0x37373E);
            cText = Rgb(0xF4F4F6); cSub = Rgb(0xA3A3AD); cTrack = Rgb(0x34343B); cBorder = Rgb(0x3C3C44);
            cAccent = Rgb(0x60CDFF); cAccentHover = Rgb(0x86DAFF); cAccentPressed = Rgb(0x4CB4E6); cOnAccent = Rgb(0x0A1A24);
        } else {
            cBg = Rgb(0xF8F8FA); cSurface = Rgb(0xECECF0); cSurfaceHover = Rgb(0xE2E2E8);
            cText = Rgb(0x1B1B1F); cSub = Rgb(0x60606A); cTrack = Rgb(0xE3E3E9); cBorder = Rgb(0xD6D6DC);
            cAccent = Rgb(0x0067C0); cAccentHover = Rgb(0x1A7AD0); cAccentPressed = Rgb(0x00559E); cOnAccent = Color.White;
        }
        if (FontExists("Segoe Fluent Icons")) iconFont = "Segoe Fluent Icons";

        Text = "Keyboard Lock";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        TopMost = true;
        ShowInTaskbar = true;
        BackColor = cBg;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        try { Icon = MakeIcon(); } catch { }

        timer = new System.Windows.Forms.Timer();
        timer.Interval = 50;
        timer.Tick += OnTick;
    }

    static Color Rgb(int v) { return Color.FromArgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF); }
    static int ColorRef(Color c) { return c.R | (c.G << 8) | (c.B << 16); }
    static bool FontExists(string name) {
        try { using (FontFamily f = new FontFamily(name)) { return true; } } catch { return false; }
    }

    float S(float v) { return v * scale; }
    RectangleF R(float x, float y, float w, float h) { return new RectangleF(S(x), S(y), S(w), S(h)); }

    // Layout, in 96-DPI units. Everything is multiplied by the screen scale.
    RectangleF rIcon   { get { return R(24, 24, 36, 36); } }
    RectangleF rRing   { get { return R(96, 104, 168, 168); } }
    RectangleF rMinus  { get { return R(82, 300, 92, 36); } }
    RectangleF rPlus   { get { return R(186, 300, 92, 36); } }
    RectangleF rToggle { get { return R(24, 356, 312, 62); } }
    RectangleF rSwitch { get { return R(276, 376, 44, 22); } }
    RectangleF rUnlock { get { return R(24, 434, 312, 54); } }

    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; }   // drop shadow
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        uint dpi = 0;
        try { dpi = Native.GetDpiForWindow(Handle); } catch { }
        if (dpi == 0) { using (Graphics g = CreateGraphics()) dpi = (uint)g.DpiX; }
        ApplyScale(dpi / 96f);
        Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(wa.Left + (wa.Width - Width) / 2, wa.Top + (wa.Height - Height) / 2);
        try {
            int round = 2;  Native.DwmSetWindowAttribute(Handle, 33, ref round, 4);   // Windows 11 rounded corners
            int border = ColorRef(cBorder); Native.DwmSetWindowAttribute(Handle, 34, ref border, 4);
            int dm = dark ? 1 : 0; Native.DwmSetWindowAttribute(Handle, 20, ref dm, 4);
        } catch { }
    }

    void ApplyScale(float s) {
        scale = s <= 0 ? 1f : s;
        Font[] old = { fTitle, fSub, fBig, fSmall, fPill, fBody, fButton, fIcon };
        fTitle  = new Font(uiFont + " Semibold", S(17), GraphicsUnit.Pixel);
        fSub    = new Font(uiFont, S(13), GraphicsUnit.Pixel);
        fBig    = new Font(uiFont + " Semibold", S(46), GraphicsUnit.Pixel);
        fSmall  = new Font(uiFont, S(12.5f), GraphicsUnit.Pixel);
        fPill   = new Font(uiFont + " Semibold", S(14), GraphicsUnit.Pixel);
        fBody   = new Font(uiFont + " Semibold", S(14), GraphicsUnit.Pixel);
        fButton = new Font(uiFont + " Semibold", S(16), GraphicsUnit.Pixel);
        fIcon   = new Font(iconFont, S(17), GraphicsUnit.Pixel);
        foreach (Font f in old) if (f != null) f.Dispose();
        ClientSize = new Size((int)Math.Round(S(W)), (int)Math.Round(S(H)));
        Invalidate();
    }

    protected override void OnShown(EventArgs e) {
        base.OnShown(e);
        if (!Hooks.Start()) {
            MessageBox.Show(this,
                "Could not lock the keyboard (Windows error " + Hooks.LastError + ").\n\n" +
                "Some security or anti-cheat programs block keyboard hooks. Nothing was locked.",
                "Keyboard Lock", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            done = true;
            Close();
            return;
        }
        Hooks.AllowRect = Bounds;
        Hooks.BlockClicks = startBlock && Hooks.MouseHookOk;
        totalMs = startSeconds * 1000.0;
        endTime = DateTime.UtcNow.AddSeconds(startSeconds);
        timer.Start();
        Activate();
    }

    protected override void OnMove(EventArgs e) { base.OnMove(e); Hooks.AllowRect = Bounds; }
    protected override void OnResize(EventArgs e) { base.OnResize(e); Hooks.AllowRect = Bounds; }

    protected override void OnFormClosing(FormClosingEventArgs e) {
        done = true;
        timer.Stop();
        Hooks.Stop();
        base.OnFormClosing(e);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x02E0) {   // WM_DPICHANGED: moved to a screen with a different scale
            int dpi = (int)(m.WParam.ToInt64() & 0xFFFF);
            Native.RECT r = (Native.RECT)Marshal.PtrToStructure(m.LParam, typeof(Native.RECT));
            ApplyScale(dpi / 96f);
            Location = new Point(r.Left, r.Top);
            m.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref m);
    }

    double RemainingMs() {
        if (endTime == DateTime.MinValue) return startSeconds * 1000.0;
        return Math.Max(0, (endTime - DateTime.UtcNow).TotalMilliseconds);
    }

    void OnTick(object sender, EventArgs e) {
        if (done) return;
        if (RemainingMs() <= 0) { Unlock(true); return; }
        if (holding && (DateTime.UtcNow - holdStart).TotalMilliseconds >= HoldMs) { Unlock(false); return; }
        if (++tick % 4 == 0) {
            // Emergency exit: Ctrl+Alt+Del can't be blocked. When its screen
            // (or the lock screen) takes over, unlock right away.
            if (Native.OnNormalDesktop()) desktopSeen = true;
            else if (desktopSeen) { Unlock(false); return; }
            if (!TopMost) TopMost = true;
        }
        Invalidate();
    }

    void Unlock(bool byTimer) {
        if (done) return;
        done = true;
        timer.Stop();
        Hooks.Stop();
        if (byTimer && sound) {
            Hide();
            try { Native.PlaySound("SystemAsterisk", IntPtr.Zero, 0x00010000 | 0x0002); } catch { }
        }
        Close();
    }

    bool HoldMode { get { return Hooks.BlockClicks; } }
    bool MinusEnabled { get { return RemainingMs() > (MinSeconds + 1) * 1000.0; } }

    string HitTest(Point p) {
        if (rUnlock.Contains(p)) return "unlock";
        if (rMinus.Contains(p)) return MinusEnabled ? "minus" : null;
        if (rPlus.Contains(p)) return "plus";
        if (rToggle.Contains(p)) return Hooks.MouseHookOk ? "toggle" : null;
        return null;
    }

    void Press(string id) {
        if (done) return;
        if (id == "plus") {
            double rem = RemainingMs();
            double add = Math.Min(Step * 1000.0, MaxSeconds * 1000.0 - rem);
            if (add > 0) { endTime = endTime.AddMilliseconds(add); totalMs = Math.Max(totalMs + add, rem + add); }
        } else if (id == "minus") {
            double rem = RemainingMs();
            double cut = Math.Min(Step * 1000.0, rem - MinSeconds * 1000.0);
            if (cut > 0) { endTime = endTime.AddMilliseconds(-cut); totalMs = Math.Max(totalMs - cut, rem - cut); }
        } else if (id == "toggle") {
            Hooks.BlockClicks = !Hooks.BlockClicks;
        } else if (id == "unlock") {
            Unlock(false);
        }
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        string h = HitTest(e.Location);
        if (holding && h != "unlock") holding = false;
        if (h != hot) { hot = h; Cursor = h != null ? Cursors.Hand : Cursors.Default; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e) {
        base.OnMouseLeave(e);
        hot = null;
        if (pressed != "unlock") holding = false;   // moving off the button (OnMouseMove) still cancels a hold
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        string h = HitTest(e.Location);
        if (h == null) {   // drag the window from any empty spot
            Native.ReleaseCapture();
            Native.SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero);
            return;
        }
        pressed = h;
        if (h == "unlock" && HoldMode) { holding = true; holdStart = DateTime.UtcNow; }
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        string h = HitTest(e.Location);
        string p = pressed;
        pressed = null;
        bool wasHolding = holding;
        holding = false;
        if (p != null && p == h) {
            if (p != "unlock" || (!HoldMode && !wasHolding)) Press(p);
        }
        Invalidate();
    }

    static GraphicsPath Rounded(RectangleF r, float radius) {
        GraphicsPath path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    void Fill(Graphics g, RectangleF r, float radius, Color c) {
        using (GraphicsPath p = Rounded(r, radius)) using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, p);
    }

    static void Txt(Graphics g, string s, Font f, RectangleF r, Color c, TextFormatFlags flags) {
        TextRenderer.DrawText(g, s, f, Rectangle.Round(r), c,
            flags | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(cBg);
        TextFormatFlags C = TextFormatFlags.HorizontalCenter, L = TextFormatFlags.Left;

        // Header
        Fill(g, rIcon, S(10), cAccent);
        Txt(g, "\uE72E", fIcon, rIcon, cOnAccent, C);
        Txt(g, "Keyboard locked", fTitle, R(72, 22, 264, 22), cText, L);
        Txt(g, "Wipe away. Nothing you press will type.", fSub, R(72, 44, 264, 18), cSub, L);

        // Countdown ring
        double rem = RemainingMs();
        float frac = (float)Math.Max(0, Math.Min(1, rem / Math.Max(1, totalMs > 0 ? totalMs : startSeconds * 1000.0)));
        float stroke = S(10);
        RectangleF ring = rRing;
        ring.Inflate(-stroke / 2, -stroke / 2);
        using (Pen track = new Pen(cTrack, stroke)) g.DrawEllipse(track, ring);
        if (frac > 0.002f) {
            using (Pen arc = new Pen(cAccent, stroke)) {
                arc.StartCap = LineCap.Round; arc.EndCap = LineCap.Round;
                g.DrawArc(arc, ring, -90, 360 * frac);
            }
        }
        int secs = (int)Math.Ceiling(rem / 1000.0);
        Txt(g, (secs / 60) + ":" + (secs % 60).ToString("00"), fBig, R(96, 150, 168, 58), cText, C);
        int k = Hooks.KeysBlocked;
        Txt(g, k == 1 ? "1 key blocked" : k + " keys blocked", fSmall, R(96, 206, 168, 18), cSub, C);

        // -30s / +30s
        DrawPill(g, rMinus, "\u2212 30 s", "minus", MinusEnabled);
        DrawPill(g, rPlus, "+ 30 s", "plus", true);

        // Touchpad toggle
        bool avail = Hooks.MouseHookOk || !Hooks.KeyboardLocked;
        Fill(g, rToggle, S(10), hot == "toggle" ? cSurfaceHover : cSurface);
        Color titleCol = avail ? cText : cSub;
        Txt(g, "Block touchpad clicks", fBody, R(40, 366, 220, 20), titleCol, L);
        Txt(g, avail ? "Taps and scrolling outside this window" : "Not available on this PC", fSmall, R(40, 388, 230, 18), cSub, L);
        DrawSwitch(g, rSwitch, Hooks.BlockClicks, avail);

        // Unlock button
        RectangleF u = rUnlock;
        Color uc = pressed == "unlock" ? cAccentPressed : (hot == "unlock" ? cAccentHover : cAccent);
        Fill(g, u, S(10), uc);
        if (holding) {
            float p = (float)Math.Min(1, (DateTime.UtcNow - holdStart).TotalMilliseconds / HoldMs);
            using (GraphicsPath path = Rounded(u, S(10))) using (SolidBrush b = new SolidBrush(Color.FromArgb(70, cOnAccent))) {
                g.SetClip(path);
                g.FillRectangle(b, u.X, u.Y, u.Width * p, u.Height);
                g.ResetClip();
            }
        }
        Txt(g, HoldMode ? "Hold to unlock" : "Unlock now", fButton, u, cOnAccent, C);

        // Footer
        string foot = HoldMode ? "Press and hold the button for 1 second." : "The mouse still works.";
        Txt(g, foot + "  Stuck? Press Ctrl+Alt+Del.", fSmall, R(12, 498, 336, 18), cSub, C);
    }

    void DrawPill(Graphics g, RectangleF r, string label, string id, bool enabled) {
        Color c = !enabled ? cSurface : (pressed == id ? cTrack : (hot == id ? cSurfaceHover : cSurface));
        Fill(g, r, r.Height / 2, c);
        Txt(g, label, fPill, r, enabled ? cText : Color.FromArgb(110, cSub), TextFormatFlags.HorizontalCenter);
    }

    void DrawSwitch(Graphics g, RectangleF r, bool on, bool enabled) {
        float knob = r.Height - S(8);
        if (on) {
            Fill(g, r, r.Height / 2, cAccent);
            using (SolidBrush b = new SolidBrush(cOnAccent)) g.FillEllipse(b, r.Right - S(4) - knob, r.Y + S(4), knob, knob);
        } else {
            Color edge = enabled ? cSub : Color.FromArgb(90, cSub);
            using (GraphicsPath p = Rounded(RectangleF.Inflate(r, -S(0.75f), -S(0.75f)), r.Height / 2)) using (Pen pen = new Pen(edge, S(1.5f))) g.DrawPath(pen, p);
            float kk = knob - S(2);
            using (SolidBrush b = new SolidBrush(edge)) g.FillEllipse(b, r.X + S(5), r.Y + (r.Height - kk) / 2, kk, kk);
        }
    }

    Icon MakeIcon() {
        using (Bitmap bmp = new Bitmap(64, 64)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using (GraphicsPath p = Rounded(new RectangleF(2, 2, 60, 60), 14)) using (SolidBrush b = new SolidBrush(cAccent)) g.FillPath(b, p);
                using (Font f = new Font(iconFont, 34, GraphicsUnit.Pixel))
                using (SolidBrush b = new SolidBrush(cOnAccent))
                using (StringFormat sf = new StringFormat()) {
                    sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                    g.DrawString("\uE72E", f, b, new RectangleF(0, 2, 64, 64), sf);
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            timer.Dispose();
            Font[] fonts = { fTitle, fSub, fBig, fSmall, fPill, fBody, fButton, fIcon };
            foreach (Font f in fonts) if (f != null) f.Dispose();
        }
        base.Dispose(disposing);
    }
}

public static class App {
    public static int Run(int seconds, bool blockTouchpad, bool sound, string theme) {
        if (seconds < 10) seconds = 10;
        if (seconds > 3600) seconds = 3600;

        bool created;
        Mutex mutex = new Mutex(true, "Local\\KeyboardLock.SingleInstance", out created);
        if (!created) {   // already running: bring that window to the front
            IntPtr h = Native.FindWindow(null, "Keyboard Lock");
            if (h != IntPtr.Zero) Native.SetForegroundWindow(h);
            mutex.Dispose();
            return 1;
        }

        ThreadExceptionEventHandler onUiError = delegate(object s, ThreadExceptionEventArgs e) {
            Hooks.Stop();
            MessageBox.Show("Keyboard Lock hit an error and unlocked:\n\n" + e.Exception.Message, "Keyboard Lock",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            Application.ExitThread();
        };
        UnhandledExceptionEventHandler onCrash = delegate(object s, UnhandledExceptionEventArgs e) { Hooks.Stop(); };
        SessionEndingEventHandler onLogoff = delegate(object s, SessionEndingEventArgs e) { Hooks.Stop(); };

        try {
            try {
                if (!Native.SetProcessDpiAwarenessContext(new IntPtr(-4))) Native.SetProcessDPIAware();   // sharp on scaled screens
            } catch { try { Native.SetProcessDPIAware(); } catch { } }

            bool dark = true;
            if (string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase)) dark = false;
            else if (!string.Equals(theme, "dark", StringComparison.OrdinalIgnoreCase)) {
                try {
                    object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0);
                    dark = !(v is int && (int)v == 1);
                } catch { }
            }

            Application.EnableVisualStyles();
            Application.ThreadException += onUiError;
            AppDomain.CurrentDomain.UnhandledException += onCrash;
            SystemEvents.SessionEnding += onLogoff;

            using (LockForm form = new LockForm(seconds, blockTouchpad, sound, dark)) {
                Application.Run(form);
            }
            return 0;
        } finally {
            Hooks.Stop();
            Application.ThreadException -= onUiError;
            AppDomain.CurrentDomain.UnhandledException -= onCrash;
            SystemEvents.SessionEnding -= onLogoff;
            try { mutex.ReleaseMutex(); } catch { }
            mutex.Dispose();
        }
    }
}

}
'@
    }
    [void][KeyLock.App]::Run($lockSeconds, $blockTouchpad, $playSound, $theme)
}
catch {
    [System.Windows.Forms.MessageBox]::Show("Keyboard Lock could not start:`n`n$($_.Exception.Message)", 'Keyboard Lock', 'OK', 'Error') | Out-Null
}
finally {
    if ('KeyLock.Hooks' -as [type]) { [KeyLock.Hooks]::Stop() }
}
