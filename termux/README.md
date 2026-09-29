# Claude Code on Android (Termux)

`setup-claude.sh` installs Claude Code inside an Ubuntu proot container and
adds a `claude` command to Termux. Claude Code has no native Android build,
which is why it runs inside Ubuntu.

Run once in Termux:

```bash
curl -fsSLO https://raw.githubusercontent.com/twall3252/fliphub/claude/android-file-system-capabilities-d0prqd/termux/setup-claude.sh
bash setup-claude.sh
```

Then just type `claude`. It starts in your current directory when Ubuntu can
see it: Termux home, `/sdcard/...` or `~/storage/...`. Otherwise it starts in
Termux home. Anything after `claude` is passed through (e.g. `claude -c`).

Inside Claude, Ubuntu's `apt install` works for extra tools. Your Claude login
and settings live in Ubuntu's `/root/.claude`.
