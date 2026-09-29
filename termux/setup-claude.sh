#!/data/data/com.termux/files/usr/bin/bash
# Sets up Claude Code on Android (Termux) and installs a `claude` command.
#
# Claude Code has no native Android build, so it runs inside an Ubuntu
# proot container. The `claude` launcher this script installs starts that
# container in your current directory, so Termux home, /sdcard and
# /storage are all reachable from Claude.
#
# Usage (in Termux, not inside Ubuntu):
#   bash setup-claude.sh
# Safe to re-run: every step is skipped if it's already done.

set -euo pipefail

DISTRO="${CLAUDE_DISTRO:-ubuntu}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "${PREFIX:-}" == */com.termux/* ]] || die "run this in Termux, not inside Ubuntu or another Linux."

# 1. Shared storage permission (Downloads, DCIM, ...). Android shows a dialog.
if [[ ! -d "$HOME/storage" ]]; then
  say "Requesting storage permission - tap Allow on the Android dialog."
  termux-setup-storage || warn "storage permission not granted; /sdcard won't be reachable."
  sleep 3
fi

# 2. proot-distro
if ! command -v proot-distro >/dev/null 2>&1; then
  say "Installing proot-distro"
  pkg install -y proot-distro
fi

# 3. Remove the npm install of Claude Code in Termux; it can't run on Android.
if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
  say "Removing the Termux npm install of Claude Code (no Android binary exists)"
  npm uninstall -g @anthropic-ai/claude-code || true
fi

# 4. Ubuntu container
PD_DIR="$PREFIX/var/lib/proot-distro"
ROOTFS=""
for d in "$PD_DIR/containers/$DISTRO/rootfs" "$PD_DIR/installed-rootfs/$DISTRO"; do
  [[ -d "$d/usr" ]] && { ROOTFS="$d"; break; }
done
if [[ -z "$ROOTFS" ]]; then
  say "Installing $DISTRO (a few hundred MB)"
  proot-distro install "$DISTRO"
  for d in "$PD_DIR/containers/$DISTRO/rootfs" "$PD_DIR/installed-rootfs/$DISTRO"; do
    [[ -d "$d/usr" ]] && { ROOTFS="$d"; break; }
  done
  [[ -n "$ROOTFS" ]] || die "installed $DISTRO but can't find its files under $PD_DIR"
fi

# 5. Claude Code inside Ubuntu. Termux downloads the Linux build and copies
# it into the container, so nothing runs apt inside proot (apt tends to hang
# there on Android).
case "$(uname -m)" in
  aarch64|arm64) CC_ARCH=arm64 ;;
  x86_64)        CC_ARCH=x64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac
CC_PKG="@anthropic-ai/claude-code-linux-$CC_ARCH"
say "Looking up the latest Claude Code for linux-$CC_ARCH"
meta="$(curl -fsSL "https://registry.npmjs.org/$CC_PKG/latest")" ||
  die "couldn't reach registry.npmjs.org - check your internet connection."
CC_VERSION="$(printf '%s' "$meta" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n1)"
CC_TARBALL="$(printf '%s' "$meta" | sed -n 's/.*"tarball":"\([^"]*\)".*/\1/p' | head -n1)"
[[ -n "$CC_VERSION" && -n "$CC_TARBALL" ]] || die "couldn't read the Claude Code version from the registry."

CC_BIN="$ROOTFS/usr/local/bin/claude"
installed="$([[ -x "$CC_BIN" ]] && cat "$ROOTFS/usr/local/share/claude-version" 2>/dev/null || true)"
if [[ "$installed" == "$CC_VERSION" ]]; then
  say "Claude Code $CC_VERSION is already installed"
else
  say "Downloading Claude Code $CC_VERSION (about 100 MB)"
  tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/claude.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  curl -fL --progress-bar -o "$tmp/claude.tgz" "$CC_TARBALL"
  tar -xzf "$tmp/claude.tgz" -C "$tmp" package/claude
  mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/share"
  mv -f "$tmp/package/claude" "$CC_BIN"
  chmod 755 "$CC_BIN"
  printf '%s\n' "$CC_VERSION" > "$ROOTFS/usr/local/share/claude-version"
fi

say "Checking that Claude Code runs inside $DISTRO"
if ! timeout 120 proot-distro login "$DISTRO" -- /usr/local/bin/claude --version; then
  warn "'claude --version' failed or timed out inside $DISTRO; the launcher is installed anyway."
fi

# Entry point inside Ubuntu: finds Claude wherever the installer put it.
cat > "$ROOTFS/usr/local/bin/claude-entry" <<'ENTRY'
#!/bin/sh
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
for c in /usr/local/bin/claude "$HOME/.local/bin/claude" /usr/bin/claude; do
  [ -x "$c" ] && exec "$c" "$@"
done
echo "Claude Code isn't installed inside Ubuntu. Re-run setup-claude.sh in Termux." >&2
exit 127
ENTRY
chmod 755 "$ROOTFS/usr/local/bin/claude-entry"

# 6. The `claude` command in Termux.
LAUNCHER="$PREFIX/bin/claude"
if [[ -e "$LAUNCHER" ]] && ! grep -q "claude-termux-launcher" "$LAUNCHER" 2>/dev/null; then
  mv "$LAUNCHER" "$LAUNCHER.bak"
  warn "moved the old $LAUNCHER to $LAUNCHER.bak"
fi
cat > "$LAUNCHER" <<LAUNCH
#!/data/data/com.termux/files/usr/bin/bash
# claude-termux-launcher: runs Claude Code inside the $DISTRO proot container.
# Installed by setup-claude.sh. Arguments are passed through to claude.

# Ubuntu's PATH includes Termux's bin, so guard against calling ourselves.
if [[ -n "\${CLAUDE_TERMUX_LAUNCHER:-}" ]]; then
  echo "claude: not found inside $DISTRO. Re-run setup-claude.sh in Termux." >&2
  exit 127
fi

# Start in the current directory when Ubuntu can see it (Termux home,
# /sdcard, /storage); otherwise fall back to Termux home.
wd="\$(pwd -P 2>/dev/null || echo "\$HOME")"
case "\$wd" in
  "\$HOME"|"\$HOME"/*|/storage/*|/sdcard|/sdcard/*) ;;
  *) wd="\$HOME" ;;
esac

exec proot-distro login $DISTRO --work-dir "\$wd" -e CLAUDE_TERMUX_LAUNCHER=1 \\
  -- /usr/local/bin/claude-entry "\$@"
LAUNCH
chmod 755 "$LAUNCHER"
hash -r 2>/dev/null || true

say "Done. Type 'claude' in Termux to start Claude Code."
say "Tip: 'cd ~/storage/downloads' (or any /sdcard folder) first to work there."
say "To update Claude Code later, re-run this script."
