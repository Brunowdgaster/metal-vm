# Portes do núcleo mínimo

Cinco linguagens executando **o mesmo bytecode** que a implementação em C
produz, com saída verificada byte a byte.

```
bash ports/verifica.sh      # 9 casos × 5 portes, contra o .fbc do C
bash ports/mede.sh          # linhas × compilação × execução × RSS
```

## O contrato, e por que ele é estreito de propósito

Um porte recebe um `.fbc` **montado pela implementação em C** e tem de imprimir
exatamente o que o `.expected` do caso diz. Nada mais:

| tem | não tem |
|---|---|
| decodificação do formato binário | montador |
| máquina de pilha, 32 opcodes | desmontador |
| frames, `CALL`, `CALLI`, closures | `--stats`, `--trace` |
| arrays no heap | coletor próprio (ver abaixo) |

**Por que o montador não entra:** o montador do C já é verificado byte a byte
contra o de Rust por `tests/cross_compat.sh`. Reescrevê-lo em cinco linguagens
mediria paciência, não a linguagem. O que o porte demonstra é a **execução** —
decodificação binária, semântica de pilha e de frame, e gestão de memória.

**O contrato é mais severo do que parece.** O `.fbc` tem little-endian
explícito, operandos de 1, 4 e 8 bytes e endereços absolutos. Errar o sinal de
um `i32`, a ordem de um byte ou a base de um frame falha em um caso específico,
e o caso aponta onde.

> Estes são **portes**, declarados como tais, não implementações de referência.
> As de referência são o C e o Rust, na raiz do repositório, e só elas têm
> montador, coletor próprio e instrumentação.

## O que cada linguagem deu, e o que cobrou

### Nim — e o mesmo bug que o C teve

O `case object` do Nim é a tag e a união numa declaração só, com o compilador
recusando o acesso ao campo errado. Em C a mesma estrutura é mantida por
convenção.

O **ORC** cuidou da memória: `gc_live.fasm` guarda 100 arrays vivos dentro de
outro e exige que sobrevivam a uma coleta. O que em C custa um mark & sweep com
pilha cinza explícita, aqui é não fazer nada.

Mas o porte em Nim errou primeiro, e errou **do mesmo jeito que o C**:

```nim
template push(v: Value) =
  pilha[sp] = v      # ERRADO
  inc sp
```

Com `push intVal(vetor(pop()).items.len)` no `ALEN`, o `sp` do lado esquerdo é
avaliado **antes** do `pop()` do lado direito, que decrementa `sp`. O valor vai
para o índice velho, o array continua no topo, e o `PRINT` imprime o array em
vez do tamanho.

É literalmente o bug que a implementação em C teve no macro `PUSH`
(`vm->stack[vm->sp++] = (v)` com `v` lendo `sp`) — porque **template de Nim
substitui texto, igual ao pré-processador do C**.

A diferença: em C era **comportamento indefinido**, o MSVC aceitou calado e só
o gcc com `-Wsequence-point` reclamou. Em Nim a ordem é definida e o código
estava simplesmente errado. Nenhum dos dois compiladores impediu de escrever;
nos dois casos foi **teste** que pegou.

### D — exaustividade que recusa o atalho

`SumType` de `std.sumtype` com `match` que **não compila** se faltar um caso —
a mesma garantia que o Gleam dá no p03-otp-mesh, numa linguagem de sistemas.

E o `final switch` do D fez o que promete: recusou o bloco interno que trata só
o subconjunto aritmético dos opcodes, exigindo um `switch` com `default`
explícito. Reclamação correta.

`littleEndianToNative` resolve a decodificação com o endianness **no nome da
função**; em C são três funções escritas à mão. O GC do runtime cuidou dos
arrays.

### V — a restrição que mudou o desenho

A declaração óbvia não compila:

```
type Value = i64 | &FvmArray
→ error: sum type cannot hold a reference type
```

Tipo-soma em V não aceita referência. E um array da VM **tem** de ser
compartilhado, senão `ASET` mutaria uma cópia.

A saída foi um **handle**: um índice para uma arena dentro da VM. E o
interessante é onde isso chegou — **é exatamente o desenho que a implementação
em Rust deste projeto usa** (`rust/src/gc.rs`), onde o motivo foi outro: o
borrow checker não aceita grafo de objetos com donos múltiplos. Duas
linguagens, duas restrições diferentes, a mesma solução.

O custo foi real: o V **tem** coletor, mas a arena mantém toda array alcançável
pelo índice, então o coletor não tem o que recolher. **Este porte não recicla
memória** — a vantagem que Nim e D tiveram, o V perdeu por uma limitação do
sistema de tipos.

Também apareceu um bug de geração de código: `Value(-n)` faz o V emitir
`&-n` em C, e o `cc` recusa com *"lvalue required as unary '&' operand"*. O
compilador do V aceita; a falha só aparece no backend. Resolvido com um
temporário.

### Odin — o alocador como parâmetro do programa

`union { i64, ^FvmArray }` é uma linha, com tag do compilador e `switch v in
valor` dando acesso só à variante certa. E, diferente do V, **aceita
ponteiro** — então aqui não foi preciso o desenho de handle.

O que distingue o Odin é o `context.allocator`: a decisão de memória do
programa fica em **uma linha no `main`**, não espalhada por cada `malloc` como
em C. Aqui ela é uma `virtual.Arena`.

Odin não tem coletor, e a linguagem não finge que tem. A arena só cresce.

`endian.get_u32` devolve `(valor, ok)` — o `ok` obriga a tratar buffer curto,
que em C é um `memcpy` lendo fora dos limites em silêncio.

### Ada — faixas verificadas no ponto do erro

```ada
subtype Stack_Index is Natural range 0 .. Stack_Max - 1;
```

Não é documentação: é verificação. Índice fora da faixa levanta
`Constraint_Error` **no ponto do erro**, não 200 linhas depois.

Isso importa porque é exatamente a classe de erro que derrubou o porte em Nim.
O tipo não impede aquele bug específico, mas transforma erro de índice em falha
localizada em vez de valor errado silencioso. O `main` captura
`Constraint_Error` separadamente de `Vm_Error` justamente para distinguir "o
bytecode está errado" de "o porte está errado".

`Unchecked_Conversion` é **explícito e nomeado**: reinterpretar 8 bytes como
`Integer_64` exige instanciar a conversão e dar nome a ela. Em C é um cast que
passa desapercebido.

Ada também não tem coletor. Mesma arena, mesma consequência.

## O limite dos 9 casos, medido

Os cinco portes passam em **9/9**. E isso não distingue quem recicla memória de
quem nunca libera nada:

* `gc.fasm` cria 20 mil arrays descartados e só confere que `42` é impresso;
* `gc_live.fasm` confere que um array alcançável sobrevive — e numa arena que
  nunca libera, sobreviver é **trivial**.

Os casos verificam **semântica**, não reciclagem. Um porte com coletor perfeito
e um porte sem coletor nenhum são indistinguíveis por eles.

É por isso que `ports/mede.sh` tem uma coluna de **RSS máximo no `gc.fasm`**:
ela mede o que os testes não medem, e é a única evidência de que as três
estratégias de memória da tabela abaixo são de fato diferentes.

| porte | memória | recicla? |
|---|---|---|
| C (referência) | mark & sweep próprio, pilha cinza explícita | sim |
| Rust (referência) | arena com handles + mark & sweep | sim |
| Nim | ORC do runtime | sim |
| D | GC do runtime | sim |
| V | arena (imposta pelo tipo-soma) | **não** |
| Odin | `virtual.Arena` explícita | **não** |
| Ada | arena em `Vector` | **não** |

## A tabela comparativa

Gerada por `bash ports/mede.sh`. Os números de tempo valem **apenas** para
comparação entre os portes, na mesma máquina e na mesma execução — nunca entre
sessões, e nunca contra outra máquina. `docs/BENCH.md` explica por que essa
restrição não é formalidade: neste repositório, dois runners idênticos do
GitHub deram 631 e 411 Mops/s na mesma medição.

Medido em Intel i5-8250U, WSL2, 11 repetições alternadas, mínimo. **Duas
execuções completas**: os mínimos reproduziram dentro de 4%.

| impl | linhas | build | `fib` | RSS no `gc.fasm` | memória |
|---|---|---|---|---|---|
| **C** (ref.) | 1.299 | — | **11,1 ms** | 3.136 KiB | mark & sweep próprio |
| **Rust** (ref.) | 1.221 | — | 15,1 ms | **2.648 KiB** | arena + mark & sweep |
| **Nim** | **255** | **1,2 s** | 13,9 ms | 2.968 KiB | ORC (contagem de referências) |
| **Odin** | 439 | 8,1 s | 14,6 ms | 5.020 KiB | arena, não recicla |
| **D** | 479 | 11,1 s | 17,4 ms | 5.492 KiB | GC de rastreamento |
| **V** | 410 | 9,3 s | 21,2 ms | 8.696 KiB | arena, não recicla |
| **Ada** | 471 | 7,3 s | 15,9 ms | 12.028 KiB | arena, não recicla |

### O que a tabela diz

**O C continua o mais rápido**, e os portes ficam entre 1,25x e 1,9x dele. Para
~400 linhas cada, sem otimização de despacho e sem o `computed goto` que a
implementação em C tem, é um resultado melhor do que eu esperava.

**O Nim fez em 255 linhas** — a quinta parte do C — e ficou 25% mais lento. É a
melhor relação entre esforço e resultado das cinco, e a razão é o `case object`
mais o ORC: os dois pedaços que em C são, somados, a maior parte das 1.299
linhas.

**O custo de iterar varia 9x.** Nim compila em 1,2 s; D em 11,1 s. Isso não
aparece em benchmark de execução e é o número que mais afeta escrever o código:
cada erro de digitação custa 1,2 s em Nim e 11 s em D.

### O achado que eu não esperava: D tem coletor e ficou com os que não têm

Olhe a coluna de RSS agrupada:

| | RSS | estratégia |
|---|---|---|
| Rust, C, Nim | 2.648 – 3.136 KiB | reciclam durante o laço |
| **D** | **5.492 KiB** | **tem GC, e não reciclou durante o laço** |
| Odin, V, Ada | 5.020 – 12.028 KiB | não reciclam nunca |

O D tem um coletor de rastreamento de verdade, e `OP_GC` chama `GC.collect()`.
Ainda assim o pico de RSS dele ficou na faixa dos portes **sem** coletor, 1,8x
acima do Nim.

A explicação está na diferença entre as duas estratégias, e o `gc.fasm` é o
teste que a expõe: ele cria 20 mil arrays que ficam inalcançáveis
**imediatamente após o `POP`**.

* o **ORC do Nim** é contagem de referências: o contador chega a zero no `POP`
  e a memória volta ali, então o pico nunca cresce;
* o **mark & sweep do C** dispara por limiar de bytes alocados, então ele
  coleta **durante** o laço e o pico fica em 3,1 MiB;
* o **GC de rastreamento do D** coleta quando ele decide. O `GC.collect()` do
  `OP_GC` só roda no fim, depois do pico já ter acontecido.

Ou seja: a coluna não mede "tem coletor ou não". Mede **quando** o coletor
roda — e, para um programa que gera lixo em rajada, essa é a diferença que
aparece no pico de memória do processo.

Nenhum dos 9 casos de teste distingue isso. Todos os sete passam.


### Por que a medição espera a máquina estar ociosa

Um jogo rodando em outra janela contamina qualquer número de tempo — por
disputa de núcleo e, principalmente, por *throttling* térmico, que persiste
minutos depois de o jogo fechar.

O script alterna os portes a cada repetição, então carga de fundo
aproximadamente constante atinge todos igualmente e a **comparação** sobrevive
mesmo com os absolutos inflados. A coluna de dispersão é o detector: acima de
~15%, o número serve de ordem de grandeza e não de comparação fina.

Isto está escrito aqui porque aconteceu durante o desenvolvimento, e a primeira
execução foi descartada por isso.
