// fvm.cpp — porte do núcleo mínimo da Forge VM para C++.
//
//     g++ -O2 -std=c++20 -Wall -Wextra -o ports/cpp/fvm_cpp ports/cpp/fvm.cpp
//     ./ports/cpp/fvm_cpp programa.fbc
//
// ## O que este porte responde
//
// A implementação em C deste repositório tem 1.571 linhas e um mark & sweep
// escrito à mão. A pergunta de todo porte aqui é: **o que a linguagem dá de
// graça no mesmo problema?**
//
// C++ é o caso mais interessante dessa pergunta, porque ele é a única
// linguagem do conjunto que compartilha a semântica do C **e** oferece
// abstração sem custo de execução. As três coisas abaixo são exatamente isso.
//
// ## 1. O coletor desapareceu, e não virou outro coletor
//
// Em C, um array da VM entra numa lista encadeada de objetos vivos, e o
// `OP_GC` percorre a pilha marcando o que alcança. São ~200 linhas.
//
// Aqui, `Value` guarda um `std::shared_ptr<Array>`. A contagem de referências
// é feita pelo compilador, nos lugares em que o C precisava de código.
//
// **E a diferença com o Nim do porte ao lado é real:** o ORC do Nim coleta
// ciclos; `shared_ptr` **não**. Uma closure que capture a si mesma vaza aqui.
// O teste `gc_live.fasm` passa porque não constrói ciclo — e dizer isso é
// mais honesto que anunciar "o C++ também resolveu".
//
// O custo do ciclo está declarado, e a correção seria `weak_ptr` na captura:
// mais código, e exatamente o tipo de decisão que o C++ delega a quem escreve.
//
// ## 2. `std::variant`, e o acesso errado virando erro
//
// Em C, `Value` é uma struct com tag e união, e nada impede ler `as.o` de um
// valor cuja tag é `VAL_INT` — é convenção, verificada por revisão.
//
// `std::variant<int64_t, ArrayPtr>` faz o `std::get` lançar `bad_variant_access`
// no acesso errado. Não é tão forte quanto o `case object` do Nim, que recusa
// em compilação, e é muito mais forte que a união do C.
//
// ## 3. O despacho continua sendo um `switch`
//
// C++ não tem `computed goto` padrão (o `&&label` é extensão do GCC, usada na
// implementação em C deste repositório). O `switch` abaixo é o que o padrão
// oferece, e o compilador o transforma numa tabela de saltos — o mesmo
// resultado, sem a extensão.
//
// Isso importa para o projeto: o ganho do `computed goto` medido na
// implementação em C vem de **uma previsão de salto por opcode** em vez de uma
// compartilhada, e não da tabela em si.

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <variant>
#include <vector>

namespace {

constexpr const char* kMagic = "FVM1";
constexpr std::size_t kStackMax = 1u << 16;
constexpr std::size_t kFramesMax = 1024;

// Os opcodes, na ordem do ISA. O valor numérico é o byte no `.fbc`, então a
// ordem desta enum É o formato -- trocar duas linhas aqui quebra os 9 casos.
enum class Op : std::uint8_t {
    Halt = 0, Push, Pop, Dup, Swap,
    Add, Sub, Mul, Div, Mod, Neg,
    Lt, Le, Gt, Ge, Eq, Ne,
    Jmp, Jz, Jnz,
    Load, Store, Reserve,
    Call, Ret, Print,
    Newarr, Aget, Aset, Alen, Gc,
    Calli
};

class VmError : public std::runtime_error {
public:
    explicit VmError(const std::string& msg) : std::runtime_error(msg) {}
};

struct Array;
using ArrayPtr = std::shared_ptr<Array>;

// `std::variant` em vez de struct com tag e união.
//
// O acesso ao membro errado lança `bad_variant_access`, que o `main` captura.
// Em C, o mesmo erro lê lixo e segue.
using Value = std::variant<std::int64_t, ArrayPtr>;

struct Array {
    std::vector<Value> items;
};

Value intVal(std::int64_t n) { return Value{n}; }
Value arrVal(ArrayPtr a) { return Value{std::move(a)}; }

std::int64_t comoInt(const Value& v) {
    if (!std::holds_alternative<std::int64_t>(v)) {
        throw VmError("esperava inteiro");
    }
    return std::get<std::int64_t>(v);
}

const ArrayPtr& comoArr(const Value& v) {
    if (!std::holds_alternative<ArrayPtr>(v)) {
        throw VmError("esperava array");
    }
    const ArrayPtr& a = std::get<ArrayPtr>(v);
    if (!a) {
        throw VmError("referencia nula");
    }
    return a;
}

// A formatação do PRINT tem de casar com `value_print` do C EXATAMENTE:
// inteiro em decimal, array como `[1, 2, 3]` com vírgula e espaço, `nil` para
// referência nula. Qualquer diferença aqui reprova os 9 casos.
std::string formata(const Value& v) {
    if (std::holds_alternative<std::int64_t>(v)) {
        return std::to_string(std::get<std::int64_t>(v));
    }
    const ArrayPtr& a = std::get<ArrayPtr>(v);
    if (!a) {
        return "nil";
    }
    std::string s = "[";
    for (std::size_t i = 0; i < a->items.size(); ++i) {
        if (i > 0) {
            s += ", ";
        }
        s += formata(a->items[i]);
    }
    s += "]";
    return s;
}

// ---------------------------------------------------------------- bytecode
//
// Formato do .fbc (docs/ISA.md):
//
//   offset 0  : "FVM1"   4 bytes
//   offset 4  : entry     u32 little-endian
//   offset 8  : len       u32 little-endian
//   offset 12 : code[len]
//
// Little-endian EXPLÍCITO, byte a byte, e não um `reinterpret_cast`. A VM roda
// em x86-64 e ARM64, e o formato é definido como little-endian -- um cast
// funcionaria por acidente na máquina de hoje e quebraria na próxima.
//
// E em C++20 há `std::endian`, que diria qual é a da máquina. Não usá-lo é
// deliberado: ler byte a byte é correto em TODA máquina, e não só nas que o
// programa souber identificar.

struct Chunk {
    std::vector<std::uint8_t> code;
    std::size_t entry = 0;
};

std::uint32_t leU32(const std::vector<std::uint8_t>& b, std::size_t off) {
    return static_cast<std::uint32_t>(b[off]) |
           (static_cast<std::uint32_t>(b[off + 1]) << 8) |
           (static_cast<std::uint32_t>(b[off + 2]) << 16) |
           (static_cast<std::uint32_t>(b[off + 3]) << 24);
}

Chunk carrega(const std::string& caminho) {
    std::ifstream f(caminho, std::ios::binary);
    if (!f) {
        throw std::ios_base::failure("nao consegui abrir " + caminho);
    }

    std::vector<std::uint8_t> bruto(
        (std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());

    if (bruto.size() < 12) {
        throw VmError("arquivo curto demais para ser um .fbc");
    }
    if (std::memcmp(bruto.data(), kMagic, 4) != 0) {
        throw VmError(std::string("magic invalido: esperava ") + kMagic);
    }

    const std::uint32_t entry = leU32(bruto, 4);
    const std::uint32_t n = leU32(bruto, 8);

    if (static_cast<std::size_t>(n) + 12 > bruto.size()) {
        throw VmError("len do cabecalho (" + std::to_string(n) +
                      ") maior que o arquivo");
    }
    if (entry > n) {
        throw VmError("entry fora do codigo");
    }

    Chunk c;
    c.code.assign(bruto.begin() + 12, bruto.begin() + 12 + n);
    c.entry = entry;
    return c;
}

// --------------------------------------------------------------- execução

struct Frame {
    std::size_t retIp = 0;
    std::size_t base = 0;
};

void executa(const Chunk& chunk) {
    std::vector<Value> pilha(kStackMax, intVal(0));
    std::size_t sp = 0;

    std::vector<Frame> frames(kFramesMax);

    // O FRAME RAIZ, e por que ele existe.
    //
    // A implementação em C monta `frames[0] = {ret_ip: NULL, base: 0}` e começa
    // com `fp = 1`, com o comentário: "faz com que LOAD/STORE e RET funcionem
    // no nível de topo sem nenhum caso especial no loop quente".
    //
    // A primeira versão deste porte começava com `fp = 0`, e falhou em 4 dos 9
    // casos -- `closure`, `closure_dispatch`, `fib` e `locals`, todos os que
    // usam CALL. O sintoma era SAÍDA VAZIA e retorno 0: o primeiro `RET`
    // decrementava `fp` para 0, caía no ramo "RET no frame raiz encerra o
    // programa", e terminava antes do `PRINT` que vinha depois da chamada.
    //
    // Nada no bytecode nem no ISA menciona esse frame -- ele é uma decisão de
    // implementação que o contrato do porte herda, e descobri-la exigiu ler o
    // `vm_run` do C. É o tipo de detalhe que o README dos portes chama de
    // "contrato mais severo do que parece".
    frames[0] = Frame{0, 0};
    std::size_t fp = 1;

    std::size_t ip = chunk.entry;
    std::size_t base = 0;

    const std::vector<std::uint8_t>& code = chunk.code;

    // O temporário em `push` NÃO é estilo: é o mesmo bug que a implementação
    // em C teve no macro `PUSH` e que o porte em Nim repetiu.
    //
    // `pilha[sp] = v` com `v` contendo um `pop()` avalia `sp` para o lvalue
    // ANTES de rodar o `pop()`, que decrementa `sp` -- e a escrita vai para o
    // índice velho.
    //
    // Em C++17+ a ordem de avaliação de `a = b` é definida (b antes de a), o
    // que torna este caso seguro na linguagem. O temporário fica porque o
    // código é lido ao lado dos outros portes, e porque depender de uma regra
    // que mudou em 2017 num programa que também existe em C é convite a erro.
    auto push = [&](Value v) {
        Value tmp = std::move(v);
        if (sp >= kStackMax) {
            throw VmError("estouro da pilha de dados");
        }
        pilha[sp] = std::move(tmp);
        ++sp;
    };

    auto pop = [&]() -> Value {
        if (sp == 0) {
            throw VmError("pilha vazia");
        }
        --sp;
        return pilha[sp];
    };

    auto precisa = [&](std::size_t n) {
        if (sp < n) {
            throw VmError("pilha com menos de " + std::to_string(n) +
                          " valores");
        }
    };

    auto leU8 = [&]() -> std::uint8_t {
        if (ip >= code.size()) {
            throw VmError("operando u8 fora do codigo");
        }
        return code[ip++];
    };

    auto leI32 = [&]() -> std::int32_t {
        if (ip + 4 > code.size()) {
            throw VmError("operando i32 fora do codigo");
        }
        const std::uint32_t u = static_cast<std::uint32_t>(code[ip]) |
                                (static_cast<std::uint32_t>(code[ip + 1]) << 8) |
                                (static_cast<std::uint32_t>(code[ip + 2]) << 16) |
                                (static_cast<std::uint32_t>(code[ip + 3]) << 24);
        ip += 4;
        return static_cast<std::int32_t>(u);
    };

    auto leI64 = [&]() -> std::int64_t {
        if (ip + 8 > code.size()) {
            throw VmError("operando i64 fora do codigo");
        }
        std::uint64_t u = 0;
        for (int k = 7; k >= 0; --k) {
            u = (u << 8) | static_cast<std::uint64_t>(code[ip + k]);
        }
        ip += 8;
        return static_cast<std::int64_t>(u);
    };

    auto binario = [&](auto op) {
        precisa(2);
        const std::int64_t b = comoInt(pop());
        const std::int64_t a = comoInt(pop());
        push(intVal(op(a, b)));
    };

    for (;;) {
        if (ip >= code.size()) {
            throw VmError("ip fora do codigo");
        }

        const Op op = static_cast<Op>(code[ip++]);

        switch (op) {
        case Op::Halt:
            return;

        case Op::Push:
            push(intVal(leI64()));
            break;

        case Op::Pop:
            precisa(1);
            (void)pop();
            break;

        case Op::Dup: {
            precisa(1);
            Value v = pilha[sp - 1];
            push(std::move(v));
            break;
        }

        case Op::Swap: {
            precisa(2);
            std::swap(pilha[sp - 1], pilha[sp - 2]);
            break;
        }

        case Op::Add: binario([](auto a, auto b) { return a + b; }); break;
        case Op::Sub: binario([](auto a, auto b) { return a - b; }); break;
        case Op::Mul: binario([](auto a, auto b) { return a * b; }); break;

        case Op::Div: {
            precisa(2);
            const std::int64_t b = comoInt(pop());
            const std::int64_t a = comoInt(pop());
            if (b == 0) {
                throw VmError("divisao por zero");
            }
            push(intVal(a / b));
            break;
        }

        case Op::Mod: {
            precisa(2);
            const std::int64_t b = comoInt(pop());
            const std::int64_t a = comoInt(pop());
            if (b == 0) {
                throw VmError("modulo por zero");
            }
            push(intVal(a % b));
            break;
        }

        case Op::Neg:
            precisa(1);
            push(intVal(-comoInt(pop())));
            break;

        case Op::Lt: binario([](auto a, auto b) { return a < b ? 1 : 0; }); break;
        case Op::Le: binario([](auto a, auto b) { return a <= b ? 1 : 0; }); break;
        case Op::Gt: binario([](auto a, auto b) { return a > b ? 1 : 0; }); break;
        case Op::Ge: binario([](auto a, auto b) { return a >= b ? 1 : 0; }); break;

        // EQ e NE comparam objetos por IDENTIDADE, como o ISA manda. Para
        // `shared_ptr` isso é comparar o ponteiro, e não o conteúdo.
        case Op::Eq:
        case Op::Ne: {
            precisa(2);
            const Value b = pop();
            const Value a = pop();
            bool iguais;
            if (std::holds_alternative<std::int64_t>(a) &&
                std::holds_alternative<std::int64_t>(b)) {
                iguais = std::get<std::int64_t>(a) == std::get<std::int64_t>(b);
            } else if (std::holds_alternative<ArrayPtr>(a) &&
                       std::holds_alternative<ArrayPtr>(b)) {
                iguais = std::get<ArrayPtr>(a) == std::get<ArrayPtr>(b);
            } else {
                iguais = false;
            }
            push(intVal((op == Op::Eq) == iguais ? 1 : 0));
            break;
        }

        case Op::Jmp: {
            const std::int32_t destino = leI32();
            if (destino < 0 ||
                static_cast<std::size_t>(destino) >= code.size()) {
                throw VmError("JMP para endereco invalido");
            }
            ip = static_cast<std::size_t>(destino);
            break;
        }

        case Op::Jz:
        case Op::Jnz: {
            const std::int32_t destino = leI32();
            precisa(1);
            const std::int64_t c = comoInt(pop());
            const bool salta = (op == Op::Jz) ? (c == 0) : (c != 0);
            if (salta) {
                if (destino < 0 ||
                    static_cast<std::size_t>(destino) >= code.size()) {
                    throw VmError("salto para endereco invalido");
                }
                ip = static_cast<std::size_t>(destino);
            }
            break;
        }

        case Op::Load: {
            const std::int32_t slot = leI32();
            if (slot < 0 || base + static_cast<std::size_t>(slot) >= sp) {
                throw VmError("LOAD fora do frame");
            }
            Value v = pilha[base + static_cast<std::size_t>(slot)];
            push(std::move(v));
            break;
        }

        case Op::Store: {
            const std::int32_t slot = leI32();
            precisa(1);
            const Value v = pop();
            if (slot < 0 || base + static_cast<std::size_t>(slot) >= sp) {
                throw VmError("STORE fora do frame");
            }
            pilha[base + static_cast<std::size_t>(slot)] = v;
            break;
        }

        case Op::Reserve: {
            const std::int32_t n = leI32();
            if (n < 0) {
                throw VmError("RESERVE negativo");
            }
            for (std::int32_t k = 0; k < n; ++k) {
                push(intVal(0));
            }
            break;
        }

        case Op::Call: {
            const std::int32_t destino = leI32();
            const std::uint8_t nargs = leU8();
            if (destino < 0 ||
                static_cast<std::size_t>(destino) >= code.size()) {
                throw VmError("CALL para endereco invalido");
            }
            if (sp < nargs) {
                throw VmError("CALL sem argumentos suficientes");
            }
            if (fp >= kFramesMax) {
                throw VmError("estouro da pilha de chamadas");
            }
            frames[fp] = Frame{ip, sp - nargs};
            ++fp;
            base = sp - nargs;
            ip = static_cast<std::size_t>(destino);
            break;
        }

        case Op::Calli: {
            const std::uint8_t nargs = leU8();
            if (sp < static_cast<std::size_t>(nargs) + 1) {
                throw VmError("CALLI sem closure e argumentos suficientes");
            }
            const std::size_t novaBase = sp - nargs - 1;
            const ArrayPtr& clo = comoArr(pilha[novaBase]);
            if (clo->items.empty()) {
                throw VmError("CALLI: closure sem endereco de codigo");
            }
            const std::int64_t destino = comoInt(clo->items[0]);
            if (destino < 0 ||
                static_cast<std::size_t>(destino) >= code.size()) {
                throw VmError("CALLI: endereco de codigo fora do programa");
            }
            if (fp >= kFramesMax) {
                throw VmError("estouro da pilha de chamadas");
            }
            frames[fp] = Frame{ip, novaBase};
            ++fp;
            base = novaBase;
            ip = static_cast<std::size_t>(destino);
            break;
        }

        case Op::Ret: {
            precisa(1);
            const Value v = pop();
            if (fp == 0) {
                throw VmError("RET sem frame");
            }
            --fp;
            const Frame f = frames[fp];
            sp = f.base;
            push(v);
            if (fp == 0) {
                return;
            }
            base = frames[fp - 1].base;
            ip = f.retIp;
            break;
        }

        case Op::Print:
            precisa(1);
            std::printf("%s\n", formata(pop()).c_str());
            break;

        case Op::Newarr: {
            precisa(1);
            const std::int64_t n = comoInt(pop());
            if (n < 0) {
                throw VmError("NEWARR com tamanho negativo");
            }
            auto a = std::make_shared<Array>();
            a->items.assign(static_cast<std::size_t>(n), intVal(0));
            push(arrVal(std::move(a)));
            break;
        }

        case Op::Aget: {
            precisa(2);
            const std::int64_t i = comoInt(pop());
            const ArrayPtr a = comoArr(pop());
            if (i < 0 || static_cast<std::size_t>(i) >= a->items.size()) {
                throw VmError("AGET fora dos limites");
            }
            Value v = a->items[static_cast<std::size_t>(i)];
            push(std::move(v));
            break;
        }

        case Op::Aset: {
            precisa(3);
            const Value v = pop();
            const std::int64_t i = comoInt(pop());
            const ArrayPtr a = comoArr(pop());
            if (i < 0 || static_cast<std::size_t>(i) >= a->items.size()) {
                throw VmError("ASET fora dos limites");
            }
            a->items[static_cast<std::size_t>(i)] = v;
            break;
        }

        case Op::Alen: {
            precisa(1);
            const ArrayPtr a = comoArr(pop());
            push(intVal(static_cast<std::int64_t>(a->items.size())));
            break;
        }

        case Op::Gc:
            // Não há o que coletar: `shared_ptr` libera quando a última
            // referência sai de escopo, e isso já aconteceu.
            //
            // O `OP_GC` em C dispara um mark & sweep de verdade, e remover a
            // chamada lá quebra o `gc.fasm`. Aqui o opcode é reconhecido e
            // ignorado -- e a ressalva do CICLO está no cabeçalho deste
            // arquivo, porque `shared_ptr` não coleta ciclo e o ORC do Nim
            // coleta.
            break;

        default:
            throw VmError("opcode desconhecido: " +
                          std::to_string(static_cast<int>(op)));
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "uso: fvm_cpp <prog.fbc>\n");
        return 64;
    }

    try {
        executa(carrega(argv[1]));
    } catch (const VmError& e) {
        std::fprintf(stderr, "erro de execucao: %s\n", e.what());
        return 70;
    } catch (const std::bad_variant_access&) {
        // O acesso ao membro errado do `variant`. Em C, o mesmo erro lê lixo
        // e segue -- aqui ele chega como exceção com nome próprio.
        std::fprintf(stderr, "erro de execucao: tipo errado no variant\n");
        return 70;
    } catch (const std::ios_base::failure& e) {
        std::fprintf(stderr, "erro de E/S: %s\n", e.what());
        return 66;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "erro: %s\n", e.what());
        return 70;
    }

    return 0;
}
