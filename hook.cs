// bubbles-hook.exe - Claude Code runs this for each hook event, with the event JSON on stdin.
// It forwards that JSON as one line to the Bubbles pipe and exits, printing nothing.
// Two events wait for a reply line from Bubbles:
//   PermissionRequest (up to 110 s): your Allow / Deny / question answers from a bubble
//   UserPromptSubmit (up to 1.5 s): a note that the prompt was dictated
// A reply "json:{...}" is printed for Claude Code as the hook's output; anything else prints nothing,
// so Claude's own prompt and normal behavior decide. If Bubbles is not running it exits at once.
// install.ps1 compiles this file.
using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

static class BubblesHook {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool WaitNamedPipe(string name, uint timeoutMs);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    // Pipe names are machine-wide: another account could create ours first while Bubbles is not running.
    // Only talk to a server process that runs as this same Windows user.
    static bool ServerIsMe(NamedPipeClientStream c, SecurityIdentifier me) {
        uint pid;
        if (!GetNamedPipeServerProcessId(c.SafePipeHandle.DangerousGetHandle(), out pid)) return false;
        IntPtr proc = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
        if (proc == IntPtr.Zero) return false;
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(proc, 0x0008, out token)) return false;   // TOKEN_QUERY
            using (WindowsIdentity id = new WindowsIdentity(token)) return me.Equals(id.User);
        } finally {
            if (token != IntPtr.Zero) CloseHandle(token);
            CloseHandle(proc);
        }
    }

    const int PermissionWaitMs = 110000;   // the hook's own timeout in settings.json is 120 s
    const int PromptWaitMs = 1500;         // never hold up a prompt for long

    static int Main() {
        try {
            string raw;
            using (StreamReader r = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false))) raw = r.ReadToEnd();
            // JSON escapes newlines inside strings, so raw line breaks are only whitespace
            raw = raw.Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (raw.Length == 0) return 0;
            Match ev = Regex.Match(raw, "\"hook_event_name\"\\s*:\\s*\"([A-Za-z]+)\"");
            string name = ev.Success ? ev.Groups[1].Value : "";
            int waitMs = name == "PermissionRequest" ? PermissionWaitMs : name == "UserPromptSubmit" ? PromptWaitMs : 0;
            SecurityIdentifier me = WindowsIdentity.GetCurrent().User;
            string pipe = "bubbles-" + me.Value;
            // fails immediately when no such pipe exists
            if (!WaitNamedPipe(@"\\.\pipe\" + pipe, 500)) return 0;
            using (NamedPipeClientStream c = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous)) {
                c.Connect(500);
                // checked before sending anything: event JSON holds prompts and commands
                if (!ServerIsMe(c, me)) return 0;
                byte[] b = Encoding.UTF8.GetBytes(raw + "\n");
                c.Write(b, 0, b.Length);
                c.Flush();
                if (waitMs == 0) return 0;
                Task<string> t = new StreamReader(c, new UTF8Encoding(false)).ReadLineAsync();
                if (!t.Wait(waitMs)) return 0;
                string reply = (t.Result ?? "").Trim();
                if (reply.StartsWith("json:{")) {
                    // Claude Code reads hook output as UTF-8 (the console default would mangle accents)
                    using (StreamWriter o = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))) o.Write(reply.Substring(5));
                }
            }
        } catch { }
        return 0;
    }
}
