## fvm.nim — porte do núcleo mínimo da Forge VM para Nim.
##
## ## O que este arquivo é, e o que ele não é
##
## É um **porte**, não uma implementação de referência. Ele executa bytecode
## `.fbc` já montado e tem de produzir **a saída byte a byte idêntica** à das
## implementações em C e em Rust nos 9 casos de `tests/cases/`.
##
## O que ele deliberadamente **não** tem:
##
## * **montador** — o `.fbc` vem do montador em C, que já é verificado byte a
##   byte contra o de Rust. Reescrever o montador em cinco linguagens mediria
##   paciência, não a linguagem;
## * **coletor de lixo próprio** — e esta é a parte interessante do ensaio, não
##   uma omissão. Ver "Memória" abaixo;
## * `--stats`, `--trace`, desmontador.
##
## O propósito do porte é responder **o que a linguagem dá de graça** no mesmo
## problema que em C custou 1.571 linhas.
##
## ## Memória: o que o Nim resolveu sozinho
##
## A implementação em C tem um mark & sweep com pilha cinza explícita, lista
## encadeada de todos os objetos vivos, e contabilidade de bytes para decidir
## quando coletar. Aqui, um array da VM é um `ref FvmArray`, e **o ORC do Nim
## cuida do resto**.
##
## O teste `gc_live.fasm` é o que prova que isso não é trapaça: ele guarda 100
## arrays dentro de outro array, força uma coleta, e exige que o item 99
## continue com 4 elementos. O ORC acerta porque o `seq[Value]` dentro do array
## raiz mantém as referências vivas — exatamente o que o mark & sweep em C
## precisa de uma pilha cinza para descobrir.
##
## Por isso `OP_GC` aqui é quase um no-op: `GC_fullCollect()` existe e é
## chamado, mas o resultado seria o mesmo sem ele. Em C, remover a chamada
## quebra o `gc.fasm`.
##
## ## Por que `case object` e não um ponteiro etiquetado
##
## Em C, `Value` é uma struct de 16 bytes com uma tag e uma união — e nada no
## compilador impede ler `as.o` de um valor cuja tag é `VAL_INT`. Em Nim, o
## `case object` abaixo faz o compilador recusar o acesso ao campo errado.
##
## É a mesma estrutura de dados com uma garantia a mais, e custa a mesma
## memória.
##
## uso: fvm_nim <prog.fbc>

import std/[os, strutils]

const
  Magic = "FVM1"
  StackMax = 1 shl 16
  FramesMax = 1024

type
  Op = enum
    opHalt, opPush, opPop, opDup, opSwap,
    opAdd, opSub, opMul, opDiv, opMod, opNeg,
    opLt, opLe, opGt, opGe, opEq, opNe,
    opJmp, opJz, opJnz,
    opLoad, opStore, opReserve,
    opCall, opRet, opPrint,
    opNewarr, opAget, opAset, opAlen, opGc,
    opCalli

  ValKind = enum vkInt, vkArr

  FvmArray = ref object
    items: seq[Value]

  ## O `case object` do Nim: a tag e a união numa só declaração, com o
  ## compilador impedindo o acesso ao campo errado. Em C isso é convenção.
  Value = object
    case kind: ValKind
    of vkInt: i: int64
    of vkArr: arr: FvmArray

  Frame = object
    retIp: int
    base: int

  VmError = object of CatchableError

func intVal(n: int64): Value = Value(kind: vkInt, i: n)
func arrVal(a: FvmArray): Value = Value(kind: vkArr, arr: a)

proc erro(msg: string) {.noreturn.} =
  raise newException(VmError, msg)

## Formatação do PRINT. Tem de casar com `value_print` do C **exatamente**:
## inteiro em decimal, array como `[1, 2, 3]` com vírgula e espaço, e `nil`
## para referência nula. Qualquer diferença aqui reprova os 9 casos.
proc formata(v: Value): string =
  case v.kind
  of vkInt:
    $v.i
  of vkArr:
    if v.arr == nil:
      "nil"
    else:
      var partes = newSeqOfCap[string](v.arr.items.len)
      for it in v.arr.items:
        partes.add formata(it)
      "[" & partes.join(", ") & "]"

# ------------------------------------------------------------------ bytecode
#
# Formato do .fbc (docs/ISA.md):
#
#   offset 0  : "FVM1"   4 bytes
#   offset 4  : entry     u32 little-endian
#   offset 8  : len       u32 little-endian
#   offset 12 : code[len]
#
# Little-endian explícito, byte a byte, e NÃO um cast para u32. A VM em C roda
# em x86-64 e ARM64, e o formato é definido como little-endian -- um cast
# funcionaria por acidente na máquina de hoje e quebraria na próxima.

proc leU32(b: openArray[byte], off: int): uint32 =
  uint32(b[off]) or (uint32(b[off + 1]) shl 8) or
    (uint32(b[off + 2]) shl 16) or (uint32(b[off + 3]) shl 24)

proc leI32(b: openArray[byte], off: int): int32 =
  cast[int32](leU32(b, off))

proc leI64(b: openArray[byte], off: int): int64 =
  var r: uint64 = 0
  for k in countdown(7, 0):
    r = (r shl 8) or uint64(b[off + k])
  cast[int64](r)

type Chunk = object
  code: seq[byte]
  entry: int

proc carrega(caminho: string): Chunk =
  let bruto = readFile(caminho)
  if bruto.len < 12:
    erro("arquivo curto demais para ser um .fbc")
  if bruto[0 .. 3] != Magic:
    erro("magic invalido: esperava " & Magic)

  var bytes = newSeq[byte](bruto.len)
  for k in 0 ..< bruto.len:
    bytes[k] = byte(bruto[k])

  let entry = int(leU32(bytes, 4))
  let n = int(leU32(bytes, 8))

  if 12 + n > bytes.len:
    erro("len do cabecalho (" & $n & ") maior que o arquivo")
  if entry > n:
    erro("entry fora do codigo")

  result.code = bytes[12 ..< 12 + n]
  result.entry = entry

# ----------------------------------------------------------------- execução

proc executa(chunk: Chunk) =
  var
    pilha = newSeq[Value](StackMax)
    sp = 0
    frames = newSeq[Frame](FramesMax)
    fp = 0
    ip = chunk.entry
    base = 0

  let code = chunk.code

  ## ATENÇÃO: o valor é avaliado para um temporário ANTES de `sp` ser usado
  ## como índice.
  ##
  ## Sem o temporário, `pilha[sp] = v` com `v` contendo um `pop()` -- como em
  ## `push intVal(vetor(pop()).items.len)` no ALEN -- avalia `sp` para o
  ## lvalue, depois roda `pop()`, que **decrementa sp**, e escreve no índice
  ## velho. O resultado é que o array continua no topo e o PRINT imprime ele
  ## em vez do tamanho.
  ##
  ## É **exatamente** o mesmo bug que a implementação em C teve no macro PUSH
  ## (`vm->stack[vm->sp++] = (v)` com `v` lendo `sp`), e pela mesma razão: o
  ## template do Nim substitui texto, igual ao pré-processador do C, e a ordem
  ## de avaliação do destino contra a da fonte não é a que se imagina.
  ##
  ## Diferença entre as duas linguagens aqui: em C era **comportamento
  ## indefinido** -- o MSVC aceitava calado e o gcc só reclamou com
  ## `-Wsequence-point`. Em Nim a ordem é definida; o código estava
  ## simplesmente errado, e os testes pegaram. Nenhum dos dois compiladores
  ## impediu de escrever.
  template push(v: Value) =
    let tmp = v
    if sp >= StackMax: erro("estouro da pilha de dados")
    pilha[sp] = tmp
    inc sp

  template pop(): Value =
    if sp <= 0: erro("pilha vazia")
    dec sp
    pilha[sp]

  template precisa(n: int) =
    if sp < n: erro("pilha com menos de " & $n & " valores")

  template inteiro(v: Value): int64 =
    let tmp = v
    if tmp.kind != vkInt: erro("esperava inteiro")
    tmp.i

  template vetor(v: Value): FvmArray =
    let tmp = v
    if tmp.kind != vkArr or tmp.arr == nil: erro("esperava array")
    tmp.arr

  template leU8(): int =
    let b = int(code[ip]); inc ip; b

  template leOpI32(): int32 =
    let v = leI32(code, ip); ip += 4; v

  template leOpI64(): int64 =
    let v = leI64(code, ip); ip += 8; v

  # O frame raiz é empilhado antes da primeira instrução, como em C, para que
  # LOAD/STORE/RET funcionem no topo sem caso especial dentro do laço.
  frames[0] = Frame(retIp: -1, base: 0)
  fp = 1

  while true:
    if ip < 0 or ip >= code.len:
      erro("ip fora do codigo")

    let op = Op(code[ip])
    inc ip

    case op
    of opHalt:
      return

    of opPush:
      push intVal(leOpI64())

    of opPop:
      precisa(1)
      dec sp

    of opDup:
      precisa(1)
      push pilha[sp - 1]

    of opSwap:
      precisa(2)
      swap pilha[sp - 1], pilha[sp - 2]

    of opAdd, opSub, opMul, opDiv, opMod,
       opLt, opLe, opGt, opGe, opEq, opNe:
      precisa(2)
      let b = inteiro(pop())
      let a = inteiro(pop())
      case op
      of opAdd: push intVal(a + b)
      of opSub: push intVal(a - b)
      of opMul: push intVal(a * b)
      of opDiv:
        if b == 0: erro("divisao por zero")
        push intVal(a div b)
      of opMod:
        if b == 0: erro("modulo por zero")
        push intVal(a mod b)
      of opLt: push intVal(if a < b: 1 else: 0)
      of opLe: push intVal(if a <= b: 1 else: 0)
      of opGt: push intVal(if a > b: 1 else: 0)
      of opGe: push intVal(if a >= b: 1 else: 0)
      of opEq: push intVal(if a == b: 1 else: 0)
      of opNe: push intVal(if a != b: 1 else: 0)
      else: discard

    of opNeg:
      precisa(1)
      push intVal(-inteiro(pop()))

    of opJmp:
      ip = int(leOpI32())

    of opJz:
      let dest = int(leOpI32())
      precisa(1)
      if inteiro(pop()) == 0: ip = dest

    of opJnz:
      let dest = int(leOpI32())
      precisa(1)
      if inteiro(pop()) != 0: ip = dest

    of opLoad:
      let slot = int(leOpI32())
      let idx = base + slot
      if slot < 0 or idx >= sp: erro("LOAD de slot inexistente")
      push pilha[idx]

    of opStore:
      let slot = int(leOpI32())
      let idx = base + slot
      precisa(1)
      if slot < 0 or idx >= sp: erro("STORE em slot inexistente")
      pilha[idx] = pop()

    of opReserve:
      let n = int(leOpI32())
      if n < 0: erro("RESERVE negativo")
      for _ in 0 ..< n:
        push intVal(0)

    of opCall:
      let destino = int(leOpI32())
      let nargs = leU8()
      if destino < 0 or destino >= code.len: erro("CALL para endereco invalido")
      if sp < nargs: erro("CALL sem argumentos suficientes")
      if fp >= FramesMax: erro("estouro da pilha de chamadas")
      frames[fp] = Frame(retIp: ip, base: sp - nargs)
      inc fp
      base = sp - nargs
      ip = destino

    of opRet:
      precisa(1)
      let v = pop()
      dec fp
      let f = frames[fp]
      sp = f.base
      push v
      if fp == 0:
        return
      base = frames[fp - 1].base
      ip = f.retIp

    of opPrint:
      precisa(1)
      echo formata(pop())

    of opNewarr:
      precisa(1)
      let n = inteiro(pop())
      if n < 0: erro("NEWARR exige tamanho inteiro >= 0")
      # `newSeq` zera, e a VM em C também inicializa com INT_VAL(0).
      let a = FvmArray(items: newSeq[Value](int(n)))
      for k in 0 ..< int(n):
        a.items[k] = intVal(0)
      push arrVal(a)

    of opAget:
      precisa(2)
      let idx = inteiro(pop())
      let a = vetor(pop())
      if idx < 0 or idx >= a.items.len: erro("AGET fora dos limites")
      push a.items[int(idx)]

    of opAset:
      precisa(3)
      let v = pop()
      let idx = inteiro(pop())
      let a = vetor(pop())
      if idx < 0 or idx >= a.items.len: erro("ASET fora dos limites")
      a.items[int(idx)] = v

    of opAlen:
      precisa(1)
      push intVal(int64(vetor(pop()).items.len))

    of opGc:
      # Em C esta instrução roda um mark & sweep de verdade e o `gc.fasm`
      # quebra sem ela. Aqui o ORC já reciclou tudo o que ficou inalcançável;
      # a chamada existe para honrar a semântica declarada do opcode, não
      # porque o teste precise dela.
      GC_fullCollect()

    of opCalli:
      let nargs = leU8()
      if sp < nargs + 1: erro("CALLI sem closure e argumentos suficientes")
      let novaBase = sp - nargs - 1
      let clo = vetor(pilha[novaBase])
      if clo.items.len < 1: erro("CALLI: closure sem endereco de codigo")
      let destino = inteiro(clo.items[0])
      if destino < 0 or destino >= code.len:
        erro("CALLI: endereco de codigo fora do programa")
      if fp >= FramesMax: erro("estouro da pilha de chamadas")
      frames[fp] = Frame(retIp: ip, base: novaBase)
      inc fp
      base = novaBase
      ip = int(destino)

when isMainModule:
  let args = commandLineParams()
  if args.len != 1:
    stderr.writeLine "uso: fvm_nim <prog.fbc>"
    quit 64

  try:
    executa(carrega(args[0]))
  except VmError as e:
    stderr.writeLine "erro de execucao: " & e.msg
    quit 70
  except IOError as e:
    stderr.writeLine "erro de E/S: " & e.msg
    quit 66
