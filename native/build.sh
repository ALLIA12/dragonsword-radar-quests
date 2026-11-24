#!/bin/sh
# Builds Mods/DragonSwordRadar/dsradar.dll with MinGW-w64 g++ (64-bit).
set -e
cd "$(dirname "$0")"
OUT=../Mods/DragonSwordRadar/dsradar.dll
mkdir -p obj
# ooz is used unmodified; its command-line main() is renamed out of the way.
for f in kraken lzna bitknit; do
  g++ -O2 -msse4.1 -fpermissive -w -include sys/stat.h -Dmain=ooz_cli_main -c ../third_party/ooz/$f.cpp -o obj/$f.o
done
g++ -O2 -std=c++17 -Wall -shared -static -static-libgcc -static-libstdc++ \
  -o "$OUT" dsradar.cpp pak.cpp save.cpp crypto.cpp util.cpp obj/kraken.o obj/lzna.o obj/bitknit.o -lbcrypt
echo "built $OUT"
