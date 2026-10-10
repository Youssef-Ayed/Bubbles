// bubbles-hook.exe - Claude Code runs this for each hook event, with the event JSON on stdin.
// It forwards that JSON as one line to the Bubbles pipe and exits. It never prints anything,
// so it never changes what Claude Code does (permission prompts stay in Claude).
// If Bubbles is not running it exits at once. install.ps1 compiles this file.
using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

static class BubblesHook {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool WaitNamedPipe(string name, uint timeoutMs);

    static int Main() {
        try {
            string raw;
            using (StreamReader r = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false))) raw = r.ReadToEnd();
            // JSON escapes newlines inside strings, so raw line breaks are only whitespace
            raw = raw.Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (raw.Length == 0) return 0;
            string pipe = "bubbles-" + WindowsIdentity.GetCurrent().User.Value;
            // fails immediately when no such pipe exists
            if (!WaitNamedPipe(@"\\.\pipe\" + pipe, 500)) return 0;
            using (NamedPipeClientStream c = new NamedPipeClientStream(".", pipe, PipeDirection.Out)) {
                c.Connect(500);
                byte[] b = Encoding.UTF8.GetBytes(raw + "\n");
                c.Write(b, 0, b.Length);
                c.Flush();
            }
        } catch { }
        return 0;
    }
}
