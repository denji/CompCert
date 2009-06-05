(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** The Mach intermediate language: concrete semantics. *)

Require Import Coqlib.
Require Import Maps.
Require Import AST.
Require Import Integers.
Require Import Values.
Require Import Mem.
Require Import Events.
Require Import Globalenvs.
Require Import Smallstep.
Require Import Op.
Require Import Locations.
Require Conventions.
Require Import Mach.
Require Stacklayout.
Require Asmgenretaddr.

(** In the concrete semantics for Mach, the three stack-related Mach
  instructions are interpreted as memory accesses relative to the
  stack pointer.  More precisely:
- [Mgetstack ofs ty r] is a memory load at offset [ofs * 4] relative
  to the stack pointer.
- [Msetstack r ofs ty] is a memory store at offset [ofs * 4] relative
  to the stack pointer.
- [Mgetparam ofs ty r] is a memory load at offset [ofs * 4]
  relative to the pointer found at offset 0 from the stack pointer.
  The semantics maintain a linked structure of activation records,
  with the current record containing a pointer to the record of the
  caller function at offset 0.

In addition to this linking of activation records, the concrete
semantics also make provisions for storing a back link at offset
[f.(fn_link_ofs)] from the stack pointer, and a return address at
offset [f.(fn_retaddr_ofs)].  The latter stack location will be used
by the Asm code generated by [Asmgen] to save the return address into
the caller at the beginning of a function, then restore it and jump to
it at the end of a function.  The Mach concrete semantics does not
attach any particular meaning to the pointer stored in this reserved
location, but makes sure that it is preserved during execution of a
function.  The [return_address_offset] predicate from module
[Asmgenretaddr] is used to guess the value of the return address that
the Asm code generated later will store in the reserved location.
*)

Definition chunk_of_type (ty: typ) :=
  match ty with Tint => Mint32 | Tfloat => Mfloat64 end.

Definition load_stack (m: mem) (sp: val) (ty: typ) (ofs: int) :=
  Mem.loadv (chunk_of_type ty) m (Val.add sp (Vint ofs)).

Definition store_stack (m: mem) (sp: val) (ty: typ) (ofs: int) (v: val) :=
  Mem.storev (chunk_of_type ty) m (Val.add sp (Vint ofs)) v.

(** Extract the values of the arguments of an external call. *)

Inductive extcall_arg: regset -> mem -> val -> loc -> val -> Prop :=
  | extcall_arg_reg: forall rs m sp r,
      extcall_arg rs m sp (R r) (rs r)
  | extcall_arg_stack: forall rs m sp ofs ty v,
      load_stack m sp ty (Int.repr (Stacklayout.fe_ofs_arg + 4 * ofs)) = Some v ->
      extcall_arg rs m sp (S (Outgoing ofs ty)) v.

Inductive extcall_args: regset -> mem -> val -> list loc -> list val -> Prop :=
  | extcall_args_nil: forall rs m sp,
      extcall_args rs m sp nil nil
  | extcall_args_cons: forall rs m sp l1 ll v1 vl,
      extcall_arg rs m sp l1 v1 -> extcall_args rs m sp ll vl ->
      extcall_args rs m sp (l1 :: ll) (v1 :: vl).

Definition extcall_arguments
   (rs: regset) (m: mem) (sp: val) (sg: signature) (args: list val) : Prop :=
  extcall_args rs m sp (Conventions.loc_arguments sg) args.

(** Mach execution states. *)

Inductive stackframe: Type :=
  | Stackframe:
      forall (f: block)       (**r pointer to calling function *)
             (sp: val)        (**r stack pointer in calling function *)
             (retaddr: val)   (**r Asm return address in calling function *)
             (c: code),       (**r program point in calling function *)
      stackframe.

Inductive state: Type :=
  | State:
      forall (stack: list stackframe)  (**r call stack *)
             (f: block)                (**r pointer to current function *)
             (sp: val)                 (**r stack pointer *)
             (c: code)                 (**r current program point *)
             (rs: regset)              (**r register state *)
             (m: mem),                 (**r memory state *)
      state
  | Callstate:
      forall (stack: list stackframe)  (**r call stack *)
             (f: block)                (**r pointer to function to call *)
             (rs: regset)              (**r register state *)
             (m: mem),                 (**r memory state *)
      state
  | Returnstate:
      forall (stack: list stackframe)  (**r call stack *)
             (rs: regset)              (**r register state *)
             (m: mem),                 (**r memory state *)
      state.

Definition parent_sp (s: list stackframe) : val :=
  match s with
  | nil => Vptr Mem.nullptr Int.zero
  | Stackframe f sp ra c :: s' => sp
  end.

Definition parent_ra (s: list stackframe) : val :=
  match s with
  | nil => Vzero
  | Stackframe f sp ra c :: s' => ra
  end.

Section RELSEM.

Variable ge: genv.

Inductive step: state -> trace -> state -> Prop :=
  | exec_Mlabel:
      forall s f sp lbl c rs m,
      step (State s f sp (Mlabel lbl :: c) rs m)
        E0 (State s f sp c rs m)
  | exec_Mgetstack:
      forall s f sp ofs ty dst c rs m v,
      load_stack m sp ty ofs = Some v ->
      step (State s f sp (Mgetstack ofs ty dst :: c) rs m)
        E0 (State s f sp c (rs#dst <- v) m)
  | exec_Msetstack:
      forall s f sp src ofs ty c rs m m',
      store_stack m sp ty ofs (rs src) = Some m' ->
      step (State s f sp (Msetstack src ofs ty :: c) rs m)
        E0 (State s f sp c rs m')
  | exec_Mgetparam:
      forall s fb f sp parent ofs ty dst c rs m v,
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      load_stack m sp Tint f.(fn_link_ofs) = Some parent ->
      load_stack m parent ty ofs = Some v ->
      step (State s fb sp (Mgetparam ofs ty dst :: c) rs m)
        E0 (State s fb sp c (rs#dst <- v) m)
  | exec_Mop:
      forall s f sp op args res c rs m v,
      eval_operation ge sp op rs##args = Some v ->
      step (State s f sp (Mop op args res :: c) rs m)
        E0 (State s f sp c (rs#res <- v) m)
  | exec_Mload:
      forall s f sp chunk addr args dst c rs m a v,
      eval_addressing ge sp addr rs##args = Some a ->
      Mem.loadv chunk m a = Some v ->
      step (State s f sp (Mload chunk addr args dst :: c) rs m)
        E0 (State s f sp c (rs#dst <- v) m)
  | exec_Mstore:
      forall s f sp chunk addr args src c rs m m' a,
      eval_addressing ge sp addr rs##args = Some a ->
      Mem.storev chunk m a (rs src) = Some m' ->
      step (State s f sp (Mstore chunk addr args src :: c) rs m)
        E0 (State s f sp c rs m')
  | exec_Mcall:
      forall s fb sp sig ros c rs m f f' ra,
      find_function_ptr ge ros rs = Some f' ->
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      Asmgenretaddr.return_address_offset f c ra ->
      step (State s fb sp (Mcall sig ros :: c) rs m)
        E0 (Callstate (Stackframe fb sp (Vptr fb ra) c :: s)
                       f' rs m)
  | exec_Mtailcall:
      forall s fb stk soff sig ros c rs m f f',
      find_function_ptr ge ros rs = Some f' ->
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      load_stack m (Vptr stk soff) Tint f.(fn_link_ofs) = Some (parent_sp s) ->
      load_stack m (Vptr stk soff) Tint f.(fn_retaddr_ofs) = Some (parent_ra s) ->
      step (State s fb (Vptr stk soff) (Mtailcall sig ros :: c) rs m)
        E0 (Callstate s f' rs (Mem.free m stk))
  | exec_Mgoto:
      forall s fb f sp lbl c rs m c',
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      find_label lbl f.(fn_code) = Some c' ->
      step (State s fb sp (Mgoto lbl :: c) rs m)
        E0 (State s fb sp c' rs m)
  | exec_Mcond_true:
      forall s fb f sp cond args lbl c rs m c',
      eval_condition cond rs##args = Some true ->
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      find_label lbl f.(fn_code) = Some c' ->
      step (State s fb sp (Mcond cond args lbl :: c) rs m)
        E0 (State s fb sp c' rs m)
  | exec_Mcond_false:
      forall s f sp cond args lbl c rs m,
      eval_condition cond rs##args = Some false ->
      step (State s f sp (Mcond cond args lbl :: c) rs m)
        E0 (State s f sp c rs m)
  | exec_Mreturn:
      forall s fb stk soff c rs m f,
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      load_stack m (Vptr stk soff) Tint f.(fn_link_ofs) = Some (parent_sp s) ->
      load_stack m (Vptr stk soff) Tint f.(fn_retaddr_ofs) = Some (parent_ra s) ->
      step (State s fb (Vptr stk soff) (Mreturn :: c) rs m)
        E0 (Returnstate s rs (Mem.free m stk))
  | exec_function_internal:
      forall s fb rs m f m1 m2 m3 stk,
      Genv.find_funct_ptr ge fb = Some (Internal f) ->
      Mem.alloc m (- f.(fn_framesize)) f.(fn_stacksize) = (m1, stk) ->
      let sp := Vptr stk (Int.repr (-f.(fn_framesize))) in
      store_stack m1 sp Tint f.(fn_link_ofs) (parent_sp s) = Some m2 ->
      store_stack m2 sp Tint f.(fn_retaddr_ofs) (parent_ra s) = Some m3 ->
      step (Callstate s fb rs m)
        E0 (State s fb sp f.(fn_code) rs m3)
  | exec_function_external:
      forall s fb rs m t rs' ef args res,
      Genv.find_funct_ptr ge fb = Some (External ef) ->
      event_match ef args t res ->
      extcall_arguments rs m (parent_sp s) ef.(ef_sig) args ->
      rs' = (rs#(Conventions.loc_result ef.(ef_sig)) <- res) ->
      step (Callstate s fb rs m)
         t (Returnstate s rs' m)
  | exec_return:
      forall s f sp ra c rs m,
      step (Returnstate (Stackframe f sp ra c :: s) rs m)
        E0 (State s f sp c rs m).

End RELSEM.

Inductive initial_state (p: program): state -> Prop :=
  | initial_state_intro: forall fb,
      let ge := Genv.globalenv p in
      let m0 := Genv.init_mem p in
      Genv.find_symbol ge p.(prog_main) = Some fb ->
      initial_state p (Callstate nil fb (Regmap.init Vundef) m0).

Inductive final_state: state -> int -> Prop :=
  | final_state_intro: forall rs m r,
      rs (Conventions.loc_result (mksignature nil (Some Tint))) = Vint r ->
      final_state (Returnstate nil rs m) r.

Definition exec_program (p: program) (beh: program_behavior) : Prop :=
  program_behaves step (initial_state p) final_state (Genv.globalenv p) beh.
