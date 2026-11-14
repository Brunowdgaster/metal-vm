//! A pilha de operandos, em duas implementações selecionáveis em tempo de
//! compilação.
//!
//! # Por que duas
//!
//! O projeto existe para medir, e medir exige comparar na mesma máquina, na
//! mesma sessão. A primeira versão do porte usava `Vec<Value>`; a hipótese era
//! que um slice de tamanho fixo com `sp` explícito — estrutura idêntica à do
//! C — seria mais rápido, porque o `Vec` pode realocar e obriga o compilador
//! a reler o ponteiro base.
//!
//! **A hipótese estava errada**, e só a medição mostrou isso. O motivo:
//!
//! ```text
//! push com Vec:            1 teste (len < capacidade) + escrita
//! push com Box<[Value]>:   2 testes — o meu (sp < STACK_MAX) e o que o
//!                          Rust insere na indexação do slice, que ainda
//!                          precisa carregar o `len` do slice da memória
//! ```
//!
//! Em C o teste é um só, porque indexar um array cru não gera verificação. Em
//! Rust seguro não há como ter um só sem `get_unchecked`, isto é, sem
//! `unsafe` — e o porte inteiro não tem uma linha de `unsafe`.
//!
//! Este módulo mantém as duas implementações atrás da mesma interface, com o
//! corpo do interpretador escrito uma única vez (mesma estratégia dos macros
//! de dispatch em `c/src/vm.c`). Assim qualquer pessoa reproduz a comparação:
//!
//! ```sh
//! cargo build --release                       # Vec (padrao)
//! cargo build --release --features boxed-stack # Box<[Value]> + sp
//! ```
//!
//! Os números das duas estão em docs/BENCH.md.

use crate::value::Value;

pub const STACK_MAX: usize = 65536;

// ---------------------------------------------------------------- Vec (padrão)
#[cfg(not(feature = "boxed-stack"))]
pub struct Stack {
    buf: Vec<Value>,
}

#[cfg(not(feature = "boxed-stack"))]
impl Stack {
    pub fn new() -> Self {
        // Capacidade total reservada de uma vez: o `Vec` nunca realoca em
        // execução, então a comparação não mede a política de crescimento.
        Stack {
            buf: Vec::with_capacity(STACK_MAX),
        }
    }

    #[inline(always)]
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    #[inline(always)]
    pub fn push(&mut self, v: Value) -> bool {
        if self.buf.len() >= STACK_MAX {
            return false;
        }
        self.buf.push(v);
        true
    }

    #[inline(always)]
    pub fn pop(&mut self) -> Option<Value> {
        self.buf.pop()
    }

    #[inline(always)]
    pub fn get(&self, i: usize) -> Option<Value> {
        self.buf.get(i).copied()
    }

    #[inline(always)]
    pub fn set(&mut self, i: usize, v: Value) -> bool {
        match self.buf.get_mut(i) {
            Some(cell) => {
                *cell = v;
                true
            }
            None => false,
        }
    }

    #[inline(always)]
    pub fn top(&self) -> Option<Value> {
        self.buf.last().copied()
    }

    #[inline(always)]
    pub fn swap_top2(&mut self) -> bool {
        let n = self.buf.len();
        if n < 2 {
            return false;
        }
        self.buf.swap(n - 1, n - 2);
        true
    }

    #[inline(always)]
    pub fn truncate(&mut self, n: usize) {
        self.buf.truncate(n);
    }

    #[inline(always)]
    pub fn live(&self) -> &[Value] {
        &self.buf
    }
}

// ------------------------------------------------- Box<[Value]> + sp explícito
#[cfg(feature = "boxed-stack")]
pub struct Stack {
    buf: Box<[Value]>,
    sp: usize,
}

#[cfg(feature = "boxed-stack")]
impl Stack {
    pub fn new() -> Self {
        // Construído via Vec e convertido: `Box::new([_; STACK_MAX])`
        // materializaria 1 MB na pilha nativa antes de mover para o heap — o
        // mesmo estouro que derrubou a primeira versão em C.
        Stack {
            buf: vec![Value::Int(0); STACK_MAX].into_boxed_slice(),
            sp: 0,
        }
    }

    #[inline(always)]
    pub fn len(&self) -> usize {
        self.sp
    }

    #[inline(always)]
    pub fn push(&mut self, v: Value) -> bool {
        if self.sp >= STACK_MAX {
            return false;
        }
        self.buf[self.sp] = v;
        self.sp += 1;
        true
    }

    #[inline(always)]
    pub fn pop(&mut self) -> Option<Value> {
        if self.sp == 0 {
            return None;
        }
        self.sp -= 1;
        Some(self.buf[self.sp])
    }

    #[inline(always)]
    pub fn get(&self, i: usize) -> Option<Value> {
        if i < self.sp {
            Some(self.buf[i])
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn set(&mut self, i: usize, v: Value) -> bool {
        if i < self.sp {
            self.buf[i] = v;
            true
        } else {
            false
        }
    }

    #[inline(always)]
    pub fn top(&self) -> Option<Value> {
        if self.sp == 0 {
            None
        } else {
            Some(self.buf[self.sp - 1])
        }
    }

    #[inline(always)]
    pub fn swap_top2(&mut self) -> bool {
        if self.sp < 2 {
            return false;
        }
        self.buf.swap(self.sp - 1, self.sp - 2);
        true
    }

    #[inline(always)]
    pub fn truncate(&mut self, n: usize) {
        if n <= self.sp {
            self.sp = n;
        }
    }

    #[inline(always)]
    pub fn live(&self) -> &[Value] {
        &self.buf[..self.sp]
    }
}

impl Default for Stack {
    fn default() -> Self {
        Self::new()
    }
}

pub const fn stack_impl_name() -> &'static str {
    if cfg!(feature = "boxed-stack") {
        "Box<[Value]> + sp"
    } else {
        "Vec<Value>"
    }
}
