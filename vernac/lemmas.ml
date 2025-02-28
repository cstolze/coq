(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(* Created by Hugo Herbelin from contents related to lemma proofs in
   file command.ml, Aug 2009 *)

open CErrors
open Util
open Pp
open Names
open Constr
open Declarations
open Declareops
open Entries
open Nameops
open Globnames
open Decls
open Decl_kinds
open Declare
open Pretyping
open Termops
open Namegen
open Reductionops
open Constrintern
open Impargs

module RelDecl = Context.Rel.Declaration
module NamedDecl = Context.Named.Declaration

type hook_type = UState.t -> (Id.t * Constr.t) list -> Decl_kinds.locality -> GlobRef.t -> unit
type declaration_hook = hook_type

let mk_hook hook = hook

let call_hook ?hook ?fix_exn uctx trans l c =
  try Option.iter (fun hook -> hook uctx trans l c) hook
  with e when CErrors.noncritical e ->
    let e = CErrors.push e in
    let e = Option.cata (fun fix -> fix e) e fix_exn in
    iraise e

(* Support for mutually proved theorems *)

let retrieve_first_recthm uctx = function
  | VarRef id ->
      (NamedDecl.get_value (Global.lookup_named id),variable_opacity id)
  | ConstRef cst ->
      let cb = Global.lookup_constant cst in
      (* we get the right order somehow but surely it could be enforced in a better way *)
      let uctx = UState.context uctx in
      let inst = Univ.UContext.instance uctx in
      let map (c, ctx) = Vars.subst_instance_constr inst c in
      (Option.map map (Global.body_of_constant_body Library.indirect_accessor cb), is_opaque cb)
  | _ -> assert false

let adjust_guardness_conditions const = function
  | [] -> const (* Not a recursive statement *)
  | possible_indexes ->
  (* Try all combinations... not optimal *)
     let env = Global.env() in
     { const with const_entry_body =
        Future.chain const.const_entry_body
        (fun ((body, ctx), eff) ->
          match Constr.kind body with
          | Fix ((nv,0),(_,_,fixdefs as fixdecls)) ->
(*      let possible_indexes =
	List.map2 (fun i c -> match i with Some i -> i | None ->
	  List.interval 0 (List.length ((lam_assum c))))
	  lemma_guard (Array.to_list fixdefs) in
*)
              let env = Safe_typing.push_private_constants env eff in
              let indexes =
                search_guard env
                  possible_indexes fixdecls in
		(mkFix ((indexes,0),fixdecls), ctx), eff
          | _ -> (body, ctx), eff) }

let find_mutually_recursive_statements sigma thms =
    let n = List.length thms in
    let inds = List.map (fun (id,(t,impls)) ->
      let (hyps,ccl) = EConstr.decompose_prod_assum sigma t in
      let x = (id,(t,impls)) in
      let whnf_hyp_hds = EConstr.map_rel_context_in_env
        (fun env c -> fst (Reductionops.whd_all_stack env sigma c))
        (Global.env()) hyps in
      let ind_hyps =
        List.flatten (List.map_i (fun i decl ->
          let t = RelDecl.get_type decl in
          match EConstr.kind sigma t with
          | Ind ((kn,_ as ind),u) when
                let mind = Global.lookup_mind kn in
                mind.mind_finite <> Declarations.CoFinite ->
              [ind,x,i]
          | _ ->
              []) 0 (List.rev (List.filter Context.Rel.Declaration.is_local_assum whnf_hyp_hds))) in
      let ind_ccl =
        let cclenv = EConstr.push_rel_context hyps (Global.env()) in
        let whnf_ccl,_ = whd_all_stack cclenv Evd.empty ccl in
        match EConstr.kind sigma whnf_ccl with
        | Ind ((kn,_ as ind),u) when
              let mind = Global.lookup_mind kn in
              Int.equal mind.mind_ntypes n && mind.mind_finite == Declarations.CoFinite ->
            [ind,x,0]
        | _ ->
            [] in
      ind_hyps,ind_ccl) thms in
    let inds_hyps,ind_ccls = List.split inds in
    let of_same_mutind ((kn,_),_,_) = function ((kn',_),_,_) -> MutInd.equal kn kn' in
    (* Check if all conclusions are coinductive in the same type *)
    (* (degenerated cartesian product since there is at most one coind ccl) *)
    let same_indccl =
      List.cartesians_filter (fun hyp oks ->
	if List.for_all (of_same_mutind hyp) oks
	then Some (hyp::oks) else None) [] ind_ccls in
    let ordered_same_indccl =
      List.filter (List.for_all_i (fun i ((kn,j),_,_) -> Int.equal i j) 0) same_indccl in
    (* Check if some hypotheses are inductive in the same type *)
    let common_same_indhyp =
      List.cartesians_filter (fun hyp oks ->
	if List.for_all (of_same_mutind hyp) oks
	then Some (hyp::oks) else None) [] inds_hyps in
    let ordered_inds,finite,guard =
      match ordered_same_indccl, common_same_indhyp with
      | indccl::rest, _ ->
	  assert (List.is_empty rest);
          (* One occ. of common coind ccls and no common inductive hyps *)
	  if not (List.is_empty common_same_indhyp) then
	    Flags.if_verbose Feedback.msg_info (str "Assuming mutual coinductive statements.");
	  flush_all ();
          indccl, true, []
      | [], _::_ ->
          let () = match same_indccl with
          | ind :: _ ->
            if List.distinct_f ind_ord (List.map pi1 ind)
            then
              Flags.if_verbose Feedback.msg_info
                (strbrk
                   ("Coinductive statements do not follow the order of "^
                    "definition, assuming the proof to be by induction."));
            flush_all ()
          | _ -> ()
          in
          let possible_guards = List.map (List.map pi3) inds_hyps in
	  (* assume the largest indices as possible *)
	  List.last common_same_indhyp, false, possible_guards
      | _, [] ->
	  user_err Pp.(str
            ("Cannot find common (mutual) inductive premises or coinductive" ^
             " conclusions in the statements."))
    in
    (finite,guard,None), ordered_inds

let look_for_possibly_mutual_statements sigma = function
  | [id,(t,impls)] ->
      (* One non recursively proved theorem *)
      None,[id,(t,impls)],None
  | _::_ as thms ->
    (* More than one statement and/or an explicit decreasing mark: *)
    (* we look for a common inductive hyp or a common coinductive conclusion *)
    let recguard,ordered_inds = find_mutually_recursive_statements sigma thms in
    let thms = List.map pi2 ordered_inds in
    Some recguard,thms, Some (List.map (fun (_,_,i) -> succ i) ordered_inds)
  | [] -> anomaly (Pp.str "Empty list of theorems.")

(* Saving a goal *)

let save ?export_seff id const uctx do_guard (locality,poly,kind) hook universes =
  let fix_exn = Future.fix_exn_of const.Entries.const_entry_body in
  try
    let const = adjust_guardness_conditions const do_guard in
    let k = Kindops.logical_kind_of_goal_kind kind in
    let should_suggest = const.const_entry_opaque && Option.is_empty const.const_entry_secctx in
    let r = match locality with
      | Discharge when Lib.sections_are_opened () ->
          let c = SectionLocalDef const in
          let _ = declare_variable id (Lib.cwd(), c, k) in
          let () = if should_suggest
            then Proof_using.suggest_variable (Global.env ()) id
          in
          VarRef id
      | Local | Global | Discharge ->
          let local = match locality with
          | Local | Discharge -> true
          | Global -> false
          in
          let kn =
           declare_constant ?export_seff id ~local (DefinitionEntry const, k) in
          let () = if should_suggest
            then Proof_using.suggest_constant (Global.env ()) kn
          in
          let gr = ConstRef kn in
          Declare.declare_univ_binders gr (UState.universe_binders uctx);
          gr
    in
    definition_message id;
    call_hook ?hook universes [] locality r
  with e when CErrors.noncritical e ->
    let e = CErrors.push e in
    iraise (fix_exn e)

let default_thm_id = Id.of_string "Unnamed_thm"

let fresh_name_for_anonymous_theorem () =
  next_global_ident_away default_thm_id Id.Set.empty

let check_name_freshness locality {CAst.loc;v=id} : unit =
  (* We check existence here: it's a bit late at Qed time *)
  if Nametab.exists_cci (Lib.make_path id) || is_section_variable id ||
     locality == Global && Nametab.exists_cci (Lib.make_path_except_section id)
  then
    user_err ?loc  (Id.print id ++ str " already exists.")

let save_remaining_recthms env sigma (locality,p,kind) norm univs body opaq i (id,(t_i,(_,imps))) =
  let t_i = norm t_i in
  let k = IsAssumption Conjectural in
  match body with
  | None ->
      (match locality with
      | Discharge ->
          let impl = false in (* copy values from Vernacentries *)
          let univs = match univs with
            | Polymorphic_entry (_, univs) ->
              (* What is going on here? *)
              Univ.ContextSet.of_context univs
            | Monomorphic_entry univs -> univs
          in
          let c = SectionLocalAssum ((t_i, univs),p,impl) in
	  let _ = declare_variable id (Lib.cwd(),c,k) in
          (Discharge, VarRef id,imps)
      | Local | Global ->
          let local = match locality with
          | Local -> true
          | Global -> false
          | Discharge -> assert false
          in
          let decl = (ParameterEntry (None,(t_i,univs),None), k) in
          let kn = declare_constant id ~local decl in
          (locality,ConstRef kn,imps))
  | Some body ->
      let body = norm body in
      let k = Kindops.logical_kind_of_goal_kind kind in
      let rec body_i t = match Constr.kind t with
        | Fix ((nv,0),decls) -> mkFix ((nv,i),decls)
        | CoFix (0,decls) -> mkCoFix (i,decls)
        | LetIn(na,t1,ty,t2) -> mkLetIn (na,t1,ty, body_i t2)
        | Lambda(na,ty,t) -> mkLambda(na,ty,body_i t)
        | App (t, args) -> mkApp (body_i t, args)
        | _ ->
          anomaly Pp.(str "Not a proof by induction: " ++ Printer.pr_constr_env env sigma body ++ str ".") in
      let body_i = body_i body in
      match locality with
      | Discharge ->
          let const = definition_entry ~types:t_i ~opaque:opaq ~univs body_i in
	  let c = SectionLocalDef const in
	  let _ = declare_variable id (Lib.cwd(), c, k) in
          (Discharge,VarRef id,imps)
      | Local | Global ->
        let local = match locality with
        | Local -> true
        | Global -> false
        | Discharge -> assert false
        in
        let const =
          Declare.definition_entry ~types:t_i ~univs ~opaque:opaq body_i
	in
        let kn = declare_constant id ~local (DefinitionEntry const, k) in
        (locality,ConstRef kn,imps)

let check_anonymity id save_ident =
  if not (String.equal (atompart_of_id id) (Id.to_string (default_thm_id))) then
    user_err Pp.(str "This command can only be used for unnamed theorem.")

(* Admitted *)

let warn_let_as_axiom =
  CWarnings.create ~name:"let-as-axiom" ~category:"vernacular"
                   (fun id -> strbrk "Let definition" ++ spc () ++ Id.print id ++
                                spc () ++ strbrk "declared as an axiom.")

let admit ?hook ctx (id,k,e) pl () =
  let kn = declare_constant id (ParameterEntry e, IsAssumption Conjectural) in
  let () = match k with
  | Global, _, _ -> ()
  | Local, _, _ | Discharge, _, _ -> warn_let_as_axiom id
  in
  let () = assumption_message id in
  Declare.declare_univ_binders (ConstRef kn) pl;
  call_hook ?hook ctx [] Global (ConstRef kn)

(* Starting a goal *)

let standard_proof_terminator ?(hook : declaration_hook option) compute_guard =
  let open Proof_global in
  make_terminator begin function
  | Admitted (id,k,pe,ctx) ->
    let () = admit ?hook ctx (id,k,pe) (UState.universe_binders ctx) () in
    Feedback.feedback Feedback.AddedAxiom
  | Proved (opaque,idopt, { id; entries=[const]; persistence; universes } ) ->
    let is_opaque, export_seff = match opaque with
      | Transparent -> false, true
      | Opaque      -> true, false
    in
    assert (is_opaque == const.const_entry_opaque);
    let id = match idopt with
      | None -> id
      | Some { CAst.v = save_id } -> check_anonymity id save_id; save_id in
    let () = save ~export_seff id const universes compute_guard persistence hook universes in
    ()
  | Proved (opaque,idopt, _ ) ->
    CErrors.anomaly Pp.(str "[universe_proof_terminator] close_proof returned more than one proof term")
  end

let initialize_named_context_for_proof () =
  let sign = Global.named_context () in
  List.fold_right
    (fun d signv ->
      let id = NamedDecl.get_id d in
      let d = if variable_opacity id then NamedDecl.drop_body d else d in
      Environ.push_named_context_val d signv) sign Environ.empty_named_context_val

let start_proof id ?pl kind sigma ?terminator ?sign ?(compute_guard=[]) ?hook c =
  let terminator = match terminator with
  | None -> standard_proof_terminator ?hook compute_guard
  | Some terminator -> terminator ?hook compute_guard
  in
  let sign =
    match sign with
    | Some sign -> sign
    | None -> initialize_named_context_for_proof ()
  in
  let goals = [ Global.env_of_context sign , c ] in
  Proof_global.start_proof sigma id ?pl kind goals terminator

let rec_tac_initializer finite guard thms snl =
  if finite then
    match List.map (fun (id,(t,_)) -> (id,t)) thms with
    | (id,_)::l -> Tactics.mutual_cofix id l 0
    | _ -> assert false
  else
    (* nl is dummy: it will be recomputed at Qed-time *)
    let nl = match snl with 
     | None -> List.map succ (List.map List.last guard)
     | Some nl -> nl
    in match List.map2 (fun (id,(t,_)) n -> (id,n, t)) thms nl with
       | (id,n,_)::l -> Tactics.mutual_fix id n l 0
       | _ -> assert false

let start_proof_with_initialization ?hook kind sigma decl recguard thms snl =
  let intro_tac (_, (_, (ids, _))) = Tactics.auto_intros_tac ids in
  let init_tac,guard = match recguard with
  | Some (finite,guard,init_tac) ->
    let rec_tac = rec_tac_initializer finite guard thms snl in
    Some (match init_tac with
        | None ->
          Tacticals.New.tclTHENS rec_tac (List.map intro_tac thms)
        | Some tacl ->
          Tacticals.New.tclTHENS rec_tac
            List.(map2 (fun tac thm -> Tacticals.New.tclTHEN tac (intro_tac thm)) tacl thms)
      ),guard
  | None ->
    let () = match thms with [_] -> () | _ -> assert false in
    Some (intro_tac (List.hd thms)), [] in
  match thms with
  | [] -> anomaly (Pp.str "No proof to start.")
  | (id,(t,(_,imps)))::other_thms ->
      let hook ctx _ strength ref =
        let other_thms_data =
          if List.is_empty other_thms then [] else
            (* there are several theorems defined mutually *)
            let body,opaq = retrieve_first_recthm ctx ref in
            let norm c = EConstr.to_constr (Evd.from_ctx ctx) c in
            let body = Option.map EConstr.of_constr body in
            let uctx = UState.check_univ_decl ~poly:(pi2 kind) ctx decl in
            let env = Global.env () in
            List.map_i (save_remaining_recthms env sigma kind norm uctx body opaq) 1 other_thms in
        let thms_data = (strength,ref,imps)::other_thms_data in
        List.iter (fun (strength,ref,imps) ->
	  maybe_declare_manual_implicits false ref imps;
          call_hook ?hook ctx [] strength ref) thms_data in
      let pstate = start_proof id ~pl:decl kind sigma t ~hook ~compute_guard:guard in
      let pstate = Proof_global.modify_proof (fun p ->
          match init_tac with
          | None -> p
          | Some tac -> pi1 @@ Proof.run_tactic Global.(env ()) tac p) pstate in
      pstate

let start_proof_com ~program_mode ?inference_hook ?hook kind thms =
  let env0 = Global.env () in
  let decl = fst (List.hd thms) in
  let evd, decl = Constrexpr_ops.interp_univ_decl_opt env0 (snd decl) in
  let evd, thms = List.fold_left_map (fun evd ((id, _), (bl, t)) ->
    let evd, (impls, ((env, ctx), imps)) = interp_context_evars ~program_mode env0 evd bl in
    let evd, (t', imps') = interp_type_evars_impls ~program_mode ~impls env evd t in
    let flags = { all_and_fail_flags with program_mode } in
    let hook = inference_hook in
    let evd = solve_remaining_evars ?hook flags env evd in
    let ids = List.map RelDecl.get_name ctx in
    check_name_freshness (pi1 kind) id;
    (* XXX: The nf_evar is critical !! *)
    evd, (id.CAst.v,
          (Evarutil.nf_evar evd (EConstr.it_mkProd_or_LetIn t' ctx),
           (ids, imps @ lift_implicits (Context.Rel.nhyps ctx) imps'))))
      evd thms in
  let recguard,thms,snl = look_for_possibly_mutual_statements evd thms in
  let evd = Evd.minimize_universes evd in
  (* XXX: This nf_evar is critical too!! We are normalizing twice if
     you look at the previous lines... *)
  let thms = List.map (fun (n, (t, info)) -> (n, (nf_evar evd t, info))) thms in
  let () =
    let open UState in
    if not (decl.univdecl_extensible_instance && decl.univdecl_extensible_constraints) then
       ignore (Evd.check_univ_decl ~poly:(pi2 kind) evd decl)
  in
  let evd =
    if pi2 kind then evd
    else (* We fix the variables to ensure they won't be lowered to Set *)
      Evd.fix_undefined_variables evd
  in
  start_proof_with_initialization ?hook kind evd decl recguard thms snl

(* Saving a proof *)

let keep_admitted_vars = ref true

let () =
  let open Goptions in
  declare_bool_option
    { optdepr  = false;
      optname  = "keep section variables in admitted proofs";
      optkey   = ["Keep"; "Admitted"; "Variables"];
      optread  = (fun () -> !keep_admitted_vars);
      optwrite = (fun b -> keep_admitted_vars := b) }

let save_proof_admitted ?proof ~pstate =
  let pe =
    let open Proof_global in
    match proof with
    | Some ({ id; entries; persistence = k; universes }, _) ->
      if List.length entries <> 1 then
        user_err Pp.(str "Admitted does not support multiple statements");
      let { const_entry_secctx; const_entry_type } = List.hd entries in
      if const_entry_type = None then
        user_err Pp.(str "Admitted requires an explicit statement");
      let typ = Option.get const_entry_type in
      let ctx = UState.univ_entry ~poly:(pi2 k) universes in
      let sec_vars = if !keep_admitted_vars then const_entry_secctx else None in
      Admitted(id, k, (sec_vars, (typ, ctx), None), universes)
    | None ->
      let pftree = Proof_global.give_me_the_proof pstate in
      let gk = Proof_global.get_current_persistence pstate in
      let Proof.{ name; poly; entry } = Proof.data pftree in
      let typ = match Proofview.initial_goals entry with
        | [typ] -> snd typ
        | _ ->
          CErrors.anomaly
            ~label:"Lemmas.save_proof" (Pp.str "more than one statement.")
      in
      let typ = EConstr.Unsafe.to_constr typ in
      let universes = Proof.((data pftree).initial_euctx) in
      (* This will warn if the proof is complete *)
      let pproofs, _univs =
        Proof_global.return_proof ~allow_partial:true pstate in
      let sec_vars =
        if not !keep_admitted_vars then None
        else match Proof_global.get_used_variables pstate, pproofs with
          | Some _ as x, _ -> x
          | None, (pproof, _) :: _ ->
            let env = Global.env () in
            let ids_typ = Environ.global_vars_set env typ in
            let ids_def = Environ.global_vars_set env pproof in
            Some (Environ.keep_hyps env (Id.Set.union ids_typ ids_def))
          | _ -> None in
      let decl = Proof_global.get_universe_decl pstate in
      let ctx = UState.check_univ_decl ~poly universes decl in
      Admitted(name,gk,(sec_vars, (typ, ctx), None), universes)
  in
  Proof_global.apply_terminator (Proof_global.get_terminator pstate) pe

let save_pstate_proved ~pstate ~opaque ~idopt =
  let obj, terminator = Proof_global.close_proof ~opaque
      ~keep_body_ucst_separate:false (fun x -> x) pstate
  in
  Proof_global.(apply_terminator terminator (Proved (opaque, idopt, obj)))

let save_proof_proved ?proof ?ontop ~opaque ~idopt =
  (* Invariant (uh) *)
  if Option.is_empty ontop && Option.is_empty proof then
    user_err (str "No focused proof (No proof-editing in progress).");
  let (proof_obj,terminator) =
    match proof with
    | None ->
      (* XXX: The close_proof and proof state API should be refactored
         so it is possible to insert proofs properly into the state *)
      let pstate = Proof_global.get_current_pstate @@ Option.get ontop in
      Proof_global.close_proof ~opaque ~keep_body_ucst_separate:false (fun x -> x) pstate
    | Some proof -> proof
  in
  (* if the proof is given explicitly, nothing has to be deleted *)
  let ontop = if Option.is_empty proof then Proof_global.discard_current Option.(get ontop) else ontop in
  Proof_global.(apply_terminator terminator (Proved (opaque,idopt,proof_obj)));
  ontop
