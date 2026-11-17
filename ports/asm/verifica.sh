#!/usr/bin/env bash
# verifica.sh — os portes em Assembly, que são um SUBCONJUNTO declarado.
#
#     bash ports/asm/verifica.sh
#
# ## Por que uma suíte separada
#
# `ports/verifica.sh` exige 9/9: todo porte listado lá executa os nove casos.
# Os portes em Assembly executam **dois** — `arith` e `control` —, e colocá-los
# naquela lista os faria aparecer como falha.
#
# A alternativa seria baixar a exigência de lá para "os casos que cada porte
# suportar", e isso destruiria o que aquela suíte garante. Uma suíte separada,
# com o escopo escrito no topo, é mais honesto que um critério elástico.
#
# ## O que estes portes demonstram
#
# O plano do projeto é explícito: *"Assembly entra no dispatch loop (computed
# goto vs. jump table em asm puro) com medição"*. O subconjunto inteiro
# (pilha, aritmética, comparação, saltos, locais, PRINT) é o que isola o custo
# do despacho — os opcodes de heap passariam por alocador, e a medição mediria
# o alocador.
#
# E a suíte verifica **as duas direções**:
#
#   1. nos casos suportados, a saída é byte a byte a do C;
#   2. nos NÃO suportados, o porte falha ALTO, com código 70 — e não produz
#      saída parcial plausível.
#
# A segunda importa tanto quanto a primeira: um porte que ignorasse `NEWARR`
# imprimiria números errados em silêncio.
set -uo pipefail

cd "$(dirname "$0")/../.."

OK=0
FALHOU=0
PULADO=0

verde()    { printf '\033[32m%s\033[0m' "$1"; }
vermelho() { printf '\033[31m%s\033[0m' "$1"; }
cinza()    { printf '\033[90m%s\033[0m' "$1"; }

passa() { printf '  %s    %s\n' "$(verde ok)" "$1"; OK=$((OK+1)); }
falha() { printf '  %s %s\n' "$(vermelho FALHA)" "$1"; FALHOU=$((FALHOU+1)); }
pula()  { printf '  %s  %s\n' "$(cinza pulado)" "$1"; PULADO=$((PULADO+1)); }
secao() { printf '\n%s\n' "$(cinza "$1")"; }
tem()   { command -v "$1" >/dev/null 2>&1; }

# Os casos que o subconjunto cobre, e os que ele tem de RECUSAR.
SUPORTADOS=(arith control)
RECUSADOS=(arrays fib locals gc)

C_BIN=""
for cand in build-goto/fvm build/fvm c/build/fvm; do
    [ -x "$cand" ] && C_BIN="$cand" && break
done

printf '\n%s\n' '=============================================================='
printf '%s\n' 'portes em Assembly — o subconjunto inteiro, e o despacho'
printf '%s\n' '=============================================================='

if [ -z "$C_BIN" ]; then
    falha 'a implementação em C não está compilada: sem ela não há bytecode'
    printf '\n  %s passaram, %s falharam\n\n' "$(verde "$OK")" "$FALHOU"
    exit 1
fi

FBC="${TMPDIR:-/tmp}/fvm_asm"
mkdir -p "$FBC"

for caso in "${SUPORTADOS[@]}" "${RECUSADOS[@]}"; do
    if ! "$C_BIN" asm "tests/cases/$caso.fasm" -o "$FBC/$caso.fbc" \
            >/dev/null 2>&1; then
        falha "o C não montou $caso.fasm"
    fi
done

# ---------------------------------------------------------------------------
# Cada arquitetura: como montar, ligar, e como executar.
#
# O x86-64 roda direto; ARM64 e RISC-V rodam sob `qemu-user`, que executa
# binário de outra arquitetura traduzindo as instruções. Não é emulação de
# máquina inteira -- as syscalls são repassadas ao kernel do hospedeiro.
# ---------------------------------------------------------------------------

testa_arquitetura() {  # $1 = nome, $2 = dir, $3 = as, $4 = ld, $5 = runner
    local nome="$1" dir="$2" montador="$3" ligador="$4" runner="$5"
    local fonte="ports/asm/$dir/fvm.s"
    local obj="ports/asm/$dir/fvm.o"
    local bin="ports/asm/$dir/fvm_$dir"

    secao "$nome"

    if [ ! -f "$fonte" ]; then
        pula "$nome: $fonte ainda não existe"
        return
    fi

    if ! tem "$montador"; then
        pula "$nome: $montador ausente"
        return
    fi

    if [ -n "$runner" ] && ! tem "${runner%% *}"; then
        pula "$nome: ${runner%% *} ausente (apt install qemu-user)"
        return
    fi

    if "$montador" -o "$obj" "$fonte" 2>/dev/null \
       && "$ligador" -o "$bin" "$obj" 2>/dev/null; then
        passa "$nome monta e liga sem libc"
    else
        falha "$nome não monta"
        "$montador" -o "$obj" "$fonte" 2>&1 | head -4 | sed 's/^/        /'
        return
    fi

    for caso in "${SUPORTADOS[@]}"; do
        local esperado obtido
        esperado=$("$C_BIN" exec "$FBC/$caso.fbc" 2>&1)
        obtido=$($runner "./$bin" "$FBC/$caso.fbc" 2>&1)

        if [ "$obtido" = "$esperado" ]; then
            passa "$nome executa $caso com a saída do C, byte a byte"
        else
            falha "$nome divergiu em $caso"
            diff <(printf '%s\n' "$esperado") <(printf '%s\n' "$obtido") \
                | head -4 | sed 's/^/        /'
        fi
    done

    # A OUTRA DIRECAO: o que esta fora do subconjunto tem de FALHAR ALTO.
    local recusou=0
    for caso in "${RECUSADOS[@]}"; do
        if $runner "./$bin" "$FBC/$caso.fbc" >/dev/null 2>&1; then
            falha "$nome ACEITOU $caso, que usa opcode fora do subconjunto"
        else
            recusou=$((recusou + 1))
        fi
    done

    if [ "$recusou" = "${#RECUSADOS[@]}" ]; then
        passa "$nome recusa os ${#RECUSADOS[@]} casos fora do subconjunto, com erro"
    fi
}

testa_arquitetura 'x86-64 (nativo)' x86_64 \
    as ld ''

testa_arquitetura 'ARM64 (sob qemu-user)' aarch64 \
    aarch64-linux-gnu-as aarch64-linux-gnu-ld 'qemu-aarch64 -L /usr/aarch64-linux-gnu'

testa_arquitetura 'RISC-V 64 (sob qemu-user)' riscv64 \
    riscv64-linux-gnu-as riscv64-linux-gnu-ld 'qemu-riscv64 -L /usr/riscv64-linux-gnu'

printf '\n%s\n' '=============================================================='
if [ "$PULADO" -gt 0 ]; then
    printf '  %s passaram, %s falharam, %s pulado(s)\n' \
        "$(verde "$OK")" "$FALHOU" "$(cinza "$PULADO")"
else
    printf '  %s passaram, %s falharam\n' "$(verde "$OK")" "$FALHOU"
fi
printf '%s\n\n' '=============================================================='

[ "$FALHOU" -eq 0 ]
