--  fvm.adb — porte do núcleo mínimo da Forge VM para Ada.
--
--  ## O que este arquivo é
--
--  Um **porte**: executa `.fbc` montado pela implementação em C e produz saída
--  byte a byte idêntica nos 9 casos de `tests/cases/`. Sem montador, sem
--  `--stats`, sem desmontador. Ver `ports/README.md`.
--
--  ## O que o Ada dá, e nenhuma das outras quatro deu
--
--  **Subtipos restritos.** `subtype Slot_Index is Integer range 0 .. Stack_Max - 1`
--  não é documentação: é verificação. Um índice fora da faixa levanta
--  `Constraint_Error` no ponto do erro, não 200 linhas depois.
--
--  Isso importa porque **foi exatamente onde o porte em Nim errou primeiro**:
--  um template avaliava o índice da pilha antes do valor, o array ficava no
--  topo, e o sintoma aparecia no `PRINT`. Em Ada o tipo não impede esse bug
--  específico, mas a faixa restrita transforma a classe inteira de erros de
--  índice em falha localizada em vez de valor errado silencioso.
--
--  **`Unchecked_Conversion` é explícito e nomeado.** Reinterpretar os 8 bytes
--  do operando de `PUSH` como `Integer_64` exige instanciar a conversão e
--  dizer o nome dela. Em C é um cast que passa desapercebido; aqui aparece na
--  declaração.
--
--  ## Ada não tem coletor de lixo
--
--  Como Odin, e pela mesma razão de projeto. A escolha aqui foi a mesma: os
--  arrays da VM são alocados de um *storage pool* padrão e **nunca liberados**
--  individualmente. `OP_GC` não recicla nada, e isso está declarado.
--
--  Os 9 casos passam porque verificam **semântica**, não reciclagem — e isso é
--  um limite dos casos, não uma virtude do porte. A coluna de RSS em
--  `ports/README.md` mede o que eles não medem.
--
--  uso: fvm_ada <prog.fbc>

pragma Ada_2012;

with Ada.Command_Line;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Interfaces;

procedure Fvm is

   use Interfaces;
   use Ada.Strings.Unbounded;

   Stack_Max  : constant := 2 ** 16;
   Frames_Max : constant := 1024;

   --  Os 32 opcodes, na ordem de `c/include/fvm.h`. A ordem É o formato
   --  binário: trocar duas linhas aqui quebra todo `.fbc` existente.
   --
   --  `Op_Div` e `Op_Mod` com prefixo porque `mod` é palavra reservada.
   type Op is
     (Op_Halt, Op_Push, Op_Pop, Op_Dup, Op_Swap,
      Op_Add, Op_Sub, Op_Mul, Op_Div, Op_Mod, Op_Neg,
      Op_Lt, Op_Le, Op_Gt, Op_Ge, Op_Eq, Op_Ne,
      Op_Jmp, Op_Jz, Op_Jnz,
      Op_Load, Op_Store, Op_Reserve,
      Op_Call, Op_Ret, Op_Print,
      Op_Newarr, Op_Aget, Op_Aset, Op_Alen, Op_Gc,
      Op_Calli);

   for Op use
     (Op_Halt    => 0,  Op_Push    => 1,  Op_Pop     => 2,  Op_Dup   => 3,
      Op_Swap    => 4,  Op_Add     => 5,  Op_Sub     => 6,  Op_Mul   => 7,
      Op_Div     => 8,  Op_Mod     => 9,  Op_Neg     => 10, Op_Lt    => 11,
      Op_Le      => 12, Op_Gt      => 13, Op_Ge      => 14, Op_Eq    => 15,
      Op_Ne      => 16, Op_Jmp     => 17, Op_Jz      => 18, Op_Jnz   => 19,
      Op_Load    => 20, Op_Store   => 21, Op_Reserve => 22, Op_Call  => 23,
      Op_Ret     => 24, Op_Print   => 25, Op_Newarr  => 26, Op_Aget  => 27,
      Op_Aset    => 28, Op_Alen    => 29, Op_Gc      => 30, Op_Calli => 31);

   --  Erro de execução como exceção nomeada, com a mensagem separada: Ada
   --  permite `raise E with Message`, mas guardar a mensagem à parte deixa o
   --  texto da saída igual ao das outras implementações.
   Vm_Error : exception;
   Msg_Erro : Unbounded_String;

   procedure Erro (Texto : String) is
   begin
      Msg_Erro := To_Unbounded_String (Texto);
      raise Vm_Error;
   end Erro;

   ----------------------------------------------------------------- valores

   --  Handle para a arena de arrays. Zero significa "nenhum", como um ponteiro
   --  nulo, e os índices válidos começam em 1 -- convenção de Ada, e evita a
   --  confusão de ter 0 como handle válido e como ausência.
   type Arr_Handle is new Natural;
   Nenhum : constant Arr_Handle := 0;

   type Val_Kind is (K_Int, K_Arr);

   --  Registro variante: a tag é parte do tipo, e o compilador **recusa** o
   --  acesso ao campo da variante errada em tempo de execução
   --  (`Constraint_Error`). Em C a mesma estrutura é mantida por convenção.
   type Value (Kind : Val_Kind := K_Int) is record
      case Kind is
         when K_Int =>
            I : Integer_64 := 0;
         when K_Arr =>
            H : Arr_Handle := Nenhum;
      end case;
   end record;

   function Int_Val (N : Integer_64) return Value is
     (Kind => K_Int, I => N);

   function Arr_Val (H : Arr_Handle) return Value is
     (Kind => K_Arr, H => H);

   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Value);

   --  Um array da VM. A arena guarda estes.
   type Fvm_Array is record
      Items : Value_Vectors.Vector;
   end record;

   package Array_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Fvm_Array);

   --  A arena. Cresce e nunca encolhe: Ada não tem coletor, e esta é a decisão
   --  de memória do porte, declarada no topo do arquivo.
   Arena : Array_Vectors.Vector;

   ---------------------------------------------------------------- bytecode

   type Byte_Array is array (Natural range <>) of Unsigned_8;
   type Byte_Array_Access is access Byte_Array;

   Code  : Byte_Array_Access;
   Entry_Point : Natural := 0;

   --  Reinterpretação de bits, explícita e nomeada. `U64_To_I64` aparece na
   --  declaração; em C seria um cast invisível no meio de uma expressão.
   function U64_To_I64 is new Ada.Unchecked_Conversion
     (Source => Unsigned_64, Target => Integer_64);

   function U32_To_I32 is new Ada.Unchecked_Conversion
     (Source => Unsigned_32, Target => Integer_32);

   --  Little-endian montado byte a byte, como nas outras quatro
   --  implementações: o formato do .fbc é definido como little-endian, e um
   --  cast de memória funcionaria por acidente na máquina de hoje.
   function Le_U32 (B : Byte_Array; Off : Natural) return Unsigned_32 is
     (Unsigned_32 (B (Off))
      or Shift_Left (Unsigned_32 (B (Off + 1)), 8)
      or Shift_Left (Unsigned_32 (B (Off + 2)), 16)
      or Shift_Left (Unsigned_32 (B (Off + 3)), 24));

   function Le_I32 (B : Byte_Array; Off : Natural) return Integer_32 is
     (U32_To_I32 (Le_U32 (B, Off)));

   function Le_I64 (B : Byte_Array; Off : Natural) return Integer_64 is
      R : Unsigned_64 := 0;
   begin
      for K in reverse 0 .. 7 loop
         R := Shift_Left (R, 8) or Unsigned_64 (B (Off + K));
      end loop;
      return U64_To_I64 (R);
   end Le_I64;

   procedure Carrega (Caminho : String) is
      use Ada.Streams.Stream_IO;
      F      : File_Type;
      S      : Stream_Access;
      Tam    : Natural;
      Bruto  : Byte_Array_Access;
      Tam_Codigo : Natural;
   begin
      if not Ada.Directories.Exists (Caminho) then
         Erro ("arquivo nao encontrado: " & Caminho);
      end if;

      Tam := Natural (Ada.Directories.Size (Caminho));

      if Tam < 12 then
         Erro ("arquivo curto demais para ser um .fbc");
      end if;

      Open (F, In_File, Caminho);
      S := Stream (F);
      Bruto := new Byte_Array (0 .. Tam - 1);

      for K in Bruto.all'Range loop
         Unsigned_8'Read (S, Bruto (K));
      end loop;

      Close (F);

      if Bruto (0) /= Character'Pos ('F')
        or else Bruto (1) /= Character'Pos ('V')
        or else Bruto (2) /= Character'Pos ('M')
        or else Bruto (3) /= Character'Pos ('1')
      then
         Erro ("magic invalido: esperava FVM1");
      end if;

      Entry_Point := Natural (Le_U32 (Bruto.all, 4));
      Tam_Codigo  := Natural (Le_U32 (Bruto.all, 8));

      if 12 + Tam_Codigo > Tam then
         Erro ("len do cabecalho maior que o arquivo");
      end if;

      if Entry_Point > Tam_Codigo then
         Erro ("entry fora do codigo");
      end if;

      Code := new Byte_Array (0 .. Tam_Codigo - 1);
      for K in Code.all'Range loop
         Code (K) := Bruto (12 + K);
      end loop;
   end Carrega;

   ---------------------------------------------------------------- execução

   --  Faixas restritas: o compilador insere a verificação, e um índice fora da
   --  faixa levanta Constraint_Error NO PONTO do erro.
   subtype Stack_Index  is Natural range 0 .. Stack_Max - 1;
   subtype Frame_Index  is Natural range 0 .. Frames_Max - 1;

   type Frame is record
      Ret_Ip : Integer := -1;
      Base   : Natural := 0;
   end record;

   type Stack_Array is array (Stack_Index) of Value;
   type Frame_Array is array (Frame_Index) of Frame;

   Pilha  : access Stack_Array := new Stack_Array;
   Frames : access Frame_Array := new Frame_Array;

   Sp   : Natural := 0;
   Fp   : Natural := 0;
   Ip   : Integer := 0;
   Base : Natural := 0;

   procedure Empilha (V : Value) is
   begin
      if Sp >= Stack_Max then
         Erro ("estouro da pilha de dados");
      end if;
      Pilha (Sp) := V;
      Sp := Sp + 1;
   end Empilha;

   function Desempilha return Value is
   begin
      if Sp = 0 then
         Erro ("pilha vazia");
      end if;
      Sp := Sp - 1;
      return Pilha (Sp);
   end Desempilha;

   procedure Precisa (N : Natural) is
   begin
      if Sp < N then
         Erro ("pilha com valores insuficientes");
      end if;
   end Precisa;

   function Inteiro (V : Value) return Integer_64 is
   begin
      if V.Kind /= K_Int then
         Erro ("esperava inteiro, veio array");
      end if;
      return V.I;
   end Inteiro;

   function Handle (V : Value) return Arr_Handle is
   begin
      if V.Kind /= K_Arr then
         Erro ("esperava array, veio inteiro");
      end if;
      if V.H = Nenhum or else Natural (V.H) > Natural (Arena.Length) then
         Erro ("handle de array invalido");
      end if;
      return V.H;
   end Handle;

   function Le_U8 return Unsigned_8 is
      B : constant Unsigned_8 := Code (Natural (Ip));
   begin
      Ip := Ip + 1;
      return B;
   end Le_U8;

   function Le_Op_I32 return Integer_32 is
      V : constant Integer_32 := Le_I32 (Code.all, Natural (Ip));
   begin
      Ip := Ip + 4;
      return V;
   end Le_Op_I32;

   function Le_Op_I64 return Integer_64 is
      V : constant Integer_64 := Le_I64 (Code.all, Natural (Ip));
   begin
      Ip := Ip + 8;
      return V;
   end Le_Op_I64;

   --  Formatação do PRINT. Casa com `value_print` do C: inteiro em decimal,
   --  array como `[1, 2, 3]`, `nil` para handle nulo.
   function Formata (V : Value) return String is
   begin
      case V.Kind is
         when K_Int =>
            --  `Integer_64'Image` prefixa espaço para o sinal; o C não.
            declare
               S : constant String := Integer_64'Image (V.I);
            begin
               if S (S'First) = ' ' then
                  return S (S'First + 1 .. S'Last);
               else
                  return S;
               end if;
            end;

         when K_Arr =>
            if V.H = Nenhum then
               return "nil";
            end if;

            declare
               A   : Fvm_Array renames Arena (Positive (V.H));
               Acc : Unbounded_String := To_Unbounded_String ("[");
               Primeiro : Boolean := True;
            begin
               for I in 0 .. Natural (A.Items.Length) - 1 loop
                  if not Primeiro then
                     Append (Acc, ", ");
                  end if;
                  Primeiro := False;
                  Append (Acc, Formata (A.Items (I)));
               end loop;
               Append (Acc, "]");
               return To_String (Acc);
            end;
      end case;
   end Formata;

   procedure Executa is
      Instrucao : Op;
      A, B, R   : Integer_64;
      Destino   : Integer_32;
      Nargs     : Natural;
      Slot      : Integer_32;
      Idx       : Integer;
      N         : Integer_64;
      Nova_Base : Natural;
      V         : Value;
   begin
      --  Frame raiz antes da primeira instrução, como em C, para que LOAD,
      --  STORE e RET funcionem no topo sem caso especial no laço.
      Frames (0) := (Ret_Ip => -1, Base => 0);
      Fp := 1;
      Ip := Entry_Point;

      loop
         if Ip < 0 or else Ip > Code.all'Last then
            Erro ("ip fora do codigo");
         end if;

         Instrucao := Op'Enum_Val (Integer (Code (Natural (Ip))));
         Ip := Ip + 1;

         case Instrucao is
            when Op_Halt =>
               return;

            when Op_Push =>
               Empilha (Int_Val (Le_Op_I64));

            when Op_Pop =>
               Precisa (1);
               Sp := Sp - 1;

            when Op_Dup =>
               Precisa (1);
               Empilha (Pilha (Sp - 1));

            when Op_Swap =>
               Precisa (2);
               declare
                  T : constant Value := Pilha (Sp - 1);
               begin
                  Pilha (Sp - 1) := Pilha (Sp - 2);
                  Pilha (Sp - 2) := T;
               end;

            when Op_Add | Op_Sub | Op_Mul | Op_Div | Op_Mod
               | Op_Lt | Op_Le | Op_Gt | Op_Ge | Op_Eq | Op_Ne =>
               Precisa (2);
               B := Inteiro (Desempilha);
               A := Inteiro (Desempilha);

               case Instrucao is
                  when Op_Add => R := A + B;
                  when Op_Sub => R := A - B;
                  when Op_Mul => R := A * B;
                  when Op_Div =>
                     if B = 0 then
                        Erro ("divisao por zero");
                     end if;
                     R := A / B;
                  when Op_Mod =>
                     if B = 0 then
                        Erro ("modulo por zero");
                     end if;
                     R := A rem B;
                  when Op_Lt => R := (if A < B then 1 else 0);
                  when Op_Le => R := (if A <= B then 1 else 0);
                  when Op_Gt => R := (if A > B then 1 else 0);
                  when Op_Ge => R := (if A >= B then 1 else 0);
                  when Op_Eq => R := (if A = B then 1 else 0);
                  when Op_Ne => R := (if A /= B then 1 else 0);
                  when others => R := 0;
               end case;

               Empilha (Int_Val (R));

            when Op_Neg =>
               Precisa (1);
               Empilha (Int_Val (-Inteiro (Desempilha)));

            when Op_Jmp =>
               Ip := Integer (Le_Op_I32);

            when Op_Jz =>
               Destino := Le_Op_I32;
               Precisa (1);
               if Inteiro (Desempilha) = 0 then
                  Ip := Integer (Destino);
               end if;

            when Op_Jnz =>
               Destino := Le_Op_I32;
               Precisa (1);
               if Inteiro (Desempilha) /= 0 then
                  Ip := Integer (Destino);
               end if;

            when Op_Load =>
               Slot := Le_Op_I32;
               Idx := Base + Integer (Slot);
               if Slot < 0 or else Idx >= Sp then
                  Erro ("LOAD de slot inexistente");
               end if;
               Empilha (Pilha (Idx));

            when Op_Store =>
               Slot := Le_Op_I32;
               Idx := Base + Integer (Slot);
               Precisa (1);
               if Slot < 0 or else Idx >= Sp then
                  Erro ("STORE em slot inexistente");
               end if;
               Pilha (Idx) := Desempilha;

            when Op_Reserve =>
               Slot := Le_Op_I32;
               if Slot < 0 then
                  Erro ("RESERVE negativo");
               end if;
               for K in 1 .. Integer (Slot) loop
                  Empilha (Int_Val (0));
               end loop;

            when Op_Call =>
               Destino := Le_Op_I32;
               Nargs := Natural (Le_U8);
               if Destino < 0 or else Natural (Destino) > Code.all'Last then
                  Erro ("CALL para endereco invalido");
               end if;
               if Sp < Nargs then
                  Erro ("CALL sem argumentos suficientes");
               end if;
               if Fp >= Frames_Max then
                  Erro ("estouro da pilha de chamadas");
               end if;
               Frames (Fp) := (Ret_Ip => Ip, Base => Sp - Nargs);
               Fp := Fp + 1;
               Base := Sp - Nargs;
               Ip := Integer (Destino);

            when Op_Ret =>
               Precisa (1);
               V := Desempilha;
               Fp := Fp - 1;
               declare
                  F : constant Frame := Frames (Fp);
               begin
                  Sp := F.Base;
                  Empilha (V);
                  if Fp = 0 then
                     return;
                  end if;
                  Base := Frames (Fp - 1).Base;
                  Ip := F.Ret_Ip;
               end;

            when Op_Print =>
               Precisa (1);
               Ada.Text_IO.Put_Line (Formata (Desempilha));

            when Op_Newarr =>
               Precisa (1);
               N := Inteiro (Desempilha);
               if N < 0 then
                  Erro ("NEWARR exige tamanho inteiro >= 0");
               end if;
               declare
                  Novo : Fvm_Array;
               begin
                  for K in 1 .. Natural (N) loop
                     Novo.Items.Append (Int_Val (0));
                  end loop;
                  Arena.Append (Novo);
                  Empilha (Arr_Val (Arr_Handle (Arena.Length)));
               end;

            when Op_Aget =>
               Precisa (2);
               N := Inteiro (Desempilha);
               declare
                  H : constant Arr_Handle := Handle (Desempilha);
                  A_Ref : Fvm_Array renames Arena (Positive (H));
               begin
                  if N < 0 or else Natural (N) >= Natural (A_Ref.Items.Length) then
                     Erro ("AGET fora dos limites");
                  end if;
                  Empilha (A_Ref.Items (Natural (N)));
               end;

            when Op_Aset =>
               Precisa (3);
               V := Desempilha;
               N := Inteiro (Desempilha);
               declare
                  H : constant Arr_Handle := Handle (Desempilha);
                  A_Ref : Fvm_Array renames Arena (Positive (H));
               begin
                  if N < 0 or else Natural (N) >= Natural (A_Ref.Items.Length) then
                     Erro ("ASET fora dos limites");
                  end if;
                  A_Ref.Items.Replace_Element (Natural (N), V);
               end;

            when Op_Alen =>
               Precisa (1);
               declare
                  H : constant Arr_Handle := Handle (Desempilha);
               begin
                  Empilha
                    (Int_Val (Integer_64 (Arena (Positive (H)).Items.Length)));
               end;

            when Op_Gc =>
               --  Ada não tem coletor de lixo, e a arena só cresce. Declarado
               --  no topo do arquivo e medido na coluna de RSS de
               --  ports/README.md. Um no-op honesto é melhor que chamar algo
               --  que não recicla -- o porte em V e o em Odin tomaram a mesma
               --  decisão, por motivos diferentes.
               null;

            when Op_Calli =>
               Nargs := Natural (Le_U8);
               if Sp < Nargs + 1 then
                  Erro ("CALLI sem closure e argumentos suficientes");
               end if;
               Nova_Base := Sp - Nargs - 1;
               declare
                  H : constant Arr_Handle := Handle (Pilha (Nova_Base));
                  Clo : Fvm_Array renames Arena (Positive (H));
               begin
                  if Natural (Clo.Items.Length) < 1 then
                     Erro ("CALLI: closure sem endereco de codigo");
                  end if;
                  N := Inteiro (Clo.Items (0));
                  if N < 0 or else Natural (N) > Code.all'Last then
                     Erro ("CALLI: endereco de codigo fora do programa");
                  end if;
                  if Fp >= Frames_Max then
                     Erro ("estouro da pilha de chamadas");
                  end if;
                  Frames (Fp) := (Ret_Ip => Ip, Base => Nova_Base);
                  Fp := Fp + 1;
                  Base := Nova_Base;
                  Ip := Integer (N);
               end;
         end case;
      end loop;
   end Executa;

begin
   if Ada.Command_Line.Argument_Count /= 1 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "uso: fvm_ada <prog.fbc>");
      Ada.Command_Line.Set_Exit_Status (64);
      return;
   end if;

   Carrega (Ada.Command_Line.Argument (1));
   Executa;

exception
   when Vm_Error =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "erro de execucao: " & To_String (Msg_Erro));
      Ada.Command_Line.Set_Exit_Status (70);

   --  Constraint_Error capturado à parte: ele é a verificação de faixa do Ada
   --  disparando, e distinguir isso de um erro do bytecode importa para
   --  depurar o porte.
   when Constraint_Error =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "Constraint_Error: indice ou faixa violada no porte");
      Ada.Command_Line.Set_Exit_Status (71);
end Fvm;
