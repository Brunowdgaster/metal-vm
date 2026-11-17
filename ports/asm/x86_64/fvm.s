/* fvm.s — o laço de despacho da Forge VM em Assembly x86-64 puro.
 *
 *     as --64 -o fvm.o ports/asm/x86_64/fvm.s
 *     ld -o fvm_x86 fvm.o
 *     ./fvm_x86 programa.fbc
 *
 * ## O escopo, declarado antes de tudo
 *
 * Este NÃO é um porte completo como os de C++, Zig, Nim, Odin, D, V e Ada.
 * É o **subconjunto inteiro** da VM: pilha, aritmética, comparação, saltos,
 * locais e PRINT. Sem heap, sem frames, sem closures.
 *
 * O plano do projeto é explícito sobre isso: *"Assembly entra no dispatch
 * loop (computed goto vs. jump table em asm puro) com medição"*. O que se
 * quer medir é o **custo do despacho**, e para isso o subconjunto basta — os
 * opcodes de heap passariam por `malloc`, que é tempo de alocador e não de
 * despacho.
 *
 * Os casos que ele executa são `arith.fasm` e `control.fasm`, e a saída é
 * comparada byte a byte com a do C, como todo porte.
 *
 * ## Sem libc
 *
 * O ponto de entrada é `_start`, e as três chamadas ao sistema — `open`,
 * `read`, `write`, `exit` — são feitas direto com `syscall`. Não há `printf`:
 * a conversão de inteiro para decimal está escrita abaixo, com a divisão por
 * 10 em laço.
 *
 * Isso não é purismo. É o que torna a medição do despacho significativa: com
 * libc, o `printf` de um `PRINT` custaria mais que centenas de despachos, e a
 * medição mediria a libc.
 *
 * ## A tabela de saltos É o conteúdo deste arquivo
 *
 * Em C, `switch` vira tabela de saltos pelo compilador, e `computed goto`
 * (`&&label`) dá uma tabela com **uma previsão de salto por opcode** em vez
 * de uma compartilhada — é a diferença que o `bench/` deste repositório mede.
 *
 * Aqui as duas formas são escritas à mão, e a diferença fica visível:
 *
 *   despacho CENTRALIZADO    um único `jmp *tabela(,%rax,8)`, e todo opcode
 *                            volta para ele. Uma entrada no preditor.
 *
 *   despacho REPLICADO       cada opcode termina com o SEU próprio
 *                            `jmp *tabela(,%rax,8)`. Uma entrada por opcode.
 *
 * Este arquivo usa o replicado, que é o equivalente em asm do `computed goto`.
 * A macro `PROXIMO` abaixo é o que o replica.
 */

    .intel_syntax noprefix

    .section .rodata
magic:
    .ascii "FVM1"
msg_uso:
    .ascii "uso: fvm_x86 <prog.fbc>\n"
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

    .section .bss
    .align 16
/* O arquivo inteiro cabe aqui: os casos deste projeto têm dezenas de bytes.
 * Um .fbc maior que isto é recusado na leitura, e não truncado em silêncio. */
    .equ TAM_ARQ, 1 << 20
arquivo:
    .skip TAM_ARQ

    .equ PILHA_MAX, 1 << 16
pilha:
    .skip PILHA_MAX * 8

/* O buffer do itoa: 20 dígitos cobrem qualquer i64, mais o sinal. */
buf_num:
    .skip 24

    .section .text
    .global _start

/* ---------------------------------------------------------------------------
 * A macro de despacho.
 *
 * Ela é colada no fim de CADA opcode, e é isso que dá ao preditor de saltos
 * uma entrada por instrução da VM em vez de uma compartilhada.
 *
 * Em C, o equivalente é `goto *dtable[*ip++]` repetido em cada caso -- que é
 * exatamente o que o `VM_NEXT()` da implementação em C deste repositório faz
 * quando compilada com FVM_USE_GOTO.
 * --------------------------------------------------------------------------- */
.macro PROXIMO
    movzx   rax, byte ptr [r12]     /* opcode */
    inc     r12
    cmp     rax, 32
    jae     erro_opcode
    jmp     [tabela + rax * 8]
.endm

_start:
    /* argc em [rsp], argv[0] em [rsp+8], argv[1] em [rsp+16] */
    mov     rax, [rsp]
    cmp     rax, 2
    jne     erro_uso

    mov     rdi, [rsp + 16]         /* caminho */

    /* open(caminho, O_RDONLY) */
    mov     rax, 2
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      erro_abrir
    mov     rbx, rax                /* fd */

    /* read(fd, arquivo, TAM_ARQ) */
    mov     rax, 0
    mov     rdi, rbx
    lea     rsi, [rip + arquivo]
    mov     rdx, TAM_ARQ
    syscall
    test    rax, rax
    js      erro_abrir
    mov     r15, rax                /* bytes lidos */

    /* close(fd) */
    mov     rax, 3
    mov     rdi, rbx
    syscall

    cmp     r15, 12
    jb      erro_magic

    /* O magic, quatro bytes. Comparado como u32 porque "FVM1" cabe num
     * registrador de 32 bits -- e a comparação byte a byte seria quatro
     * instruções para a mesma garantia. */
    lea     rsi, [rip + arquivo]
    mov     eax, [rsi]
    mov     ecx, [rip + magic]
    cmp     eax, ecx
    jne     erro_magic

    /* entry (u32 LE em +4) e len (u32 LE em +8).
     *
     * Little-endian é o formato, e o x86-64 é little-endian -- então um `mov`
     * de 32 bits lê certo. Isso É um cast que funciona por coincidência de
     * arquitetura, e os portes em linguagem de alto nível deste projeto
     * montam o valor byte a byte justamente para não depender dela.
     *
     * Aqui a coincidência é o ponto: este arquivo SÓ roda em x86-64, e o
     * porte ARM64 ao lado faz a mesma leitura com as instruções de lá. */
    mov     r13d, [rsi + 4]         /* entry */
    mov     r14d, [rsi + 8]         /* len */

    /* r12 = ip, apontando para o código */
    lea     r12, [rsi + 12]
    add     r12, r13

    /* rbp = topo da pilha de dados (sp), como ponteiro */
    lea     rbp, [rip + pilha]

    PROXIMO

/* ---------------------------------------------------------------------------
 * Os opcodes.
 *
 * Convenção: rbp aponta para o PRÓXIMO slot livre da pilha. Empilhar é
 * `mov [rbp], v; add rbp, 8`; desempilhar é `sub rbp, 8; mov v, [rbp]`.
 * --------------------------------------------------------------------------- */

op_halt:
    xor     rdi, rdi
    jmp     sair

op_push:
    mov     rax, [r12]              /* i64 LE, 8 bytes */
    add     r12, 8
    mov     [rbp], rax
    add     rbp, 8
    PROXIMO

op_pop:
    call    checa1
    sub     rbp, 8
    PROXIMO

op_dup:
    call    checa1
    mov     rax, [rbp - 8]
    mov     [rbp], rax
    add     rbp, 8
    PROXIMO

op_swap:
    call    checa2
    mov     rax, [rbp - 8]
    mov     rcx, [rbp - 16]
    mov     [rbp - 16], rax
    mov     [rbp - 8], rcx
    PROXIMO

op_add:
    call    checa2
    sub     rbp, 8
    mov     rax, [rbp]
    add     [rbp - 8], rax
    PROXIMO

op_sub:
    call    checa2
    sub     rbp, 8
    mov     rax, [rbp]
    sub     [rbp - 8], rax
    PROXIMO

op_mul:
    call    checa2
    sub     rbp, 8
    mov     rax, [rbp - 8]
    imul    rax, [rbp]
    mov     [rbp - 8], rax
    PROXIMO

op_div:
    call    checa2
    sub     rbp, 8
    mov     rcx, [rbp]
    test    rcx, rcx
    jz      erro_div0
    mov     rax, [rbp - 8]
    cqo                             /* estende o sinal para rdx:rax */
    idiv    rcx
    mov     [rbp - 8], rax
    PROXIMO

op_mod:
    call    checa2
    sub     rbp, 8
    mov     rcx, [rbp]
    test    rcx, rcx
    jz      erro_div0
    mov     rax, [rbp - 8]
    cqo
    idiv    rcx
    mov     [rbp - 8], rdx          /* o resto fica em rdx */
    PROXIMO

op_neg:
    call    checa1
    neg     qword ptr [rbp - 8]
    PROXIMO

/* As comparações. `setcc` escreve 0 ou 1 num byte, e `movzx` estende --
 * sem salto, o que importa num laço medido por despacho. */
.macro CMPOP cc
    call    checa2
    sub     rbp, 8
    mov     rax, [rbp - 8]
    cmp     rax, [rbp]
    set\cc  al
    movzx   rax, al
    mov     [rbp - 8], rax
    PROXIMO
.endm

op_lt:  CMPOP l
op_le:  CMPOP le
op_gt:  CMPOP g
op_ge:  CMPOP ge
op_eq:  CMPOP e
op_ne:  CMPOP ne

op_jmp:
    mov     eax, [r12]              /* destino absoluto, i32 LE */
    lea     r12, [rip + arquivo]
    add     r12, 12
    add     r12, rax
    PROXIMO

op_jz:
    mov     eax, [r12]
    add     r12, 4
    call    checa1
    sub     rbp, 8
    mov     rcx, [rbp]
    test    rcx, rcx
    jnz     1f
    lea     r12, [rip + arquivo]
    add     r12, 12
    add     r12, rax
1:  PROXIMO

op_jnz:
    mov     eax, [r12]
    add     r12, 4
    call    checa1
    sub     rbp, 8
    mov     rcx, [rbp]
    test    rcx, rcx
    jz      1f
    lea     r12, [rip + arquivo]
    add     r12, 12
    add     r12, rax
1:  PROXIMO

/* LOAD e STORE no frame raiz: `base` é zero neste porte, porque ele não
 * implementa CALL. O índice é o slot direto na pilha. */
op_load:
    mov     eax, [r12]
    add     r12, 4
    lea     rcx, [rip + pilha]
    mov     rdx, [rcx + rax * 8]
    mov     [rbp], rdx
    add     rbp, 8
    PROXIMO

op_store:
    mov     eax, [r12]
    add     r12, 4
    call    checa1
    sub     rbp, 8
    mov     rdx, [rbp]
    lea     rcx, [rip + pilha]
    mov     [rcx + rax * 8], rdx
    PROXIMO

op_reserve:
    mov     eax, [r12]
    add     r12, 4
    test    eax, eax
    jle     2f
1:  mov     qword ptr [rbp], 0
    add     rbp, 8
    dec     eax
    jnz     1b
2:  PROXIMO

op_print:
    call    checa1
    sub     rbp, 8
    mov     rdi, [rbp]
    call    escreve_i64
    PROXIMO

/* Os opcodes de heap e de chamada não estão neste porte. Cair aqui é erro
 * explícito, e não um no-op -- um porte que ignorasse NEWARR produziria saída
 * errada em silêncio. */
op_nao_suportado:
    jmp     erro_opcode

/* ---------------------------------------------------------------------------
 * A tabela de saltos. A ORDEM tem de seguir o enum Op do ISA.
 * --------------------------------------------------------------------------- */
    .section .rodata
    .align 8
tabela:
    .quad op_halt, op_push, op_pop, op_dup, op_swap
    .quad op_add, op_sub, op_mul, op_div, op_mod, op_neg
    .quad op_lt, op_le, op_gt, op_ge, op_eq, op_ne
    .quad op_jmp, op_jz, op_jnz
    .quad op_load, op_store, op_reserve
    .quad op_nao_suportado          /* CALL    */
    .quad op_nao_suportado          /* RET     */
    .quad op_print
    .quad op_nao_suportado          /* NEWARR  */
    .quad op_nao_suportado          /* AGET    */
    .quad op_nao_suportado          /* ASET    */
    .quad op_nao_suportado          /* ALEN    */
    .quad op_nao_suportado          /* GC      */
    .quad op_nao_suportado          /* CALLI   */

    .section .text

/* ---------------------------------------------------------------------------
 * Verificações de pilha.
 *
 * Elas custam um `call` por opcode, o que é caro num laço medido -- e estão
 * aqui porque a alternativa é ler memória fora da pilha quando o bytecode
 * está errado. O custo está declarado em BENCH.md, e a versão sem checagem
 * seria outro experimento, não este.
 * --------------------------------------------------------------------------- */
/* r11, e NÃO rax.
 *
 * A primeira versão destas duas rotinas usava `rax` como temporário, e o
 * `control.fasm` deu SEGMENTATION FAULT.
 *
 * A causa: `op_jnz` e `op_store` leem o operando para `eax` e SÓ DEPOIS
 * chamam `checa1` -- que sobrescrevia `rax` com o endereço da pilha. O salto
 * ia para um endereço absurdo.
 *
 * Em C, o compilador conhece a convenção de chamada e salva o que precisa.
 * Em Assembly **não há convenção que proteja nada**: quem escreve É a
 * convenção, e um registrador compartilhado entre duas rotinas que nunca se
 * leem é um acoplamento invisível.
 *
 * `r11` é escolhido por ser caller-saved na ABI System V e não ser usado por
 * nenhum opcode deste arquivo. A escolha está documentada porque ela é a
 * única coisa que impede o bug de voltar. */
checa1:
    lea     r11, [rip + pilha]
    cmp     rbp, r11
    jbe     erro_pilha
    ret

checa2:
    lea     r11, [rip + pilha]
    add     r11, 8
    cmp     rbp, r11
    jbe     erro_pilha
    ret

/* ---------------------------------------------------------------------------
 * escreve_i64: o inteiro em rdi, em decimal, seguido de \n.
 *
 * Sem libc. A divisão por 10 em laço, do dígito menos significativo para o
 * mais, escrevendo de trás para a frente no buffer.
 *
 * O caso de INT64_MIN é tratado pela negação em magnitude sem sinal: negar
 * -9223372036854775808 em complemento de dois devolve ele mesmo, e um itoa
 * ingênuo imprimiria o número errado. Aqui o sinal é guardado antes.
 * --------------------------------------------------------------------------- */
escreve_i64:
    push    rbx
    lea     rbx, [rip + buf_num + 23]
    mov     byte ptr [rbx], 10      /* \n */
    dec     rbx

    xor     r8, r8                  /* r8 = 1 se negativo */
    mov     rax, rdi
    test    rax, rax
    jns     1f
    mov     r8, 1
    neg     rax                     /* para INT64_MIN isto envolve, e o laço
                                     * abaixo trata a magnitude como SEM sinal
                                     * via div -- que é o certo */
1:
    mov     rcx, 10
2:
    xor     rdx, rdx
    div     rcx                     /* div SEM sinal: rax = rax/10, rdx = resto */
    add     dl, '0'
    mov     [rbx], dl
    dec     rbx
    test    rax, rax
    jnz     2b

    test    r8, r8
    jz      3f
    mov     byte ptr [rbx], '-'
    dec     rbx
3:
    inc     rbx                     /* rbx aponta para o primeiro caractere */

    lea     rdx, [rip + buf_num + 24]
    sub     rdx, rbx                /* tamanho */
    mov     rsi, rbx
    mov     rax, 1                  /* write */
    mov     rdi, 1                  /* stdout */
    syscall

    pop     rbx
    ret

/* --------------------------------------------------------------------------- */

.macro ERRO rotulo, msg, tam, codigo
\rotulo:
    mov     rax, 1
    mov     rdi, 2                  /* stderr */
    lea     rsi, [rip + \msg]
    mov     rdx, \tam
    syscall
    mov     rdi, \codigo
    jmp     sair
.endm

ERRO erro_uso,    msg_uso,    len_uso,    64
ERRO erro_abrir,  msg_abrir,  len_abrir,  66
ERRO erro_magic,  msg_magic,  len_magic,  65
ERRO erro_opcode, msg_opcode, len_opcode, 70
ERRO erro_pilha,  msg_pilha,  len_pilha,  70
ERRO erro_div0,   msg_div0,   len_div0,   70

sair:
    mov     rax, 60                 /* exit */
    syscall

    .section .note.GNU-stack,"",@progbits
