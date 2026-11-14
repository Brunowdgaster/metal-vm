//! O loop de execução.
//!
//! # Por que não há variante "computed goto" aqui
//!
//! A versão em C compila o mesmo corpo de instruções de duas formas: `switch`
//! e computed goto. Em Rust estável e seguro, a segunda **não existe**:
//!
//! - não há `goto`, muito menos `goto *expr`;
//! - não há como tomar o endereço de um rótulo;
//! - a alternativa idiomática — um `match` que o compilador transforma em
//!   tabela de salto — é exatamente o que o `switch` do C já faz;
//! - despacho por chamadas em cauda (`become`) depende de feature instável.
//!
//! Isso não é lacuna do porte, é **resultado da comparação**: a técnica não
//! está disponível em Rust seguro. E, medida em duas máquinas, ela ganha numa
//! e perde na outra (docs/BENCH.md), o que torna a ausência bem menos grave
//! do que parecia quando este comentário foi escrito. Quem precisa dela em
//! Rust escreve `unsafe` com uma tabela de ponteiros de função, e aí perde
//! justamente a propriedade pela qual escolheu Rust.
//!
//! # Onde fica a pilha
//!
//! Em `stack.rs`, com duas implementações atrás da mesma interface
//! (`Vec<Value>` e `Box<[Value]>` + `sp`), selecionadas pela feature
//! `boxed-stack`. O corpo do interpretador abaixo é escrito uma única vez e
//! serve às duas — mesma estratégia dos macros de dispatch em `c/src/vm.c`.
//! O porquê e os números estão em `stack.rs` e em docs/BENCH.md.
//!
//! O porte inteiro não tem uma linha de `unsafe`. O custo disso é um teste de
//! limite por indexação que o C não paga; medi-lo é o ponto do projeto.

use crate::chunk::*;
use crate::gc::Heap;
use crate::stack::Stack;
use crate::value::{format_value, Value};
use std::io::Write;

pub const FRAMES_MAX: usize = 4096;

#[derive(Clone, Copy)]
struct Frame {
    ret_ip: usize,
    base: usize,
}

pub struct Vm {
    stack: Stack,
    frames: Box<[Frame]>,
    fp: usize,
    pub heap: Heap,
    pub ins_count: u64,
    pub trace: bool,
}

fn err(ip: usize, msg: &str) -> String {
    format!("erro em tempo de execucao @{ip:06}: {msg}")
}

#[inline(always)]
fn rd_u8(code: &[u8], ip: &mut usize) -> Result<u8, String> {
    let b = *code
        .get(*ip)
        .ok_or_else(|| err(*ip, "fim do codigo sem HALT"))?;
    *ip += 1;
    Ok(b)
}

#[inline(always)]
fn rd_i32(code: &[u8], ip: &mut usize) -> Result<i32, String> {
    if *ip + 4 > code.len() {
        return Err(err(*ip, "operando de 32 bits truncado"));
    }
    let v = i32::from_le_bytes(code[*ip..*ip + 4].try_into().unwrap());
    *ip += 4;
    Ok(v)
}

#[inline(always)]
fn rd_i64(code: &[u8], ip: &mut usize) -> Result<i64, String> {
    if *ip + 8 > code.len() {
        return Err(err(*ip, "operando de 64 bits truncado"));
    }
    let v = i64::from_le_bytes(code[*ip..*ip + 8].try_into().unwrap());
    *ip += 8;
    Ok(v)
}

impl Vm {
    pub fn new() -> Self {
        Vm {
            stack: Stack::new(),
            frames: vec![Frame { ret_ip: 0, base: 0 }; FRAMES_MAX].into_boxed_slice(),
            fp: 0,
            heap: Heap::new(),
            ins_count: 0,
            trace: false,
        }
    }

    /// Contador condicional, espelhando `FVM_STATS` do build em C. Sem a
    /// feature `stats`, o corpo desaparece e a chamada é eliminada.
    #[inline(always)]
    fn count(&mut self) {
        #[cfg(feature = "stats")]
        {
            self.ins_count += 1;
        }
    }

    #[inline(always)]
    fn push(&mut self, ip: usize, v: Value) -> Result<(), String> {
        if self.stack.push(v) {
            Ok(())
        } else {
            Err(err(ip, "estouro da pilha de operandos"))
        }
    }

    #[inline(always)]
    fn pop(&mut self, ip: usize) -> Result<Value, String> {
        self.stack
            .pop()
            .ok_or_else(|| err(ip, "pilha insuficiente"))
    }

    #[inline(always)]
    fn pop_int(&mut self, ip: usize) -> Result<i64, String> {
        match self.pop(ip)? {
            Value::Int(i) => Ok(i),
            Value::Obj(_) => Err(err(ip, "esperado inteiro, veio objeto")),
        }
    }

    fn pop_array(&mut self, ip: usize) -> Result<usize, String> {
        match self.pop(ip)? {
            Value::Obj(id) => {
                if self.heap.get(id).is_some() {
                    Ok(id)
                } else {
                    Err(err(ip, "referencia para objeto liberado"))
                }
            }
            Value::Int(_) => Err(err(ip, "esperado array, veio inteiro")),
        }
    }

    pub fn run(&mut self, chunk: &Chunk, out: &mut dyn Write) -> Result<(), String> {
        if chunk.code.is_empty() {
            return Ok(());
        }
        let code = &chunk.code;
        let mut ip = chunk.entry as usize;
        if ip >= code.len() {
            return Err(err(ip, "entry fora do codigo"));
        }

        // Frame raiz: faz LOAD/STORE/RET funcionarem no nível de topo sem
        // nenhum caso especial dentro do loop quente. Igual à versão em C.
        self.frames[0] = Frame { ret_ip: 0, base: 0 };
        self.fp = 1;
        let mut base: usize = 0;

        loop {
            self.count();

            if self.trace {
                let name = code
                    .get(ip)
                    .and_then(|o| op_info(*o))
                    .map(|i| i.name)
                    .unwrap_or("???");
                eprintln!(
                    "[{:06}] {:<8} sp={} fp={}",
                    ip,
                    name,
                    self.stack.len(),
                    self.fp
                );
            }

            let op = rd_u8(code, &mut ip)?;

            match op {
                OP_HALT => return Ok(()),

                OP_PUSH => {
                    let v = rd_i64(code, &mut ip)?;
                    self.push(ip, Value::Int(v))?;
                }

                OP_POP => {
                    self.pop(ip)?;
                }

                OP_DUP => {
                    let v = self
                        .stack
                        .top()
                        .ok_or_else(|| err(ip, "pilha insuficiente"))?;
                    self.push(ip, v)?;
                }

                OP_SWAP => {
                    if !self.stack.swap_top2() {
                        return Err(err(ip, "pilha insuficiente"));
                    }
                }

                // `wrapping_*` é deliberado: em C, estouro de inteiro com
                // sinal é comportamento indefinido e o -O3 explora isso; em
                // Rust, `a + b` entraria em pânico em debug e faria wrapping
                // em release. `wrapping_*` fixa a semântica nas duas builds e
                // a iguala à que o C de fato produz em -O3.
                OP_ADD => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int(a.wrapping_add(b)))?;
                }
                OP_SUB => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int(a.wrapping_sub(b)))?;
                }
                OP_MUL => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int(a.wrapping_mul(b)))?;
                }
                OP_DIV => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    if b == 0 {
                        return Err(err(ip, "divisao por zero"));
                    }
                    self.push(ip, Value::Int(a.wrapping_div(b)))?;
                }
                OP_MOD => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    if b == 0 {
                        return Err(err(ip, "modulo por zero"));
                    }
                    self.push(ip, Value::Int(a.wrapping_rem(b)))?;
                }
                OP_NEG => {
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int(a.wrapping_neg()))?;
                }

                OP_LT => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int((a < b) as i64))?;
                }
                OP_LE => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int((a <= b) as i64))?;
                }
                OP_GT => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int((a > b) as i64))?;
                }
                OP_GE => {
                    let b = self.pop_int(ip)?;
                    let a = self.pop_int(ip)?;
                    self.push(ip, Value::Int((a >= b) as i64))?;
                }

                OP_EQ => {
                    let b = self.pop(ip)?;
                    let a = self.pop(ip)?;
                    self.push(ip, Value::Int((a == b) as i64))?;
                }
                OP_NE => {
                    let b = self.pop(ip)?;
                    let a = self.pop(ip)?;
                    self.push(ip, Value::Int((a != b) as i64))?;
                }

                OP_JMP => {
                    let t = rd_i32(code, &mut ip)?;
                    if t < 0 || t as usize >= code.len() {
                        return Err(err(ip, "JMP fora do codigo"));
                    }
                    ip = t as usize;
                }

                OP_JZ => {
                    let t = rd_i32(code, &mut ip)?;
                    let c = self.pop(ip)?;
                    if !c.is_truthy() {
                        if t < 0 || t as usize >= code.len() {
                            return Err(err(ip, "JZ fora do codigo"));
                        }
                        ip = t as usize;
                    }
                }

                OP_JNZ => {
                    let t = rd_i32(code, &mut ip)?;
                    let c = self.pop(ip)?;
                    if c.is_truthy() {
                        if t < 0 || t as usize >= code.len() {
                            return Err(err(ip, "JNZ fora do codigo"));
                        }
                        ip = t as usize;
                    }
                }

                OP_LOAD => {
                    let slot = rd_i32(code, &mut ip)?;
                    if slot < 0 {
                        return Err(err(ip, "LOAD com slot negativo"));
                    }
                    let v = self
                        .stack
                        .get(base + slot as usize)
                        .ok_or_else(|| err(ip, "LOAD de slot inexistente"))?;
                    self.push(ip, v)?;
                }

                OP_STORE => {
                    let slot = rd_i32(code, &mut ip)?;
                    if slot < 0 {
                        return Err(err(ip, "STORE com slot negativo"));
                    }
                    let v = self.pop(ip)?;
                    if !self.stack.set(base + slot as usize, v) {
                        return Err(err(ip, "STORE em slot inexistente"));
                    }
                }

                OP_RESERVE => {
                    let n = rd_i32(code, &mut ip)?;
                    if n < 0 {
                        return Err(err(ip, "RESERVE negativo"));
                    }
                    for _ in 0..n {
                        self.push(ip, Value::Int(0))?;
                    }
                }

                OP_CALL => {
                    let target = rd_i32(code, &mut ip)?;
                    let nargs = rd_u8(code, &mut ip)? as usize;
                    if target < 0 || target as usize >= code.len() {
                        return Err(err(ip, "CALL para endereco invalido"));
                    }
                    if self.stack.len() < nargs {
                        return Err(err(ip, "CALL sem argumentos suficientes"));
                    }
                    if self.fp >= FRAMES_MAX {
                        return Err(err(ip, "estouro da pilha de chamadas"));
                    }
                    base = self.stack.len() - nargs;
                    self.frames[self.fp] = Frame { ret_ip: ip, base };
                    self.fp += 1;
                    ip = target as usize;
                }

                OP_RET => {
                    let v = self.pop(ip)?;
                    if self.fp == 0 {
                        return Err(err(ip, "RET sem frame"));
                    }
                    self.fp -= 1;
                    let f = self.frames[self.fp];
                    self.stack.truncate(f.base); // descarta args e locais
                    if self.fp == 0 {
                        // RET no frame raiz encerra o programa.
                        self.push(ip, v)?;
                        return Ok(());
                    }
                    self.push(ip, v)?;
                    base = self.frames[self.fp - 1].base;
                    ip = f.ret_ip;
                }

                OP_PRINT => {
                    let v = self.pop(ip)?;
                    let s = format_value(&self.heap, v);
                    writeln!(out, "{s}")
                        .map_err(|e| err(ip, &format!("falha ao escrever: {e}")))?;
                }

                OP_NEWARR => {
                    let n = self.pop_int(ip)?;
                    if n < 0 {
                        return Err(err(ip, "NEWARR exige tamanho >= 0"));
                    }
                    // `self.stack.live()` é o conjunto de raízes: a parte viva
                    // da pilha. Como os locais são slots da própria pilha, não
                    // existe um segundo conjunto de raízes — mesma propriedade
                    // da implementação em C, e pelo mesmo motivo.
                    //
                    // Escrito assim, e não como um método `self.roots()`: um
                    // método tomaria `&self` inteiro e conflitaria com o
                    // `&mut self.heap` da mesma expressão. Com os dois campos
                    // acessados diretamente, o borrow checker vê empréstimos
                    // disjuntos e aceita. É o tipo de atrito que o Rust cobra.
                    let id = self.heap.alloc_array(n as usize, self.stack.live());
                    self.push(ip, Value::Obj(id))?;
                }

                OP_AGET => {
                    let i = self.pop_int(ip)?;
                    let id = self.pop_array(ip)?;
                    let idx = usize::try_from(i).map_err(|_| err(ip, "AGET fora dos limites"))?;
                    let arr = self.heap.get(id).expect("validado em pop_array");
                    let v = *arr
                        .items
                        .get(idx)
                        .ok_or_else(|| err(ip, "AGET fora dos limites"))?;
                    self.push(ip, v)?;
                }

                OP_ASET => {
                    let val = self.pop(ip)?;
                    let i = self.pop_int(ip)?;
                    let id = self.pop_array(ip)?;
                    let idx = usize::try_from(i).map_err(|_| err(ip, "ASET fora dos limites"))?;
                    let arr = self.heap.get_mut(id).expect("validado em pop_array");
                    match arr.items.get_mut(idx) {
                        Some(cell) => *cell = val,
                        None => return Err(err(ip, "ASET fora dos limites")),
                    }
                }

                OP_ALEN => {
                    let id = self.pop_array(ip)?;
                    let n = self
                        .heap
                        .get(id)
                        .expect("validado em pop_array")
                        .items
                        .len();
                    self.push(ip, Value::Int(n as i64))?;
                }

                OP_GC => {
                    self.heap.collect(self.stack.live());
                }

                // Chamada indireta: o destino vem de DADOS, não do código.
                // Por isso cada validação abaixo existe — um .fbc mal gerado
                // faria a VM saltar para um endereço arbitrário, e "mal
                // gerado" inclui o caso normal de um compilador em
                // desenvolvimento, que é exatamente o uso previsto.
                //
                // Pilha na entrada: [... closure arg1 .. argN]
                // Frame: base = sp - N - 1, slot 0 = closure, 1..N = args.
                // A closure NÃO é desempilhada: fica como slot 0, e as
                // capturas saem de LOAD 0 + PUSH i + AGET.
                OP_CALLI => {
                    let nargs = rd_u8(code, &mut ip)? as usize;
                    if self.stack.len() < nargs + 1 {
                        return Err(err(ip, "CALLI sem closure e argumentos suficientes"));
                    }
                    let newbase = self.stack.len() - nargs - 1;
                    let cv = self
                        .stack
                        .get(newbase)
                        .ok_or_else(|| err(ip, "CALLI: pilha inconsistente"))?;
                    let id = match cv {
                        Value::Obj(id) => id,
                        Value::Int(_) => {
                            return Err(err(ip, "CALLI: o valor chamado nao e uma closure"))
                        }
                    };
                    let target = match self.heap.get(id) {
                        None => return Err(err(ip, "CALLI: closure ja liberada")),
                        Some(arr) => match arr.items.first() {
                            Some(Value::Int(t)) => *t,
                            _ => {
                                return Err(err(
                                    ip,
                                    "CALLI: closure sem endereco de codigo no item 0",
                                ))
                            }
                        },
                    };
                    if target < 0 || target as usize >= code.len() {
                        return Err(err(ip, "CALLI: endereco de codigo fora do programa"));
                    }
                    if self.fp >= FRAMES_MAX {
                        return Err(err(ip, "estouro da pilha de chamadas"));
                    }
                    self.frames[self.fp] = Frame {
                        ret_ip: ip,
                        base: newbase,
                    };
                    self.fp += 1;
                    base = newbase;
                    ip = target as usize;
                }

                other => return Err(err(ip, &format!("opcode invalido: {other}"))),
            }
        }
    }
}

impl Default for Vm {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::asm::assemble;
    use crate::stack::STACK_MAX;

    fn run_src(src: &str) -> String {
        let chunk = assemble(src, "<teste>").expect("deveria montar");
        let mut out: Vec<u8> = Vec::new();
        let mut vm = Vm::new();
        vm.run(&chunk, &mut out).expect("deveria executar");
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn aritmetica() {
        assert_eq!(run_src("PUSH 2\nPUSH 3\nADD\nPRINT\nHALT\n"), "5\n");
    }

    #[test]
    fn dup_nao_corrompe_a_pilha() {
        // O equivalente em C deste caso era comportamento indefinido:
        // `vm->stack[vm->sp++] = vm->stack[vm->sp - 1]`.
        assert_eq!(run_src("PUSH 7\nDUP\nADD\nPRINT\nHALT\n"), "14\n");
    }

    #[test]
    fn recursao() {
        let src = "PUSH 10\nCALL fib 1\nPRINT\nHALT\nfib:\nLOAD 0\nPUSH 2\nLT\nJZ rec\nLOAD 0\nRET\nrec:\nLOAD 0\nPUSH 1\nSUB\nCALL fib 1\nLOAD 0\nPUSH 2\nSUB\nCALL fib 1\nADD\nRET\n";
        assert_eq!(run_src(src), "55\n");
    }

    #[test]
    fn gc_preserva_o_que_esta_alcancavel() {
        let src = "PUSH 4\nNEWARR\nGC\nALEN\nPRINT\nHALT\n";
        assert_eq!(run_src(src), "4\n");
    }

    #[test]
    fn divisao_por_zero_e_erro_nao_panico() {
        let chunk = assemble("PUSH 1\nPUSH 0\nDIV\nHALT\n", "<teste>").unwrap();
        let mut out: Vec<u8> = Vec::new();
        let e = Vm::new().run(&chunk, &mut out).unwrap_err();
        assert!(e.contains("divisao por zero"), "mensagem foi: {e}");
    }

    #[test]
    fn estouro_de_pilha_e_erro_nao_panico() {
        // RESERVE pede mais slots do que a pilha tem: tem de virar erro
        // reportado, não pânico nem corrupção de memória.
        let src = format!("RESERVE {}\nHALT\n", STACK_MAX + 1);
        let chunk = assemble(&src, "<teste>").unwrap();
        let mut out: Vec<u8> = Vec::new();
        let e = Vm::new().run(&chunk, &mut out).unwrap_err();
        assert!(e.contains("estouro da pilha"), "mensagem foi: {e}");
    }
}
