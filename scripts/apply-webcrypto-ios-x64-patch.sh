#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Local FluffyChat study fork
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Idempotently add the four Fiat/ADX assembly sources to
# crypto_sources_apple_x86_64 in package webcrypto 0.6.1.
# See docs/IOS_LOCAL_BUILD_RU.md.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
CMAKE_FILE="${PUB_CACHE}/hosted/pub.dev/webcrypto-0.6.1/third_party/boringssl/sources.cmake"
MARKER='third_party/fiat/asm/fiat_p256_adx_mul.S'

if [[ ! -f "$CMAKE_FILE" ]]; then
  echo "webcrypto 0.6.1 not found at:"
  echo "  $CMAKE_FILE"
  echo "Run 'flutter pub get' first."
  exit 1
fi

if grep -q "$MARKER" "$CMAKE_FILE"; then
  # The marker exists in linux_x86_64 too. Check it is inside apple_x86_64.
  # The `if` keeps set -e from aborting when the files are listed only for Linux.
  if python3 - "$CMAKE_FILE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
start = text.find("set(crypto_sources_apple_x86_64")
end = text.find("set(crypto_sources_linux_aarch64")
block = text[start:end]
if "fiat_p256_adx_mul.S" in block:
    print("webcrypto apple x86_64 ADX sources are already listed. Nothing to do.")
    raise SystemExit(0)
raise SystemExit(2)
PY
  then
    exit 0
  fi
fi

python3 - "$CMAKE_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = """  ${BORINGSSL_ROOT}gen/test_support/trampoline-x86_64-apple.S
)
"""
insert = """  ${BORINGSSL_ROOT}gen/test_support/trampoline-x86_64-apple.S
  ${BORINGSSL_ROOT}third_party/fiat/asm/fiat_curve25519_adx_mul.S
  ${BORINGSSL_ROOT}third_party/fiat/asm/fiat_curve25519_adx_square.S
  ${BORINGSSL_ROOT}third_party/fiat/asm/fiat_p256_adx_mul.S
  ${BORINGSSL_ROOT}third_party/fiat/asm/fiat_p256_adx_sqr.S
)
"""
if needle not in text:
    sys.exit("Could not find crypto_sources_apple_x86_64 closing lines to patch.")
path.write_text(text.replace(needle, insert, 1))
print(f"Patched {path}")
PY
