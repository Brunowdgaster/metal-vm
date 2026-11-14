//! Coletor mark & sweep sobre uma arena de slots.
//!
//! # A decisão que o Rust forçou
//!
//! A versão em C encadeia os objetos por ponteiro cru (`Obj *next`) e o
//! `Value` guarda um `Obj *`. Em Rust isso é impossível sem `unsafe`: um
//! grafo de objetos com donos cíclicos não satisfaz o modelo de ownership.
//!
//! As três saídas eram:
//!
//! 1. `unsafe` com ponteiros crus — transcreveria o C e não mediria nada
//!    sobre Rust;
//! 2. `Rc<RefCell<..>>` — contagem de referências, que vaza ciclos (um array
//!    que contém a si mesmo nunca seria liberado) e põe contadores no caminho
//!    quente, exatamente o que o projeto quer evitar;
//! 3. **arena com handles**: os objetos vivem num `Vec`, e `Value::Obj(id)`
//!    carrega um índice, não um ponteiro.
//!
//! A escolha foi a 3, e o projeto inteiro em Rust não tem uma linha de
//! `unsafe`. O detalhe que importa: arena com handles não é uma concessão ao
//! borrow checker, é o design que VMs de produção adotam por conta própria
//! (índices são menores que ponteiros, sobrevivem a realocação da arena e
//! permitem compactação). O Rust empurrou para a solução melhor.
//!
//! # O que se perde
//!
//! Um handle para um slot já liberado não é um use-after-free — é um acesso a
//! `None`, detectado. Mas se o slot tiver sido reutilizado, o handle antigo
//! passa a apontar para o objeto novo (problema ABA). Aqui isso não pode
//! acontecer: os únicos handles existentes estão na pilha de operandos, que é
//! o conjunto de raízes, logo nenhum handle alcançável aponta para um slot
//! coletado. Uma VM que guardasse handles fora do conjunto de raízes
//! precisaria de contador de geração no handle.

use crate::value::Value;

pub type ObjId = usize;

/// Contabilidade de bytes idêntica à da implementação em C
/// (`sizeof(ObjArray) + len * sizeof(Value)` com o layout de 64 bits), e não
/// o `size_of` real das structs Rust. É deliberado: com a mesma fórmula, as
/// duas implementações disparam coletas nos mesmos pontos e o número de
/// coletas fica comparável. O layout real do Rust é menor, o que daria menos
/// coletas e uma vantagem que não teria nada a ver com desempenho.
const OBJ_OVERHEAD: usize = 32;
const VALUE_SIZE: usize = 16;
const GC_INITIAL_THRESHOLD: usize = 256 * 1024;
const GC_GROWTH_FACTOR: usize = 2;

fn obj_bytes(len: usize) -> usize {
    OBJ_OVERHEAD + len * VALUE_SIZE
}

pub struct ObjArray {
    pub items: Vec<Value>,
}

pub struct Heap {
    slots: Vec<Option<ObjArray>>,
    free: Vec<ObjId>,
    marked: Vec<bool>,
    bytes: usize,
    next_gc: usize,
    pub runs: u64,
    pub freed: usize,
    pub peak: usize,
}

impl Heap {
    pub fn new() -> Self {
        Heap {
            slots: Vec::new(),
            free: Vec::new(),
            marked: Vec::new(),
            bytes: 0,
            next_gc: GC_INITIAL_THRESHOLD,
            runs: 0,
            freed: 0,
            peak: 0,
        }
    }

    pub fn get(&self, id: ObjId) -> Option<&ObjArray> {
        self.slots.get(id)?.as_ref()
    }

    pub fn get_mut(&mut self, id: ObjId) -> Option<&mut ObjArray> {
        self.slots.get_mut(id)?.as_mut()
    }

    /// Aloca um array de `len` zeros, coletando antes se o limiar for atingido.
    /// `roots` é a pilha de operandos da VM — ver a nota sobre ABA acima.
    pub fn alloc_array(&mut self, len: usize, roots: &[Value]) -> ObjId {
        if self.bytes + obj_bytes(len) > self.next_gc {
            self.collect(roots);
        }

        let obj = ObjArray {
            items: vec![Value::Int(0); len],
        };

        let id = match self.free.pop() {
            Some(id) => {
                self.slots[id] = Some(obj);
                id
            }
            None => {
                self.slots.push(Some(obj));
                self.marked.push(false);
                self.slots.len() - 1
            }
        };

        self.bytes += obj_bytes(len);
        if self.bytes > self.peak {
            self.peak = self.bytes;
        }
        id
    }

    pub fn collect(&mut self, roots: &[Value]) {
        // --- mark -----------------------------------------------------------
        // Pilha explícita de objetos gray, não recursão: um array
        // suficientemente aninhado estouraria a pilha nativa durante a coleta,
        // e um GC que quebra com dados do usuário não é um GC. Mesma decisão
        // da implementação em C.
        let mut gray: Vec<ObjId> = Vec::new();

        for v in roots {
            if let Value::Obj(id) = *v {
                if let Some(m) = self.marked.get_mut(id) {
                    if !*m {
                        *m = true;
                        gray.push(id);
                    }
                }
            }
        }

        while let Some(id) = gray.pop() {
            // Os filhos são copiados antes de marcar porque `self.slots` e
            // `self.marked` seriam dois empréstimos simultâneos de `self`.
            // Um `Vec<ObjId>` por objeto é o preço; a alternativa é dividir a
            // struct em dois campos independentes, o que está no roadmap.
            let children: Vec<ObjId> = match self.slots.get(id).and_then(|s| s.as_ref()) {
                Some(arr) => arr
                    .items
                    .iter()
                    .filter_map(|v| match v {
                        Value::Obj(c) => Some(*c),
                        _ => None,
                    })
                    .collect(),
                None => continue,
            };

            for c in children {
                if let Some(m) = self.marked.get_mut(c) {
                    if !*m {
                        *m = true;
                        gray.push(c);
                    }
                }
            }
        }

        // --- sweep ----------------------------------------------------------
        let mut freed_bytes = 0usize;
        let mut freed_ids: Vec<ObjId> = Vec::new();

        for (id, slot) in self.slots.iter_mut().enumerate() {
            if self.marked[id] {
                self.marked[id] = false; // limpa para o próximo ciclo
            } else if let Some(arr) = slot.take() {
                freed_bytes += obj_bytes(arr.items.len());
                freed_ids.push(id);
            }
        }

        self.free.extend(freed_ids);
        self.bytes -= freed_bytes;
        self.freed += freed_bytes;
        self.runs += 1;

        self.next_gc = (self.bytes * GC_GROWTH_FACTOR).max(GC_INITIAL_THRESHOLD);
    }
}

impl Default for Heap {
    fn default() -> Self {
        Self::new()
    }
}
