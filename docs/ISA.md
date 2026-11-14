# ISA da Forge VM

Máquina de **pilha**, valores de 64 bits com tag. Bytecode em bytes: 1 byte de
opcode seguido do operando, quando existe, em little-endian explícito.

Por que pilha e não registradores: o decodificador fica trivial (nenhum campo
de registrador para extrair), o montador dispensa alocação de registradores e
o foco do projeto — custo de *dispatch* — fica isolado. O preço é mais
instruções executadas para o mesmo trabalho; uma VM de registradores faria
`fib(30)` com ~40% menos instruções. Está anotado como trabalho futuro.

## Formato dos operandos

| Tipo | Bytes | Usado por |
|---|---|---|
| nenhum | 0 | aritmética, pilha, heap |
| `i64` | 8 | `PUSH` |
| `label` | 4 | `JMP`, `JZ`, `JNZ` (endereço absoluto) |
| `slot` | 4 | `LOAD`, `STORE`, `RESERVE` |
| `call` | 4 + 1 | `CALL` (endereço + nargs) |
| `nargs` | 1 | `CALLI` |

## Instruções

Notação de efeito na pilha: `antes -- depois`, topo à direita.

| Op | Operando | Efeito | Observação |
|---|---|---|---|
| `HALT` | — | `--` | encerra |
| `PUSH n` | i64 | `-- n` | |
| `POP` | — | `a --` | |
| `DUP` | — | `a -- a a` | |
| `SWAP` | — | `a b -- b a` | |
| `ADD` `SUB` `MUL` | — | `a b -- (a op b)` | só inteiros |
| `DIV` `MOD` | — | `a b -- (a op b)` | erro se `b == 0` |
| `NEG` | — | `a -- -a` | |
| `LT` `LE` `GT` `GE` | — | `a b -- 0\|1` | só inteiros |
| `EQ` `NE` | — | `a b -- 0\|1` | objetos comparam por identidade |
| `JMP addr` | label | `--` | salto incondicional |
| `JZ addr` | label | `c --` | salta se `c == 0` |
| `JNZ addr` | label | `c --` | salta se `c != 0` |
| `LOAD i` | slot | `-- v` | lê `stack[base + i]` |
| `STORE i` | slot | `v --` | escreve `stack[base + i]` |
| `RESERVE n` | slot | `-- 0 ... 0` | abre `n` locais |
| `CALL addr n` | call | `a1..an -- ret` | novo frame, `base = sp - n` |
| `RET` | — | `v --` | descarta o frame, devolve `v` |
| `PRINT` | — | `v --` | imprime e consome |
| `NEWARR` | — | `n -- arr` | array de `n` zeros no heap |
| `AGET` | — | `arr i -- v` | com verificação de limites |
| `ASET` | — | `arr i v --` | com verificação de limites |
| `ALEN` | — | `arr -- n` | |
| `GC` | — | `--` | força uma coleta (para testes) |
| `CALLI n` | nargs | `clo a1..an -- ret` | chamada **indireta**: o destino vem da closure |

## Chamada indireta e closures

`CALL` tem o endereço fixo no bytecode: basta para funções de primeira ordem e
não basta para closures. `CALLI` resolve o destino a partir de **dados**.

Uma closure é um **array comum** — nada de novo no modelo de memória:

```
closure = [ endereço_do_código, capturado_0, capturado_1, ... ]
            ^ item 0, inteiro    ^ itens 1..
```

Convenção de chamada do `CALLI n`:

```
pilha na entrada:  [... closure arg1 ... argN]
frame resultante:  base = sp - N - 1
                   slot 0    = a própria closure
                   slot 1..N = os argumentos
```

Duas consequências deliberadas:

1. **A closure não é desempilhada.** Fica como slot 0, então as capturas são
   lidas com `LOAD 0; PUSH i; AGET` — instruções que já existiam. Não há
   registrador de ambiente nem instrução de acesso a captura.
2. **`RET` não mudou.** Ele trunca a pilha até `base`, o que descarta closure e
   argumentos juntos.

Como closure é array, o coletor mark & sweep já a percorre e já coleta ciclos:
uma closure que capture a si mesma não precisa de tratamento nenhum.

### `PUSH` aceita rótulo

Para montar uma closure é preciso o **endereço do código como valor**. Em vez
de um opcode novo, `PUSH` passou a aceitar um rótulo, que o montador resolve
como imediato de 64 bits:

```
PUSH soma_capturado      ; empurra o endereço, não um número escrito à mão
```

É o que mantém o custo da Fase 2 em **uma única instrução nova** (`CALLI`):
alocar a closure é `NEWARR` + `ASET`, que já existiam.

### Compatibilidade

`CALLI` entrou no **fim** do enum de opcodes (valor 31), então todo `.fbc`
anterior continua válido byte a byte e o magic segue `FVM1`. Um `.fbc` que use
`CALLI` executado numa VM anterior falha com "opcode invalido" — erro detectado
e reportado, não corrupção silenciosa.

## Modelo de frames

Os locais **não** vivem numa área separada: são slots da própria pilha de
operandos, a partir de `base`.

```
CALL soma 2        ; pilha: [... a b]      base = sp - 2
                   ; dentro de soma: LOAD 0 -> a, LOAD 1 -> b
RESERVE 1          ; pilha: [... a b 0]    slot 2 = temporário
RET                ; sp volta para base, o valor de retorno é empilhado
```

Duas consequências, ambas deliberadas:

1. **O conjunto de raízes do GC é a pilha inteira.** Não existe uma segunda
   estrutura a percorrer, o que elimina a classe de bug mais comum em GC
   caseiro: esquecer um conjunto de raízes.
2. **`LOAD` e `STORE` custam uma soma e um acesso indexado**, sem indireção
   por frame.

O frame raiz é empilhado por `vm_run` antes da primeira instrução, para que
`LOAD`, `STORE` e `RET` funcionem no nível de topo sem nenhum caso especial
dentro do loop quente.

## Formato do arquivo `.fbc`

```
offset 0  : "FVM1"      4 bytes, magic
offset 4  : entry        u32 little-endian
offset 8  : len          u32 little-endian
offset 12 : code[len]
```

O magic existe para que `fvm dis` decida sozinho se o argumento é fonte ou
bytecode, em vez de confiar na extensão do arquivo.
