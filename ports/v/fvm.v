// fvm.v — porte do núcleo mínimo da Forge VM para V.
//
// ## O que este arquivo é
//
// Um **porte**: executa `.fbc` montado pela implementação em C e produz saída
// byte a byte idêntica nos 9 casos de `tests/cases/`. Sem montador, sem
// `--stats`, sem desmontador. Ver `ports/README.md`.
//
// ## A restrição do V que mudou o desenho, e para onde ela empurrou
//
// A primeira versão deste porte declarava o que parecia obvio:
//
//     type Value = i64 | &FvmArray
//
// O compilador recusou:
//
//     error: sum type cannot hold a reference type
//     Details: declare the sum type with non-reference types
//
// Tipo-soma em V não pode conter referência. E um array da VM **tem** de ser
// compartilhado: `ASET` sobre uma cópia não mutaria o original, e o
// `arrays.fasm` falharia.
//
// A saída foi um **handle**: `ArrRef` guarda um índice para uma arena de
// arrays dentro da VM, e o tipo-soma guarda o handle, que é struct de um `int`.
//
// O interessante é **onde isso chegou**: é exatamente o desenho que a
// implementação em Rust deste mesmo projeto usa (`rust/src/gc.rs`, arena com
// handles), e lá o motivo foi outro — o borrow checker não aceita um grafo de
// objetos com donos múltiplos. Duas linguagens, duas restrições diferentes, a
// mesma solução.
//
// ## O que o V deu, e o que a restrição tirou
//
// **Deu:** tipo-soma na linguagem (não na biblioteca, como o `SumType` de D),
// `match` exaustivo por padrão, e erros como valores — `!Chunk` no retorno
// obriga o chamador a tratar, igual ao `Result` do Rust.
//
// **Tirou:** o coletor de lixo. O V tem GC, mas a arena mantém **toda** array
// alcançável para sempre pelo índice, então o GC não tem o que recolher. Este
// porte não recicla memória.
//
// Isso é honesto e **medido**: os 9 casos passam igual, porque eles verificam
// semântica e não reciclagem — o `gc.fasm` cria 20 mil arrays descartados e só
// confere que `42` é impresso. A coluna de RSS em `ports/README.md` mede o que
// os casos não medem, e este porte aparece lá com o custo que cobra.
//
// uso: fvm_v <prog.fbc>

module main

import os

const stack_max = 1 << 16
const frames_max = 1024

// Os 32 opcodes, na ordem de `c/include/fvm.h`. A ordem É o formato binário:
// trocar duas linhas aqui quebra todo `.fbc` existente.
//
// `do_div` e não `div` porque `div` é palavra reservada em V.
enum Op as u8 {
	halt = 0
	push
	pop
	dup
	swap
	add
	sub
	mul
	do_div
	mod
	neg
	lt
	le
	gt
	ge
	eq
	ne
	jmp
	jz
	jnz
	load
	store
	reserve
	call
	ret
	print
	newarr
	aget
	aset
	alen
	gc
	calli
}

// Handle para a arena. Struct de um campo, e não um `int` solto, para que o
// tipo-soma distinga "o inteiro 3" de "o array 3" -- sem isso, `Value = i64 |
// int` seria ambíguo e `AGET` aceitaria um inteiro como array.
struct ArrRef {
	idx int
}

// Tipo-soma nativo, com os dois lados sendo tipos de valor.
type Value = ArrRef | i64

struct FvmArray {
mut:
	items []Value
}

struct Frame {
	ret_ip i64
	base   i64
}

struct Chunk {
	code  []u8
	entry int
}

// ------------------------------------------------------------------ bytecode
//
// Formato do .fbc (docs/ISA.md):
//
//   offset 0  : "FVM1"   4 bytes
//   offset 4  : entry     u32 little-endian
//   offset 8  : len       u32 little-endian
//   offset 12 : code[len]
//
// Montado byte por byte, e não por reinterpretação de memória: o formato é
// definido como little-endian, e um cast funcionaria por acidente na máquina
// de hoje e quebraria num alvo big-endian.

fn le_u32(b []u8, off int) u32 {
	return u32(b[off]) | (u32(b[off + 1]) << 8) | (u32(b[off + 2]) << 16) | (u32(b[off + 3]) << 24)
}

fn le_i32(b []u8, off int) int {
	return int(i32(le_u32(b, off)))
}

fn le_i64(b []u8, off int) i64 {
	mut r := u64(0)
	for k := 7; k >= 0; k-- {
		r = (r << 8) | u64(b[off + k])
	}
	return i64(r)
}

fn carrega(caminho string) !Chunk {
	bruto := os.read_bytes(caminho)!

	if bruto.len < 12 {
		return error('arquivo curto demais para ser um .fbc')
	}
	if bruto[0] != `F` || bruto[1] != `V` || bruto[2] != `M` || bruto[3] != `1` {
		return error('magic invalido: esperava FVM1')
	}

	entry := int(le_u32(bruto, 4))
	n := int(le_u32(bruto, 8))

	if 12 + n > bruto.len {
		return error('len do cabecalho (${n}) maior que o arquivo')
	}
	if entry > n {
		return error('entry fora do codigo')
	}

	return Chunk{
		code:  bruto[12..12 + n]
		entry: entry
	}
}

// ----------------------------------------------------------------- execução

struct Vm {
mut:
	pilha  []Value
	sp     i64
	frames []Frame
	fp     i64
	ip     i64
	base   i64
	code   []u8
	// A arena. Cresce e nunca encolhe -- ver o comentário do topo.
	arena []&FvmArray
}

fn (mut vm Vm) empilha(v Value) ! {
	if vm.sp >= stack_max {
		return error('estouro da pilha de dados')
	}
	vm.pilha[vm.sp] = v
	vm.sp++
}

fn (mut vm Vm) desempilha() !Value {
	if vm.sp <= 0 {
		return error('pilha vazia')
	}
	vm.sp--
	return vm.pilha[vm.sp]
}

fn (mut vm Vm) precisa(n i64) ! {
	if vm.sp < n {
		return error('pilha com menos de ${n} valores')
	}
}

fn inteiro(v Value) !i64 {
	match v {
		i64 { return v }
		ArrRef { return error('esperava inteiro, veio array') }
	}
}

// Resolve o handle. A validação do índice está aqui, e não em cada opcode,
// porque um `.fbc` mal gerado é o caso de uso previsto -- o compilador do p02
// em desenvolvimento emite bytecode errado o tempo todo.
fn (vm &Vm) resolve(v Value) !&FvmArray {
	match v {
		i64 {
			return error('esperava array, veio inteiro')
		}
		ArrRef {
			if v.idx < 0 || v.idx >= vm.arena.len {
				return error('handle de array fora da arena')
			}
			return vm.arena[v.idx]
		}
	}
}

fn (mut vm Vm) le_u8() u8 {
	b := vm.code[vm.ip]
	vm.ip++
	return b
}

fn (mut vm Vm) le_op_i32() int {
	v := le_i32(vm.code, int(vm.ip))
	vm.ip += 4
	return v
}

fn (mut vm Vm) le_op_i64() i64 {
	v := le_i64(vm.code, int(vm.ip))
	vm.ip += 8
	return v
}

// Formatação do PRINT. Casa com `value_print` do C: inteiro em decimal, array
// como `[1, 2, 3]`. Precisa da VM porque o valor é um handle, não o array.
fn (vm &Vm) formata(v Value) string {
	match v {
		i64 {
			return v.str()
		}
		ArrRef {
			if v.idx < 0 || v.idx >= vm.arena.len {
				return 'nil'
			}
			a := vm.arena[v.idx]
			mut partes := []string{cap: a.items.len}
			for it in a.items {
				partes << vm.formata(it)
			}
			return '[' + partes.join(', ') + ']'
		}
	}
}

fn executa(chunk Chunk) ! {
	mut vm := Vm{
		pilha:  []Value{len: stack_max, init: Value(i64(0))}
		frames: []Frame{len: frames_max}
		code:   chunk.code
		ip:     i64(chunk.entry)
		arena:  []&FvmArray{}
	}

	// Frame raiz antes da primeira instrução, como em C, para que LOAD, STORE
	// e RET funcionem no topo sem caso especial dentro do laço.
	vm.frames[0] = Frame{
		ret_ip: -1
		base:   0
	}
	vm.fp = 1

	for {
		if vm.ip < 0 || vm.ip >= i64(vm.code.len) {
			return error('ip fora do codigo')
		}

		op := unsafe { Op(vm.code[vm.ip]) }
		vm.ip++

		match op {
			.halt {
				return
			}
			.push {
				vm.empilha(Value(vm.le_op_i64()))!
			}
			.pop {
				vm.precisa(1)!
				vm.sp--
			}
			.dup {
				vm.precisa(1)!
				t := vm.pilha[vm.sp - 1]
				vm.empilha(t)!
			}
			.swap {
				vm.precisa(2)!
				t := vm.pilha[vm.sp - 1]
				vm.pilha[vm.sp - 1] = vm.pilha[vm.sp - 2]
				vm.pilha[vm.sp - 2] = t
			}
			.add, .sub, .mul, .do_div, .mod, .lt, .le, .gt, .ge, .eq, .ne {
				vm.precisa(2)!
				b := inteiro(vm.desempilha()!)!
				a := inteiro(vm.desempilha()!)!
				r := match op {
					.add { a + b }
					.sub { a - b }
					.mul { a * b }
					.do_div {
						if b == 0 {
							return error('divisao por zero')
						}
						a / b
					}
					.mod {
						if b == 0 {
							return error('modulo por zero')
						}
						a % b
					}
					.lt { if a < b { i64(1) } else { i64(0) } }
					.le { if a <= b { i64(1) } else { i64(0) } }
					.gt { if a > b { i64(1) } else { i64(0) } }
					.ge { if a >= b { i64(1) } else { i64(0) } }
					.eq { if a == b { i64(1) } else { i64(0) } }
					.ne { if a != b { i64(1) } else { i64(0) } }
					else { return error('opcode binario inesperado') }
				}
				vm.empilha(Value(r))!
			}
			.neg {
				vm.precisa(1)!
				n := inteiro(vm.desempilha()!)!
				// O temporário é obrigatório: `Value(-n)` faz o V gerar
				// `i64_to_sumtype_main__Value(&-n, ...)` e o C recusa com
				// "lvalue required as unary '&' operand". É bug de geração de
				// código do V 0.5.2, não erro de tipo -- o compilador do V
				// aceita, e a falha aparece no cc.
				oposto := -n
				vm.empilha(Value(oposto))!
			}
			.jmp {
				vm.ip = i64(vm.le_op_i32())
			}
			.jz {
				dest := vm.le_op_i32()
				vm.precisa(1)!
				if inteiro(vm.desempilha()!)! == 0 {
					vm.ip = i64(dest)
				}
			}
			.jnz {
				dest := vm.le_op_i32()
				vm.precisa(1)!
				if inteiro(vm.desempilha()!)! != 0 {
					vm.ip = i64(dest)
				}
			}
			.load {
				slot := vm.le_op_i32()
				idx := vm.base + i64(slot)
				if slot < 0 || idx >= vm.sp {
					return error('LOAD de slot inexistente')
				}
				t := vm.pilha[idx]
				vm.empilha(t)!
			}
			.store {
				slot := vm.le_op_i32()
				idx := vm.base + i64(slot)
				vm.precisa(1)!
				if slot < 0 || idx >= vm.sp {
					return error('STORE em slot inexistente')
				}
				vm.pilha[idx] = vm.desempilha()!
			}
			.reserve {
				n := vm.le_op_i32()
				if n < 0 {
					return error('RESERVE negativo')
				}
				for _ in 0 .. n {
					vm.empilha(Value(i64(0)))!
				}
			}
			.call {
				destino := vm.le_op_i32()
				nargs := i64(vm.le_u8())
				if destino < 0 || destino >= vm.code.len {
					return error('CALL para endereco invalido')
				}
				if vm.sp < nargs {
					return error('CALL sem argumentos suficientes')
				}
				if vm.fp >= frames_max {
					return error('estouro da pilha de chamadas')
				}
				vm.frames[vm.fp] = Frame{
					ret_ip: vm.ip
					base:   vm.sp - nargs
				}
				vm.fp++
				vm.base = vm.sp - nargs
				vm.ip = i64(destino)
			}
			.ret {
				vm.precisa(1)!
				v := vm.desempilha()!
				vm.fp--
				f := vm.frames[vm.fp]
				vm.sp = f.base
				vm.empilha(v)!
				if vm.fp == 0 {
					return
				}
				vm.base = vm.frames[vm.fp - 1].base
				vm.ip = f.ret_ip
			}
			.print {
				vm.precisa(1)!
				v := vm.desempilha()!
				println(vm.formata(v))
			}
			.newarr {
				vm.precisa(1)!
				n := inteiro(vm.desempilha()!)!
				if n < 0 {
					return error('NEWARR exige tamanho inteiro >= 0')
				}
				a := &FvmArray{
					items: []Value{len: int(n), init: Value(i64(0))}
				}
				vm.arena << a
				vm.empilha(Value(ArrRef{ idx: vm.arena.len - 1 }))!
			}
			.aget {
				vm.precisa(2)!
				idx := inteiro(vm.desempilha()!)!
				a := vm.resolve(vm.desempilha()!)!
				if idx < 0 || idx >= i64(a.items.len) {
					return error('AGET fora dos limites')
				}
				t := a.items[idx]
				vm.empilha(t)!
			}
			.aset {
				vm.precisa(3)!
				v := vm.desempilha()!
				idx := inteiro(vm.desempilha()!)!
				mut a := vm.resolve(vm.desempilha()!)!
				if idx < 0 || idx >= i64(a.items.len) {
					return error('ASET fora dos limites')
				}
				a.items[idx] = v
			}
			.alen {
				vm.precisa(1)!
				a := vm.resolve(vm.desempilha()!)!
				vm.empilha(Value(i64(a.items.len)))!
			}
			.gc {
				// Não há nada a fazer: a arena mantém toda array alcançável
				// pelo índice, então o GC do V não tem o que recolher. É a
				// consequência direta da restrição de tipo-soma explicada no
				// topo deste arquivo, e está medida na coluna de RSS de
				// ports/README.md.
				//
				// Chamar gc_collect() aqui seria teatro: daria a impressão de
				// que o opcode faz algo.
			}
			.calli {
				nargs := i64(vm.le_u8())
				if vm.sp < nargs + 1 {
					return error('CALLI sem closure e argumentos suficientes')
				}
				nova_base := vm.sp - nargs - 1
				clo := vm.resolve(vm.pilha[nova_base])!
				if clo.items.len < 1 {
					return error('CALLI: closure sem endereco de codigo')
				}
				destino := inteiro(clo.items[0])!
				if destino < 0 || destino >= i64(vm.code.len) {
					return error('CALLI: endereco de codigo fora do programa')
				}
				if vm.fp >= frames_max {
					return error('estouro da pilha de chamadas')
				}
				vm.frames[vm.fp] = Frame{
					ret_ip: vm.ip
					base:   nova_base
				}
				vm.fp++
				vm.base = nova_base
				vm.ip = destino
			}
		}
	}
}

fn main() {
	if os.args.len != 2 {
		eprintln('uso: fvm_v <prog.fbc>')
		exit(64)
	}

	chunk := carrega(os.args[1]) or {
		eprintln('erro de carga: ${err}')
		exit(66)
	}

	executa(chunk) or {
		eprintln('erro de execucao: ${err}')
		exit(70)
	}
}
