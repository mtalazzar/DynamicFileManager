#!/bin/bash
# Installs the free helper programs DynamicFileConverter uses for some formats.
# Uses prebuilt downloads only (Homebrew would compile from source on macOS 13).
set -uo pipefail

SUPPORT="$HOME/Library/Application Support/DynamicFileConverter"
mkdir -p "$SUPPORT/bin"
export HOMEBREW_NO_AUTO_UPDATE=1

need() { ! command -v "$1" >/dev/null 2>&1 && [ ! -x "$SUPPORT/bin/$1" ]; }

if need pandoc; then
  echo "▸ pandoc"
  TMP="$(mktemp -d)"
  curl -sL -o "$TMP/pandoc.zip" https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-x86_64-macOS.zip
  unzip -q -o "$TMP/pandoc.zip" -d "$TMP"
  cp "$TMP"/pandoc-*/bin/pandoc "$SUPPORT/bin/pandoc"
  rm -rf "$TMP"
fi

if [ ! -d /Applications/LibreOffice.app ]; then
  echo "▸ LibreOffice"
  brew install --cask libreoffice
fi

if [ ! -x "$SUPPORT/venv/bin/python" ] || ! "$SUPPORT/venv/bin/python" -c "import pdf2docx, pptx, pdfplumber, openpyxl" 2>/dev/null; then
  echo "▸ Python PDF tools"
  python3 -m venv "$SUPPORT/venv"
  "$SUPPORT/venv/bin/pip" install -q --only-binary=:all: pdf2docx python-pptx pdfplumber openpyxl
fi

for tool in ffmpeg gs tesseract cwebp avifenc; do
  command -v "$tool" >/dev/null || echo "! $tool is missing (brew install ffmpeg ghostscript tesseract webp libavif)"
done
echo "✓ Done"
