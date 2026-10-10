# Bubbles

Talk to Claude Code on Windows. Press a hotkey, speak, and your words land in a Claude Code session in the Claude desktop app (Code tab) and get sent. Each session then gets a small floating bubble that shows what Claude is doing, and taps you on the shoulder when it needs you.

Claude is the brain. Bubbles is the mouth, ears and display.

## What it does

- **Voice in.** `Ctrl+Alt+V` opens a pill at the top of the screen and starts Windows voice typing (`Win+H`). Enter sends, Esc cancels.
- **Project routing.** Start with a project name ("storefront fix the header spacing") and a new session opens in that folder. Press Down in the pill to pick an open session instead.
- **Spoken slash commands.** Say "slash compact" or "slash brainstorming ideas" and it becomes `/compact` or `/superpowers:brainstorming ideas`. It knows the built-in commands plus your own and your plugins' commands and skills. The pill shows what will be sent before you send it.
- **Auto-send.** Checks through UI Automation that the text reached Claude's message box, then presses Enter for you.
- **One bubble per session.** A little character that breathes, blinks and follows your cursor. It spins while working, celebrates when done, turns amber and shakes when Claude asks for permission, and falls asleep after a few idle minutes.
  - Hover to peek at the latest step. Click for the activity card (timeline, open in Claude, reply by voice). Double-click to jump to the session. Drag it anywhere and it snaps to the screen edge.
- **Answer permissions without switching windows.** When Claude asks to run a command or edit a file, the bubble's card shows **Allow** and **Deny**. Or press the hotkey and just say "allow" or "deny" (short answers only, so "no, use pnpm instead" is still sent as a normal prompt). Claude's own prompt stays up too, and whichever you answer first wins. Questions from Claude (multiple choice) still open in Claude.
- **Tray icon** with the bubble list, cleanup actions, and a shortcut to edit the config.

## Requirements

- Windows 11 with Windows PowerShell 5.1. Nothing else to install.
- The [Claude desktop app](https://claude.ai/download) with the Code tab.

## Setup

```powershell
git clone https://github.com/Youssef-Ayed/Bubbles.git
cd Bubbles
powershell -ExecutionPolicy Bypass -File .\install.ps1
copy config.example.json config.json   # optional, then edit it
.\start-bubbles.cmd
```

`install.ps1` does three things, and `-Remove` undoes them:

1. Compiles `hook.cs` into `bubbles-hook.exe` with the C# compiler built into Windows.
2. Adds that hook to the Claude Code hooks in `~/.claude/settings.json`, after saving a backup. Your other hooks are left alone.
3. Adds a `Bubbles` shortcut to your Startup folder (skip it with `-NoStartup`).

The hook forwards each event to Bubbles over a local named pipe that only your Windows user can open, and exits at once when Bubbles isn't running. For every event but one it prints nothing, so it never changes what Claude does. The exception is a permission request: the hook waits up to 110 seconds for your Allow or Deny from a bubble and hands that decision to Claude. It only ever answers after your own click or spoken answer; if you don't answer, Claude's normal prompt decides. Without the hook, voice input still works; the bubbles just don't show live status.

If `config.json` is missing, it is created with defaults on first run.

## Files

| File | What it is |
| --- | --- |
| `bubbles.ps1` | Main script: hotkey, voice pill, routing, auto-send, tray |
| `bubble-ui.ps1` | The floating bubbles and their character |
| `commands.ps1` | Spoken slash commands and the Claude message-box checks |
| `hook.cs` | Source of `bubbles-hook.exe` |
| `install.ps1` | Builds the hook, registers it, adds the Startup shortcut |
| `start-bubbles.cmd` | Starts Bubbles without a console window |

## Config

| Key | Default | Meaning |
| --- | --- | --- |
| `hotkey` | `Ctrl+Alt+V` | Global hotkey to open the pill |
| `folder` | your profile | Folder for new sessions when no project is named |
| `startDictation` | `true` | Press `Win+H` automatically when the pill opens |
| `autoPaste` | `true` | Paste into an existing session's message box |
| `autoSend` | `true` | Press Enter once the text is verified in the box |
| `bubbleMinutes` | `0` | Close idle bubbles after N minutes (0 = never) |
| `showActivity` | `voice` | `voice`: bubbles only for sessions you started by voice. `all`: every session |
| `permSound` | `true` | Play a sound when Claude asks for permission |
| `restoreClipboard` | `false` | Put your old clipboard back after pasting |
| `projects` | `[]` | `{ name, folder, aliases }`. Say the name or an alias to target that folder |

## Notes

- New sessions opened from a link show Claude's "Trust workspace" dialog. Bubbles never clicks it for you. Click it yourself and the message is sent right after.
- Bubble positions and open sessions are kept in `state.json` (not tracked).
- Logs go to `bubbles.log` next to the scripts.
- Bubbles is not affiliated with Anthropic.
