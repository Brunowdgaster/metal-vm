#!/usr/bin/env bash
# run_bench.sh — mede throughput de dispatch e custo do GC.
#
# uso:  bash bench/run_bench.sh <binario> [<binario> ...]
#       REPS=7 bash bench/run_bench.sh ...
#
# Decisões de metodologia, porque benchmark mal feito é pior que nenhum:
#
# 1. MELHOR tempo, não a média. O mínimo é a amostra menos contaminada por
#    escalonamento do SO e por outros processos; a média mediria a máquina.
# 2. Execuções INTERCALADAS (rodada externa = repetição, interna = binário).
#    Rodar 7x o binário A e depois 7x o B atribui a A e B qualquer deriva de
#    frequência da CPU que aconteça no meio — foi exatamente o que produziu a
#    primeira tabela deste projeto, onde a variante mais rápida apareceu como
#    a mais lenta.
# 3. Uma rodada de aquecimento descartada antes de medir, para o arquivo já
#    estar no cache de página e a CPU já ter subido de frequência.
# 4. A contagem de instruções só existe com FVM_STATS=ON. Para binários sem
#    instrumentação, o script reusa a contagem do mesmo programa obtida de um
#    binário instrumentado: os programas são determinísticos, então a contagem
#    é idêntica por construção.
set -u

REPS=${REPS:-5}
HERE=$(cd "$(dirname "$0")" && pwd)
PROGS=${PROGS:-"loop fib alloc"}

declare -A BEST
declare -A WORST
declare -A COUNT

run_once() {   # $1 = binário, $2 = programa -> escreve tempo em REPLY
    local exe=$1 prog=$2 err t i
    err=$("$exe" run "$HERE/$prog.fasm" --stats 2>&1 >/dev/null)
    t=$(printf '%s' "$err" | sed -n 's/^tempo *: *\([0-9.]*\) s/\1/p')
    i=$(printf '%s' "$err" | sed -n 's/^instrucoes *: *\([0-9]*\)/\1/p')
    [ -n "$i" ] && COUNT[$prog]=$i
    REPLY=$t
}

# aquecimento (descartado)
for exe in "$@"; do
    [ -x "$exe" ] || continue
    for prog in $PROGS; do run_once "$exe" "$prog"; done
done

# medição intercalada
for _ in $(seq "$REPS"); do
    for prog in $PROGS; do
        for exe in "$@"; do
            [ -x "$exe" ] || continue
            run_once "$exe" "$prog"
            t=$REPLY
            key="$exe|$prog"
            if [ -n "$t" ]; then
                if [ -z "${BEST[$key]:-}" ] || awk "BEGIN{exit !($t < ${BEST[$key]})}"; then
                    BEST[$key]=$t
                fi
                if [ -z "${WORST[$key]:-}" ] || awk "BEGIN{exit !($t > ${WORST[$key]})}"; then
                    WORST[$key]=$t
                fi
            fi
        done
    done
done

printf '| %-26s | %-6s | %10s | %13s | %9s | %7s |\n' binario programa tempo_s instrucoes Mops/s disp_pct
printf '|%s|%s|%s|%s|%s|%s|\n' "----------------------------" "--------" "------------" "---------------" "-----------" "---------"
for exe in "$@"; do
    [ -x "$exe" ] || continue
    # Rótulo: o nome do binário, quando ele é distintivo; o diretório pai,
    # quando o binário se chama apenas "fvm" (caso dos builds do CMake).
    label=$(basename "$exe")
    [ "$label" = fvm ] && label=$(basename "$(dirname "$exe")")
    for prog in $PROGS; do
        t=${BEST["$exe|$prog"]:-}
        i=${COUNT[$prog]:-}
        if [ -n "$t" ] && [ -n "$i" ]; then
            mops=$(awk "BEGIN{printf \"%.1f\", $i/$t/1e6}")
        else
            mops="-"
        fi
        w=${WORST["$exe|$prog"]:-}
        if [ -n "$t" ] && [ -n "$w" ]; then
            spread=$(awk "BEGIN{printf \"%.1f\", ($w-$t)/$t*100}")
        else
            spread="-"
        fi
        printf '| %-26s | %-6s | %10s | %13s | %9s | %7s |\n' "$label" "$prog" "${t:--}" "${i:--}" "$mops" "$spread"
    done
done
