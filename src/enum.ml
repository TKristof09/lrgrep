open Utils

(* Command-line parsing. *)

let opt_grammar_file = ref None
let opt_verbose = ref false

let usage =
  Printf.sprintf
    "lrgrep, a menhir lexer\n\
     usage: %s [options] <source>"
    Sys.argv.(0)

let print_version_num () =
  print_endline "0.1";
  exit 0

let print_version_string () =
  print_string "The Menhir parser lexer generator :-], version ";
  print_version_num ()

let error {Front.Syntax. line; col} fmt =
  Printf.eprintf "Error line %d, column %d: " line col;
  Printf.kfprintf (fun oc -> output_char oc '\n'; flush oc; exit 1) stderr fmt

let warn {Front.Syntax. line; col} fmt =
  Printf.eprintf "Warning line %d, column %d: " line col;
  Printf.kfprintf (fun oc -> output_char oc '\n'; flush oc) stderr fmt

let eprintf = Printf.eprintf

let specs = [
  "-g", Arg.String (fun x -> opt_grammar_file := Some x),
  " <file.cmly>  Path of the Menhir compiled grammar to analyse (*.cmly)";
  "-v", Arg.Set opt_verbose,
  " Increase output verbosity";
  "-version", Arg.Unit print_version_string,
  " Print version and exit";
  "-vnum", Arg.Unit print_version_num,
  " Print version number and exit";
]

let () = Arg.parse specs (fun arg -> failwith ("Unexpected argument: " ^ arg)) usage

let grammar_file = match !opt_grammar_file with
  | Some filename -> filename
  | None ->
    Format.eprintf "No grammar provided (-g), stopping now.\n";
    Arg.usage specs usage;
    exit 1

let () = Stopwatch.step Stopwatch.main "Beginning"

module Grammar = MenhirSdk.Cmly_read.Read(struct let filename = grammar_file end)

let () = Stopwatch.step Stopwatch.main "Loaded grammar"

module Info = Mid.Info.Make(Grammar)
module Viable = Mid.Viable_reductions.Make(Info)()
module Reachability = Mid.Reachability.Make(Info)()
(*module Lrc = Mid.Lrc.Make(Info)(Reachability)*)
(* Re-enable when minimization is fixed *)
(*module Lrc = Mid.Lrc.Minimize(Info)(Mid.Lrc.Make(Info)(Reachability))
  module Reachable = Mid.Reachable_reductions.Make2(Info)(Viable)(Lrc)()*)
module Lrc = Mid.Lrc.Make(Info)(Reachability)
module Reachable = Mid.Reachable_reductions.Make2(Info)(Viable)(Lrc)()

open Fix.Indexing

module Reduction_coverage = struct

  type tree = {
    depth: int;
    mutable next: (Reachable.state index * tree) list;
  }

  let add_node root state =
    let node = { depth = root.depth + 1; next = [] } in
    root.next <- (state, node) :: root.next;
    node

  let rec count (sum, steps as acc) = function
    | { depth; next = [] } -> (sum + 1, steps + depth)
    | { depth = _; next } -> List.fold_left count_transitions acc next

  and count_transitions acc (_, node) =
    count acc node

  let measure node =
    let count, steps = IndexMap.fold (fun _ node acc -> count acc node) node (0, 0) in
    Printf.sprintf "%d sentences, average length %.02f" count (float steps /. float count)

  let bfs =
    let visited = Vector.make Reachable.state false in
    let enter parent ~depth:_ acc {Reachable.target=st; _} =
      if Vector.get visited st then
        acc
      else (
        let node = add_node parent st in
        Vector.set visited st true;
        (node, st) :: acc
      )
    in
    let visit acc (node, st) =
      Reachable.fold_transitions (enter node) acc
        (Vector.get Reachable.states st).transitions
    in
    let rec loop = function
      | [] -> ()
      | acc -> loop (List.fold_left visit [] acc)
    in
    let acc = ref [] in
    let bfs =
      IndexMap.map (fun st ->
        let node = { depth = 1; next = [] } in
        acc := Reachable.fold_transitions (enter node) !acc
            (Vector.get Reachable.states st).transitions;
        node
      ) Reachable.initial
    in
    loop !acc;
    bfs

  let dfs =
    let visited = Vector.make Reachable.state false in
    let rec enter parent ~depth:_ {Reachable. target=st; _} =
      if not (Vector.get visited st) then
        visit (add_node parent st) st
    and visit node st =
      Vector.set visited st true;
      Reachable.iter_transitions
        (Vector.get Reachable.states st).transitions
        (enter node)
    in
    IndexMap.map (fun st ->
        let node = { depth = 1; next = [] } in
        visit node st;
        node
      ) Reachable.initial


  let () = Printf.eprintf "Reduction coverage: dfs:%s, bfs:%s\n%!" (measure dfs) (measure bfs)
end

let lrc_successors =
  Vector.get (Misc.relation_reverse' Lrc.n Lrc.predecessors)

let lrc_prefix =
  let table = Vector.make Lrc.n [] in
  let todo = ref [] in
  let expand prefix state =
    match Vector.get table state with
    | [] ->
      Vector.set table state prefix;
      let prefix = state :: prefix in
      let successors = lrc_successors state in
      if not (IndexSet.is_empty successors) then
        Misc.push todo (successors, prefix)
    | _ -> ()
  in
  let visit (successors, prefix) =
    IndexSet.iter (expand prefix) successors
  in
  let rec loop = function
    | [] -> ()
    | other ->
      todo := [];
      List.iter visit other;
      loop !todo
  in
  Index.iter Info.Lr1.n (fun lr1 ->
      if Option.is_none (Info.Lr1.incoming lr1) then
        expand [] (Lrc.first_lrc_of_lr1 lr1)
    );
  loop !todo;
  Vector.get table

let output_item oc (prod, dot) =
  let open Info in
  output_string oc " /";
  output_string oc (Nonterminal.to_string (Production.lhs prod));
  output_char oc ':';
  let rhs = Production.rhs prod in
  for i = 0 to dot - 1 do
    output_char oc ' ';
    output_string oc (Symbol.name rhs.(i));
  done;
  output_string oc " .";
  for i = dot to Array.length rhs - 1 do
    output_char oc ' ';
    output_string oc (Symbol.name rhs.(i));
  done

let pr_lrc lrc =
  let lr1 = Lrc.lr1_of_lrc lrc in
  Info.Lr1.to_string lr1 ^ "@" ^
  if (lr1 : _ index :> int) = 601 then
    Misc.string_of_indexset
      ~index:Info.Terminal.to_string
      (Lrc.lookahead lrc)
  else
    string_of_int (Lrc.class_index lrc)

(* Validate prefixes *)
let () =
  if false then
    Index.iter Lrc.n (fun lrc ->
        let open Info in
        let lr1 = Lrc.lr1_of_lrc lrc in
        let p, n =
          match Lr1.items lr1 with
          | [] -> assert false
          | (p, n) :: other ->
            List.fold_left
              (fun (_, n as acc) (_, m as it) -> if m > n then it else acc)
              (p, n) other
        in
        let rhs = Production.rhs p in
        let prefix = lrc_prefix lrc in
        let invalid () =
          Printf.printf "Invalid prefix: %s\n"
            (Misc.string_concat_map " " pr_lrc prefix);
          Printf.printf "For state with items:\n";
          List.iter (fun x ->
              output_item stdout x;
              print_newline ()
            ) (Lr1.items lr1);
        in
        if prefix = [] then
          invalid ()
        else
          let cursor = ref (lrc_prefix lrc) in
          for i = n - 2 downto 0 do
            let valid = match !cursor with
              | [] -> false
              | hd :: tl ->
                cursor := tl;
                Lr1.incoming (Lrc.lr1_of_lrc hd) = Some rhs.(i)
            in
            if not valid then (
              invalid();
              assert false
            )
          done
      )

module Lookahead_coverage = struct
  open Info

  type node = {
    state: Reachable.state index;
    depth: int;
    committed: Terminal.set;
    rejected: Terminal.set;
    mutable next: (Info.Reduction.t * int * node) list;
  }

  type status = {
    accepted: Terminal.set;
    node: node;
  }

  let root state ~accepted ~rejected =
    let committed = Reachable.potential_reject_after state in
    let committed = IndexSet.diff committed accepted in
    let committed = IndexSet.diff committed rejected in
    {state; depth = 1; committed; rejected; next = []}

  let add_node parent ~committed ~rejected ~depth {Reachable.target; reduction} =
    let node = {state=target; depth = parent.depth + 1; committed; rejected; next = []} in
    parent.next <- (reduction, depth, node) :: parent.next;
    node

  let rec count (sum, steps as acc) = function
    | { next = []; depth; _ } -> (sum + 1, steps + depth)
    | { next; _ } -> List.fold_left count_transitions acc next

  and count_transitions acc (_, _, node) =
    count acc node

  let measure map =
    let count, steps =
      IndexMap.fold
        (fun _ nodes acc -> count acc nodes)
        map (0, 0)
    in
    Printf.sprintf "%d sentences, average length %.02f" count (float steps /. float count)

  let enter () =
    let node_pra = Vector.init Reachable.state Reachable.potential_reject_after in
    let node_prb = Vector.init Reachable.state Reachable.potential_reject_before in
    fun status ~depth tr ->
    let st = tr.Reachable.target in
    let rejected = IndexSet.diff (Reachable.immediate_reject st) status.accepted in
    let accepted = IndexSet.diff (Reachable.immediate_accept st) status.node.rejected in
    let rejected = IndexSet.union rejected status.node.rejected in
    let accepted = IndexSet.union accepted status.accepted in
    let prb = Vector.get node_prb st in
    let prb' = IndexSet.diff prb rejected in
    let pra = Vector.get node_pra st in
    let pra' = IndexSet.diff pra accepted in
    if prb == prb' || IndexSet.is_empty pra' then
      None
    else (
      let committed = IndexSet.diff (IndexSet.union status.node.committed pra') rejected in
      let node = add_node status.node ~depth ~committed ~rejected tr in
      Vector.set node_prb st prb';
      Vector.set node_pra st (IndexSet.diff pra pra');
      Some {accepted; node}
    )

  let dfs =
    let enter = enter () in
    let rec visit status ~depth tr =
      match enter status ~depth tr with
      | None -> ()
      | Some status' ->
        Reachable.iter_transitions
          (Vector.get Reachable.states tr.Reachable.target).transitions
          (visit status');
    in
    IndexMap.mapi (fun lrc st ->
      let lr1 = Lrc.lr1_of_lrc lrc in
      let accepted = Lr1.shift_on lr1 in
      let rejected = Lr1.reject lr1 in
      let node = root ~accepted ~rejected st in
      Reachable.iter_transitions
        (Vector.get Reachable.states st).transitions
        (visit {accepted; node});
      node
    ) Reachable.initial

  let bfs =
    let enter = enter () in
    let visit acc (status, depth, tr) =
      match enter status ~depth tr with
      | None -> acc
      | Some status' ->
        Reachable.fold_transitions
          (fun ~depth acc tr -> (status', depth, tr) :: acc)
          acc (Vector.get Reachable.states tr.Reachable.target).transitions
    in
    let todo, map =
      let todo = ref [] in
      let map = IndexMap.mapi (fun lrc st ->
          let lr1 = Lrc.lr1_of_lrc lrc in
          let accepted = Lr1.shift_on lr1 in
          let rejected = Lr1.reject lr1 in
          let node = root ~accepted ~rejected st in
          Reachable.iter_transitions
            (Vector.get Reachable.states st).transitions
            (fun ~depth tr ->
               Misc.push todo ({accepted; node}, depth, tr));
          node
        ) Reachable.initial
      in
      !todo, map
    in
    let rec loop = function
      | [] -> ()
      | todo' -> loop (List.fold_left visit [] todo')
    in
    loop todo;
    map

  let () =
    Printf.eprintf "Abstract lookahead coverage: dfs:%s, bfs:%s\n" (measure dfs) (measure bfs)

  let measure_lookaheads map =
    let count = ref 0 in
    let remainder = ref 0 in
    let rec visit node =
      let rejected =
        match node.next with
        | [] ->
          count := !count + IndexSet.cardinal node.rejected;
          node.rejected
        | children ->
          List.fold_left
            (fun acc (_, _, node) -> IndexSet.union acc (visit node))
            IndexSet.empty children
      in
      assert (IndexSet.subset node.rejected rejected);
      remainder := !remainder + IndexSet.cardinal (IndexSet.diff node.committed rejected);
      IndexSet.union rejected node.committed
    in
    IndexMap.iter (fun _ node -> ignore (visit node)) map;
    Printf.sprintf "%d sentences (%d direct, %d indirect)" (!count + !remainder) !count !remainder

  let () =
    Printf.eprintf "Concrete lookahead coverage: dfs:%s, bfs:%s\n"
      (measure_lookaheads dfs)
      (measure_lookaheads bfs)

  type suffix =
    | Top of Reachable.state index * Lrc.t
    | Reduce of Reachable.state index * Info.Reduction.t * int * suffix

  let items_from_suffix suffix =
    let items_of_state state =
      let desc = Vector.get Reachable.states state in
      let config = Viable.get_config desc.config.source in
      Lr1.items config.top
    in
    let rec loop acc = function
      | Reduce (state, _, _, next) ->
        loop (items_of_state state :: acc) next
      | Top (state, _) ->
        items_of_state state :: acc
    in
    loop [] suffix

  let enum_sentences map f =
    let rec visit_node suffix node =
      let rejected = match node.next with
        | [] ->
          f suffix node.rejected;
          node.rejected
        | children ->
          List.fold_left
            (fun acc node -> IndexSet.union acc (visit_child suffix node))
            IndexSet.empty children
      in
      assert (IndexSet.subset node.rejected rejected);
      let remainder = IndexSet.diff node.committed rejected in
      ignore remainder; (*TODO*)
      IndexSet.union rejected node.committed
    and visit_child suffix (reduction, depth, node) =
      visit_node (Reduce (node.state, reduction, depth, suffix)) node
    in
    IndexMap.iter (fun lrc node ->
      ignore (visit_node (Top (node.state, lrc)) node)) map

  module Form_generator : sig
    type t
    val start : Lr1.t -> t
    val pop : t -> t
    val push : t -> t
    val base : t -> Lrc.set -> t
    val reduce : t -> Lrc.set -> Production.t -> t
    val finish : t -> Lrc.set list
  end = struct
    type t = {
      stack: Lrc.set list;
      pop: Lrc.set list;
      push: int;
    }

    let start lr1 =
      let lrc = Lrc.first_lrc_of_lr1 lr1 in
      let lrcs = Lrc.predecessors lrc in
      let stack = [lrcs; IndexSet.singleton lrc] in
      {stack; pop = []; push = 1 }

    let top t = match t.pop with
      | x :: _ -> x
      | [] -> List.hd t.stack

    let pop t =
      if t.push > 0 then (
        assert (t.pop = []);
        {t with push = t.push - 1}
      ) else (
        assert (t.push = 0);
        let top' = Misc.indexset_bind (top t) Lrc.predecessors in
        {t with pop = top' :: t.pop}
      )


    let push t =
      {t with push = t.push + 1}

    let rec popn t = function
      | 0 -> t
      | n -> popn (pop t) (n - 1)

    let base t x =
      assert (IndexSet.subset x (top t));
      match t.pop with
      | [] ->
        {t with stack = (x :: List.tl t.stack); pop = []}
      | _x :: xs ->
        let rec update x = function
          | [] -> t.stack
          | x' :: xs ->
            let x'' = IndexSet.inter x' (Misc.indexset_bind x lrc_successors) in
            assert (not (IndexSet.is_empty x''));
            x'' :: update x'' xs
        in
        {t with stack = (x :: update x xs); pop = []}

    let reduce t lrcs prod =
      let t' = popn t (Production.length prod) in
      let pr_lrcs xs =
        Misc.string_concat_map " " (Misc.string_of_indexset ~index:pr_lrc) xs
      in
      let top = top t' in
      if not (IndexSet.subset lrcs top) then (
        Printf.eprintf "Broke base invariant:\n\
                        reducing %s: %s\n\
                        from gen: {stack:%s; pop:%s; push:%d}\n\
                        after gen: {stack:%s; pop:%s; push:%d}\n\
                        expected base: %s\n\
                        found base: %s\n\
                       "
          (Nonterminal.to_string (Production.lhs prod))
          (Misc.string_concat_map " " Symbol.name
             (Array.to_list (Production.rhs prod)))
          (pr_lrcs t.stack)
          (pr_lrcs t.pop)
          t.push
          (pr_lrcs t'.stack)
          (pr_lrcs t'.pop)
          t'.push
          (Misc.string_of_indexset ~index:pr_lrc lrcs)
          (Misc.string_of_indexset ~index:pr_lrc top)
      ) else (
        assert (if IndexSet.is_empty lrcs then IndexSet.is_empty top else true)
      );
      base (push t') lrcs

    let finish t =
      assert (t.pop = []);
      match t.stack with
      | x :: xs when IndexSet.is_empty x -> xs
      | xs -> xs
  end

  (*module Form_generator : sig
    type t
    val start : Lrc.set -> t
    val grow : Lrc.set -> int -> t -> t
    val finish : t -> Lrc.set list
  end = struct

    type t = {
      top: Lrc.set;
      head: Lrc.set list;
      tail: Lrc.set list;
    }

    let pr_lrcs lrcs =
      let lr1s = IndexSet.map Lrc.lr1_of_lrc lrcs in
      Misc.string_of_indexset ~index:Lr1.to_string lr1s

    let start x =
      Printf.printf "Form_gen: start with %s\n" (pr_lrcs x);
      { top = x; head = []; tail = []}

    let normalize t =
      let rec prepend = function
        | [] -> assert false
        | [x] -> x :: t.tail
        | x :: y :: ys ->
          let y' = Misc.indexset_bind x lrc_successors in
          let y' = IndexSet.inter y y' in
          assert (not (IndexSet.is_empty y'));
          let ys' = prepend (y' :: ys) in
          Printf.printf "Form_gen: normalize %s\n" (pr_lrcs x);
          x :: ys'
      in
      prepend (t.top :: t.head)

    let rec candidates acc y = function
      | 1 -> acc
      | n ->
        let y' = Misc.indexset_bind y Lrc.predecessors in
        candidates (y' :: acc) y' (n - 1)

    let grow top n t =
      if n <= 0 then (
        assert (IndexSet.subset top t.top);
        Printf.printf "Form_gen: restrict %s\n" (pr_lrcs top);
        {t with top = top}
      ) else (
        let tail = normalize t in
        let head = candidates [] t.top n in
        Printf.printf "Form_gen: grow %d: %s\n" n (Misc.string_concat_map " " pr_lrcs (top :: head));
        {top; head; tail}
      )

    let finish = normalize
  end*)

  let rec cells_of_lrc_list = function
    | [] -> assert false
    | [_] ->  []
    | (x :: (y :: _ as tail)) ->
      let xl = Lrc.lr1_of_lrc x in
      let yl = Lrc.lr1_of_lrc y in
      let yi = Lrc.class_index y in
      let tr =
        List.find
          (fun tr -> Transition.source tr = xl)
          (Transition.predecessors yl)
      in
      let open Reachability in
      let xi =
        match Classes.pre_transition tr with
        | [|c_pre|] when IndexSet.is_singleton c_pre ->
          if not (IndexSet.subset c_pre (Lrc.lookahead x)) then (
            Printf.eprintf "pre:%s expected:%s\nfrom:%s to:%s after:%s\n%!"
              (Misc.string_of_indexset ~index:Terminal.to_string c_pre)
              (Misc.string_of_indexset ~index:Terminal.to_string (Lrc.lookahead x))
              (Lr1.to_string xl)
              (Lr1.to_string yl)
              (if IndexSet.equal (Lrc.lookahead y) Terminal.all
               then "all"
               else Misc.string_of_indexset ~index:Terminal.to_string (Lrc.lookahead y))
            ;
            assert false
          );
          0
        | _ -> Lrc.class_index x
      in
      let yi = (Coercion.infix (Classes.post_transition tr) (Classes.for_lr1 yl)).backward.(yi)
      in
      Cells.encode (Tree.leaf tr) xi yi :: cells_of_lrc_list tail

  (*let expand_node xi node yi acc =
    let open Reachability in
    match Cells.cost (Cells.encode node xi yi) with
    | 0 -> acc
    | n ->
      let _null, eqns = Tree.goto_equations goto in
      let pre = Tree.pre_classes node in
      let check_eqn (node', lookahead) =
        match Coercion.pre pre (Tree.pre_classes node') with
        | None -> None
        | Some (Pre_singleton xi') ->
          if xi = xi' then
            Some (expand_transition (0,
                                     | Some Pre_identity ->
      in
      Option.get (List.find_map check_eqn eqns)*)

  exception Break of Terminal.t list

  let rec prepend_word cell acc =
    let open Reachability in
    let node, i_pre, i_post = Cells.decode cell in
    match Tree.split node with
    | L tr ->
      (* The node corresponds to a transition *)
      begin match Transition.split tr with
        | R shift ->
          (* It is a shift transition, just shift the symbol *)
          Transition.shift_symbol shift :: acc
        | L goto ->
          (* It is a goto transition *)
          let nullable, non_nullable = Tree.goto_equations goto in
          let c_pre = (Tree.pre_classes node).(i_pre) in
          let c_post = (Tree.post_classes node).(i_post) in
          if not (IndexSet.is_empty nullable) &&
             IndexSet.quick_subset c_post nullable &&
             not (IndexSet.disjoint c_pre c_post) then
            (* If a nullable reduction is possible, don't do anything *)
            acc
          else
            (* Otherwise look at all equations that define the cost of the
               goto transition and recursively visit one of minimal cost *)
            let current_cost = Cells.cost cell in
            match
              List.find_map (fun (node', lookahead) ->
                  if IndexSet.disjoint c_post lookahead then
                    (* The post lookahead class does not permit reducing this
                       production *)
                    None
                  else
                    let costs = Vector.get Cells.table node' in
                    match Tree.pre_classes node' with
                    | [|c_pre'|] when IndexSet.disjoint c_pre' c_pre ->
                      (* The pre lookahead class does not allow to enter this
                         branch. *)
                      None
                    | pre' ->
                      (* Visit all lookahead classes, pre and post, and find
                         the mapping between the parent node and this
                         sub-node *)
                      let pred_pre _ c_pre' = IndexSet.quick_subset c_pre' c_pre in
                      let pred_post _ c_post' = IndexSet.quick_subset c_post c_post' in
                      match
                        Misc.array_findi pred_pre 0 pre',
                        Misc.array_findi pred_post 0 (Tree.post_classes node')
                      with
                      | exception Not_found -> None
                      | i_pre', i_post' ->
                        let offset = Cells.offset node' i_pre' i_post' in
                        if costs.(offset) = current_cost then
                          (* We found a candidate of minimal cost *)
                          Some (Cells.encode_offset node' offset)
                        else
                          None
                ) non_nullable
            with
            | None ->
              Printf.eprintf "abort, cost = %d\n%!" current_cost;
              assert false
            | Some cell' ->
              (* Solve the sub-node *)
              prepend_word cell' acc
      end
    | R (l, r) ->
      (* It is an inner node.
         We decompose the problem in a left-hand and a right-hand
         sub-problems, and find sub-solutions of minimal cost *)
      let current_cost = Cells.cost cell in
      let coercion =
        Coercion.infix (Tree.post_classes l) (Tree.pre_classes r)
      in
      let l_index = Cells.encode l in
      let r_index = Cells.encode r in
      begin try
          Array.iteri (fun i_post_l all_pre_r ->
              let l_cost = Cells.cost (l_index i_pre i_post_l) in
              Array.iter (fun i_pre_r ->
                  let r_cost = Cells.cost (r_index i_pre_r i_post) in
                  if l_cost + r_cost = current_cost then (
                    let acc = prepend_word (r_index i_pre_r i_post) acc in
                    let acc = prepend_word (l_index i_pre i_post_l) acc in
                    raise (Break acc)
                  )
                ) all_pre_r
            ) coercion.Coercion.forward;
          assert false
        with Break acc -> acc
      end

  let () =
    let construct_form suffix =
      let rec loop =  function
        | Top (state, _) ->
          Form_generator.start
            (Viable.get_config (Vector.get Reachable.states state).config.source).top
        | Reduce (state, red, _depth, suffix) ->
          let gen = loop suffix in
          let lrcs = (Vector.get Reachable.states state).config.lrcs in
          Form_generator.reduce gen lrcs (Reduction.production red)
      in
      Form_generator.finish (loop suffix)
    in
    let construct_form2 suffix =
      let rec loop = function
        | Top (state, lrc) ->
          let lrcs = (Vector.get Reachable.states state).config.lrcs in
          (lrcs, [IndexSet.singleton lrc])
        | Reduce (state, _red, depth, suffix) ->
          let (lrcs', result) = loop suffix in
          let lrcs = (Vector.get Reachable.states state).config.lrcs in
          let result =
            if depth <= 0 then (
              if depth = -1
              then assert (IndexSet.equal lrcs lrcs')
              else assert (IndexSet.subset lrcs lrcs');
              result
            ) else (
              let rlrcs = ref lrcs' in
              let result' = ref [lrcs'] in
              for _ = 1 to depth - 1 do
                rlrcs := Misc.indexset_bind !rlrcs Lrc.predecessors;
                result' := !rlrcs :: !result';
              done;
              let rec restrict lrcs = function
                | [] -> result
                | x :: xs ->
                  let lrcs = Misc.indexset_bind lrcs lrc_successors in
                  IndexSet.inter lrcs x :: restrict lrcs xs
              in
              restrict lrcs !result'
            )
          in
          (lrcs, result)
      in
      let lrcs, result = loop suffix in
      if IndexSet.is_empty lrcs then
        result
      else
        lrcs :: result
    in
    let print_terminal t = print_char ' '; print_string (Terminal.to_string t) in
    let print_items items =
      print_string " [";
      List.iter (output_item stdout) items;
      print_string " ]";
    in
    let rec select_one = function
      | [] -> []
      | [x] -> [IndexSet.choose x]
      | x :: y :: ys ->
        let x = IndexSet.choose x in
        x :: select_one (IndexSet.inter (lrc_successors x) y :: ys)
    in
    let prepare_sentence lrcs =
      let lrcs = select_one lrcs in
      let lrcs = List.rev_append (lrc_prefix (List.hd lrcs)) lrcs in
      Printf.printf "form: %s\n" (Misc.string_concat_map " " pr_lrc lrcs);
      let cells = cells_of_lrc_list lrcs in
      let result = List.fold_right prepend_word cells [] in
      (List.hd lrcs, result)
    in
    enum_sentences dfs (fun suffix lookaheads ->
        let entrypoint, word = prepare_sentence (construct_form suffix) in
        let _entrypoint, word' = prepare_sentence (construct_form2 suffix) in
        assert (List.equal Index.equal word word');
        let entrypoint =
          entrypoint
          |> Lrc.lr1_of_lrc
          |> Lr1.entrypoint
          |> Option.get
          |> Nonterminal.to_string
        in
        let entrypoint = String.sub entrypoint 0 (String.length entrypoint - 1) in
        print_string entrypoint;
        List.iter print_terminal word;
        print_string "\n";
        List.iter print_terminal word';
        print_string "\n@";
        IndexSet.iter print_terminal lookaheads;
        List.iter print_items (items_from_suffix suffix);
        print_newline ()
      )
end
