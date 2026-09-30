#!/usr/bin/env bash
# Renders Native/Assets.xcassets/AppIcon.appiconset from the Actual logo mark
# (packages/component-library/src/icons/logo/logo.svg upstream).
# Requires rsvg-convert (brew install librsvg).
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${project_root}/Native/Assets.xcassets/AppIcon.appiconset"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Upstream logo paths, 30x32 viewBox; the glyph's visual centre is ~(14.9, 16.1).
glyph='<path d="M1.13785 30.4226L14.9372 1.11397C14.99 1.00184 15.1027 0.930283 15.2267 0.930283H15.8318C15.9542 0.930283 16.0659 1.00015 16.1195 1.11023L25.0219 19.3999L27.8131 18.3264C27.978 18.2629 28.1632 18.3452 28.2266 18.5102L28.9695 20.4417C29.033 20.6067 28.9507 20.7918 28.7857 20.8553L26.2121 21.8452L29.3875 28.3689C29.4648 28.5278 29.3987 28.7193 29.2398 28.7967L27.379 29.7024C27.2201 29.7798 27.0286 29.7136 26.9512 29.5547L23.6739 22.8215L1.6943 31.2754C1.52935 31.3389 1.3442 31.2566 1.28075 31.0916C1.28006 31.0898 1.27938 31.088 1.27872 31.0862L1.12666 30.6684C1.09749 30.5883 1.10152 30.4998 1.13785 30.4226ZM15.56 6.1518L5.85065 26.7737L22.4837 20.3762L15.56 6.1518Z"/><path d="M21.7768 14.5682L22.7095 17.1121L1.50597 24.8867C1.34004 24.9476 1.1562 24.8624 1.09536 24.6964L0.382928 22.7534C0.322087 22.5875 0.407278 22.4037 0.573207 22.3428L21.7768 14.5682Z"/>'
place='translate(512 520) scale(18) translate(-14.93 -16.13)'

# icon <name> <background fill or none> <glyph fill> <extra defs>
icon() {
  cat > "${tmp}/$1.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6c4dd0"/><stop offset="1" stop-color="#4b2fa6"/>
    </linearGradient>
    <linearGradient id="bgDark" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#241a3f"/><stop offset="1" stop-color="#130d24"/>
    </linearGradient>
    <linearGradient id="mark" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#ddd3ff"/>
    </linearGradient>
    <linearGradient id="markDark" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#c9b8ff"/><stop offset="1" stop-color="#8f6ff0"/>
    </linearGradient>
    <!-- In glyph units: the mark is drawn at 18x scale. -->
    <filter id="shadow" filterUnits="userSpaceOnUse" x="-10" y="-10" width="50" height="52">
      <feDropShadow dx="0" dy="0.8" stdDeviation="1" flood-color="#1a0d4a" flood-opacity="0.35"/>
    </filter>
  </defs>
  <rect width="1024" height="1024" fill="$2"/>
  <g transform="${place}" fill="$3" $4>${glyph}</g>
</svg>
SVG
  rsvg-convert --width 1024 --height 1024 --background-color "$5" "${tmp}/$1.svg" -o "${out}/$1.png"
}

icon AppIcon        "url(#bg)"     "url(#mark)"     'filter="url(#shadow)"' "#5c3dbb"
icon AppIcon-Dark   "url(#bgDark)" "url(#markDark)" ''                      "#130d24"
icon AppIcon-Tinted "#000000"      "#ffffff"        ''                      "#000000"

echo "Wrote icons to ${out}"
