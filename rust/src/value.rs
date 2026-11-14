//! Valores da VM.
//!
//! `Value` é um enum de duas variantes, que é exatamente o que a versão em C
//! implementa à mão com `struct { ValType t; union { int64_t i; Obj *o; } }`.
//! A diferença é que aqui o compilador garante que a tag e o payload não
//! saiam de sincronia: ler um `Value::Int` como objeto não é um bug possível,
//! é um erro de compilação.
//!
//! Tamanho: 16 bytes nas duas implementações (8 de payload + tag alinhada).
//! A otimização seguinte nas duas é NaN boxing, que derruba para 8.

use crate::gc::{Heap, ObjId};

#[derive(Clone, Copy, Debug)]
pub enum Value {
    Int(i64),
    Obj(ObjId),
}

impl Value {
    pub fn is_truthy(self) -> bool {
        !matches!(self, Value::Int(0))
    }
}

/// Igualdade: inteiros por valor, objetos por identidade — mesma semântica da
/// implementação em C, onde objetos comparam ponteiros.
impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::Int(a), Value::Int(b)) => a == b,
            (Value::Obj(a), Value::Obj(b)) => a == b,
            _ => false,
        }
    }
}

/// Formata um valor para impressão.
///
/// Precisa do heap porque `Value::Obj` carrega um índice, não um ponteiro:
/// em C, `value_print` desreferencia o ponteiro e se basta. É o custo visível
/// do design de arena — toda operação sobre objeto passa a exigir o heap em
/// mão. Em troca, não existe ponteiro pendurado possível.
pub fn format_value(heap: &Heap, v: Value) -> String {
    match v {
        Value::Int(i) => i.to_string(),
        Value::Obj(id) => match heap.get(id) {
            Some(arr) => {
                let parts: Vec<String> = arr.items.iter().map(|x| format_value(heap, *x)).collect();
                format!("[{}]", parts.join(", "))
            }
            None => "<obj liberado>".to_string(),
        },
    }
}
