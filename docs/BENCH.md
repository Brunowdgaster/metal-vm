# Medições

## Ambiente

| | |
|---|---|
| CPU | Intel Core i5-8250U @ 1.60 GHz (4 núcleos / 8 threads, classe U, com throttling) |
| SO | Ubuntu 26.04 sob WSL2, em Windows 11 Home |
| Compiladores | gcc 15.2.0 (`-O3`), rustc 1.93.1 (`opt-level=3`, sem LTO) |
| Data | 2026-11-13 |
| Carga | `load average` entre 0,9 e 1,0 nas rodadas reportadas |

As quatro configurações medidas:

| rótulo | o que é |
|---|---|
| `build-linux-switch` | C, dispatch por `switch` |
| `build-linux-goto` | C, dispatch por computed goto |
| `fvm-rust-vec` | Rust, pilha de operandos em `Vec<Value>` (padrão) |
| `fvm-rust-boxed` | Rust, pilha em `Box<[Value]>` + `sp` explícito (`--features boxed-stack`) |

## Metodologia

- `REPS=15` a `REPS=21` execuções por combinação, mais uma rodada de
  aquecimento descartada.
- **Melhor** tempo, não a média.
- Execuções **intercaladas** (rodada externa = repetição, interna = binário):
  medir 15× o binário A e depois 15× o B atribui a cada um a deriva de
  frequência que ocorra no meio.
- `disp_pct` = (pior − melhor) / melhor, reportado em toda tabela.

Reproduzir:

```bash
bash build.sh switch
bash build.sh goto
cargo build --release --manifest-path rust/Cargo.toml --target-dir rust/target-vec
cargo build --release --manifest-path rust/Cargo.toml --features boxed-stack --target-dir rust/target-boxed
REPS=15 bash bench/run_bench.sh build-switch/fvm build-goto/fvm \
    rust/target-vec/release/fvm rust/target-boxed/release/fvm
```

### Por que o mínimo, com evidência

A dispersão deste ambiente é brutal: 120 % a 220 %. Isso faz a média inútil.
O mínimo, porém, **reproduz**. Três sessões independentes do mesmo programa
(`loop`, 390 M instruções), melhor tempo em segundos:

| configuração | sessão 1 | sessão 2 | sessão 3 | variação do mínimo |
|---|---|---|---|---|
| C switch | 0,976776 | 0,978438 | 0,979730 | **0,3 %** |
| Rust boxed | 1,770221 | 1,782587 | 1,739665 | **2,5 %** |
| Rust vec | 2,151671 | 1,858531 | 1,832222 | 17 % |

O mínimo do C variou 0,3 % entre sessões enquanto o máximo variava 2–3×. É a
justificativa empírica de usar o mínimo, e não um argumento de autoridade.

A linha do `Rust vec` mostra o limite do método: a sessão 1 rodou com
`load average 4,87` (logo após o boot do Windows) e contaminou até o mínimo.
As sessões 2 e 3, com carga ~1,0, concordam dentro de 1,5 %. **Só as rodadas
com carga baixa entram nas tabelas abaixo.**

## Resultado 1: dispatch (`loop`, 390 M instruções)

| configuração | tempo (s) | Mops/s | relativo ao C switch |
|---|---|---|---|
| C, computed goto | 0,875731 | **445,3** | +11,8 % |
| C, switch | 0,979730 | 398,1 | — |
| Rust, boxed stack | 1,739665 | 224,2 | −43,7 % |
| Rust, Vec stack | 1,832222 | 212,9 | −46,5 % |

> ⚠️ **A linha do computed goto só vale para esta máquina.** Num runner
> dedicado o sinal se inverte (−10,3 %), com dispersão de 0,2 %. Ver
> [A medição que inverteu a conclusão](#a-medição-que-inverteu-a-conclusão-runner-do-github).
> A comparação Rust × C, por ser uma razão entre dois binários medidos juntos
> na mesma máquina, não é afetada por isso.

## Resultado 2: chamadas de função (`fib(30)`, 26,9 M instruções)

| configuração | tempo (s) | Mops/s | relativo ao C switch |
|---|---|---|---|
| C, computed goto | 0,071814 | **374,9** | +6,0 % |
| C, switch | 0,076134 | 353,7 | — |
| Rust, boxed stack | 0,152036 | 177,1 | −49,9 % |
| Rust, Vec stack | 0,162359 | 165,8 | −53,1 % |

## Resultado 3: alocação e GC (`alloc`, 3 M arrays descartados)

| configuração | tempo (s) | Mops/s | relativo ao C switch |
|---|---|---|---|
| Rust, boxed stack | 0,285437 | **126,1** | +5,3 % |
| Rust, Vec stack | 0,290089 | 124,1 | +3,7 % |
| C, computed goto | 0,292738 | 123,0 | +2,8 % |
| C, switch | 0,300645 | 119,7 | — |

**A ordenação se inverte.** Quando a carga é dominada por alocação, as quatro
configurações ficam dentro de 5 % e o Rust fica na frente.

A explicação é estrutural: a versão em C faz `malloc` e `free` por objeto; a
versão em Rust mantém uma arena de slots com lista de livres, então reciclar
um objeto é um `pop` num `Vec<usize>`. Com 1.831 coletas e 3 M de objetos, a
diferença entre "chamar o alocador do sistema" e "reaproveitar um índice"
compensa inteiramente a desvantagem do Rust no dispatch.

Isso **não** é mérito da linguagem: é mérito do design de arena — que o Rust
tornou obrigatório (ver `rust/src/gc.rs`) e que nada impedia de adotar em C.
A conclusão correta é "arena vence malloc por objeto", e o C deveria adotar a
mesma estratégia. Está no roadmap.

## A medição que inverteu a conclusão: runner do GitHub

O primeiro CI rodou o mesmo `bench/run_bench.sh` num runner `ubuntu-latest`,
que é uma máquina **dedicada e ociosa** — o oposto do notebook. O resultado
desmonta o headline anterior deste arquivo:

| configuração | programa | tempo (s) | Mops/s | disp_pct |
|---|---|---|---|---|
| C, switch | loop | 0,617553 | **631,5** | **0,2 %** |
| C, computed goto | loop | 0,688374 | 566,6 | 2,6 % |
| C, switch | fib | 0,044805 | 600,9 | 2,0 % |
| C, computed goto | fib | 0,045106 | 596,9 | 2,3 % |
| C, switch | alloc | 0,151957 | 236,9 | 1,1 % |
| C, computed goto | alloc | 0,147816 | **243,5** | 0,9 % |

**No runner, o computed goto é 10 % mais LENTO no `loop`**, empata no `fib`
(0,7 % de diferença, dentro da dispersão) e ganha 2,8 % no `alloc`.

E olhe a coluna `disp_pct`: **0,2 % a 2,6 %**, contra 120 % a 220 % no
notebook. Esta medição é incomparavelmente mais confiável que todas as
anteriores.

### A conclusão honesta

**O ganho do computed goto não é uma propriedade da técnica: depende do
hardware.** Mesmo código, mesmo compilador, mesmas flags:

| máquina | dispersão | computed goto no `loop` |
|---|---|---|
| i5-8250U (notebook, classe U, com throttling, carga ~1,0) | 120–220 % | **+11,8 %** |
| runner `ubuntu-latest` (dedicado, ocioso) | 0,2–2,6 % | **−10,3 %** |

A explicação provável está no preditor de saltos indiretos. A vantagem do
computed goto sempre foi dar ao preditor um sítio por opcode em vez de um
compartilhado. Isso valia quando os preditores eram simples — é o resultado
clássico de Ertl & Gregg, *The Structure and Performance of Efficient
Interpreters* (2003). Preditores modernos do tipo ITTAGE correlacionam um
único salto indireto com um histórico longo e acertam o `switch` quase tão bem,
e aí o custo que sobra para o computed goto — código maior, mais pressão no
cache de instruções — passa a dominar. Rohou, Swamy e Seznec descreveram
exatamente isso em *Branch Prediction and the Performance of Interpreters —
Don't Trust Folklore* (CGO 2015), e o nome do artigo resume o que aconteceu
aqui.

Não afirmo que o mecanismo é esse: afirmo que **duas máquinas deram sinais
opostos**, que a medição da máquina limpa é a confiável, e que a hipótese do
preditor é compatível com a literatura. Separar isso exige `perf stat`
contando *branch misses* nas duas — é o primeiro item do roadmap, agora por um
motivo bem mais forte que antes.

### O que isso ensina sobre o projeto

A pergunta original era "quanto se ganha com computed goto". A resposta medida
é "depende da CPU, e no hardware moderno pode ser negativo". Isso é mais
valioso que um número: é a razão pela qual este arquivo reporta dispersão,
identifica a máquina e guarda as medições descartadas em vez de publicar só a
tabela que ficou bonita.

O `README.md` foi corrigido para dizer isso. A versão anterior afirmava
"+11,8 %" como resultado do projeto — era o resultado de **uma** máquina
ruidosa, apresentado como se fosse geral.

## Reprodução independente (no notebook)

Sessão posterior, depois de `cargo fmt` e das correções do `clippy` (nenhuma
delas no caminho quente), com `load average 1,17`:

| configuração | `loop` | `fib(30)` | `alloc` |
|---|---|---|---|
| C, computed goto | 434,7 | 369,2 | 121,8 |
| C, switch | 393,9 | 324,3 | 116,6 |
| Rust, boxed | 220,3 | 173,4 | **126,1** |
| Rust, Vec | 205,9 | 164,6 | 123,7 |

Todos os valores caem dentro de 1–8 % das tabelas acima, **com a ordenação
preservada em todas as três cargas**, incluindo a inversão no `alloc`. É o que
dá confiança nas conclusões apesar da dispersão por execução.

## Paridade de contabilidade do GC

As duas implementações, rodando `bench/alloc.fasm`:

```
C (computed goto):  coletas: 1831  bytes liberados: 479868480  pico: 262080
Rust (boxed):       coletas: 1831  bytes liberados: 479868480  pico: 262080
```

Idênticos nos três números. Não é coincidência: `rust/src/gc.rs` usa
deliberadamente a **fórmula de bytes do layout C** (`32 + len * 16`) em vez do
`size_of` real das structs Rust, para que as duas disparem coletas nos mesmos
pontos. Sem isso, o layout menor do Rust daria menos coletas e uma vantagem
que não teria nada a ver com desempenho.

> **480 MB de lixo reciclados mantendo o heap vivo em 256 KB**, nas duas
> implementações.

E o contrateste, `tests/cases/gc_live.fasm` (100 arrays alcançáveis, `GC`
forçado): `coletas: 1, bytes liberados: 0`. Zero bytes é o resultado correto —
nada do que estava alcançável foi coletado. Um GC que libera 1 byte aqui está
errado, e o teste falha.

## A hipótese que a medição refutou (duas vezes)

Vale registrar porque é o método em funcionamento, não a conclusão.

**Hipótese:** trocar a pilha de `Vec<Value>` por `Box<[Value]>` + `sp`
explícito deixaria o Rust próximo do C, porque o `Vec` pode realocar e obriga
o compilador a reler o ponteiro base.

**Primeira medição (sessões diferentes):** `boxed` apareceu 30 % **mais
lento** (162 contra 230 Mops/s). Conclusão aparente: hipótese errada, o teste
de limite do slice custa mais do que o `Vec` economiza.

**Segunda medição (mesma sessão, lado a lado):** `boxed` ficou 5 % mais
rápido, consistentemente, em três rodadas.

**O que estava errado era a primeira comparação**, não a hipótese: números de
sessões diferentes não são comparáveis nesta máquina. O efeito real existe mas
é pequeno (~5 %), muito menor que os 40 % que a primeira leitura sugeria em
qualquer das direções.

A consequência de engenharia foi manter **as duas** implementações atrás da
mesma interface (`rust/src/stack.rs`, feature `boxed-stack`), para que a
comparação seja reproduzível por qualquer pessoa, numa sessão só.

## Por que o Rust seguro perdeu ~44 % no dispatch

Hipóteses, em ordem de suspeita, **não medidas individualmente** — separá-las
exige `perf` contando ciclos e *branch misses*, que é o próximo item do
roadmap. Listadas para que ninguém confunda hipótese com resultado:

1. **Teste de limite por indexação.** Cada leitura de bytecode (`code.get(ip)`,
   `code[ip..ip+8]`) e cada acesso à pilha carrega uma verificação que o C não
   paga. O compilador não consegue eliminá-la porque não sabe que
   `stack.len() == STACK_MAX`.
2. **Propagação de erro com `?`.** Cada operação devolve `Result`, e o `?`
   insere um desvio após cada chamada auxiliar. Em C, o erro é um `return`
   direto de dentro do macro.
3. **Ausência de computed goto.** O C tem essa variante; o Rust seguro não tem
   equivalente. Mas como a variante só ganha em parte do hardware (ver acima),
   isso deixou de ser desvantagem relevante do Rust: a comparação justa sempre
   foi contra o `switch`, e é dela que vêm os ~44 %.

O que **não** foi tentado, e provavelmente fecharia parte da diferença, sem
`unsafe`: manter `ip` como iterador em vez de índice, usar `chunks_exact` para
os operandos, e trocar `Result<_, String>` por um enum de erro sem alocação.
Afirmar "Rust é 44 % mais lento" sem essas tentativas seria desonesto — o
medido é **esta** implementação em Rust seguro contra **esta** em C.

Fechar o resto exigiria `get_unchecked`, isto é, `unsafe` — e aí se perde a
propriedade pela qual se escolheu Rust. Esse é o trade-off que o projeto mede.

## Compilação e tamanho

| | C (gcc, CMake) | Rust (cargo) |
|---|---|---|
| configure (uma vez) | 8,67 s | — |
| build limpo | 2,33 s | 7,52 s |
| rebuild de 1 arquivo | 3,15 s | 7,46 s |
| binário | 34.672 bytes | 619.616 bytes (488.280 com `strip`) |

Dois pontos:

- **O Rust não tem rebuild incremental útil aqui.** A unidade de compilação é
  a crate inteira: tocar um arquivo recompila tudo (7,46 s contra 7,52 s do
  build limpo). Em C, cada `.c` é uma unidade independente — mas com só 5
  arquivos e `-j`, o ganho prático também desaparece (3,15 s contra 2,33 s).
  A diferença aparece em projetos grandes, nas duas direções.
- **O binário Rust é 18× maior** porque linka estaticamente a biblioteca padrão,
  incluindo formatação, *backtrace* e maquinário de pânico. `opt-level="z"`,
  `panic="abort"` e `strip` reduziriam muito; não foram usados porque mudariam
  o código gerado e invalidariam a comparação de desempenho.

## Linhas de código

Contagem sem comentários, linhas vazias nem módulos de teste:

| | C | Rust |
|---|---|---|
| total do projeto | 1.158 | 1.205 |
| descontando a segunda implementação de pilha (sem equivalente em C) | 1.158 | **1.053** |

Rust escreveu **9 % menos código** para a mesma funcionalidade — com todos os
erros tratados como valores, zero `unsafe` e uma camada extra de abstração na
pilha. O enum `Value` substitui a dupla `struct`+`union` manual do C, o
`Result` substitui a convenção de código de retorno, e o `Vec` substitui as
rotinas de crescimento de buffer escritas à mão em `value.c`.

## Throughput em perspectiva

Comparar com CPython, Lua ou LuaJIT exigiria rodar os três na **mesma**
máquina, com programas equivalentes. Qualquer número citado de memória aqui
seria chute, e chute em README de benchmark é pior que silêncio. Essa
comparação está no roadmap como item próprio.

O que separa esta VM de um interpretador de produção são três técnicas que ela
ainda não usa:

1. **NaN boxing** — valores de 8 bytes em vez de 16, teste de tipo por expoente;
2. **superinstruções** para pares frequentes (`LOAD`+`PUSH`+`ADD`);
3. **cache do topo da pilha em registrador**, evitando ida e volta à memória.
