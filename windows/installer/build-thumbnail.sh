#!/bin/sh
# Builds pdfthumb.dll (File Explorer thumbnails of PDFs) for 64-bit Windows with MinGW-w64
# (brew install mingw-w64). The DLL is checked in, so `npm run dist` doesn't need this.
# A changed DLL needs a new number in THUMB_DLL (installer.nsh).
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -shared -static-libgcc -s \
    -o pdfthumb.dll pdfthumb.c pdfthumb.def \
    -lruntimeobject -lshcore -lole32 -luuid -lshlwapi -lwindowscodecs -lgdi32
echo "OK: windows/installer/pdfthumb.dll"
