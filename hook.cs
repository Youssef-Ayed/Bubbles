// bubbles-hook.exe - Claude Code runs this for each hook event, with the event JSON on stdin.
// It forwards that JSON as one line to the Bubbles pipe and exits, printing nothing.
// The one exception is PermissionRequest: it waits for Bubbles to answer ("allow" or "deny", from a click on
// the bubble or a spoken answer) and prints that decision for Claude Code. Claude's own permission prompt
// keeps working alongside; any other reply, a closed pipe or the wait running out prints nothing.
// If Bubbles is not running it exits at once. install.ps1 compiles this file.
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

    const int AnswerWaitMs = 110000;   // the hook's own timeout in settings.json is 120 s

    static int Main() {
        try {
            string raw;
            using (StreamReader r = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false))) raw = r.ReadToEnd();
            // JSON escapes newlines inside strings, so raw line breaks are only whitespace
            raw = raw.Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (raw.Length == 0) return 0;
            bool perm = Regex.IsMatch(raw, "\"hook_event_name\"\\s*:\\s*\"PermissionRequest\"");
            string pipe = "bubbles-" + WindowsIdentity.GetCurrent().User.Value;
            // fails immediately when no such pipe exists
            if (!WaitNamedPipe(@"\\.\pipe\" + pipe, 500)) return 0;
            using (NamedPipeClientStream c = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous)) {
                c.Connect(500);
                byte[] b = Encoding.UTF8.GetBytes(raw + "\n");
                c.Write(b, 0, b.Length);
                c.Flush();
                if (!perm) return 0;
                Task<string> t = new StreamReader(c, new UTF8Encoding(false)).ReadLineAsync();
                if (!t.Wait(AnswerWaitMs)) return 0;
                string reply = (t.Result ?? "").Trim();
                if (reply == "allow") Emit("{\"behavior\":\"allow\"}");
                else if (reply == "deny") Emit("{\"behavior\":\"deny\",\"message\":\"The user denied this from Bubbles.\"}");
            }
        } catch { }
        return 0;
    }

    static void Emit(string decision) {
        Console.Out.Write("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":" + decision + "}}");
        Console.Out.Flush();
    }
}
