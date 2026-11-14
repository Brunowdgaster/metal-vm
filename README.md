# metal-vm — a mesma máquina virtual, em C e em Rust

Uma VM de bytecode com montador, desmontador, coletor de lixo e quatro
configurações de execução comparadas sob medição. As duas implementações
produzem **bytecode byte a byte idêntico** e executam o arquivo uma da outra.
Projeto 01 de [14](../poliglota) de um portfólio poliglota.

```
$ fvm run tests/cases/fib.fasm
6765

$ fvm run bench/loop.fasm --stats
450000015000000

--- estatisticas ---
instrucoes      : 390000012
tempo           : 0.949686 s
throughput      : 410.66 Mops/s
coletas de GC   : 0
dispatch        : switch
```

## O problema

Todo interpretador gasta a maior parte do tempo decidindo *qual* instrução
executar, não executando. Essa decisão — o **dispatch** — é um salto indireto
que o preditor de saltos da CPU precisa acertar milhões de vezes por segundo.

Três perguntas, respondidas com número e não com opinião:

1. **Quanto se ganha trocando um `switch` por *computed goto*?** E qual é a
   confiança desse número numa máquina real, com ruído real?
2. **Quanto custa a segurança do Rust** num programa onde cada instrução faz
   acesso indexado a buffer?
3. **O que o modelo de ownership força a mudar** num programa que é, por
   natureza, um grafo de objetos com ciclos e um coletor de lixo?

## Resultado

### Três máquinas, e só parte do resultado reproduz

Mesmo código, mesmas flags, três CPUs. Throughput em Mops/s, melhor execução:

| | `loop` sw → goto | `fib(30)` sw → goto | `alloc` sw → goto | dispersão |
|---|---|---|---|---|
| **i5-8250U** notebook | 398,1 → 445,3 (**+11,8 %**) | 353,7 → 374,9 (+6,0 %) | 119,7 → 123,0 (+2,8 %) | 120–220 % |
| **runner #1** CPU n/i | 631,5 → 566,6 (**−10,3 %**) | 600,9 → 596,9 (−0,7 %) | 236,9 → 243,5 (+2,8 %) | 0,2–2,6 % |
| **runner #2** EPYC 9V74 | 410,7 → 423,4 (**+3,1 %**) | 399,9 → 425,0 (+6,3 %) | 150,2 → 156,3 (+4,1 %) | 0,5–1,9 % |

E o Rust, contra o `switch` do C na mesma máquina:

| | `loop` | `fib(30)` | `alloc` |
|---|---|---|---|
| i5-8250U | 212,9 (**−46,5 %**) | 165,8 (−53,1 %) | 124,1 (+3,7 %) |
| runner #2 | 242,9 (**−40,9 %**) | 218,1 (−45,5 %) | 143,7 (−4,3 %) |

**O que reproduz nas três máquinas:**

- **O Rust seguro custa 41–47 % no dispatch** e 45–53 % em código com muita
  chamada. Dois hardwares bem diferentes, mesma ordem de grandeza: este é o
  resultado sólido do projeto. A causa provável é o teste de limite por
  indexação e a propagação de erro com `?` — *provável* porque separar as duas
  exige `perf`.
- **Computed goto ganha 3–4 % no benchmark de alocação**, nas três.
- **Computed goto ganha ~6 % no `fib`** em duas das três (na terceira, empata).

**O que NÃO reproduz:**

- **O ganho no laço apertado.** +11,8 %, −10,3 % e +3,1 %. O sinal muda com a
  CPU. Não existe um número para publicar aqui, e o honesto é dizer isso.
- **A vantagem do Rust na alocação.** +3,7 % num hardware, −4,3 % no outro: as
  quatro configurações ficam dentro de ±5 % e a ordenação troca. A arena com
  lista de livres **empata** com `malloc`/`free` por objeto; não ganha.

**E uma descoberta de método:** runner compartilhado não é linha de base. Os
dois runners `ubuntu-latest` rodaram binários idênticos e deram 631,5 e
410,7 Mops/s — **54 % de diferença**, porque o GitHub aloca modelos de CPU
diferentes a cada execução. A dispersão *dentro* de uma execução é ótima
(0,2 %), mas *entre* execuções não há comparabilidade. É a razão pela qual o
job de benchmark do CI mede e **não** falha por regressão.

Sobre o laço apertado, a hipótese compatível com a literatura é o preditor de
saltos indiretos: a vantagem do computed goto é dar ao preditor um sítio por
opcode em vez de um compartilhado, o que valia quando os preditores eram
simples (Ertl & Gregg, 2003); preditores modernos tipo ITTAGE acertam o
`switch` quase tão bem, e sobra só o custo de código maior. Rohou, Swamy e
Seznec mediram isso em *Branch Prediction and the Performance of Interpreters
— Don't Trust Folklore* (CGO 2015), e o título resume o que aconteceu aqui.
Confirmar exige `perf stat` contando *branch misses* nas três máquinas — é o
primeiro item do roadmap.

> **Histórico das correções desta seção**, porque o processo é parte do
> resultado: a v1 publicou "+11,8 %" de uma máquina só; a v2, com o runner #1,
> inverteu para "−10,3 %, e esta é a confiável"; a v3 — esta — tem três
> máquinas e conclui que o efeito no laço apertado **não é determinado**. Cada
> correção veio de uma medição nova, não de uma mudança de opinião. O `git log`
> tem as três.

E o coletor, nas duas implementações, com números idênticos:

> **480 MB de lixo reciclados mantendo o heap vivo em 256 KB**, em 1.831
> coletas.

## Compatibilidade entre as implementações

`tests/cross_compat.sh` faz 42 verificações, todas passando:

```
C monta    -> C executa          ✓     Rust monta -> Rust executa    ✓
C monta    -> RUST executa       ✓     Rust monta -> C executa       ✓
os dois .fbc sao byte a byte identicos ✓
os dois desmontadores produzem texto identico ✓
```

A quinta linha é a mais forte: não basta os dois rodarem, os montadores têm de
emitir **exatamente os mesmos bytes**. Qualquer divergência de ordem de
operando, de endianness ou de resolução de rótulo apareceria ali.

## Como rodar

**Linux, macOS ou WSL** — C (requer gcc ou clang, make, cmake):

```bash
bash build.sh            # dispatch por switch
bash build.sh goto       # computed goto (só GCC/Clang)
bash tests/run_tests.sh build-goto/fvm
```

Rust (requer cargo):

```bash
cargo build --release --manifest-path rust/Cargo.toml
bash tests/run_tests.sh rust/target/release/fvm
cargo test --release --manifest-path rust/Cargo.toml   # 9 testes unitários
```

As duas juntas:

```bash
bash tests/cross_compat.sh build-goto/fvm rust/target/release/fvm
REPS=15 bash bench/run_bench.sh build-goto/fvm rust/target/release/fvm
```

**Windows com MSVC** (o script acha o `vcvars64.bat` sozinho):

```powershell
.\build.ps1
.\tests\run_tests.ps1
```

> ⚠️ **Windows 11 com Smart App Control ligado bloqueia o `fvm.exe` compilado
> pelo MSVC.** Ver [Limites conhecidos](#limites-conhecidos) — não é bug do
> projeto, e a causa é interessante. O binário Rust **não** é bloqueado.

CLI, idêntica nas duas implementações:

```
fvm run  prog.fasm [--stats] [--trace]   monta e executa
fvm asm  prog.fasm -o prog.fbc           só monta
fvm exec prog.fbc  [--stats]             executa bytecode
fvm dis  prog.fasm | prog.fbc            desmonta
fvm version                              versão e opções de build
```

A interface ser byte a byte igual não é capricho: é o que permite a
`run_tests.sh`, `cross_compat.sh` e `run_bench.sh` receberem qualquer um dos
binários como argumento. Se a interface divergisse, cada implementação
precisaria do seu harness — e dois harnesses medem duas coisas diferentes.

## Arquitetura

```
  prog.fasm                      prog.fbc
      │                              │
      ▼                              ▼
  ┌────────┐   relocations     ┌───────────┐
  │montador│──────────────────▶│  Chunk    │   bytecode: opcode u8
  └────────┘  (patch de labels)│  code[]   │   + operando little-endian
      │                        └─────┬─────┘
      │  mesma tabela de opcodes     │
      │                              ▼
      │                        ┌───────────┐      ┌──────────────┐
      └───────────────────────▶ │ dispatch  │─────▶│  coletor     │
         (desmontador)          │           │      │ mark & sweep │
                               │ C: switch │      │              │
                               │ C: goto   │◀─────│ raízes = a   │
                               │ Rust:match│      │ pilha inteira│
                               └─────┬─────┘      └──────────────┘
                                     ▼
                            pilha de operandos
                         (locais = slots da pilha)
```

Três decisões estruturais, idênticas nas duas implementações:

1. **Uma única tabela de opcodes** serve ao montador e ao desmontador. Sem
   isso, os dois divergem na primeira instrução nova — é o bug clássico de
   toolchain caseiro, e é o que `cross_compat.sh` detectaria.
2. **Locais são slots da pilha de operandos.** Logo o conjunto de raízes do GC
   é a pilha inteira, e não existe uma segunda estrutura que alguém possa
   esquecer de percorrer.
3. **O corpo das instruções é escrito uma vez por linguagem**, e as variantes
   são escolhidas em tempo de compilação: em C, três macros
   (`VM_BEGIN`/`VM_CASE`/`VM_NEXT`) geram `switch` ou computed goto; em Rust,
   o módulo `stack.rs` troca a representação da pilha. Duas cópias do
   interpretador divergiriam na primeira correção de bug.

Conjunto de instruções, modelo de frames e formato do `.fbc`:
[docs/ISA.md](docs/ISA.md).

## Linguagens e ferramentas

| Ferramenta | Onde é usada | Por que ela, e não outra | Alternativa descartada |
|---|---|---|---|
| **C (C11)** | implementação de referência: VM, GC, montador, CLI | É a língua franca de interpretadores (CPython, Lua, Ruby MRI). Controle total de layout de memória, sem abstração entre o código e o que a CPU executa — pré-requisito para medir dispatch. E só C/C++ dão acesso a *computed goto*. | **C++** para a referência: RAII e templates ajudariam na ergonomia, mas acrescentariam decisões de abstração que confundiriam a medição. Entra como porte futuro. |
| **Computed goto** (extensão GNU) | variante de dispatch em `c/src/vm.c`, sob `-DFVM_USE_GOTO` | É a técnica que o projeto existe para medir: um salto indireto por opcode em vez de um compartilhado, o que dá ao preditor de saltos pares (opcode→próximo opcode) em vez de um único sítio. | **Threaded code** ou JIT: mais ganho, mas mudam a natureza do programa (passam a gerar código) e não isolam a pergunta do dispatch. |
| **Rust 2021 (sem `unsafe`)** | segunda implementação completa | Responde às perguntas 2 e 3: o custo da segurança em código indexado, e o que o ownership força num GC. Zero `unsafe` é a restrição que dá sentido à medição — com `unsafe`, o porte viraria "C com outra sintaxe". | **`Rc<RefCell<T>>`** para os objetos do heap: é contagem de referências, vaza ciclos (um array que contém a si mesmo nunca seria liberado) e põe contadores no caminho quente — exatamente o que o projeto quer evitar. |
| **Arena com handles** (`rust/src/gc.rs`) | representação dos objetos no Rust: `Value::Obj(usize)` indexa um `Vec` | Um grafo com ciclos e dono compartilhado não satisfaz o ownership; a arena resolve sem `unsafe`. E não é concessão: índices são menores que ponteiros, sobrevivem a realocação e permitem compactação — VMs de produção escolhem isso por conta própria. **O Rust empurrou para o design melhor.** | **Ponteiros crus com `unsafe`**: transcreveria o C e não mediria nada sobre Rust. |
| **CMake 3.16+** | build do C, opções `FVM_USE_GOTO` e `FVM_STATS` | Único sistema que cobre gcc, clang e MSVC com o mesmo arquivo — necessário porque o CI compila nos três. Cada variante de medição é uma `option()`, não um fork do código. | **Makefile puro**: exigiria um `Makefile.msvc` separado, e o Windows é um dos alvos. |
| **Cargo** | build, features e testes do Rust | As features (`stats`, `boxed-stack`) são o equivalente direto das `option()` do CMake, e `cargo test` roda os testes unitários sem nenhuma infraestrutura adicional. | — |
| **gcc 15.2** | build de referência no Linux, variante goto, `-Wall -Wextra -Wpedantic` | Achou dois bugs que o MSVC compilou calado, incluindo um comportamento indefinido real. É também o único dos dois que compila computed goto. | — |
| **MSVC 19.5** | build nativo Windows (`build.ps1`) | Compilar com dois compiladores independentes é revisão de código de graça, e garante que o projeto não depende de extensões GNU no caminho padrão. | — |
| **PowerShell** | `build.ps1`, `tests/run_tests.ps1` | Localiza o MSVC via `vswhere` e injeta o ambiente do `vcvars64.bat`, para que quem clona não precise abrir o "x64 Native Tools Prompt". | **.bat**: não consulta o `vswhere` e trata o resultado sem gambiarra. |
| **Bash** | `build.sh`, `run_tests.sh`, `cross_compat.sh`, `run_bench.sh` | O par POSIX dos scripts acima, e o que o CI Linux executa. O harness de benchmark precisa de ponto flutuante, daí `awk` embutido. | **Python** no benchmark: mais legível, mas acrescentaria dependência de runtime a um projeto cujo ponto é não ter nenhuma. |
| **GitHub Actions** | CI: gcc/clang × switch/goto, MSVC, cargo build/test, e o cross-compat | Roda a suíte nos dois compiladores de C, nas duas linguagens, a cada push. O job de benchmark mede mas **não** falha por regressão: a variância de runner compartilhado é grande demais para servir de *gate*. | — |
| **`.fasm` (DSL própria)** | linguagem de entrada dos testes e benchmarks | Escrever bytecode à mão em hexadecimal tornaria os testes ilegíveis. Com montador próprio, cada caso é um programa de 20 linhas que se lê. | **Gerar os testes de um front-end real**: é o projeto P02, que compila para este bytecode. |

## Decisões e trade-offs

### O que o Rust não tem: computed goto

A variante de computed goto **não é implementável em Rust estável e seguro**. Não há `goto`, não há como tomar o endereço de um rótulo, e o
despacho por chamada em cauda (`become`) depende de feature instável. A
alternativa idiomática é um `match`, que o compilador transforma na mesma
tabela de salto que o `switch` do C já usa.

Isso não é lacuna do porte, é **resultado**: quem precisa da técnica em Rust
escreve `unsafe` com uma tabela de ponteiros de função — e aí perde a
propriedade pela qual escolheu Rust. A comparação justa, portanto, é Rust
`match` contra C `switch`, e é a que as tabelas reportam.

E, depois da medição no runner, essa ausência importa menos do que parecia: a
técnica que falta ao Rust é a mesma que **perde 10 %** no hardware limpo.

### O que o Rust impôs: arena em vez de ponteiros

A versão em C encadeia objetos por ponteiro cru (`Obj *next`) e guarda um
`Obj *` dentro do `Value`. Em Rust isso exigiria `unsafe`: um grafo de objetos
com ciclos não satisfaz o modelo de ownership.

A saída foi uma arena — os objetos vivem num `Vec`, e `Value::Obj(id)` carrega
um índice. Consequências medidas e observadas:

- **Empatou no benchmark de alocação** (±5 % em duas máquinas, com a ordenação
  trocando entre elas): reciclar um slot é um `pop` numa lista de livres, contra
  `malloc`/`free` por objeto. Não supera o alocador do sistema — mas compensa
  inteiramente os 41 % que o Rust perde no dispatch, o que já é o resultado
  relevante.
- **Perdeu ergonomia**: `Value::Obj` não se auto-descreve. Imprimir um valor
  passa a exigir o heap em mão (`format_value(heap, v)`), enquanto em C
  `value_print(v)` desreferencia o ponteiro e se basta.
- **Trocou uma classe de bug por outra, menos grave**: um handle para slot
  liberado não é use-after-free, é um acesso a `None`, detectado. Mas se o
  slot tiver sido reutilizado, o handle antigo passa a ver o objeto novo
  (problema ABA). Aqui isso é impossível porque os únicos handles existentes
  estão na pilha, que é o conjunto de raízes — e isso está escrito no código,
  não presumido.

### Os dois bugs reais em C, e o que cada um ensinou

**1. `sizeof(VM)` > 1 MB na pilha nativa.** A primeira versão declarava
`VM vm;` como variável local. A struct tem 65.536 valores de 16 bytes mais
4.096 frames: ~1,1 MB. A thread principal do Windows tem 1 MB de pilha, então
**todos os 7 testes morriam com 0xC00000FD antes da primeira instrução**. Em
Linux, com 8 MB, teria passado — e o bug só apareceria na máquina de outra
pessoa. *Lição: o limite de pilha é a primeira coisa a verificar em qualquer
estrutura grande.* O porte em Rust tropeçaria no mesmo: `Box::new([_; N])`
materializa o array na pilha antes de mover para o heap, e por isso a pilha é
construída via `Vec` e convertida.

**2. Comportamento indefinido em `PUSH`.** O macro era
`vm->stack[vm->sp++] = (v)`. Quando `v` também lê `vm->sp` — exatamente o caso
de `PUSH(PEEK(0))` no `DUP` — o programa lê e modifica o mesmo objeto sem
ponto de sequência: UB. O MSVC compilou em silêncio e o teste passou por sorte
de ordem de avaliação; o gcc apontou com `-Wsequence-point`. *Lição: um segundo
compilador é uma segunda revisão de código, de graça.* **Em Rust esse bug não
é expressável**: a ordem de avaliação é definida, e o teste
`dup_nao_corrompe_a_pilha` existe para registrar isso.

### A hipótese que a medição refutou, e depois confirmou pequena

A pilha do Rust começou como `Vec<Value>`. Hipótese: um slice de tamanho fixo
com `sp` explícito — estrutura idêntica à do C — seria mais rápido, porque o
`Vec` pode realocar e obriga a reler o ponteiro base.

Primeira medição, em sessões diferentes: a versão `boxed` apareceu **30 % mais
lenta**. Segunda medição, lado a lado na mesma sessão: **5 % mais rápida**,
consistente em três rodadas.

O que estava errado era a primeira *comparação*, não a hipótese. Números de
sessões diferentes não são comparáveis nesta máquina. O efeito real existe mas
é pequeno, e a consequência de engenharia foi manter **as duas** atrás da mesma
interface (`rust/src/stack.rs`, feature `boxed-stack`), para que qualquer
pessoa reproduza a comparação numa sessão só.

### Mark & sweep, e não contagem de referências

Contagem de referências exigiria incrementar e decrementar contadores **no
caminho quente**, contaminando a medição que o projeto quer fazer. E vaza
ciclos. Mark & sweep coleta ciclos sem mecanismo extra e cabe em ~110 linhas.

O preço é pausa *stop-the-world* proporcional ao heap vivo. Para um projeto
cujo foco é dispatch, é o preço certo.

Nas duas implementações a marcação é **iterativa, com pilha explícita de
objetos gray**. A versão recursiva é mais curta e estava escrita primeiro; foi
trocada porque um array suficientemente aninhado estouraria a pilha nativa
durante a coleta — e um GC que quebra com dados do usuário não é um GC.

### `vm->sp` fica na memória, não em registrador (C)

Manter `sp` numa variável local é a otimização óbvia. Não foi feita porque o
GC precisa de `vm->sp` correto no momento de cada alocação, o que exigiria
sincronizar antes de todo `NEWARR` — fácil de escrever, fácil de esquecer ao
adicionar uma instrução, e o bug resultante (um objeto vivo coletado) é dos
mais difíceis que existem. Fica como otimização medida, não como padrão.

### Máquina de pilha, não de registradores

Uma VM de registradores executaria `fib(30)` com cerca de 40 % menos
instruções. Pilha foi escolhida porque o decodificador fica trivial e o
montador dispensa alocação de registradores, isolando o custo de dispatch. A
comparação pilha × registradores é um projeto por si.

### Contabilidade de bytes do GC deliberadamente "errada" no Rust

`rust/src/gc.rs` calcula bytes com a fórmula do layout C (`32 + len * 16`), não
com o `size_of` real das structs Rust. É intencional: com a mesma fórmula, as
duas implementações disparam coletas nos mesmos pontos, e os 1.831 ciclos
batem exatamente. Sem isso, o layout menor do Rust daria menos coletas e uma
vantagem que não teria nada a ver com desempenho.

## Limites conhecidos

- **Medir no CI tem limite estrutural.** O modelo de CPU do runner muda a cada
  execução (54 % de diferença de throughput entre duas), então o job serve para
  verificar que o harness roda, não para comparar commits. Comparação válida
  exige as versões rodando na mesma máquina e na mesma sessão — o que o
  `run_bench.sh` força, por receber vários binários e intercalar as execuções.
- **Portes pendentes.** C++, Zig, Assembly (x86-64, ARM64, RISC-V), Nim, Odin,
  D, V e Ada ainda não existem. Com C e Rust prontos, o projeto já responde às
  três perguntas; os demais ampliam a comparação, não a sustentam.
- **A comparação Rust × C não está exaurida.** Três otimizações plausíveis em
  Rust seguro não foram tentadas: `ip` como iterador em vez de índice,
  `chunks_exact` para operandos, e um enum de erro sem alocação em vez de
  `Result<_, String>`. Até isso ser feito, o número honesto é "esta
  implementação em Rust seguro contra esta em C", não "Rust contra C".
- **Smart App Control bloqueia o binário MSVC no Windows 11.** O `fvm.exe`
  compilado pelo MSVC é bloqueado (`Device Guard`, eventos CodeIntegrity
  3077/3118) em qualquer pasta, enquanto um hello-world do mesmo compilador e
  o binário Rust executam normalmente na mesma máquina. A hipótese é a
  heurística de reputação marcar o padrão de um interpretador — loop de
  dispatch com salto indireto sobre memória gravável — como semelhante a
  *packer* ou *shellcode*. Não há mecanismo de exclusão: as saídas são
  desligar o Smart App Control (irreversível sem redefinir o Windows),
  assinar o binário com certificado de reputação, ou compilar no WSL — foi o
  caminho adotado. **O `build.ps1` e o job MSVC do CI continuam válidos**: o
  bloqueio é da política local da máquina, não do código.
- **Sem tipos além de inteiro e array.** Nada de ponto flutuante, string,
  dicionário ou closure. O bytecode foi desenhado para o P02 estender.
- **Pilha de tamanho fixo** (65.536 valores, 4.096 frames). O estouro é
  detectado e reportado nas duas implementações, com teste para isso.
- **Sem JIT.** Deliberado: o projeto mede interpretação.
- **`gray_push` pode falhar silenciosamente sob exaustão de memória** na versão
  em C, durante a coleta: o objeto fica marcado mas seus filhos não são
  percorridos. Acontece só se o `realloc` da pilha de marcação falhar, e está
  anotado no código. A versão em Rust entraria em pânico no lugar — também
  não ideal, e também anotado.

## Roadmap

Em ordem de retorno esperado:

1. **`perf stat`** contando ciclos e *branch misses*, em CPU sem throttling,
   para (a) explicar por que o computed goto inverte de sinal entre as duas
   máquinas e (b) separar as três hipóteses sobre os 44 % do Rust. Virou o item
   mais importante do projeto depois do resultado do runner.
2. **Rust seguro otimizado**: `ip` como iterador, `chunks_exact`, erro sem
   alocação. Mede quanto da diferença era a linguagem e quanto era a escrita.
3. **Arena no C também**, para isolar "arena × malloc" de "C × Rust" no
   benchmark de alocação — hoje as duas variáveis estão confundidas, e é a
   única forma de saber qual delas explica o empate.
4. **Porte para Zig**, que tem `comptime` e alocadores explícitos — o terceiro
   ponto do triângulo entre controle manual e segurança garantida.
5. **Dispatch em Assembly** (x86-64 e ARM64) para o loop quente.
6. **NaN boxing** nas duas implementações: valores de 8 bytes em vez de 16.
7. **Superinstruções** para pares frequentes.
8. **Comparação com CPython, Lua e LuaJIT** na mesma máquina.

## Aprendizados

- **Três máquinas deram três respostas, e a conclusão principal caiu.** O ganho
  de 11,8 % do computed goto, medido com cuidado no notebook, virou −10,3 %
  num runner e +3,1 % em outro. A lição não é "meça mais": é que **um número de
  uma máquina só não é um resultado**, por mais caprichada que seja a
  metodologia. O que sobrou de sólido foi justamente o que reproduziu nas três.
- **Nem a máquina "limpa" serve de base por si.** Dois runners
  `ubuntu-latest` rodaram binários idênticos e deram 631,5 e 410,7 Mops/s — 54 %
  de diferença, porque o modelo de CPU muda a cada execução. Dispersão baixa
  *dentro* de uma execução não garante comparabilidade *entre* execuções, e
  confundir as duas coisas foi o erro da segunda versão deste README.
- **O CI mediu errado em silêncio.** O harness pulava binários ausentes sem
  reclamar, e a tabela saiu plausível com uma linha a menos. Hoje ele falha com
  erro. *Ferramenta de medição que degrada em silêncio é pior que ferramenta
  quebrada.*
- **Um segundo compilador encontrou um UB que a suíte de testes não pegou.**
  Testes verificam o que o código faz; o compilador verifica o que o código
  *significa*.
- **Benchmark errado é pior que nenhum.** Duas tabelas deste projeto afirmaram
  com confiança resultados que a medição seguinte derrubou: uma por ordem de
  execução, outra por comparar sessões diferentes. O que salvou foi reportar a
  dispersão junto com o número.
- **O mínimo é a estatística certa em máquina ruidosa, e isso é verificável:**
  o mínimo variou 0,3 % entre sessões enquanto o máximo variava 3×.
- **O borrow checker não impediu o GC, redirecionou o design** — para arena com
  handles, que empata com `malloc` e apaga a desvantagem do Rust nessa carga.
  Mas cobrou ergonomia em cada operação sobre objeto.
- **Zero `unsafe` tem preço mensurável** (~44 % no dispatch) e benefício
  mensurável (uma classe inteira de bug deixa de ser expressável). O valor do
  projeto é ter os dois números em vez de uma preferência.
- **O conjunto de raízes do GC é decisão de arquitetura, não de
  implementação.** Colocar os locais na pilha de operandos eliminou uma classe
  de bug antes de ela existir, nas duas linguagens.
- **Restrição de ambiente é conteúdo técnico.** O bloqueio do Smart App
  Control ensinou mais sobre política de integridade de código no Windows que
  qualquer tutorial.

## Estado atual

| Parte | Estado |
|---|---|
| VM em C (pilha, frames, 31 instruções) | ✅ completo |
| VM em Rust, zero `unsafe` | ✅ completo |
| Montador com relocations + desmontador (nas duas) | ✅ completo |
| GC mark & sweep iterativo (nas duas) | ✅ completo, contabilidade idêntica |
| Dispatch `switch` e computed goto (C) | ✅ ambos, mesmo corpo de código |
| Pilha `Vec` e `Box<[T]>` (Rust) | ✅ ambas, mesma interface |
| Suíte `.fasm` (7 casos) | ✅ 7/7 em C (gcc e MSVC) e em Rust |
| Testes unitários do Rust | ✅ 9/9 |
| Compatibilidade cruzada de bytecode | ✅ 42/42 verificações |
| Harness de benchmark com dispersão | ✅ |
| CI (gcc/clang × switch/goto, MSVC, cargo, cross-compat, bench) | ✅ 9/9 jobs verdes |
| Portes C++, Zig, Assembly, Nim, Odin, D, V, Ada | ⬜ não iniciados |
| `perf` para explicar a divergência do goto entre CPUs e o gap do Rust | ⬜ pendente |
| Benchmark das 4 configurações em 3 CPUs | ✅ feito; o que reproduz e o que não está separado |

## Licença

MIT.
