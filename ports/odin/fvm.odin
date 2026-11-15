// fvm.odin — porte do núcleo mínimo da Forge VM para Odin.
//
// ## O que este arquivo é
//
// Um **porte**: executa `.fbc` montado pela implementação em C e produz saída
// byte a byte idêntica nos 9 casos de `tests/cases/`. Sem montador, sem
// `--stats`, sem desmontador. Ver `ports/README.md`.
//
// ## Odin não tem coletor de lixo, e aqui isso fica visível
//
// Nim, D e V resolvem a memória dos arrays da VM com o coletor do runtime.
// Odin não tem runtime com coletor — e a linguagem não finge que tem.
//
// A escolha aqui foi uma **arena explícita** (`virtual.Arena`): todo array da
// VM é alocado dela, e nada é liberado individualmente. O `OP_GC` não recicla
// nada, e isso é declarado em vez de disfarçado.
//
// Por que isso passa nos 9 casos: eles verificam **semântica**, não
// reciclagem. O `gc.fasm` cria 20 mil arrays descartados e só confere que `42`
// é impresso; o `gc_live.fasm` confere que um array alcançável sobrevive — e
// numa arena que nunca libera, sobreviver é trivial.
//
// **É o modo de falha oposto ao de um GC com bug**, e os casos não distinguem
// um do outro. A coluna de RSS em `ports/README.md` mede o que eles não medem.
//
// ## O que o Odin deu de graça
//
// **`union` discriminada na linguagem.** `Value :: union { i64, ^FvmArray }`
// é uma linha, com tag gerenciada pelo compilador e `switch v in valor` que
// só dá acesso à variante certa. Em C a mesma coisa é struct + tag + união,
// mantida por convenção.
//
// E, diferente do V, a union do Odin **aceita ponteiro** — então aqui não foi
// preciso o desenho de handle que o V impôs.
//
// **`context.allocator`.** O alocador é parte do contexto implícito do
// programa: trocar a arena por outra estratégia é uma linha no `main`, sem
// passar alocador por parâmetro em cada função. É o oposto do C, onde a
// decisão de alocação está espalhada por cada `malloc`.
//
// **`slice.reinterpret` e `endian`.** `endian.get_u32(b, .Little)` devolve
// `(valor, ok)` — o `ok` obriga a lidar com buffer curto, que em C é um
// `memcpy` que leria fora dos limites em silêncio.
//
// uso: fvm_odin <prog.fbc>

package fvm

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

STACK_MAX :: 1 << 16
FRAMES_MAX :: 1024

// Os 32 opcodes, na ordem de `c/include/fvm.h`. A ordem É o formato binário:
// trocar duas linhas aqui quebra todo `.fbc` existente.
Op :: enum u8 {
	Halt    = 0,
	Push,
	Pop,
	Dup,
	Swap,
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Neg,
	Lt,
	Le,
	Gt,
	Ge,
	Eq,
	Ne,
	Jmp,
	Jz,
	Jnz,
	Load,
	Store,
	Reserve,
	Call,
	Ret,
	Print,
	Newarr,
	Aget,
	Aset,
	Alen,
	Gc,
	Calli,
}

FvmArray :: struct {
	items: []Value,
}

// Union discriminada: a tag é do compilador, e `switch v in valor` só dá
// acesso à variante correta. Aceita ponteiro, ao contrário da do V.
Value :: union {
	i64,
	^FvmArray,
}

Frame :: struct {
	ret_ip: i64,
	base:   i64,
}

Chunk :: struct {
	code:  []u8,
	entry: int,
}

Vm :: struct {
	pilha:  []Value,
	sp:     i64,
	frames: []Frame,
	fp:     i64,
	ip:     i64,
	base:   i64,
	code:   []u8,
}

// Erro como valor, não como exceção: Odin não tem exceções, e a convenção da
// biblioteca padrão é devolver `(resultado, ok)` ou um enum de erro.
Erro :: struct {
	msg: string,
}

falha: Maybe(Erro)

erro :: proc(msg: string) {
	if falha == nil {
		falha = Erro{msg = msg}
	}
}

// Formatação do PRINT. Casa com `value_print` do C: inteiro em decimal, array
// como `[1, 2, 3]`, `nil` para ponteiro nulo.
formata :: proc(v: Value, sb: ^strings.Builder) {
	switch x in v {
	case i64:
		fmt.sbprintf(sb, "%d", x)
	case ^FvmArray:
		if x == nil {
			strings.write_string(sb, "nil")
			return
		}
		strings.write_byte(sb, '[')
		for it, i in x.items {
			if i > 0 {
				strings.write_string(sb, ", ")
			}
			formata(it, sb)
		}
		strings.write_byte(sb, ']')
	}
}

// ------------------------------------------------------------------ bytecode
//
// Formato do .fbc (docs/ISA.md):
//
//   offset 0  : "FVM1"   4 bytes
//   offset 4  : entry     u32 little-endian
//   offset 8  : len       u32 little-endian
//   offset 12 : code[len]

carrega :: proc(caminho: string) -> (Chunk, bool) {
	// `read_entire_file_from_path` devolve (data, Error) nesta versao do Odin,
	// e o alocador e explicito -- aqui, a arena definida no main.
	bruto, err_io := os.read_entire_file_from_path(caminho, context.allocator)
	if err_io != nil {
		erro("nao foi possivel ler o arquivo")
		return {}, false
	}

	if len(bruto) < 12 {
		erro("arquivo curto demais para ser um .fbc")
		return {}, false
	}

	if string(bruto[0:4]) != "FVM1" {
		erro("magic invalido: esperava FVM1")
		return {}, false
	}

	// `endian.get_u32` devolve `ok`: buffer curto não vira leitura fora dos
	// limites em silêncio, como seria um memcpy em C.
	entry_u, ok1 := endian.get_u32(bruto[4:8], .Little)
	len_u, ok2 := endian.get_u32(bruto[8:12], .Little)
	if !ok1 || !ok2 {
		erro("cabecalho truncado")
		return {}, false
	}

	n := int(len_u)
	if 12 + n > len(bruto) {
		erro("len do cabecalho maior que o arquivo")
		return {}, false
	}
	if int(entry_u) > n {
		erro("entry fora do codigo")
		return {}, false
	}

	return Chunk{code = bruto[12:12 + n], entry = int(entry_u)}, true
}

// ----------------------------------------------------------------- execução

empilha :: proc(vm: ^Vm, v: Value) {
	if vm.sp >= STACK_MAX {
		erro("estouro da pilha de dados")
		return
	}
	vm.pilha[vm.sp] = v
	vm.sp += 1
}

desempilha :: proc(vm: ^Vm) -> Value {
	if vm.sp <= 0 {
		erro("pilha vazia")
		return i64(0)
	}
	vm.sp -= 1
	return vm.pilha[vm.sp]
}

precisa :: proc(vm: ^Vm, n: i64) -> bool {
	if vm.sp < n {
		erro("pilha com valores insuficientes")
		return false
	}
	return true
}

inteiro :: proc(v: Value) -> i64 {
	switch x in v {
	case i64:
		return x
	case ^FvmArray:
		erro("esperava inteiro, veio array")
		return 0
	}
	return 0
}

vetor :: proc(v: Value) -> ^FvmArray {
	switch x in v {
	case i64:
		erro("esperava array, veio inteiro")
		return nil
	case ^FvmArray:
		if x == nil {
			erro("array nulo")
		}
		return x
	}
	return nil
}

le_u8 :: proc(vm: ^Vm) -> u8 {
	b := vm.code[vm.ip]
	vm.ip += 1
	return b
}

le_i32 :: proc(vm: ^Vm) -> i32 {
	v, _ := endian.get_i32(vm.code[vm.ip:vm.ip + 4], .Little)
	vm.ip += 4
	return v
}

le_i64 :: proc(vm: ^Vm) -> i64 {
	v, _ := endian.get_i64(vm.code[vm.ip:vm.ip + 8], .Little)
	vm.ip += 8
	return v
}

executa :: proc(chunk: Chunk) {
	vm := Vm {
		pilha  = make([]Value, STACK_MAX),
		frames = make([]Frame, FRAMES_MAX),
		code   = chunk.code,
		ip     = i64(chunk.entry),
	}

	// Frame raiz antes da primeira instrução, como em C, para que LOAD, STORE
	// e RET funcionem no topo sem caso especial dentro do laço.
	vm.frames[0] = Frame{ret_ip = -1, base = 0}
	vm.fp = 1

	sb := strings.builder_make()

	for {
		if falha != nil {
			return
		}

		if vm.ip < 0 || vm.ip >= i64(len(vm.code)) {
			erro("ip fora do codigo")
			return
		}

		op := Op(vm.code[vm.ip])
		vm.ip += 1

		switch op {
		case .Halt:
			return

		case .Push:
			empilha(&vm, le_i64(&vm))

		case .Pop:
			if !precisa(&vm, 1) {return}
			vm.sp -= 1

		case .Dup:
			if !precisa(&vm, 1) {return}
			empilha(&vm, vm.pilha[vm.sp - 1])

		case .Swap:
			if !precisa(&vm, 2) {return}
			vm.pilha[vm.sp - 1], vm.pilha[vm.sp - 2] = vm.pilha[vm.sp - 2], vm.pilha[vm.sp - 1]

		case .Add, .Sub, .Mul, .Div, .Mod, .Lt, .Le, .Gt, .Ge, .Eq, .Ne:
			if !precisa(&vm, 2) {return}
			b := inteiro(desempilha(&vm))
			a := inteiro(desempilha(&vm))
			r: i64
			switch op {
			case .Add:
				r = a + b
			case .Sub:
				r = a - b
			case .Mul:
				r = a * b
			case .Div:
				if b == 0 {
					erro("divisao por zero")
					return
				}
				r = a / b
			case .Mod:
				if b == 0 {
					erro("modulo por zero")
					return
				}
				r = a % b
			case .Lt:
				r = a < b ? 1 : 0
			case .Le:
				r = a <= b ? 1 : 0
			case .Gt:
				r = a > b ? 1 : 0
			case .Ge:
				r = a >= b ? 1 : 0
			case .Eq:
				r = a == b ? 1 : 0
			case .Ne:
				r = a != b ? 1 : 0
			case .Halt, .Push, .Pop, .Dup, .Swap, .Neg, .Jmp, .Jz, .Jnz, .Load,
			     .Store, .Reserve, .Call, .Ret, .Print, .Newarr, .Aget, .Aset,
			     .Alen, .Gc, .Calli:
				erro("opcode binario inesperado")
				return
			}
			empilha(&vm, r)

		case .Neg:
			if !precisa(&vm, 1) {return}
			empilha(&vm, -inteiro(desempilha(&vm)))

		case .Jmp:
			vm.ip = i64(le_i32(&vm))

		case .Jz:
			dest := le_i32(&vm)
			if !precisa(&vm, 1) {return}
			if inteiro(desempilha(&vm)) == 0 {
				vm.ip = i64(dest)
			}

		case .Jnz:
			dest := le_i32(&vm)
			if !precisa(&vm, 1) {return}
			if inteiro(desempilha(&vm)) != 0 {
				vm.ip = i64(dest)
			}

		case .Load:
			slot := le_i32(&vm)
			idx := vm.base + i64(slot)
			if slot < 0 || idx >= vm.sp {
				erro("LOAD de slot inexistente")
				return
			}
			empilha(&vm, vm.pilha[idx])

		case .Store:
			slot := le_i32(&vm)
			idx := vm.base + i64(slot)
			if !precisa(&vm, 1) {return}
			if slot < 0 || idx >= vm.sp {
				erro("STORE em slot inexistente")
				return
			}
			vm.pilha[idx] = desempilha(&vm)

		case .Reserve:
			n := le_i32(&vm)
			if n < 0 {
				erro("RESERVE negativo")
				return
			}
			for _ in 0 ..< n {
				empilha(&vm, i64(0))
			}

		case .Call:
			destino := le_i32(&vm)
			nargs := i64(le_u8(&vm))
			if destino < 0 || int(destino) >= len(vm.code) {
				erro("CALL para endereco invalido")
				return
			}
			if vm.sp < nargs {
				erro("CALL sem argumentos suficientes")
				return
			}
			if vm.fp >= FRAMES_MAX {
				erro("estouro da pilha de chamadas")
				return
			}
			vm.frames[vm.fp] = Frame{ret_ip = vm.ip, base = vm.sp - nargs}
			vm.fp += 1
			vm.base = vm.sp - nargs
			vm.ip = i64(destino)

		case .Ret:
			if !precisa(&vm, 1) {return}
			v := desempilha(&vm)
			vm.fp -= 1
			f := vm.frames[vm.fp]
			vm.sp = f.base
			empilha(&vm, v)
			if vm.fp == 0 {
				return
			}
			vm.base = vm.frames[vm.fp - 1].base
			vm.ip = f.ret_ip

		case .Print:
			if !precisa(&vm, 1) {return}
			strings.builder_reset(&sb)
			formata(desempilha(&vm), &sb)
			fmt.println(strings.to_string(sb))

		case .Newarr:
			if !precisa(&vm, 1) {return}
			n := inteiro(desempilha(&vm))
			if n < 0 {
				erro("NEWARR exige tamanho inteiro >= 0")
				return
			}
			// Alocado do `context.allocator`, que o `main` definiu como a
			// arena. Nada é liberado individualmente -- ver o topo do arquivo.
			a := new(FvmArray)
			a.items = make([]Value, int(n))
			for i in 0 ..< int(n) {
				a.items[i] = i64(0)
			}
			empilha(&vm, a)

		case .Aget:
			if !precisa(&vm, 2) {return}
			idx := inteiro(desempilha(&vm))
			a := vetor(desempilha(&vm))
			if a == nil {return}
			if idx < 0 || int(idx) >= len(a.items) {
				erro("AGET fora dos limites")
				return
			}
			empilha(&vm, a.items[idx])

		case .Aset:
			if !precisa(&vm, 3) {return}
			v := desempilha(&vm)
			idx := inteiro(desempilha(&vm))
			a := vetor(desempilha(&vm))
			if a == nil {return}
			if idx < 0 || int(idx) >= len(a.items) {
				erro("ASET fora dos limites")
				return
			}
			a.items[idx] = v

		case .Alen:
			if !precisa(&vm, 1) {return}
			a := vetor(desempilha(&vm))
			if a == nil {return}
			empilha(&vm, i64(len(a.items)))

		case .Gc:
			// Não há coletor. A arena só cresce, e isso está declarado no topo
			// do arquivo e medido na coluna de RSS de ports/README.md.
			//
			// Um no-op honesto é melhor que chamar algo que não recicla: o
			// porte em V tomou a mesma decisão por outro motivo.

		case .Calli:
			nargs := i64(le_u8(&vm))
			if vm.sp < nargs + 1 {
				erro("CALLI sem closure e argumentos suficientes")
				return
			}
			nova_base := vm.sp - nargs - 1
			clo := vetor(vm.pilha[nova_base])
			if clo == nil {return}
			if len(clo.items) < 1 {
				erro("CALLI: closure sem endereco de codigo")
				return
			}
			destino := inteiro(clo.items[0])
			if destino < 0 || int(destino) >= len(vm.code) {
				erro("CALLI: endereco de codigo fora do programa")
				return
			}
			if vm.fp >= FRAMES_MAX {
				erro("estouro da pilha de chamadas")
				return
			}
			vm.frames[vm.fp] = Frame{ret_ip = vm.ip, base = nova_base}
			vm.fp += 1
			vm.base = nova_base
			vm.ip = destino
		}
	}
}

main :: proc() {
	args := os.args
	if len(args) != 2 {
		fmt.eprintln("uso: fvm_odin <prog.fbc>")
		os.exit(64)
	}

	// A arena como alocador do programa inteiro. Esta é a decisão de memória
	// do porte, e ela fica em UM lugar -- não espalhada por cada alocação,
	// como os malloc/free do C.
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		fmt.eprintln("nao foi possivel criar a arena")
		os.exit(70)
	}
	context.allocator = virtual.arena_allocator(&arena)

	chunk, ok := carrega(args[1])
	if !ok {
		if e, tem := falha.?; tem {
			fmt.eprintfln("erro de carga: %s", e.msg)
		}
		os.exit(66)
	}

	executa(chunk)

	if e, tem := falha.?; tem {
		fmt.eprintfln("erro de execucao: %s", e.msg)
		os.exit(70)
	}

	// `mem.free_all` em vez de liberar objeto por objeto: a arena devolve tudo
	// de uma vez. É a vantagem do desenho, e a razão de ele ser aceitável aqui.
	virtual.arena_destroy(&arena)
	_ = mem.Allocator{}
}
