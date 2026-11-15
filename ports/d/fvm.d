/**
 * fvm.d — porte do núcleo mínimo da Forge VM para D.
 *
 * ## O que este arquivo é
 *
 * Um **porte**: executa `.fbc` montado pela implementação em C e tem de
 * produzir saída byte a byte idêntica nos 9 casos de `tests/cases/`. Sem
 * montador, sem `--stats`, sem desmontador. Ver `ports/README.md`.
 *
 * ## O que o D deu de graça, e é bastante
 *
 * **`SumType` com `match` exaustivo.** Em C, `Value` é uma struct com uma tag
 * e uma união, e nada impede ler `as.o` de um valor cuja tag é `VAL_INT` — é
 * convenção mantida por disciplina. Aqui, `match` sobre um `SumType` **não
 * compila** se faltar um caso, e não há como acessar a variante errada.
 *
 * É a mesma garantia que o Gleam dá no p03-otp-mesh, numa linguagem de
 * sistemas com ponteiros e sem runtime obrigatório.
 *
 * **Coletor de lixo.** A implementação em C tem mark & sweep com pilha cinza
 * explícita, lista encadeada de objetos vivos e contabilidade de bytes.
 * Aqui, `new FvmArray` e o GC do D resolve — inclusive o caso difícil do
 * `gc_live.fasm`, em que 100 arrays ficam vivos dentro de outro.
 *
 * **`std.bitmanip.littleEndianToNative`.** Decodificar o cabeçalho e os
 * operandos do `.fbc` é uma linha por tamanho, com o endianness explícito no
 * nome da função. Em C são três funções escritas à mão.
 *
 * ## O que o D não evitou
 *
 * Nada no sistema de tipos impede confundir os **índices** da máquina de
 * pilha: `sp`, `base` e `ip` são todos `size_t`/`int`, e trocar um pelo outro
 * compila. Foi exatamente aí que o porte em Nim errou primeiro.
 *
 * ## Modo de compilação
 *
 * Compilado com `ldc2 -O3 --release`. `--release` desliga as verificações de
 * limites de array — e isso é deliberado para o ensaio comparativo: o número
 * de desempenho tem de ser do modo que alguém usaria de verdade. As
 * verificações do bytecode (limites de AGET, pilha vazia, etc.) são do
 * programa e continuam ativas.
 *
 * uso: fvm_d <prog.fbc>
 */
module fvm;

import std.bitmanip : littleEndianToNative;
import std.file : read;
import std.format : format;
import std.stdio : stderr, writeln;
import std.sumtype : SumType, match;

enum Op : ubyte
{
    halt = 0,
    push,
    pop,
    dup,
    swap,
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    jmp,
    jz,
    jnz,
    load,
    store,
    reserve,
    call,
    ret,
    print,
    newarr,
    aget,
    aset,
    alen,
    gc,
    calli
}

enum StackMax = 1 << 16;
enum FramesMax = 1024;

/// Array da VM. Classe final: o GC do D cuida do ciclo de vida, e `final`
/// evita a indireção de despacho virtual que não é usada aqui.
final class FvmArray
{
    Value[] items;

    this(size_t n)
    {
        // `Value[]` novo já vem com os elementos no estado .init, mas a VM em
        // C inicializa explicitamente com INT_VAL(0) -- replicado para que o
        // comportamento observável seja o mesmo e não dependa de qual é o
        // `.init` de um SumType.
        items.length = n;
        foreach (ref it; items)
            it = Value(0L);
    }
}

/// A tag e a união numa só declaração, com exaustividade verificada pelo
/// compilador em todo `match`.
alias Value = SumType!(long, FvmArray);

class VmException : Exception
{
    this(string msg)
    {
        super(msg);
    }
}

void erro(string msg)
{
    throw new VmException(msg);
}

/// Formatação do PRINT. Casa com `value_print` do C: inteiro em decimal,
/// array como `[1, 2, 3]`, `nil` para referência nula.
string formata(Value v)
{
    return v.match!((long n) => format("%d", n), (FvmArray a) {
        if (a is null)
            return "nil";
        string s = "[";
        foreach (i, it; a.items)
        {
            if (i)
                s ~= ", ";
            s ~= formata(it);
        }
        return s ~ "]";
    });
}

long comoInteiro(Value v)
{
    return v.match!((long n) => n, (FvmArray _) {
        erro("esperava inteiro, veio array");
        return 0L;
    });
}

FvmArray comoArray(Value v)
{
    return v.match!((long _) {
        erro("esperava array, veio inteiro");
        return cast(FvmArray) null;
    }, (FvmArray a) {
        if (a is null)
            erro("array nulo");
        return a;
    });
}

struct Frame
{
    long retIp;
    long base;
}

struct Chunk
{
    ubyte[] code;
    size_t entry;
}

/**
 * Lê o `.fbc`:
 *
 *   offset 0  : "FVM1"   4 bytes
 *   offset 4  : entry     u32 little-endian
 *   offset 8  : len       u32 little-endian
 *   offset 12 : code[len]
 */
Chunk carrega(string caminho)
{
    auto bruto = cast(ubyte[]) read(caminho);

    if (bruto.length < 12)
        erro("arquivo curto demais para ser um .fbc");

    if (bruto[0 .. 4] != cast(ubyte[]) "FVM1")
        erro("magic invalido: esperava FVM1");

    ubyte[4] b4 = bruto[4 .. 8];
    const entry = littleEndianToNative!uint(b4);
    b4 = bruto[8 .. 12];
    const len = littleEndianToNative!uint(b4);

    if (12 + len > bruto.length)
        erro(format("len do cabecalho (%d) maior que o arquivo", len));
    if (entry > len)
        erro("entry fora do codigo");

    Chunk c;
    c.code = bruto[12 .. 12 + len];
    c.entry = entry;
    return c;
}

void executa(Chunk chunk)
{
    auto pilha = new Value[](StackMax);
    long sp = 0;
    auto frames = new Frame[](FramesMax);
    long fp = 0;
    long ip = cast(long) chunk.entry;
    long base = 0;

    const code = chunk.code;

    // Funções aninhadas, e não templates/mixins: o porte em Nim errou
    // justamente num template que substituía texto e avaliava o índice da
    // pilha antes do valor. Função tem ordem de avaliação definida pela
    // passagem de parâmetro, e o bug não tem como acontecer.
    void empilha(Value v)
    {
        if (sp >= StackMax)
            erro("estouro da pilha de dados");
        pilha[sp++] = v;
    }

    Value desempilha()
    {
        if (sp <= 0)
            erro("pilha vazia");
        return pilha[--sp];
    }

    void precisa(long n)
    {
        if (sp < n)
            erro(format("pilha com menos de %d valores", n));
    }

    ubyte leU8()
    {
        return code[ip++];
    }

    int leI32()
    {
        ubyte[4] b = code[ip .. ip + 4];
        ip += 4;
        return littleEndianToNative!int(b);
    }

    long leI64()
    {
        ubyte[8] b = code[ip .. ip + 8];
        ip += 8;
        return littleEndianToNative!long(b);
    }

    // Frame raiz empilhado antes da primeira instrução, como em C, para que
    // LOAD/STORE/RET funcionem no topo sem caso especial no laço quente.
    frames[0] = Frame(-1, 0);
    fp = 1;

    for (;;)
    {
        if (ip < 0 || ip >= cast(long) code.length)
            erro("ip fora do codigo");

        const op = cast(Op) code[ip++];

        switch (op)
        {
        case Op.halt:
            return;

        case Op.push:
            empilha(Value(leI64()));
            break;

        case Op.pop:
            precisa(1);
            sp--;
            break;

        case Op.dup:
            precisa(1);
            empilha(pilha[sp - 1]);
            break;

        case Op.swap:
            precisa(2);
            const t = pilha[sp - 1];
            pilha[sp - 1] = pilha[sp - 2];
            pilha[sp - 2] = t;
            break;

        case Op.add:
        case Op.sub:
        case Op.mul:
        case Op.div:
        case Op.mod:
        case Op.lt:
        case Op.le:
        case Op.gt:
        case Op.ge:
        case Op.eq:
        case Op.ne:
            precisa(2);
            const b = comoInteiro(desempilha());
            const a = comoInteiro(desempilha());
            long r;
            // `switch` com `default`, e NAO `final switch`.
            //
            // `final switch` exige todos os membros do enum e recusou este
            // bloco, que trata so o subconjunto aritmetico -- fazendo
            // exatamente o que promete. O `default` abaixo e inalcancavel
            // pelo `case` externo, mas o compilador nao sabe disso, e
            // `assert(0)` seria uma mentira silenciosa em release: `erro`
            // falha alto.
            switch (op)
            {
            case Op.add:
                r = a + b;
                break;
            case Op.sub:
                r = a - b;
                break;
            case Op.mul:
                r = a * b;
                break;
            case Op.div:
                if (b == 0)
                    erro("divisao por zero");
                r = a / b;
                break;
            case Op.mod:
                if (b == 0)
                    erro("modulo por zero");
                r = a % b;
                break;
            case Op.lt:
                r = a < b ? 1 : 0;
                break;
            case Op.le:
                r = a <= b ? 1 : 0;
                break;
            case Op.gt:
                r = a > b ? 1 : 0;
                break;
            case Op.ge:
                r = a >= b ? 1 : 0;
                break;
            case Op.eq:
                r = a == b ? 1 : 0;
                break;
            case Op.ne:
                r = a != b ? 1 : 0;
                break;
            default:
                erro("opcode binario inesperado");
                r = 0;
            }
            empilha(Value(r));
            break;

        case Op.neg:
            precisa(1);
            empilha(Value(-comoInteiro(desempilha())));
            break;

        case Op.jmp:
            ip = leI32();
            break;

        case Op.jz:
            {
                const dest = leI32();
                precisa(1);
                if (comoInteiro(desempilha()) == 0)
                    ip = dest;
                break;
            }

        case Op.jnz:
            {
                const dest = leI32();
                precisa(1);
                if (comoInteiro(desempilha()) != 0)
                    ip = dest;
                break;
            }

        case Op.load:
            {
                const slot = leI32();
                const idx = base + slot;
                if (slot < 0 || idx >= sp)
                    erro("LOAD de slot inexistente");
                empilha(pilha[idx]);
                break;
            }

        case Op.store:
            {
                const slot = leI32();
                const idx = base + slot;
                precisa(1);
                if (slot < 0 || idx >= sp)
                    erro("STORE em slot inexistente");
                pilha[idx] = desempilha();
                break;
            }

        case Op.reserve:
            {
                const n = leI32();
                if (n < 0)
                    erro("RESERVE negativo");
                foreach (_; 0 .. n)
                    empilha(Value(0L));
                break;
            }

        case Op.call:
            {
                const destino = leI32();
                const nargs = leU8();
                if (destino < 0 || destino >= cast(long) code.length)
                    erro("CALL para endereco invalido");
                if (sp < nargs)
                    erro("CALL sem argumentos suficientes");
                if (fp >= FramesMax)
                    erro("estouro da pilha de chamadas");
                frames[fp++] = Frame(ip, sp - nargs);
                base = sp - nargs;
                ip = destino;
                break;
            }

        case Op.ret:
            {
                precisa(1);
                const v = desempilha();
                fp--;
                const f = frames[fp];
                sp = f.base;
                empilha(v);
                if (fp == 0)
                    return;
                base = frames[fp - 1].base;
                ip = f.retIp;
                break;
            }

        case Op.print:
            precisa(1);
            writeln(formata(desempilha()));
            break;

        case Op.newarr:
            {
                precisa(1);
                const n = comoInteiro(desempilha());
                if (n < 0)
                    erro("NEWARR exige tamanho inteiro >= 0");
                empilha(Value(new FvmArray(cast(size_t) n)));
                break;
            }

        case Op.aget:
            {
                precisa(2);
                const idx = comoInteiro(desempilha());
                auto a = comoArray(desempilha());
                if (idx < 0 || idx >= cast(long) a.items.length)
                    erro("AGET fora dos limites");
                empilha(a.items[cast(size_t) idx]);
                break;
            }

        case Op.aset:
            {
                precisa(3);
                const v = desempilha();
                const idx = comoInteiro(desempilha());
                auto a = comoArray(desempilha());
                if (idx < 0 || idx >= cast(long) a.items.length)
                    erro("ASET fora dos limites");
                a.items[cast(size_t) idx] = v;
                break;
            }

        case Op.alen:
            precisa(1);
            empilha(Value(cast(long) comoArray(desempilha()).items.length));
            break;

        case Op.gc:
            // Em C esta instrução roda um mark & sweep de verdade. Aqui o GC
            // do D já reciclou o inalcançável; a chamada honra a semântica
            // declarada do opcode, não uma necessidade do teste.
            //
            // Nota honesta sobre o que os 9 casos NÃO verificam: um porte que
            // nunca liberasse nada passaria igual. Ver a coluna de RSS na
            // tabela de ports/README.md, que mede o que os casos não medem.
            import core.memory : GC;

            GC.collect();
            break;

        case Op.calli:
            {
                const nargs = leU8();
                if (sp < nargs + 1)
                    erro("CALLI sem closure e argumentos suficientes");
                const novaBase = sp - nargs - 1;
                auto clo = comoArray(pilha[novaBase]);
                if (clo.items.length < 1)
                    erro("CALLI: closure sem endereco de codigo");
                const destino = comoInteiro(clo.items[0]);
                if (destino < 0 || destino >= cast(long) code.length)
                    erro("CALLI: endereco de codigo fora do programa");
                if (fp >= FramesMax)
                    erro("estouro da pilha de chamadas");
                frames[fp++] = Frame(ip, novaBase);
                base = novaBase;
                ip = destino;
                break;
            }

        default:
            erro(format("opcode desconhecido: %d", cast(int) op));
        }
    }
}

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("uso: fvm_d <prog.fbc>");
        return 64;
    }

    try
    {
        executa(carrega(args[1]));
    }
    catch (VmException e)
    {
        stderr.writeln("erro de execucao: ", e.msg);
        return 70;
    }
    catch (Exception e)
    {
        stderr.writeln("erro: ", e.msg);
        return 66;
    }

    return 0;
}
