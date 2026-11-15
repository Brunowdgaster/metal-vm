#!/usr/bin/env bash
#
# verifica.sh — os portes executam o MESMO bytecode e produzem a MESMA saída.
#
#   bash ports/verifica.sh            # todos os portes compilados
#   bash ports/verifica.sh nim d      # só esses
#
# ## O contrato de um porte
#
# Um porte do núcleo mínimo recebe um `.fbc` **montado pela implementação em
# C** e tem de imprimir exatamente o que o `.expected` do caso diz. Nada mais:
# sem montador, sem `--stats`, sem desmontador.
#
# Isso é mais forte do que parece. O `.fbc` é um formato binário com
# little-endian explícito, operandos de 1, 4 e 8 bytes e endereços absolutos.
# Qualquer porte que erre a decodificação de um operando, o sinal de um i32 ou
# a semântica de frame falha aqui — e falha de um jeito que aponta o caso.
#
# ## Por que a montagem vem do C e não de cada porte
#
# O montador do C já é verificado byte a byte contra o de Rust por
# `tests/cross_compat.sh`. Reescrevê-lo em cinco linguagens mediria paciência,
# não a linguagem. O que o porte demonstra é a **execução**: decodificação
# binária, máquina de pilha, frames e memória.
#
# ## Falha alto, de propósito
#
# Sétima encarnação da mesma lição deste portfólio: se o binário do porte não
# existe, este script **não** pula em silêncio — ele diz que o porte não foi
# compilado e conta como falha. Harness que pula teste é harness que mente.

set -uo pipefail

cd "$(dirname "$0")/.."

C_BIN="${C_BIN:-build-switch/fvm}"
CASOS_DIR="tests/cases"
FBC_DIR="${TMPDIR:-/tmp}/fvm_portes"

# porte -> binário. Único lugar que precisa mudar ao acrescentar uma linguagem.
declare -A BINARIO=(
  [nim]="ports/nim/fvm_nim"
  [odin]="ports/odin/fvm_odin"
  [d]="ports/d/fvm_d"
  [v]="ports/v/fvm_v"
  [ada]="ports/ada/fvm_ada"
)

ORDEM=(nim odin d v ada)

if [ $# -gt 0 ]; then
  ORDEM=("$@")
fi

echo
echo "=============================================================="
echo "  Portes do núcleo mínimo da Forge VM"
echo "=============================================================="
echo

if [ ! -x "$C_BIN" ]; then
  echo "A implementação de referência em C não existe em '$C_BIN'."
  echo "Rode: bash build.sh"
  exit 1
fi

# ------------------------------------------------- bytecode, montado uma vez
#
# Os mesmos arquivos .fbc servem todos os portes. Montar uma vez e reusar não é
# só economia: garante que os portes recebam BYTES IDÊNTICOS, e não bytes
# equivalentes montados em momentos diferentes.
mkdir -p "$FBC_DIR"
casos=()

for f in "$CASOS_DIR"/*.fasm; do
  nome=$(basename "$f" .fasm)
  if ! "$C_BIN" asm "$f" -o "$FBC_DIR/$nome.fbc" >/dev/null 2>&1; then
    echo "FALHA: o C não conseguiu montar $nome.fasm"
    echo "       (o binário em C está velho? rode 'bash build.sh')"
    exit 1
  fi
  casos+=("$nome")
done

echo "bytecode montado pelo C: ${#casos[@]} casos em $FBC_DIR"
echo

# Linha de base: o próprio C executando o bytecode que montou. Se isto falhar,
# o problema não está em porte nenhum.
base_ok=0
for nome in "${casos[@]}"; do
  obtido=$("$C_BIN" exec "$FBC_DIR/$nome.fbc" 2>&1)
  if [ "$obtido" = "$(cat "$CASOS_DIR/$nome.expected")" ]; then
    base_ok=$((base_ok + 1))
  else
    echo "FALHA NA LINHA DE BASE: o C divergiu em $nome"
    exit 1
  fi
done

echo "linha de base (C executa o próprio bytecode): $base_ok/${#casos[@]}"
echo

# ----------------------------------------------------------------- os portes
total_falhas=0
declare -A RESULTADO

for porte in "${ORDEM[@]}"; do
  bin="${BINARIO[$porte]:-}"

  if [ -z "$bin" ]; then
    echo "porte desconhecido: $porte"
    total_falhas=$((total_falhas + 1))
    continue
  fi

  printf '%-6s ' "$porte"

  if [ ! -x "$bin" ]; then
    echo "NÃO COMPILADO ($bin) — conta como falha"
    RESULTADO[$porte]="não compilado"
    total_falhas=$((total_falhas + 1))
    continue
  fi

  ok=0
  falhas=()

  for nome in "${casos[@]}"; do
    obtido=$("$bin" "$FBC_DIR/$nome.fbc" 2>&1)
    esperado=$(cat "$CASOS_DIR/$nome.expected")

    if [ "$obtido" = "$esperado" ]; then
      ok=$((ok + 1))
    else
      falhas+=("$nome")
    fi
  done

  if [ ${#falhas[@]} -eq 0 ]; then
    echo "$ok/${#casos[@]}"
    RESULTADO[$porte]="$ok/${#casos[@]}"
  else
    echo "$ok/${#casos[@]}  — falhou em: ${falhas[*]}"
    RESULTADO[$porte]="$ok/${#casos[@]}"
    total_falhas=$((total_falhas + ${#falhas[@]}))

    # Mostra o primeiro diff, que é onde está a informação.
    primeiro="${falhas[0]}"
    echo
    echo "       primeiro diff ($primeiro):"
    diff <(cat "$CASOS_DIR/$primeiro.expected") \
         <("$bin" "$FBC_DIR/$primeiro.fbc" 2>&1) \
      | sed 's/^/         /' | head -12
    echo
  fi
done

echo
echo "=============================================================="

if [ "$total_falhas" -eq 0 ]; then
  echo "  Todos os portes verificados executam o bytecode do C."
  exit 0
else
  echo "  $total_falhas divergência(s)."
  exit 1
fi
