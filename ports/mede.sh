#!/usr/bin/env bash
#
# mede.sh — a tabela comparativa dos portes: linhas, compilação, execução, RSS.
#
#   bash ports/mede.sh
#
# ## O que cada coluna responde
#
# **linhas** — quanto código a linguagem exigiu para o mesmo trabalho. Conta
# linhas de código, sem comentários nem vazias, porque os portes deste
# repositório são densamente comentados e a contagem bruta mediria a
# documentação.
#
# **compilação** — tempo de build limpo, mínimo de 3. É o custo de iterar, e
# varia uma ordem de grandeza entre as cinco.
#
# **execução** — `fib.fasm`, o caso que faz trabalho de CPU de verdade. Mínimo
# de N, **alternando** entre os portes a cada repetição.
#
# **RSS no gc.fasm** — a coluna que mede o que os 9 casos NÃO medem.
#
# O `gc.fasm` cria 20 mil arrays descartados imediatamente. Um porte que
# recicla mantém o RSS baixo; um porte que nunca libera cresce. **Os dois
# passam no teste**, porque o teste verifica que `42` é impresso, não que a
# memória voltou.
#
# Sem esta coluna, a tabela diria que os cinco portes são equivalentes. Eles
# não são, e a diferença é de projeto: Nim e D têm coletor, V tem coletor mas a
# restrição de tipo-soma o tornou inútil aqui, e Odin e Ada não têm.
#
# ## Método
#
# Mínimo de N, alternado, com dispersão reportada — a mesma disciplina do resto
# do portfólio, pelas razões que `docs/BENCH.md` e a seção do NIF no
# p03-otp-mesh documentam. Medir A em bloco e depois B em bloco já produziu
# conclusões opostas em execuções seguidas neste mesmo portfólio.
#
# Nenhum destes números é comparável com os de outra máquina, e não há
# pretensão de que sejam: a tabela compara os portes ENTRE SI, na mesma
# máquina, na mesma sessão.

set -uo pipefail

cd "$(dirname "$0")/.."

C_BIN="${C_BIN:-build-switch/fvm}"
REPS="${REPS:-7}"
FBC_DIR="${TMPDIR:-/tmp}/fvm_portes"

declare -A FONTE=(
  [c]="c/src/vm.c c/src/value.c c/src/gc.c c/src/asm.c c/src/main.c c/include/fvm.h"
  [rust]="rust/src/vm.rs rust/src/value.rs rust/src/gc.rs rust/src/stack.rs rust/src/asm.rs rust/src/main.rs"
  [nim]="ports/nim/fvm.nim"
  [odin]="ports/odin/fvm.odin"
  [d]="ports/d/fvm.d"
  [v]="ports/v/fvm.v"
  [ada]="ports/ada/fvm.adb"
)

declare -A BINARIO=(
  [c]="$C_BIN"
  [rust]="binaries/fvm-rust-vec"
  [nim]="ports/nim/fvm_nim"
  [odin]="ports/odin/fvm_odin"
  [d]="ports/d/fvm_d"
  [v]="ports/v/fvm_v"
  [ada]="ports/ada/fvm_ada"
)

# Comando de build limpo de cada porte, para medir compilação.
declare -A BUILD=(
  [nim]="cd ports/nim && rm -rf ~/.cache/nim/fvm_d 2>/dev/null; nim c -d:release --hints:off --out:fvm_nim fvm.nim"
  [odin]="cd ports/odin && odin build fvm.odin -file -o:speed -out:fvm_odin"
  [d]="cd ports/d && ldc2 -O3 --release -of=fvm_d fvm.d"
  [v]="cd ports/v && v -prod -o fvm_v fvm.v"
  [ada]="cd ports/ada && rm -f *.o *.ali && gnatmake -O2 -o fvm_ada fvm.adb"
)

# Os portes, e as duas implementações de referência para contraste.
ORDEM=(c rust nim odin d v ada)

# `c` e `rust` recebem o .fbc por `exec`; os portes, direto no argv.
invoca() { # $1 = nome, $2 = arquivo .fbc
  case "$1" in
    c | rust) echo "${BINARIO[$1]} exec $2" ;;
    *) echo "${BINARIO[$1]} $2" ;;
  esac
}

echo
echo "=============================================================="
echo "  Tabela comparativa: 2 implementações + 5 portes"
echo "=============================================================="
echo
echo "máquina  : $(uname -sr)"
echo "cpu      : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
echo "reps     : $REPS, alternadas, mínimo"
echo

# ------------------------------------------------------------------ bytecode
if [ ! -x "$C_BIN" ]; then
  echo "A referência em C não existe em '$C_BIN'. Rode: bash build.sh"
  exit 1
fi

mkdir -p "$FBC_DIR"
for f in tests/cases/*.fasm; do
  nome=$(basename "$f" .fasm)
  "$C_BIN" asm "$f" -o "$FBC_DIR/$nome.fbc" >/dev/null 2>&1 || {
    echo "o C não montou $nome.fasm"
    exit 1
  }
done

# ------------------------------------------------------- 1. linhas de código
#
# Sem comentários nem linhas vazias. Os portes aqui são muito comentados de
# propósito, e contar isso mediria a documentação em vez da linguagem.
linhas_codigo() { # $@ = arquivos
  local total=0
  for arq in "$@"; do
    [ -f "$arq" ] || continue
    local n
    n=$(sed -e 's/--.*$//' -e 's#//.*$##' -e 's/^[[:space:]]*#.*$//' \
            -e 's/^[[:space:]]*;.*$//' "$arq" |
        grep -cve '^[[:space:]]*$')
    total=$((total + n))
  done
  echo "$total"
}

declare -A LINHAS
for nome in "${ORDEM[@]}"; do
  LINHAS[$nome]=$(linhas_codigo ${FONTE[$nome]})
done

# ---------------------------------------------------- 2. tempo de compilação
declare -A COMPILA
for nome in "${ORDEM[@]}"; do
  cmd="${BUILD[$nome]:-}"
  if [ -z "$cmd" ]; then
    COMPILA[$nome]="-"
    continue
  fi

  melhor=999999
  for _ in $(seq 1 3); do
    ini=$(date +%s%N)
    ( eval "$cmd" ) >/dev/null 2>&1
    rc=$?
    fim=$(date +%s%N)
    if [ $rc -ne 0 ]; then
      melhor=-1
      break
    fi
    ms=$(( (fim - ini) / 1000000 ))
    [ "$ms" -lt "$melhor" ] && melhor=$ms
  done

  if [ "$melhor" -lt 0 ]; then
    COMPILA[$nome]="FALHOU"
  else
    COMPILA[$nome]="$melhor"
  fi
done

# ------------------------------------------------------- 3. tempo de execução
#
# Alternado: uma repetição de cada porte por volta, e não todas as repetições
# de um e depois do outro. Medir em bloco atribui ao segundo qualquer deriva de
# frequência que aconteça no meio -- erro que este portfólio já cometeu duas
# vezes e documentou nas duas.
declare -A MELHOR_EXEC
declare -A PIOR_EXEC

for nome in "${ORDEM[@]}"; do
  MELHOR_EXEC[$nome]=999999999
  PIOR_EXEC[$nome]=0
done

for _ in $(seq 1 "$REPS"); do
  for nome in "${ORDEM[@]}"; do
    [ -x "${BINARIO[$nome]}" ] || continue
    cmd=$(invoca "$nome" "$FBC_DIR/fib.fbc")
    ini=$(date +%s%N)
    eval "$cmd" >/dev/null 2>&1
    fim=$(date +%s%N)
    us=$(( (fim - ini) / 1000 ))
    [ "$us" -lt "${MELHOR_EXEC[$nome]}" ] && MELHOR_EXEC[$nome]=$us
    [ "$us" -gt "${PIOR_EXEC[$nome]}" ] && PIOR_EXEC[$nome]=$us
  done
done

# ------------------------------------------------ 4. RSS máximo no gc.fasm
#
# A coluna que distingue quem recicla de quem não recicla. Os dois passam nos
# 9 casos.
declare -A RSS
for nome in "${ORDEM[@]}"; do
  if [ ! -x "${BINARIO[$nome]}" ]; then
    RSS[$nome]="-"
    continue
  fi
  cmd=$(invoca "$nome" "$FBC_DIR/gc.fbc")
  # %M é o RSS máximo em KiB.
  kib=$(/usr/bin/time -f '%M' $cmd 2>&1 >/dev/null | tail -1)
  case "$kib" in
    *[!0-9]*) RSS[$nome]="?" ;;
    *) RSS[$nome]="$kib" ;;
  esac
done

# ------------------------------------------------------------------ relatório
printf '%-7s %8s %10s %12s %9s %11s %s\n' \
  "impl" "linhas" "build(ms)" "fib(ms)" "disp" "RSS(KiB)" "memória"
printf '%s\n' "----------------------------------------------------------------------------"

for nome in "${ORDEM[@]}"; do
  if [ ! -x "${BINARIO[$nome]}" ]; then
    printf '%-7s %8s %10s %12s %9s %11s %s\n' \
      "$nome" "${LINHAS[$nome]}" "${COMPILA[$nome]}" "não compilado" "-" "-" "-"
    continue
  fi

  mel=${MELHOR_EXEC[$nome]}
  pio=${PIOR_EXEC[$nome]}
  disp="-"
  if [ "$mel" -gt 0 ]; then
    disp=$(awk -v a="$mel" -v b="$pio" 'BEGIN { printf "%.0f%%", (b - a) / a * 100 }')
  fi
  ms=$(awk -v u="$mel" 'BEGIN { printf "%.1f", u / 1000 }')

  case "$nome" in
    c) memoria="mark & sweep próprio" ;;
    rust) memoria="arena + mark & sweep" ;;
    nim) memoria="ORC do runtime" ;;
    d) memoria="GC do runtime" ;;
    v) memoria="arena, não recicla" ;;
    odin) memoria="arena, não recicla" ;;
    ada) memoria="arena, não recicla" ;;
    *) memoria="?" ;;
  esac

  printf '%-7s %8s %10s %12s %9s %11s %s\n' \
    "$nome" "${LINHAS[$nome]}" "${COMPILA[$nome]}" "$ms" "$disp" "${RSS[$nome]}" "$memoria"
done

echo
echo "notas:"
echo "  * 'linhas' exclui comentários e linhas vazias."
echo "  * c e rust implementam TAMBÉM o montador, o desmontador e --stats;"
echo "    os portes só executam. A comparação de linhas não é de igual para"
echo "    igual, e é por isso que a coluna existe junto com esta nota."
echo "  * 'disp' é (pior-melhor)/melhor. Acima de ~15% o número de execução"
echo "    serve de ordem de grandeza, não de comparação fina."
echo "  * RSS no gc.fasm distingue quem recicla de quem não recicla -- e os 9"
echo "    casos de teste NÃO distinguem: todos passam."
