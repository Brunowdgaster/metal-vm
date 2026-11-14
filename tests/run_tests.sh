#!/usr/bin/env bash
# run_tests.sh — equivalente POSIX do run_tests.ps1 (usado no CI Linux/macOS).
set -u
EXE="${1:-$(dirname "$0")/../build/fvm}"
[ -x "$EXE" ] || { echo "fvm nao encontrado em $EXE"; exit 2; }

pass=0; fail=0
for case in "$(dirname "$0")"/cases/*.fasm; do
    expected="${case%.fasm}.expected"
    [ -f "$expected" ] || continue
    name=$(basename "$case" .fasm)
    actual=$("$EXE" run "$case" 2>/dev/null)
    code=$?
    if [ $code -ne 0 ]; then
        printf 'FAIL %-10s exit code %d\n' "$name" "$code"; fail=$((fail+1))
    elif [ "$actual" != "$(cat "$expected")" ]; then
        printf 'FAIL %-10s\n  esperado: %s\n  obtido  : %s\n' "$name" \
            "$(tr '\n' '|' < "$expected")" "$(printf '%s' "$actual" | tr '\n' '|')"
        fail=$((fail+1))
    else
        printf 'ok   %-10s\n' "$name"; pass=$((pass+1))
    fi
done
echo; echo "$pass passaram, $fail falharam"
[ $fail -eq 0 ]
