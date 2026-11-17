//! fvm.zig — porte do núcleo mínimo da Forge VM para Zig.
//!
//!     zig build-exe -O ReleaseFast --name fvm_zig ports/zig/fvm.zig
//!     ./fvm_zig programa.fbc
//!
//! ## O que este porte responde
//!
//! O plano deste projeto diz que "Zig mostra `comptime` e alocadores
//! explícitos". As duas coisas aparecem aqui, e a segunda é a que muda o
//! programa.
//!
//! ## 1. Alocador explícito: a pergunta que o Zig obriga a responder
//!
//! Em C, `malloc` é global e invisível na assinatura. Em C++, `shared_ptr`
//! esconde a alocação atrás de `make_shared`. Em Nim, o ORC decide sozinho.
//!
//! Em Zig, **toda função que aloca recebe um `Allocator`**, e isso aparece no
//! tipo. Não é cerimônia: é a resposta para "quem é dono disto?" escrita na
//! assinatura, no lugar em que o C deixa para a documentação.
//!
//! A consequência neste porte: a VM tem um `arena` próprio, e a liberação é
//! **uma linha no fim**. Um array da VM nunca é liberado individualmente —
//! todos morrem juntos quando o programa termina.
//!
//! **E isso é uma decisão, não uma omissão.** A VM em C tem um mark & sweep
//! de verdade, com ~200 linhas. Aqui o `OP_GC` não coleta: a arena só cresce.
//! Para os 9 casos isso é suficiente, e para um programa longo não seria.
//! Declarar o limite é o que separa um porte honesto de um que finge.
//!
//! ## 2. `comptime`: a tabela de operandos, gerada em compilação
//!
//! `larguraOperando` abaixo é uma função normal que roda **em tempo de
//! compilação** para montar uma tabela constante. Em C isso seria um array
//! escrito à mão, com o risco de sair de sincronia com o enum; aqui o
//! compilador deriva um do outro, e um opcode novo sem largura declarada é
//! **erro de compilação**.
//!
//! É o `comptime` fazendo o que macro de C faz, com tipos e sem texto.
//!
//! ## 3. O que o Zig cobra
//!
//! Erro é valor, e a propagação é explícita com `try`. Não há exceção, então
//! toda função que pode falhar diz isso no tipo de retorno — e o `catch` no
//! `main` é o único lugar que decide o código de saída.
//!
//! Mais verboso que o `throw` do C++ e mais honesto: não existe caminho de
//! erro invisível.

const std = @import("std");

const MAGIC = "FVM1";
const STACK_MAX: usize = 1 << 16;
const FRAMES_MAX: usize = 1024;

/// Os opcodes, na ordem do ISA. O valor numérico É o byte no `.fbc`.
const Op = enum(u8) {
    halt = 0, push, pop, dup, swap,
    add, sub, mul, div, mod, neg,
    lt, le, gt, ge, eq, ne,
    jmp, jz, jnz,
    load, store, reserve,
    call, ret, print,
    newarr, aget, aset, alen, gc,
    calli,
};

/// A largura do operando de cada opcode, em bytes.
///
/// Esta função roda em COMPILAÇÃO. A tabela `LARGURA` abaixo é construída a
/// partir dela, e o `else` obriga a declarar a largura de todo opcode novo --
/// um `switch` sem caso em Zig é erro de compilação, não um ramo esquecido.
fn larguraOperando(op: Op) usize {
    return switch (op) {
        .push => 8,
        .jmp, .jz, .jnz, .load, .store, .reserve => 4,
        .call => 5,
        .calli => 1,
        .halt, .pop, .dup, .swap, .add, .sub, .mul, .div, .mod, .neg,
        .lt, .le, .gt, .ge, .eq, .ne, .ret, .print,
        .newarr, .aget, .aset, .alen, .gc => 0,
    };
}

/// A tabela, gerada em tempo de compilação.
///
/// Ela não é usada pelo laço quente -- cada opcode lê o próprio operando --,
/// e existe para `validaPrograma`, que percorre o bytecode uma vez antes de
/// executar. Em C essa validação não existe, e um `.fbc` truncado só falha
/// quando o `ip` passa do fim.
const LARGURA = blk: {
    var t: [32]usize = undefined;
    for (std.enums.values(Op)) |op| {
        t[@intFromEnum(op)] = larguraOperando(op);
    }
    break :blk t;
};

const VmError = error{
    MagicInvalido,
    ArquivoCurto,
    CabecalhoInconsistente,
    PilhaVazia,
    EstouroPilha,
    EstouroFrames,
    TipoErrado,
    ReferenciaNula,
    DivisaoPorZero,
    ForaDosLimites,
    EnderecoInvalido,
    OpcodeDesconhecido,
    OperandoTruncado,
    RetSemFrame,
};

const Array = struct {
    items: []Value,
};

const Value = union(enum) {
    int: i64,
    arr: ?*Array,
};

fn comoInt(v: Value) VmError!i64 {
    return switch (v) {
        .int => |n| n,
        .arr => error.TipoErrado,
    };
}

fn comoArr(v: Value) VmError!*Array {
    return switch (v) {
        .int => error.TipoErrado,
        .arr => |a| a orelse error.ReferenciaNula,
    };
}

/// A formatação do PRINT tem de casar com `value_print` do C EXATAMENTE:
/// inteiro em decimal, array como `[1, 2, 3]`, `nil` para referência nula.
fn escreveValor(w: anytype, v: Value) !void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .arr => |maybe| {
            const a = maybe orelse {
                try w.writeAll("nil");
                return;
            };
            try w.writeAll("[");
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try escreveValor(w, item);
            }
            try w.writeAll("]");
        },
    }
}

// ----------------------------------------------------------------- bytecode
//
// Formato do .fbc (docs/ISA.md):
//
//   offset 0  : "FVM1"   4 bytes
//   offset 4  : entry     u32 little-endian
//   offset 8  : len       u32 little-endian
//   offset 12 : code[len]

const Chunk = struct {
    code: []u8,
    entry: usize,
};

fn leU32(b: []const u8, off: usize) u32 {
    // `std.mem.readInt` com endianness EXPLÍCITA. Zig obriga a dizer qual --
    // não há leitura "nativa" por omissão, que é o que faz um programa
    // funcionar por acidente na máquina de hoje.
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn carrega(alloc: std.mem.Allocator, caminho: []const u8) !Chunk {
    const f = try std.fs.cwd().openFile(caminho, .{});
    defer f.close();

    const bruto = try f.readToEndAlloc(alloc, 64 * 1024 * 1024);

    if (bruto.len < 12) return error.ArquivoCurto;
    if (!std.mem.eql(u8, bruto[0..4], MAGIC)) return error.MagicInvalido;

    const entry = leU32(bruto, 4);
    const n = leU32(bruto, 8);

    if (@as(usize, n) + 12 > bruto.len) return error.CabecalhoInconsistente;
    if (entry > n) return error.CabecalhoInconsistente;

    return Chunk{
        .code = bruto[12 .. 12 + n],
        .entry = entry,
    };
}

/// Percorre o bytecode uma vez, conferindo que todo operando cabe.
///
/// A implementação em C não faz isso: lá, um `.fbc` truncado falha quando o
/// `ip` passa do fim, no meio da execução, possivelmente depois de já ter
/// impresso. Aqui a falha acontece antes de qualquer efeito.
///
/// É a tabela `LARGURA` gerada por `comptime` que torna isso barato de
/// escrever -- sem ela, seria um `switch` duplicado.
fn validaPrograma(code: []const u8) VmError!void {
    var ip: usize = 0;
    while (ip < code.len) {
        const b = code[ip];
        if (b >= LARGURA.len) return error.OpcodeDesconhecido;
        ip += 1;
        const larg = LARGURA[b];
        if (ip + larg > code.len) return error.OperandoTruncado;
        ip += larg;
    }
}

// ---------------------------------------------------------------- execução

const Frame = struct {
    ret_ip: usize = 0,
    base: usize = 0,
};

const Vm = struct {
    alloc: std.mem.Allocator,
    pilha: []Value,
    sp: usize = 0,
    frames: []Frame,
    fp: usize = 0,
    base: usize = 0,
    ip: usize = 0,

    fn push(self: *Vm, v: Value) VmError!void {
        if (self.sp >= STACK_MAX) return error.EstouroPilha;
        self.pilha[self.sp] = v;
        self.sp += 1;
    }

    fn pop(self: *Vm) VmError!Value {
        if (self.sp == 0) return error.PilhaVazia;
        self.sp -= 1;
        return self.pilha[self.sp];
    }

    fn precisa(self: *Vm, n: usize) VmError!void {
        if (self.sp < n) return error.PilhaVazia;
    }
};

fn executa(alloc: std.mem.Allocator, chunk: Chunk, w: anytype) !void {
    const pilha = try alloc.alloc(Value, STACK_MAX);
    const frames = try alloc.alloc(Frame, FRAMES_MAX);

    var vm = Vm{
        .alloc = alloc,
        .pilha = pilha,
        .frames = frames,
        .ip = chunk.entry,
    };

    // O FRAME RAIZ.
    //
    // A implementação em C monta `frames[0] = {ret_ip: NULL, base: 0}` e
    // começa com `fp = 1`, para LOAD/STORE e RET funcionarem no nível de topo
    // sem caso especial no laço quente.
    //
    // Nada no ISA menciona esse frame: é decisão de implementação que o
    // contrato do porte herda. O porte em C++ ao lado falhou em 4 dos 9 casos
    // por começar com `fp = 0`, e o sintoma era saída VAZIA com retorno zero.
    vm.frames[0] = Frame{ .ret_ip = 0, .base = 0 };
    vm.fp = 1;

    const code = chunk.code;

    while (true) {
        if (vm.ip >= code.len) return error.EnderecoInvalido;

        const byte = code[vm.ip];
        vm.ip += 1;

        if (byte >= LARGURA.len) return error.OpcodeDesconhecido;
        const op: Op = @enumFromInt(byte);

        switch (op) {
            .halt => return,

            .push => {
                const n = std.mem.readInt(i64, code[vm.ip..][0..8], .little);
                vm.ip += 8;
                try vm.push(.{ .int = n });
            },

            .pop => {
                try vm.precisa(1);
                _ = try vm.pop();
            },

            .dup => {
                try vm.precisa(1);
                const v = vm.pilha[vm.sp - 1];
                try vm.push(v);
            },

            .swap => {
                try vm.precisa(2);
                const t = vm.pilha[vm.sp - 1];
                vm.pilha[vm.sp - 1] = vm.pilha[vm.sp - 2];
                vm.pilha[vm.sp - 2] = t;
            },

            .add, .sub, .mul, .lt, .le, .gt, .ge => {
                try vm.precisa(2);
                const b = try comoInt(try vm.pop());
                const a = try comoInt(try vm.pop());
                // `+%` e `-%` e `*%`: aritmética com WRAP explícito.
                //
                // Em Zig, `a + b` que estoura é ERRO EM EXECUÇÃO no modo
                // seguro e comportamento indefinido no rápido. O C da VM usa
                // `int64_t` com overflow indefinido, e na prática envolve.
                // Para o porte produzir a mesma saída, o wrap tem de ser
                // pedido -- e pedi-lo é mais honesto que herdá-lo.
                const r: i64 = switch (op) {
                    .add => a +% b,
                    .sub => a -% b,
                    .mul => a *% b,
                    .lt => if (a < b) 1 else 0,
                    .le => if (a <= b) 1 else 0,
                    .gt => if (a > b) 1 else 0,
                    .ge => if (a >= b) 1 else 0,
                    else => unreachable,
                };
                try vm.push(.{ .int = r });
            },

            .div, .mod => {
                try vm.precisa(2);
                const b = try comoInt(try vm.pop());
                const a = try comoInt(try vm.pop());
                if (b == 0) return error.DivisaoPorZero;
                const r: i64 = if (op == .div) @divTrunc(a, b) else @rem(a, b);
                try vm.push(.{ .int = r });
            },

            .neg => {
                try vm.precisa(1);
                const a = try comoInt(try vm.pop());
                try vm.push(.{ .int = -%a });
            },

            .eq, .ne => {
                try vm.precisa(2);
                const b = try vm.pop();
                const a = try vm.pop();
                // Objetos comparam por IDENTIDADE, como o ISA manda.
                const iguais = switch (a) {
                    .int => |x| switch (b) {
                        .int => |y| x == y,
                        .arr => false,
                    },
                    .arr => |x| switch (b) {
                        .int => false,
                        .arr => |y| x == y,
                    },
                };
                const r: i64 = if ((op == .eq) == iguais) 1 else 0;
                try vm.push(.{ .int = r });
            },

            .jmp, .jz, .jnz => {
                const destino = std.mem.readInt(i32, code[vm.ip..][0..4], .little);
                vm.ip += 4;

                const salta = switch (op) {
                    .jmp => true,
                    .jz, .jnz => blk: {
                        try vm.precisa(1);
                        const c = try comoInt(try vm.pop());
                        break :blk if (op == .jz) c == 0 else c != 0;
                    },
                    else => unreachable,
                };

                if (salta) {
                    if (destino < 0 or @as(usize, @intCast(destino)) >= code.len)
                        return error.EnderecoInvalido;
                    vm.ip = @intCast(destino);
                }
            },

            .load => {
                const slot = std.mem.readInt(i32, code[vm.ip..][0..4], .little);
                vm.ip += 4;
                if (slot < 0) return error.ForaDosLimites;
                const idx = vm.base + @as(usize, @intCast(slot));
                if (idx >= vm.sp) return error.ForaDosLimites;
                try vm.push(vm.pilha[idx]);
            },

            .store => {
                const slot = std.mem.readInt(i32, code[vm.ip..][0..4], .little);
                vm.ip += 4;
                try vm.precisa(1);
                const v = try vm.pop();
                if (slot < 0) return error.ForaDosLimites;
                const idx = vm.base + @as(usize, @intCast(slot));
                if (idx >= vm.sp) return error.ForaDosLimites;
                vm.pilha[idx] = v;
            },

            .reserve => {
                const n = std.mem.readInt(i32, code[vm.ip..][0..4], .little);
                vm.ip += 4;
                if (n < 0) return error.ForaDosLimites;
                var k: i32 = 0;
                while (k < n) : (k += 1) try vm.push(.{ .int = 0 });
            },

            .call => {
                const destino = std.mem.readInt(i32, code[vm.ip..][0..4], .little);
                vm.ip += 4;
                const nargs = code[vm.ip];
                vm.ip += 1;

                if (destino < 0 or @as(usize, @intCast(destino)) >= code.len)
                    return error.EnderecoInvalido;
                if (vm.sp < nargs) return error.PilhaVazia;
                if (vm.fp >= FRAMES_MAX) return error.EstouroFrames;

                vm.frames[vm.fp] = Frame{ .ret_ip = vm.ip, .base = vm.sp - nargs };
                vm.fp += 1;
                vm.base = vm.sp - nargs;
                vm.ip = @intCast(destino);
            },

            .calli => {
                const nargs = code[vm.ip];
                vm.ip += 1;

                if (vm.sp < @as(usize, nargs) + 1) return error.PilhaVazia;
                const nova_base = vm.sp - nargs - 1;
                const clo = try comoArr(vm.pilha[nova_base]);
                if (clo.items.len < 1) return error.ForaDosLimites;
                const destino = try comoInt(clo.items[0]);
                if (destino < 0 or @as(usize, @intCast(destino)) >= code.len)
                    return error.EnderecoInvalido;
                if (vm.fp >= FRAMES_MAX) return error.EstouroFrames;

                vm.frames[vm.fp] = Frame{ .ret_ip = vm.ip, .base = nova_base };
                vm.fp += 1;
                vm.base = nova_base;
                vm.ip = @intCast(destino);
            },

            .ret => {
                try vm.precisa(1);
                const v = try vm.pop();
                if (vm.fp == 0) return error.RetSemFrame;
                vm.fp -= 1;
                const f = vm.frames[vm.fp];
                vm.sp = f.base;
                try vm.push(v);
                if (vm.fp == 0) return;
                vm.base = vm.frames[vm.fp - 1].base;
                vm.ip = f.ret_ip;
            },

            .print => {
                try vm.precisa(1);
                const v = try vm.pop();
                try escreveValor(w, v);
                try w.writeAll("\n");
            },

            .newarr => {
                try vm.precisa(1);
                const n = try comoInt(try vm.pop());
                if (n < 0) return error.ForaDosLimites;

                // A alocação vem do ALOCADOR da VM, passado como parâmetro --
                // não de um `malloc` global. É a assinatura dizendo quem é o
                // dono.
                const a = try alloc.create(Array);
                a.items = try alloc.alloc(Value, @intCast(n));
                for (a.items) |*slot| slot.* = .{ .int = 0 };
                try vm.push(.{ .arr = a });
            },

            .aget => {
                try vm.precisa(2);
                const i = try comoInt(try vm.pop());
                const a = try comoArr(try vm.pop());
                if (i < 0 or @as(usize, @intCast(i)) >= a.items.len)
                    return error.ForaDosLimites;
                try vm.push(a.items[@intCast(i)]);
            },

            .aset => {
                try vm.precisa(3);
                const v = try vm.pop();
                const i = try comoInt(try vm.pop());
                const a = try comoArr(try vm.pop());
                if (i < 0 or @as(usize, @intCast(i)) >= a.items.len)
                    return error.ForaDosLimites;
                a.items[@intCast(i)] = v;
            },

            .alen => {
                try vm.precisa(1);
                const a = try comoArr(try vm.pop());
                try vm.push(.{ .int = @intCast(a.items.len) });
            },

            .gc => {
                // A ARENA NÃO COLETA, e isso está declarado no cabeçalho.
                //
                // A VM em C dispara um mark & sweep aqui, e remover a chamada
                // lá quebra o `gc.fasm`. Este porte reconhece o opcode e não
                // faz nada: toda memória sai junto, no fim do programa.
                //
                // Para os 9 casos é suficiente. Para um programa longo não
                // seria, e dizer isso é o que separa um porte honesto de um
                // que finge ter coletor.
            },
        }
    }
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    const caminho = args.next() orelse {
        std.debug.print("uso: fvm_zig <prog.fbc>\n", .{});
        std.process.exit(64);
    };

    // A ARENA: o alocador explícito do Zig, visível aqui e passado adiante.
    //
    // `deinit` numa linha libera tudo -- arrays da VM, pilha, frames e o
    // próprio bytecode. É o modelo de memória deste porte, e ele cabe numa
    // frase porque a linguagem obriga a dizê-lo.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const chunk = carrega(alloc, caminho) catch |e| {
        std.debug.print("erro de E/S: {s}\n", .{@errorName(e)});
        std.process.exit(66);
    };

    validaPrograma(chunk.code) catch |e| {
        std.debug.print("bytecode invalido: {s}\n", .{@errorName(e)});
        std.process.exit(65);
    };

    var buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const w = buf.writer();

    executa(alloc, chunk, w) catch |e| {
        buf.flush() catch {};
        std.debug.print("erro de execucao: {s}\n", .{@errorName(e)});
        std.process.exit(70);
    };

    try buf.flush();
}
