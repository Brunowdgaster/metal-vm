#!/usr/bin/env bash
# cross_compat.sh — prova que as implementações em C e em Rust falam o mesmo
# bytecode, nas duas direções.
#
#   uso: bash tests/cross_compat.sh <bin_c> <bin_rust>
#
# Para cada caso de teste, verifica quatro coisas:
#
#   1. C monta   -> C executa      (linha de base)
#   2. Rust monta-> Rust executa   (linha de base)
#   3. C monta   -> RUST executa   (compatibilidade de leitura do .fbc)
#   4. Rust monta-> C executa      (compatibilidade de escrita do .fbc)
#   5. os dois .fbc são byte a byte IDÊNTICOS
#
# O item 5 é o mais forte: não basta os dois rodarem, os montadores têm de
# emitir exatamente os mesmos bytes. Qualquer divergência de ordem de
# operando, de endianness ou de resolução de rótulo aparece aqui.
set -u

C_BIN=${1:?uso: cross_compat.sh <bin_c> <bin_rust>}
R_BIN=${2:?uso: cross_compat.sh <bin_c> <bin_rust>}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() { # $1 = rótulo, $2 = esperado, $3 = obtido
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n  esperado: %s\n  obtido  : %s\n' "$1" \
            "$(printf '%s' "$2" | tr '\n' '|')" "$(printf '%s' "$3" | tr '\n' '|')"
        fail=$((fail + 1))
    fi
}

for case in "$HERE"/cases/*.fasm; do
    expected_file="${case%.fasm}.expected"
    [ -f "$expected_file" ] || continue
    name=$(basename "$case" .fasm)
    expected=$(cat "$expected_file")

    "$C_BIN" asm "$case" -o "$TMP/c.fbc"    2>/dev/null
    "$R_BIN" asm "$case" -o "$TMP/rust.fbc" 2>/dev/null

    check "$name c-asm/c-exec"       "$expected" "$("$C_BIN" exec "$TMP/c.fbc"    2>/dev/null)"
    check "$name rust-asm/rust-exec" "$expected" "$("$R_BIN" exec "$TMP/rust.fbc" 2>/dev/null)"
    check "$name c-asm/rust-exec"    "$expected" "$("$R_BIN" exec "$TMP/c.fbc"    2>/dev/null)"
    check "$name rust-asm/c-exec"    "$expected" "$("$C_BIN" exec "$TMP/rust.fbc" 2>/dev/null)"

    if cmp -s "$TMP/c.fbc" "$TMP/rust.fbc"; then
        pass=$((pass + 1))
    else
        printf 'FAIL %s: os .fbc diferem\n' "$name"
        cmp "$TMP/c.fbc" "$TMP/rust.fbc" || true
        fail=$((fail + 1))
    fi

    # o desmontador dos dois tem de concordar também
    check "$name dis" "$("$C_BIN" dis "$case" 2>/dev/null)" "$("$R_BIN" dis "$case" 2>/dev/null)"
done

echo
echo "$pass verificacoes passaram, $fail falharam"
[ "$fail" -eq 0 ]
