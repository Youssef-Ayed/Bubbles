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
- **Tray icon** with the bubble list, cleanup actions, and a shortcut to edit the config.

## Requirements

- Windows 11 with Windows PowerShell 5.1. Nothing to install or build.
- The [Claude desktop app](https://claude.ai/download) with the Code tab.
- For the live bubbles: the Claude Code hooks from the Coucou app (its `coucou-hook.exe` set in `~/.claude/settings.json`). Bubbles listens on the same pipe the hook writes to, so **quit the Coucou app itself** while Bubbles runs. Without the hooks, voice input still works and the bubbles just don't show live status.

## Setup

```powershell
git clone https://github.com/Youssef-Ayed/Bubbles.git
cd Bubbles\voice-claude
copy config.example.json config.json   # then edit it
.\start-voice-claude.cmd               # run it now
.\install.ps1                          # optional: start at login (-Remove to undo)
```

If `config.json` is missing, it is created with defaults on first run.

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
- Bubbles is not affiliated with Anthropic or Coucou.
