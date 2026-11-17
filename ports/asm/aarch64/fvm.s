/* fvm.s — o laço de despacho da Forge VM em Assembly ARM64 (AArch64).
 *
 *     aarch64-linux-gnu-as -o fvm.o ports/asm/aarch64/fvm.s
 *     aarch64-linux-gnu-ld -o fvm_aarch64 fvm.o
 *     qemu-aarch64 ./fvm_aarch64 programa.fbc
 *
 * ## O mesmo subconjunto, outra arquitetura
 *
 * Executa exatamente o que o porte x86-64 executa — pilha, aritmética,
 * comparação, saltos, locais e `PRINT` — e produz a mesma saída byte a byte.
 * Sem heap, sem frames, sem libc.
 *
 * Comparar os dois arquivos lado a lado é o conteúdo: a MESMA máquina de pilha
 * em dois conjuntos de instruções, com as diferenças aparecendo onde elas
 * existem de verdade.
 *
 * ## As quatro diferenças que importam
 *
 * **1. Não há `open`, só `openat`.** O ARM64 Linux nasceu depois da limpeza da
 * tabela de syscalls, e as chamadas "clássicas" com caminho relativo não
 * existem. `openat(AT_FDCWD, caminho, O_RDONLY, 0)` é a forma, e `AT_FDCWD`
 * é `-100`.
 *
 * **2. Não há endereçamento relativo ao PC em uma instrução.** No x86-64,
 * `lea rax, [rip + rotulo]` resolve num passo. Aqui são dois: `adrp` carrega a
 * página de 4 KiB e `add` soma o deslocamento dentro dela. É o preço de
 * instruções de largura fixa.
 *
 * **3. Não há instrução de módulo.** `sdiv` dá o quociente, e o resto sai de
 * `msub`: `resto = a - (a/b)*b`, numa instrução de multiplicação-subtração.
 *
 * **4. A comparação não escreve um byte, escreve um registrador.** O x86-64
 * tem `setcc` seguido de `movzx`; o ARM64 tem `cset`, que já entrega 0 ou 1 no
 * registrador inteiro. Uma instrução a menos, e o mesmo resultado.
 *
 * ## A disciplina de registradores, declarada ANTES do código
 *
 * O porte x86-64 deu **segmentation fault** porque uma rotina auxiliar usava
 * `rax`, que era onde o opcode guardava o destino do salto. A lição foi que em
 * Assembly não há convenção que proteja nada: quem escreve é a convenção.
 *
 * Então ela está escrita aqui, e não descoberta depois:
 *
 *     x19   ip        o ponteiro de instrução. NUNCA tocado fora do despacho.
 *     x20   sp        topo da pilha de dados, como ponteiro.
 *     x21   base      início do código (arquivo + 12), para os saltos.
 *     x22   fim       fim do código, para o limite.
 *
 *     x9    opcode    lido pelo despacho, e livre depois.
 *     x10   operando  o imediato do opcode corrente.
 *     x11   a         primeiro operando da pilha.
 *     x12   b         segundo operando.
 *     x13   scratch   endereço da tabela de saltos.
 *
 *     x14   RESERVADO às rotinas auxiliares (`checa1`, `checa2`).
 *
 * `x19`–`x22` são *callee-saved* na AAPCS64, e as auxiliares não os tocam.
 * `x14` existe justamente para as auxiliares não precisarem de nenhum dos
 * registradores que os opcodes usam — é a correção do bug do x86-64, aplicada
 * como regra em vez de como remendo.
 */

    .section .rodata
magic:
    .ascii "FVM1"
msg_uso:
    .ascii "uso: fvm_aarch64 <prog.fbc>\n"
    .equ len_uso, . - msg_uso
msg_abrir:
    .ascii "erro: nao consegui abrir o arquivo\n"
    .equ len_abrir, . - msg_abrir
msg_magic:
    .ascii "erro: magic invalido\n"
    .equ len_magic, . - msg_magic
msg_opcode:
    .ascii "erro: opcode nao suportado neste porte\n"
    .equ len_opcode, . - msg_opcode
msg_pilha:
    .ascii "erro: pilha vazia\n"
    .equ len_pilha, . - msg_pilha
msg_div0:
    .ascii "erro: divisao por zero\n"
    .equ len_div0, . - msg_div0

    .align 3
tabela:
    .quad op_halt, op_push, op_pop, op_dup, op_swap
    .quad op_add, op_sub, op_mul, op_div, op_mod, op_neg
    .quad op_lt, op_le, op_gt, op_ge, op_eq, op_ne
    .quad op_jmp, op_jz, op_jnz
    .quad op_load, op_store, op_reserve
    .quad op_nao_suportado          /* CALL   */
    .quad op_nao_suportado          /* RET    */
    .quad op_print
    .quad op_nao_suportado          /* NEWARR */
    .quad op_nao_suportado          /* AGET   */
    .quad op_nao_suportado          /* ASET   */
    .quad op_nao_suportado          /* ALEN   */
    .quad op_nao_suportado          /* GC     */
    .quad op_nao_suportado          /* CALLI  */

    .section .bss
    .align 4
    .equ TAM_ARQ, 1 << 20
arquivo:
    .skip TAM_ARQ

    .equ PILHA_MAX, 1 << 16
pilha:
    .skip PILHA_MAX * 8

buf_num:
    .skip 32

    .section .text
    .global _start

/* ---------------------------------------------------------------------------
 * `ENDERECO reg, rotulo` — o que o x86-64 faz com `lea reg, [rip + rotulo]`.
 *
 * `adrp` carrega o endereço da PÁGINA de 4 KiB que contém o rótulo, com o
 * deslocamento zerado; o `add` soma a posição dentro dela. As duas instruções
 * juntas são o endereço, e o montador calcula as duas metades.
 * --------------------------------------------------------------------------- */
.macro ENDERECO reg, rotulo
    adrp    \reg, \rotulo
    add     \reg, \reg, :lo12:\rotulo
.endm

/* ---------------------------------------------------------------------------
 * O despacho, replicado em cada opcode.
 *
 * `ldrb w9, [x19], #1` lê o byte E incrementa x19 na mesma instrução --
 * pós-indexação, que o x86-64 faz com `movzx`+`inc`.
 *
 * `br x13` é o salto indireto. Replicá-lo dá ao preditor uma entrada por
 * opcode em vez de uma compartilhada, que é o equivalente do `computed goto`
 * do C.
 * --------------------------------------------------------------------------- */
.macro PROXIMO
    cmp     x19, x22
    b.hs    erro_opcode
    ldrb    w9, [x19], #1
    cmp     x9, #32
    b.hs    erro_opcode
    ENDERECO x13, tabela
    ldr     x13, [x13, x9, lsl #3]
    br      x13
.endm

_start:
    /* argc em [sp], argv[1] em [sp+16] */
    ldr     x0, [sp]
    cmp     x0, #2
    b.ne    erro_uso
    ldr     x1, [sp, #16]           /* caminho */

    /* openat(AT_FDCWD, caminho, O_RDONLY, 0)
     *
     * Não existe `open` no ARM64 Linux: a tabela de syscalls desta
     * arquitetura foi definida depois da limpeza, e só tem a forma com
     * diretório de referência. `AT_FDCWD` é -100. */
    mov     x0, #-100
    mov     x2, #0                  /* O_RDONLY */
    mov     x3, #0
    mov     x8, #56                 /* openat */
    svc     #0
    tbnz    x0, #63, erro_abrir     /* bit de sinal: negativo = erro */
    mov     x23, x0                 /* fd */

    /* read(fd, arquivo, TAM_ARQ) */
    mov     x0, x23
    ENDERECO x1, arquivo
    mov     x2, #TAM_ARQ
    mov     x8, #63                 /* read */
    svc     #0
    tbnz    x0, #63, erro_abrir
    mov     x24, x0                 /* bytes lidos */

    /* close(fd) */
    mov     x0, x23
    mov     x8, #57
    svc     #0

    cmp     x24, #12
    b.lo    erro_magic

    /* O magic, como u32. ARM64 é little-endian na configuração padrão do
     * Linux, e o formato também -- então a leitura de 32 bits acerta. É a
     * mesma coincidência que o porte x86-64 declara: um arquivo em Assembly
     * roda numa arquitetura só, e pode depender dela. */
    ENDERECO x1, arquivo
    ldr     w2, [x1]
    ENDERECO x3, magic
    ldr     w4, [x3]
    cmp     w2, w4
    b.ne    erro_magic

    ldr     w25, [x1, #4]           /* entry */
    ldr     w26, [x1, #8]           /* len   */

    add     x21, x1, #12            /* base do código */
    add     x19, x21, x25           /* ip = base + entry */
    add     x22, x21, x26           /* fim do código */

    ENDERECO x20, pilha             /* sp */

    PROXIMO

/* --------------------------------------------------------------------------- */

op_halt:
    mov     x0, #0
    b       sair

op_push:
    ldr     x10, [x19], #8          /* i64 LE */
    str     x10, [x20], #8
    PROXIMO

op_pop:
    bl      checa1
    sub     x20, x20, #8
    PROXIMO

op_dup:
    bl      checa1
    ldur    x11, [x20, #-8]
    str     x11, [x20], #8
    PROXIMO

op_swap:
    bl      checa2
    ldur    x11, [x20, #-8]
    ldur    x12, [x20, #-16]
    stur    x11, [x20, #-16]
    stur    x12, [x20, #-8]
    PROXIMO

/* `BINOP op` — desempilha dois, aplica, empilha um.
 *
 * O `sub x20, x20, #8` antes das leituras deixa x20 apontando para o slot do
 * RESULTADO, e as duas leituras usam deslocamento negativo a partir dele. É o
 * mesmo arranjo do porte x86-64, para os dois arquivos serem comparáveis
 * linha a linha. */
.macro BINOP instr
    bl      checa2
    sub     x20, x20, #8
    ldur    x11, [x20, #-8]
    ldr     x12, [x20]
    \instr  x11, x11, x12
    stur    x11, [x20, #-8]
    PROXIMO
.endm

op_add: BINOP add
op_sub: BINOP sub
op_mul: BINOP mul

op_div:
    bl      checa2
    sub     x20, x20, #8
    ldr     x12, [x20]
    cbz     x12, erro_div0
    ldur    x11, [x20, #-8]
    sdiv    x11, x11, x12
    stur    x11, [x20, #-8]
    PROXIMO

op_mod:
    bl      checa2
    sub     x20, x20, #8
    ldr     x12, [x20]
    cbz     x12, erro_div0
    ldur    x11, [x20, #-8]
    /* Não há instrução de módulo no ARM64. `sdiv` dá o quociente, e `msub`
     * calcula `x11 - x13*x12` numa instrução -- o resto. */
    sdiv    x13, x11, x12
    msub    x11, x13, x12, x11
    stur    x11, [x20, #-8]
    PROXIMO

op_neg:
    bl      checa1
    ldur    x11, [x20, #-8]
    neg     x11, x11
    stur    x11, [x20, #-8]
    PROXIMO

/* `CMPOP cond` — `cset` entrega 0 ou 1 direto no registrador.
 *
 * O x86-64 precisa de `setcc` num byte mais `movzx` para estender. Aqui é uma
 * instrução, e é a diferença mais visível entre os dois arquivos. */
.macro CMPOP cond
    bl      checa2
    sub     x20, x20, #8
    ldur    x11, [x20, #-8]
    ldr     x12, [x20]
    cmp     x11, x12
    cset    x11, \cond
    stur    x11, [x20, #-8]
    PROXIMO
.endm

op_lt: CMPOP lt
op_le: CMPOP le
op_gt: CMPOP gt
op_ge: CMPOP ge
op_eq: CMPOP eq
op_ne: CMPOP ne

op_jmp:
    ldr     w10, [x19]              /* destino absoluto, i32 LE */
    add     x19, x21, x10
    PROXIMO

op_jz:
    ldr     w10, [x19], #4
    bl      checa1
    sub     x20, x20, #8
    ldr     x11, [x20]
    cbnz    x11, 1f
    add     x19, x21, x10
1:  PROXIMO

op_jnz:
    ldr     w10, [x19], #4
    bl      checa1
    sub     x20, x20, #8
    ldr     x11, [x20]
    cbz     x11, 1f
    add     x19, x21, x10
1:  PROXIMO

/* LOAD e STORE no frame raiz: `base` é zero, porque este porte não implementa
 * CALL. O índice é o slot direto na pilha. */
op_load:
    ldr     w10, [x19], #4
    ENDERECO x13, pilha
    ldr     x11, [x13, x10, lsl #3]
    str     x11, [x20], #8
    PROXIMO

op_store:
    ldr     w10, [x19], #4
    bl      checa1
    sub     x20, x20, #8
    ldr     x11, [x20]
    ENDERECO x13, pilha
    str     x11, [x13, x10, lsl #3]
    PROXIMO

op_reserve:
    ldr     w10, [x19], #4
    cmp     x10, #0
    b.le    2f
1:  str     xzr, [x20], #8
    subs    x10, x10, #1
    b.ne    1b
2:  PROXIMO

op_print:
    bl      checa1
    sub     x20, x20, #8
    ldr     x0, [x20]
    bl      escreve_i64
    PROXIMO

op_nao_suportado:
    b       erro_opcode

/* ---------------------------------------------------------------------------
 * As auxiliares usam SÓ x14, por regra.
 *
 * Esta é a correção do bug do porte x86-64, aplicada como disciplina: lá,
 * `checa1` usava o mesmo registrador em que `op_jnz` guardava o destino do
 * salto, e o `control.fasm` deu segfault.
 *
 * Elas também não tocam `x30` (o endereço de retorno) além do `ret`, porque
 * nenhuma delas chama nada.
 * --------------------------------------------------------------------------- */
checa1:
    ENDERECO x14, pilha
    cmp     x20, x14
    b.ls    erro_pilha
    ret

checa2:
    ENDERECO x14, pilha
    add     x14, x14, #8
    cmp     x20, x14
    b.ls    erro_pilha
    ret

/* ---------------------------------------------------------------------------
 * escreve_i64: o inteiro em x0, em decimal, seguido de \n.
 *
 * `x30` é salvo porque esta rotina é chamada de dentro de um opcode e o
 * `PROXIMO` seguinte não depende dele -- mas o `ret` daqui depende, e um `bl`
 * interno o sobrescreveria. Não há `bl` interno hoje; o salvamento está aqui
 * porque acrescentar um depois é o tipo de mudança que ninguém revisa.
 * --------------------------------------------------------------------------- */
escreve_i64:
    stp     x29, x30, [sp, #-16]!

    ENDERECO x1, buf_num
    add     x1, x1, #31
    mov     w2, #10                 /* \n */
    strb    w2, [x1]
    sub     x1, x1, #1

    mov     x4, #0                  /* 1 se negativo */
    mov     x5, x0
    tbz     x5, #63, 1f
    mov     x4, #1
    neg     x5, x5                  /* para INT64_MIN isto envolve, e a
                                     * divisão SEM sinal abaixo trata a
                                     * magnitude certa */
1:
    mov     x6, #10
2:
    udiv    x7, x5, x6              /* SEM sinal, pelo motivo acima */
    msub    x8, x7, x6, x5          /* resto = x5 - x7*10 */
    add     w8, w8, #'0'
    strb    w8, [x1]
    sub     x1, x1, #1
    mov     x5, x7
    cbnz    x5, 2b

    cbz     x4, 3f
    mov     w2, #'-'
    strb    w2, [x1]
    sub     x1, x1, #1
3:
    add     x1, x1, #1              /* primeiro caractere */

    ENDERECO x2, buf_num
    add     x2, x2, #32
    sub     x2, x2, x1              /* tamanho */

    mov     x0, #1                  /* stdout */
    mov     x8, #64                 /* write */
    svc     #0

    ldp     x29, x30, [sp], #16
    ret

/* --------------------------------------------------------------------------- */

.macro ERRO rotulo, msg, tam, codigo
\rotulo:
    mov     x0, #2                  /* stderr */
    ENDERECO x1, \msg
    mov     x2, #\tam
    mov     x8, #64                 /* write */
    svc     #0
    mov     x0, #\codigo
    b       sair
.endm

ERRO erro_uso,    msg_uso,    len_uso,    64
ERRO erro_abrir,  msg_abrir,  len_abrir,  66
ERRO erro_magic,  msg_magic,  len_magic,  65
ERRO erro_opcode, msg_opcode, len_opcode, 70
ERRO erro_pilha,  msg_pilha,  len_pilha,  70
ERRO erro_div0,   msg_div0,   len_div0,   70

sair:
    mov     x8, #93                 /* exit */
    svc     #0

    .section .note.GNU-stack,"",%progbits
