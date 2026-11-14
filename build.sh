#!/usr/bin/env bash
# build.sh — compila a fvm no Linux/macOS/WSL.
#
# uso:
#   bash build.sh                 # switch dispatch, Release
#   bash build.sh goto            # computed goto (precisa de GCC/Clang)
#   bash build.sh goto nostats    # sem os contadores de instrucao
#   bash build.sh rust            # o porte em Rust (precisa de cargo)
#   bash build.sh rust boxed      # Rust com a pilha Box<[Value]> + sp
set -euo pipefail

variant=${1:-switch}
stats=${2:-stats}

# O porte em Rust tem seu proprio sistema de build; o script apenas delega,
# para que exista um unico ponto de entrada documentado no README.
if [ "$variant" = rust ]; then
    feats=""
    [ "$stats" = boxed ]   && feats="--features boxed-stack"
    [ "$stats" = nostats ] && feats="--no-default-features"
    # shellcheck disable=SC2086
    cargo build --release --manifest-path rust/Cargo.toml $feats
    echo
    ./rust/target/release/fvm version
    echo "binario: rust/target/release/fvm"
    exit 0
fi

goto=OFF;  [ "$variant" = goto ]   && goto=ON
st=ON;     [ "$stats" = nostats ]  && st=OFF

dir="build-$variant"
[ "$st" = OFF ] && dir="$dir-nostats"

cmake -S . -B "$dir" -DCMAKE_BUILD_TYPE=Release -DFVM_USE_GOTO=$goto -DFVM_STATS=$st
cmake --build "$dir" -j

echo
"$dir/fvm" version
echo "binario: $dir/fvm"
