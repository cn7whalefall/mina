open Core

module Sequence_number = struct
  type t = int [@@deriving sexp]
end

(*Each node on the tree is viewed as a job that needs to be completed. When a job is completed, it creates a new "Todo" job and marks the old job as "Done"*)
module Job_status = struct
  type t = Todo | Done [@@deriving sexp]
end

(*number of jobs that can be added to this tree. This number corresponding to a specific level of the tree. New jobs received is distributed across the tree based on this number. *)
type weight = int [@@deriving sexp]

(*Base Job: Proving new transactions*)
module Base = struct
  type 'd base =
    | Empty
    | Full of {job: 'd; seq_no: Sequence_number.t; status: Job_status.t}
  [@@deriving sexp]

  type 'd t = weight * 'd base [@@deriving sexp]
end

(* Merge Job: Merging two proofs*)
module Merge = struct
  type 'a merge =
    | Empty
    | Part of 'a (*Only the left component of the job is available yet since we always complete the jobs from left to right*)
    | Full of
        { left: 'a
        ; right: 'a
        ; seq_no: Sequence_number.t (*Update no, for debugging*)
        ; status: Job_status.t }
  [@@deriving sexp]

  type 'a t = (weight * weight) * 'a merge [@@deriving sexp]
end

(*All the jobs on a tree that can be done. Base.Full and Merge.Bcomp*)
module Available_job = struct
  type ('a, 'd) t = Base of 'd | Merge of 'a * 'a [@@deriving sexp]
end

(*New jobs to be added (including new transactions or new merge jobs)*)
module New_job = struct
  type ('a, 'd) t = Base of 'd | Merge of 'a [@@deriving sexp]
end

module Space_partition = struct
  type t = {first: int; second: int option} [@@deriving sexp]
end

module Tree = struct
  type ('a, 'd) t =
    | Leaf of 'd
    | Node of {depth: int; value: 'a; sub_tree: ('a * 'a, 'd * 'd) t}
  [@@deriving sexp]

  (*Eg: Tree depth = 3

    Node M
    |
    Node (M,M)
    |
    Node ((M,M),(M,M))
    |
    Leaf (((B,B),(B,B)),((B,B),(B,B))) 
   *)

  (*mapi where i is the level of the tree*)
  let rec map_depth : type a b c d.
      fa:(int -> a -> b) -> fd:(d -> c) -> (a, d) t -> (b, c) t =
   fun ~fa ~fd tree ->
    match tree with
    | Leaf d ->
        Leaf (fd d)
    | Node {depth; value; sub_tree} ->
        Node
          { depth
          ; value= fa depth value
          ; sub_tree=
              map_depth
                ~fa:(fun i (x, y) -> (fa i x, fa i y))
                ~fd:(fun (x, y) -> (fd x, fd y))
                sub_tree }

  let map : type a b c d. fa:(a -> b) -> fd:(d -> c) -> (a, d) t -> (b, c) t =
   fun ~fa ~fd tree -> map_depth tree ~fd ~fa:(fun _ -> fa)

  (* foldi where i is the cur_level*)
  let rec fold_depth : type a c d.
         fa:(int -> a -> c)
      -> fd:(d -> c)
      -> f:(c -> c -> c)
      -> init:c
      -> (a, d) t
      -> c =
   fun ~fa ~fd ~f ~init:acc t ->
    match t with
    | Leaf d ->
        f acc (fd d)
    | Node {depth; value; sub_tree} ->
        let acc' =
          fold_depth ~f
            ~fa:(fun i (x, y) -> f (fa i x) (fa i y))
            ~fd:(fun (x, y) -> f (fd x) (fd y))
            ~init:acc sub_tree
        in
        f acc' (fa depth value)

  let fold : type a c d.
      fa:(a -> c) -> fd:(d -> c) -> f:(c -> c -> c) -> init:c -> (a, d) t -> c
      =
   fun ~fa ~fd ~f ~init t -> fold_depth t ~init ~fa:(fun _ -> fa) ~fd ~f

  (*List of things that map to a specific level on the tree**)
  module Data_list = struct
    module T = struct
      type 'a t = Single of 'a | Double of ('a * 'a) t [@@deriving sexp]
    end

    type ('a, 'b) tree = ('a, 'b) t

    include T

    let rec split : type a. a t -> (a -> a * a) -> (a * a) t =
     fun lst f ->
      match lst with
      | Single a ->
          Single (f a)
      | Double t ->
          let sub = split t (fun (x, y) -> (f x, f y)) in
          Double sub

    let rec combine : type a. a t -> a t -> (a * a) t =
     fun lst1 lst2 ->
      match (lst1, lst2) with
      | Single a, Single b ->
          Single (a, b)
      | Double a, Double b ->
          Double (combine a b)
      | _ ->
          failwith "error"

    let rec fold : type a b. a t -> f:(b -> a -> b) -> init:b -> b =
     fun t ~f ~init ->
      match t with
      | Single a ->
          f init a
      | Double a ->
          fold a ~f:(fun acc (a, b) -> f (f acc a) b) ~init

    let rec of_tree : type a b c d.
           c t
        -> (a, d) tree
        -> weight_a:(a -> b * b)
        -> weight_d:(d -> b * b)
        -> f_split:(b * b -> c -> c * c)
        -> on_level:int
        -> c t =
     fun job_list tree ~weight_a ~weight_d ~f_split ~on_level ->
      match tree with
      | Node {depth; value; sub_tree} ->
          if depth = on_level then job_list
          else
            let l, r = weight_a value in
            let new_job_list = split job_list (f_split (l, r)) in
            Double
              (of_tree new_job_list sub_tree
                 ~weight_a:(fun (a, b) -> (weight_a a, weight_a b))
                 ~weight_d:(fun (a, b) -> (weight_d a, weight_d b))
                 ~f_split:(fun ((x1, y1), (x2, y2)) (a, b) ->
                   (f_split (x1, y1) a, f_split (x2, y2) b) )
                 ~on_level)
      | Leaf b ->
          Double (split job_list (f_split (weight_d b)))

    let of_list_and_tree lst tree on_level =
      of_tree (Single lst) tree ~weight_a:fst
        ~weight_d:(fun d -> (fst d, 0))
        ~f_split:(fun (l, r) a -> (List.take a l, List.take (List.drop a l) r))
        ~on_level

    (*Just the nested data*)
    let to_data : type a. a t -> a =
     fun t ->
      let rec go : type a. a t -> a * a =
       fun data_list ->
        match data_list with Single a -> (a, a) | Double js -> fst (go js)
      in
      fst @@ go t
  end

  (*
    a -> 'a Merge.t
    b -> New_job.t Data_list.t
    c -> weight
    d -> 'd Base.t
    e -> 'a (final proof)
    fa, fb are to update the nodes with new jobs and mark old jobs to "Done"*)
  let rec update_split : type a b c d e.
         fa:(b -> int -> a -> a * e option)
      -> fd:((*int here is the current level*)
             b -> d -> d)
      -> weight_a:(a -> c * c)
      -> jobs:b Data_list.t
      -> jobs_split:(c * c -> b -> b * b)
      -> (a, d) t
      -> (a, d) t * e option =
   fun ~fa ~fd ~weight_a ~jobs ~jobs_split t ->
    match t with
    | Leaf d ->
        (Leaf (fd (Data_list.to_data jobs) d), None)
    | Node {depth; value; sub_tree} ->
        let weight_left_subtree, weight_right_subtree = weight_a value in
        (*update the jobs at the current level*)
        let value', scan_result = fa (Data_list.to_data jobs) depth value in
        (*split the jobs for the next level*)
        let new_jobs_list =
          Data_list.split jobs
            (jobs_split (weight_left_subtree, weight_right_subtree))
        in
        (*get the updated subtree*)
        let sub, _ =
          update_split
            ~fa:(fun (b, b') i (x, y) ->
              let left = fa b i x in
              let right = fa b' i y in
              ((fst left, fst right), Option.both (snd left) (snd right)) )
            ~fd:(fun (b, b') (x, x') -> (fd b x, fd b' x'))
            ~weight_a:(fun (a, b) -> (weight_a a, weight_a b))
            ~jobs_split:(fun (x, y) (a, b) -> (jobs_split x a, jobs_split y b))
            ~jobs:new_jobs_list sub_tree
        in
        (Node {depth; value= value'; sub_tree= sub}, scan_result)

  let rec update_combine : type a b d.
         fa:((b * b) Data_list.t -> a -> a * b Data_list.t)
      -> fd:((*int here is the current level*)
             d -> d * b Data_list.t)
      -> (a, d) t
      -> (a, d) t * b Data_list.t =
   fun ~fa ~fd t ->
    match t with
    | Leaf d ->
        let new_base, count_list = fd d in
        (Leaf new_base, count_list)
    | Node {depth; value; sub_tree} ->
        (*get the updated subtree*)
        let sub, counts =
          update_combine
            ~fa:(fun b (x, y) ->
              let b1, b2 = Data_list.to_data b in
              let left, count1 = fa (Single b1) x in
              let right, count2 = fa (Single b2) y in
              let count = Data_list.combine count1 count2 in
              ((left, right), count) )
            ~fd:(fun (x, y) ->
              let left, count1 = fd x in
              let right, count2 = fd y in
              let count = Data_list.combine count1 count2 in
              ((left, right), count) )
            sub_tree
        in
        let value', count_list = fa counts value in
        (Node {depth; value= value'; sub_tree= sub}, count_list)

  let update :
         ('b, 'c) New_job.t list
      -> update_level:int
      -> sequence_no:int
      -> depth:int
      -> ('a, 'd) t
      -> ('a, 'd) t * 'b option =
   fun completed_jobs ~update_level ~sequence_no:seq_no ~depth:_ tree ->
    let add_merges (jobs : ('b, 'c) New_job.t list) cur_level (weight, m) =
      let left, right = weight in
      if cur_level = update_level - 1 then
        (*Create new jobs from the completed ones*)
        let new_weight, m' =
          match (jobs, m) with
          | [], e ->
              (weight, e)
          | [New_job.Merge a; Merge b], Merge.Empty ->
              ( (left - 1, right - 1)
              , Merge.Full {left= a; right= b; seq_no; status= Job_status.Todo}
              )
          | [Merge a], Empty ->
              ((left - 1, right), Part a)
          | [Merge b], Part a ->
              ( (left, right - 1)
              , Full {left= a; right= b; seq_no; status= Job_status.Todo} )
          | [Base _], Empty ->
              (*Depending on whether this is the first or second of the two base jobs*)
              let weight =
                if left = 0 then (left, right - 1) else (left - 1, right)
              in
              (weight, m)
          | [Base _], Part _ ->
              failwith "Invalid base when merge is part"
          | [Base _; Base _], Empty ->
              ((left - 1, right - 1), m)
          | _ ->
              failwith "Invalid merge job (level-1)"
        in
        ((new_weight, m'), None)
      else if cur_level = update_level then
        (*Mark completed jobs as Done*)
        match (jobs, m) with
        | [Merge a], Full ({status= Job_status.Todo; _} as x) ->
            let new_job = Merge.Full {x with status= Job_status.Done} in
            let scan_result, weight' =
              if cur_level = 0 then (Some a, (0, 0)) else (None, weight)
            in
            ((weight', new_job), scan_result)
        | [], m ->
            ((weight, m), None)
        | _ ->
            failwith "Invalid merge job"
      else if cur_level < update_level - 1 then
        (*Update the job count for all the level above*)
        match jobs with
        | [] ->
            ((weight, m), None)
        | _ ->
            let jobs_sent_left = min (List.length jobs) left in
            let jobs_sent_right =
              min (List.length jobs - jobs_sent_left) right
            in
            let new_weight =
              (left - jobs_sent_left, right - jobs_sent_right)
            in
            ((new_weight, m), None)
      else ((weight, m), None)
    in
    let add_bases jobs (weight, d) =
      match (jobs, d) with
      | [], e ->
          (weight, e)
      | [New_job.Base d], Base.Empty ->
          (weight - 1, Base.Full {job= d; seq_no; status= Job_status.Todo})
      | [New_job.Merge _], Base.Full b ->
          (weight, Base.Full {b with status= Job_status.Done})
      | _ ->
          failwith "Invalid base job"
    in
    let jobs = Data_list.Single completed_jobs in
    update_split ~fa:add_merges ~fd:add_bases tree ~weight_a:fst ~jobs
      ~jobs_split:(fun (l, r) a -> (List.take a l, List.take (List.drop a l) r))

  let reset_weights : ('a, 'd) t -> ('a, 'd) t =
   fun tree ->
    let f_base base =
      match base with
      | _weight, Base.Full {status= Job_status.Todo; _} ->
          ((1, snd base), Data_list.Single (1, 0))
      | _ ->
          ((0, snd base), Single (0, 0))
    in
    let f_merge lst m =
      let (l1, r1), (l2, r2) = Data_list.to_data lst in
      match m with
      | (_, _), Merge.Full {status= Job_status.Todo; _} ->
          (((1, 0), snd m), Data_list.Single (1, 0))
      | _ ->
          (((l1 + r1, l2 + r2), snd m), Single (l1 + r1, l2 + r2))
    in
    fst (update_combine ~fa:f_merge ~fd:f_base tree)

  let jobs_on_level :
      depth:int -> level:int -> ('a, 'd) t -> ('b, 'c) Available_job.t list =
   fun ~depth ~level tree ->
    fold_depth ~init:[] ~f:List.append
      ~fa:(fun i a ->
        match (i = level, a) with
        | true, (_weight, Merge.Full {left; right; status= Todo; _}) ->
            [Available_job.Merge (left, right)]
        | _ ->
            [] )
      ~fd:(fun d ->
        match (level = depth, d) with
        | true, (_weight, Base.Full {job; status= Todo; _}) ->
            [Available_job.Base job]
        | _ ->
            [] )
      tree

  let to_data : ('a, 'd) t -> int -> ('b, 'c) Available_job.t list =
   fun tree max_base_jobs ->
    let depth = Int.ceil_log2 max_base_jobs + 1 in
    jobs_on_level ~level:depth ~depth tree

  let rec view_tree : type a d.
      (a, d) t -> show_a:(a -> string) -> show_d:(d -> string) -> string =
   fun tree ~show_a ~show_d ->
    match tree with
    | Leaf d ->
        sprintf !"Leaf %s\n" (show_d d)
    | Node {value; sub_tree; _} ->
        let curr = sprintf !"Node %s\n" (show_a value) in
        let subtree =
          view_tree sub_tree
            ~show_a:(fun (x, y) -> sprintf !"%s  %s" (show_a x) (show_a y))
            ~show_d:(fun (x, y) -> sprintf !"%s  %s" (show_d x) (show_d y))
        in
        curr ^ subtree

  let required_job_count = function
    | Node {value= job_count, _; _} ->
        fst job_count + snd job_count
    | Leaf b ->
        fst b
end

(*This struture works well because we always complete all the nodes on a specific level before proceeding to the next level*)
module T = struct
  type ('a, 'd) t =
    { trees: ('a Merge.t, 'd Base.t) Tree.t Non_empty_list.t
          (*use non empty list*)
    ; acc: ('a * 'd list) option
          (*last emitted proof and the corresponding transactions*)
    ; next_base_pos: int
          (*All new base jobs will start from the first tree in the list*)
    ; recent_tree_data: 'd list
    ; other_trees_data: 'd list list
          (*Keeping track of all the transactions corresponding to a proof returned*)
    ; curr_job_seq_no: int (*Sequence number for the jobs added every block*)
    ; max_base_jobs: int (*transaction_capacity_log_2*)
    ; delay: int }
  [@@deriving sexp]

  let create_tree_for_level ~level ~depth ~merge ~base =
    let rec go : type a d. int -> (int -> a) -> d -> (a, d) Tree.t =
     fun d fmerge base ->
      if d >= depth then Leaf base
      else
        let sub_tree =
          go (d + 1) (fun i -> (fmerge i, fmerge i)) (base, base)
        in
        Node {depth= d; value= fmerge d; sub_tree}
    in
    let base_weight = if level = -1 then 0 else 1 in
    go 0
      (fun d ->
        let weight =
          if level = -1 then (0, 0)
          else
            let x = Int.pow 2 level / Int.pow 2 (d + 1) in
            (x, x)
        in
        (weight, merge) )
      (base_weight, base)

  let create_tree ~depth =
    create_tree_for_level ~level:depth ~depth ~merge:Merge.Empty
      ~base:Base.Empty

  let empty : max_base_jobs:int -> delay:int -> ('a, 'd) t =
   fun ~max_base_jobs ~delay ->
    let depth = Int.ceil_log2 max_base_jobs in
    let first_tree = create_tree ~depth in
    { trees= Non_empty_list.singleton first_tree
    ; acc= None
    ; next_base_pos= 0
    ; recent_tree_data= []
    ; other_trees_data= []
    ; curr_job_seq_no= 0
    ; max_base_jobs
    ; delay }

  let delay t = t.delay

  let max_base_jobs t = t.max_base_jobs
end

module type State_intf = sig
  type ('a, 'd) t

  val empty : max_base_jobs:int -> delay:int -> ('a, 'd) t

  val max_base_jobs : ('a, 'd) t -> int

  val delay : ('a, 'd) t -> int
end

module type State_monad_intf = functor (State : State_intf) -> sig
  include Monad.S3

  val run_state :
       ('b, 'a, 'd) t
    -> state:('a, 'd) State.t
    -> ('b * ('a, 'd) State.t) Or_error.t

  val eval_state : ('b, 'a, 'd) t -> state:('a, 'd) State.t -> 'b Or_error.t

  val exec_state :
    ('b, 'a, 'd) t -> state:('a, 'd) State.t -> ('a, 'd) State.t Or_error.t

  val get : (('a, 'd) State.t, 'a, 'd) t

  val put : ('a, 'd) State.t -> (unit, 'a, 'd) t

  val error_if : bool -> message:string -> (unit, _, _) t
end

module Make_state_monad : State_monad_intf =
functor
  (State : State_intf)
  ->
  struct
    module T = struct
      type ('a, 'd) state = ('a, 'd) State.t

      type ('b, 'a, 'd) t = ('a, 'd) state -> ('b * ('a, 'd) state) Or_error.t

      let return a s = Ok (a, s)

      let bind m ~f s =
        let open Or_error.Let_syntax in
        let%bind a, s' = m s in
        f a s'

      let map = `Define_using_bind
    end

    include T
    include Monad.Make3 (T)

    let get s = Ok (s, s)

    let put : ('a, 'd) state -> (unit, 'a, 'd) t = fun s _ -> Ok ((), s)

    let run_state t ~state = t state

    let error_if b ~message =
      if b then fun _ -> Or_error.error_string message else return ()

    let eval_state t ~state =
      let open Or_error.Let_syntax in
      let%map b, _ = run_state t ~state in
      b

    let exec_state t ~state =
      let open Or_error.Let_syntax in
      let%map _, s = run_state t ~state in
      s
  end

include T
module State_monad = Make_state_monad (T)

let max_trees t = ((Int.ceil_log2 t.max_base_jobs + 1) * (t.delay + 1)) + 1

let work_to_do :
    ('a, 'd) Tree.t list -> max_base_jobs:int -> ('b, 'c) Available_job.t list
    =
 fun trees ~max_base_jobs ->
  let depth = Int.ceil_log2 max_base_jobs in
  List.concat_mapi trees ~f:(fun i tree ->
      Tree.jobs_on_level ~depth ~level:(depth - i) tree )

(*work on all the level and all the trees*)
let all_work : type a d. (a, d) t -> (a, d) Available_job.t list =
 fun t ->
  let depth = Int.ceil_log2 t.max_base_jobs in
  let rec go trees work_list delay =
    if List.length trees = depth + 1 then
      let work = work_to_do trees ~max_base_jobs:t.max_base_jobs |> List.rev in
      work @ work_list
    else
      let work_trees =
        List.take
          (List.filteri trees ~f:(fun i _ -> i % delay = delay - 1))
          (depth + 1)
      in
      let work =
        work_to_do work_trees ~max_base_jobs:t.max_base_jobs |> List.rev
      in
      let remaining_trees =
        List.filteri trees ~f:(fun i _ -> i % delay <> delay - 1)
      in
      go remaining_trees (work @ work_list) (max 2 (delay - 1))
  in
  let work_list = go (Non_empty_list.tail t.trees) [] (t.delay + 1) in
  let current_leaves =
    Tree.to_data (Non_empty_list.head t.trees) t.max_base_jobs
  in
  List.rev_append work_list current_leaves

let work trees ~delay ~max_base_jobs =
  let depth = Int.ceil_log2 max_base_jobs in
  let work_trees =
    List.take
      (List.filteri trees ~f:(fun i _ -> i % delay = delay - 1))
      (depth + 1)
  in
  work_to_do work_trees ~max_base_jobs

let work_for_current_tree : ('b, 'a, 'd) State_monad.t =
  let open State_monad.Let_syntax in
  let%map t = State_monad.get in
  let delay = t.delay + 1 in
  work (Non_empty_list.tail t.trees) ~max_base_jobs:t.max_base_jobs ~delay

let work_for_next_update : type a d.
    (a, d) t -> data_count:int -> (a, d) Available_job.t list =
 fun t ~data_count ->
  let delay = t.delay + 1 in
  let current_tree_space =
    Tree.required_job_count (Non_empty_list.head t.trees)
  in
  let set1 =
    work (Non_empty_list.tail t.trees) ~max_base_jobs:t.max_base_jobs ~delay
  in
  let count = min data_count t.max_base_jobs in
  if current_tree_space < count then
    let set2 =
      List.take
        (work
           (Non_empty_list.to_list t.trees)
           ~max_base_jobs:t.max_base_jobs ~delay)
        ((count - current_tree_space) * 2)
    in
    set1 @ set2
  else set1

let free_space_on_current_tree t =
  let tree = Non_empty_list.head t.trees in
  Tree.required_job_count tree

let cons b bs =
  Option.value_map (Non_empty_list.of_list_opt bs)
    ~default:(Non_empty_list.singleton b) ~f:(fun bs ->
      Non_empty_list.cons b bs )

let append bs bs' =
  Option.value_map (Non_empty_list.of_list_opt bs') ~default:bs ~f:(fun bs' ->
      Non_empty_list.append bs bs' )

let add_merge_jobs : completed_jobs:'a list -> ('b, 'a, _) State_monad.t =
 fun ~completed_jobs ->
  let open State_monad.Let_syntax in
  let%bind state = State_monad.get in
  let delay = state.delay + 1 in
  let depth = Int.ceil_log2 state.max_base_jobs in
  let merge_jobs = List.map completed_jobs ~f:(fun j -> New_job.Merge j) in
  let%bind jobs_required = work_for_current_tree in
  let curr_tree = Non_empty_list.head state.trees in
  let updated_trees, result_opt, _ =
    List.foldi (Non_empty_list.tail state.trees) ~init:([], None, merge_jobs)
      ~f:(fun i (trees, scan_result, jobs) tree ->
        if i % delay = delay - 1 then
          (*All the trees with delay number of trees between them*)
          let tree', scan_result' =
            Tree.update
              (List.take jobs (Tree.required_job_count tree))
              ~update_level:(depth - (i / delay))
              ~sequence_no:state.curr_job_seq_no ~depth tree
          in
          ( tree' :: trees
          , scan_result'
          , List.drop jobs (Tree.required_job_count tree) )
        else (tree :: trees, scan_result, jobs) )
  in
  let updated_trees =
    let updated_trees =
      Option.value_map result_opt ~default:updated_trees ~f:(fun _ ->
          List.tl_exn updated_trees )
      |> List.rev
    in
    if
      Option.is_some result_opt
      || List.length (curr_tree :: updated_trees) < max_trees state
         && List.length completed_jobs = List.length jobs_required
      (*exact number of jobs*)
    then List.map updated_trees ~f:Tree.reset_weights
    else updated_trees
  in
  let all_trees = cons curr_tree updated_trees in
  let%map _ = State_monad.put {state with trees= all_trees} in
  result_opt

let add_data : data:'d list -> (_, _, 'd) State_monad.t =
 fun ~data ->
  let open State_monad.Let_syntax in
  let%bind state = State_monad.get in
  let depth = Int.ceil_log2 state.max_base_jobs in
  let tree = Non_empty_list.head state.trees in
  let base_jobs = List.map data ~f:(fun j -> New_job.Base j) in
  let available_space = Tree.required_job_count tree in
  let tree, _ =
    Tree.update base_jobs ~update_level:depth
      ~sequence_no:state.curr_job_seq_no ~depth tree
  in
  let updated_trees =
    if List.length base_jobs = available_space then
      cons (create_tree ~depth) [Tree.reset_weights tree]
    else Non_empty_list.singleton tree
  in
  let%map _ =
    State_monad.put
      {state with trees= append updated_trees (Non_empty_list.tail state.trees)}
  in
  ()

let incr_sequence_no =
  let open State_monad in
  let open State_monad.Let_syntax in
  let%bind state = get in
  put {state with curr_job_seq_no= state.curr_job_seq_no + 1}

let update_helper :
    data:'d list -> completed_jobs:'a list -> ('b, 'a, 'd) State_monad.t =
 fun ~data ~completed_jobs ->
  let open State_monad in
  let open State_monad.Let_syntax in
  let%bind t = get in
  let%bind () =
    error_if
      (List.length data > t.max_base_jobs)
      ~message:
        (sprintf
           !"Data count (%d) exceeded maximum (%d)"
           (List.length data) t.max_base_jobs)
  in
  let delay = t.delay + 1 in
  (*Increment the sequence number*)
  let%bind () = incr_sequence_no in
  let latest_tree = Non_empty_list.head t.trees in
  let available_space = Tree.required_job_count latest_tree in
  (*Possible that new base jobs be added to a new tree within an update. This happens when the throughput is not always at max. Which also requires merge jobs to be done one two different set of trees*)
  let data1, data2 = List.split_n data available_space in
  let required_jobs_for_current_tree =
    work (Non_empty_list.tail t.trees) ~max_base_jobs:t.max_base_jobs ~delay
    |> List.length
  in
  let jobs1, jobs2 =
    List.split_n completed_jobs required_jobs_for_current_tree
  in
  (*update fist set of jobs and data*)
  let%bind result_opt = add_merge_jobs ~completed_jobs:jobs1 in
  let%bind () = add_data ~data:data1 in
  (*update second set of jobs and data. This will be empty if all the data fit in the current tree*)
  let%bind _ = add_merge_jobs ~completed_jobs:jobs2 in
  let%bind () = add_data ~data:data2 in
  (*Check the tree-list length is under max*)
  let%bind state = State_monad.get in
  let%map () =
    error_if
      (Non_empty_list.length state.trees > max_trees state)
      ~message:
        (sprintf
           !"Tree list length (%d) exceeded maximum (%d)"
           (Non_empty_list.length state.trees)
           (max_trees state))
  in
  result_opt

let update :
       data:'d list
    -> completed_jobs:'a list
    -> ('a, 'd) t
    -> ('a option * ('a, 'd) t) Or_error.t =
 fun ~data ~completed_jobs t ->
  State_monad.run_state (update_helper ~data ~completed_jobs) ~state:t

let next_k_jobs :
    ('a, 'd) t -> k:int -> ('a, 'd) Available_job.t list Or_error.t =
 fun t ~k ->
  let work = all_work t in
  if k > List.length work then
    Or_error.errorf "You asked for %d jobs, but I only have %d available" k
      (List.length work)
  else Ok (List.take work k)

let next_jobs : ('a, 'd) t -> ('a, 'd) Available_job.t list = all_work

let jobs_for_next_update = work_for_next_update

let free_space t = t.max_base_jobs

let last_emitted_result : ('a, 'd) t -> ('a * 'd list) option = fun t -> t.acc

let current_job_sequence_number t = t.curr_job_seq_no

let base_jobs_on_latest_tree t =
  let depth = Int.ceil_log2 t.max_base_jobs in
  List.filter_map
    (Tree.jobs_on_level ~depth ~level:depth (Non_empty_list.head t.trees))
    ~f:(fun job -> match job with Base d -> Some d | Merge _ -> None)

let partition_if_overflowing : ('a, 'd) t -> Space_partition.t =
 fun t ->
  let cur_tree_space = free_space_on_current_tree t in
  { first= cur_tree_space
  ; second=
      ( if cur_tree_space < t.max_base_jobs then
        Some (t.max_base_jobs - cur_tree_space)
      else None ) }

let next_on_new_tree t =
  let curr_tree_space = free_space_on_current_tree t in
  curr_tree_space = t.max_base_jobs

let view_int_trees (tree : (int Merge.t, int Base.t) Tree.t) =
  let show_status = function Job_status.Done -> "D" | Todo -> "T" in
  let show_a a =
    match snd a with
    | Merge.Full {seq_no; status; left; right} ->
        sprintf "(F %d %d %s)" (left + right) seq_no (show_status status)
    | Part _ ->
        "P"
    | Empty ->
        "E"
  in
  let show_d d =
    match snd d with
    | Base.Empty ->
        "E"
    | Base.Full {seq_no; status; job} ->
        sprintf "(Ba %d %d %s)" job seq_no (show_status status)
  in
  Tree.view_tree tree ~show_a ~show_d

let%test_unit "always max base jobs" =
  let max_base_jobs = 8 in
  let state : (int, int) t = empty ~max_base_jobs ~delay:2 in
  let _t' =
    List.foldi ~init:([], state) (List.init 100 ~f:Fn.id)
      ~f:(fun i (expected_results, t') _ ->
        let data = List.init max_base_jobs ~f:(fun j -> i + j) in
        let expected_results =
          List.sum (module Int) data ~f:Fn.id :: expected_results
        in
        let work = work_for_next_update t' ~data_count:(List.length data) in
        let new_merges =
          List.map work ~f:(fun job ->
              match job with Base i -> i | Merge (i, j) -> i + j )
        in
        let result_opt, t' =
          update ~data ~completed_jobs:new_merges t' |> Or_error.ok_exn
        in
        let expected_result, remaining_expected_results =
          Option.value_map result_opt ~default:(0, expected_results)
            ~f:(fun _ ->
              match List.rev expected_results with
              | [] ->
                  (0, [])
              | x :: xs ->
                  (x, List.rev xs) )
        in
        assert (
          Option.value ~default:expected_result result_opt = expected_result ) ;
        (remaining_expected_results, t') )
  in
  ()

let%test_unit "Ramdom base jobs" =
  let max_base_jobs = 8 in
  let t : (int, int) t = empty ~max_base_jobs ~delay:2 in
  let state = ref t in
  Quickcheck.test
    (Quickcheck.Generator.list (Int.gen_incl 1 1))
    ~f:(fun list ->
      let t' = !state in
      let data = List.take list max_base_jobs in
      let work =
        List.take
          (work_for_next_update t' ~data_count:(List.length data))
          (List.length data * 2)
      in
      let new_merges =
        List.map work ~f:(fun job ->
            match job with Base i -> i | Merge (i, j) -> i + j )
      in
      let result_opt, t' =
        update ~data ~completed_jobs:new_merges t' |> Or_error.ok_exn
      in
      let expected_result = max_base_jobs in
      assert (
        Option.value ~default:expected_result result_opt = expected_result ) ;
      state := t' )
