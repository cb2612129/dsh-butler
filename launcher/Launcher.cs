// DSH 管家 · 启动器
// ---------------------------------------------------------------
// 作用：双击这个 exe 时不要弹出黑色的 PowerShell 控制台窗口。
//       （Windows 11 默认用 Windows Terminal 接管控制台，
//         所以直接在 .ps1 上加 -WindowStyle Hidden 是没用的，
//         必须由一个 GUI 子系统的宿主程序来拉起 PowerShell。）
//
// 编译：运行同目录的「构建启动器.ps1」，产物是上一层的 DSH管家.exe
// 说明：不编译也能用 —— 直接右键 DSH管家.ps1 → 使用 PowerShell 运行。

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class DshButlerLauncher
{
    [STAThread]
    private static void Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = FindScript(dir);
        if (script == null)
        {
            MessageBox.Show(
                "找不到管家脚本（*.ps1）。\r\n请把启动器和 DSH管家.ps1 放在同一个文件夹里。\r\n\r\n" +
                "Cannot find the DSH Butler script (*.ps1) next to this launcher.",
                "DSH 管家", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // 用 Windows PowerShell 5.1 跑脚本（系统自带，不依赖 PowerShell 7）
        string ps = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");

        ProcessStartInfo psi = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(psi);
    }

    // 优先找名字以 DSH 开头、或者带「管家」的脚本；都没有就用第一个
    private static string FindScript(string dir)
    {
        string[] files;
        try { files = Directory.GetFiles(dir, "*.ps1"); }
        catch { return null; }
        string fallback = null;
        foreach (string f in files)
        {
            string name = Path.GetFileName(f);
            if (name.StartsWith("DSH", StringComparison.OrdinalIgnoreCase)) { return f; }
            if (name.IndexOf("管家", StringComparison.Ordinal) >= 0) { return f; }
            if (fallback == null) { fallback = f; }
        }
        return fallback;
    }
}
