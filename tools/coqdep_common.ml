(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Format
open Unix
open Coqdep_lexer
(* The whole Minisys module used to be required due to bootstrapping,
   thanks to dune it is not needed anymore and we could just remove it. *)
open Minisys

(** [coqdep_boot] is a stripped-down version of [coqdep], whose
    behavior is the one of [coqdep -boot]. Its only dependencies
    are [Coqdep_lexer], [Unix] and [Minisys], and it should stay so.
    If it need someday some additional information, pass it via
    options (see for instance [option_dynlink] below).
*)

let coqdep_warning args =
  eprintf "*** Warning: @[";
  kfprintf (fun fmt -> fprintf fmt "@]\n%!") err_formatter args

module StrSet = Set.Make(String)

module StrList = struct type t = string list let compare = compare end
module StrListMap = Map.Make(StrList)

type dynlink = Opt | Byte | Both | No | Variable

let option_noglob = ref false
let option_dynlink = ref Both
let option_boot = ref false

let norec_dirs = ref StrSet.empty

type dir = string option

(** [get_extension f l] checks whether [f] has one of the extensions
    listed in [l]. It returns [f] without its extension, alongside with
    the extension. When no extension match, [(f,"")] is returned *)

let rec get_extension f = function
  | [] -> (f, "")
  | s :: _ when Filename.check_suffix f s -> (Filename.chop_suffix f s, s)
  | _ :: l -> get_extension f l

(** [basename_noext] removes both the directory part and the extension
    (if necessary) of a filename *)

let basename_noext filename =
  let fn = Filename.basename filename in
  try Filename.chop_extension fn with Invalid_argument _ -> fn

(** Coq files specifies on the command line:
    - first string is the full filename, with only its extension removed
    - second string is the absolute version of the previous (via getcwd)
*)

let vAccu   = ref ([] : (string * string) list)

(** Queue operations *)

let addQueue q v = q := v :: !q

let safe_hash_add cmp clq q (k, (v, b)) =
  try
    let (v2, _) = Hashtbl.find q k in
    if not (cmp v v2) then
      let nv =
        try v :: StrListMap.find k !clq
        with Not_found -> [v; v2]
      in
      clq := StrListMap.add k nv !clq;
      (* overwrite previous bindings, as coqc does *)
      Hashtbl.add q k (v, b)
  with Not_found -> Hashtbl.add q k (v, b)

(** Files found in the loadpaths.
    For the ML files, the string is the basename without extension.
*)

let same_path_opt s s' =
  let nf s = (* ./foo/a.ml and foo/a.ml are the same file *)
    if Filename.is_implicit s
    then "." // s
    else s
  in
  let s = match s with None -> "." | Some s -> nf s in
  let s' = match s' with None -> "." | Some s' -> nf s' in
  s = s'

let warning_ml_clash x s suff s' suff' =
  if suff = suff' && not (same_path_opt s s') then
  coqdep_warning "%s%s already found in %s (discarding %s%s)\n" x suff
    (match s with None -> "." | Some d -> d)
    ((match s' with None -> "." | Some d -> d) // x) suff

let mkknown () =
  let h = (Hashtbl.create 19 : (string, dir * string) Hashtbl.t) in
  let add x s suff =
    try let s',suff' = Hashtbl.find h x in warning_ml_clash x s' suff' s suff
    with Not_found -> Hashtbl.add h x (s,suff)
  and iter f = Hashtbl.iter (fun x (s,_) -> f x s) h
  and search x =
    try Some (fst (Hashtbl.find h x))
    with Not_found -> None
  in add, iter, search

let add_mllib_known, _, search_mllib_known = mkknown ()
let add_mlpack_known, _, search_mlpack_known = mkknown ()

let vKnown = (Hashtbl.create 19 : (string list, string * bool) Hashtbl.t)
(* The associated boolean is true if this is a root path. *)
let coqlibKnown = (Hashtbl.create 19 : (string list, unit) Hashtbl.t)

let get_prefix p l =
  let rec drop_prefix_rec = function
    | (h1::tp, h2::tl) when h1 = h2 -> drop_prefix_rec (tp,tl)
    | ([], tl) -> Some tl
    | _ -> None
  in
  drop_prefix_rec (p, l)

let search_table (type r) is_root table ?from s = match from with
| None -> Hashtbl.find table s
| Some from ->
  let module M = struct exception Found of r end in
  let iter logpath binding =
    if is_root binding then match get_prefix from logpath with
    | None -> ()
    | Some rem ->
      match get_prefix (List.rev s) (List.rev rem) with
      | None -> ()
      | Some _ -> raise (M.Found binding)
  in
  try Hashtbl.iter iter table; raise Not_found
  with M.Found s -> s

let search_v_known ?from s =
  let is_root (_, root) = root in
  try
    let (phys_dir, _) = search_table is_root vKnown ?from s in
    Some phys_dir
  with Not_found -> None

let is_in_coqlib ?from s =
  let is_root _ = true in
  try search_table is_root coqlibKnown ?from s; true with Not_found -> false

let clash_v = ref (StrListMap.empty : string list StrListMap.t)

let error_cannot_parse s (i,j) =
  Printf.eprintf "File \"%s\", characters %i-%i: Syntax error\n" s i j;
  exit 1

let error_cannot_open_project_file msg =
  Printf.eprintf "%s\n" msg;
  exit 1

let error_cannot_parse_project_file file msg =
  Printf.eprintf "Project file \"%s\": Syntax error: %s\n" file msg;
  exit 1

let error_cannot_stat s unix_error =
  (* Print an arbitrary line number, such that the message matches
     common error message pattern. *)
  Printf.eprintf "File \"%s\", line 1: %s\n" s (error_message unix_error);
  exit 1

let error_cannot_open s msg =
  (* Print an arbitrary line number, such that the message matches
     common error message pattern. *)
  Printf.eprintf "File \"%s\", line 1: %s\n" s msg;
  exit 1

let warning_module_notfound from f s =
  match from with
  | None ->
      coqdep_warning "in file %s, library %s is required and has not been found in the loadpath!"
        f (String.concat "." s)
  | Some pth ->
      coqdep_warning "in file %s, library %s is required from root %s and has not been found in the loadpath!"
        f (String.concat "." s) (String.concat "." pth)

let warning_declare f s =
  coqdep_warning "in file %s, declared ML module %s has not been found!" f s

let warning_clash file dir =
  match StrListMap.find dir !clash_v with
    (f1::f2::fl) ->
      let f = Filename.basename f1 in
      let d1 = Filename.dirname f1 in
      let d2 = Filename.dirname f2 in
      let dl = List.rev_map Filename.dirname fl in
      eprintf
        "*** Warning: in file %s, \n    required library %s matches several files in path\n    (found %s.v in "
        file (String.concat "." dir) f;
      List.iter (fun s -> eprintf "%s, " s) dl;
      eprintf "%s and %s; used the latter)\n" d2 d1
  | _ -> assert false

let warning_cannot_open_dir dir =
  coqdep_warning "cannot open %s" dir

let safe_assoc from verbose file k =
  if verbose && StrListMap.mem k !clash_v then warning_clash file k;
  match search_v_known ?from k with
  | None -> raise Not_found
  | Some path -> path

let absolute_dir dir =
  let current = Sys.getcwd () in
    Sys.chdir dir;
    let dir' = Sys.getcwd () in
      Sys.chdir current;
      dir'

let absolute_file_name basename odir =
  let dir = match odir with Some dir -> dir | None -> "." in
  absolute_dir dir // basename

(** [find_dir_logpath dir] Return the logical path of directory [dir]
    if it has been given one. Raise [Not_found] otherwise. In
    particular we can check if "." has been attributed a logical path
    after processing all options and silently give the default one if
    it hasn't. We may also use this to warn if ap hysical path is met
    twice.*)
let register_dir_logpath,find_dir_logpath =
  let tbl: (string, string list) Hashtbl.t = Hashtbl.create 19 in
  let reg physdir logpath = Hashtbl.add tbl (absolute_dir physdir) logpath in
  let fnd physdir = Hashtbl.find tbl (absolute_dir physdir) in
  reg,fnd

let file_name s = function
  | None     -> s
  | Some d   -> d // s

(* Makefile's escaping rules are awful: $ is escaped by doubling and
   other special characters are escaped by backslash prefixing while
   backslashes themselves must be escaped only if part of a sequence
   followed by a special character (i.e. in case of ambiguity with a
   use of it as escaping character).  Moreover (even if not crucial)
   it is apparently not possible to directly escape ';' and leading '\t'. *)

let escape =
  let s' = Buffer.create 10 in
  fun s ->
    Buffer.clear s';
    for i = 0 to String.length s - 1 do
      let c = s.[i] in
      if c = ' ' || c = '#' || c = ':' (* separators and comments *)
        || c = '%' (* pattern *)
        || c = '?' || c = '[' || c = ']' || c = '*' (* expansion in filenames *)
        || i=0 && c = '~' && (String.length s = 1 || s.[1] = '/' ||
            'A' <= s.[1] && s.[1] <= 'Z' ||
            'a' <= s.[1] && s.[1] <= 'z') (* homedir expansion *)
      then begin
        let j = ref (i-1) in
        while !j >= 0 && s.[!j] = '\\' do
          Buffer.add_char s' '\\'; decr j (* escape all preceding '\' *)
        done;
        Buffer.add_char s' '\\';
      end;
      if c = '$' then Buffer.add_char s' '$';
      Buffer.add_char s' c
    done;
    Buffer.contents s'

let compare_file f1 f2 =
  absolute_file_name (Filename.basename f1) (Some (Filename.dirname f1))
  = absolute_file_name (Filename.basename f2) (Some (Filename.dirname f2))

let canonize f =
  let f' = absolute_dir (Filename.dirname f) // Filename.basename f in
  match List.filter (fun (_,full) -> f' = full) !vAccu with
    | (f,_) :: _ -> escape f
    | _ -> escape f

module VData = struct
  type t = string list option * string list
  let compare = compare
end

module VCache = Set.Make(VData)

(** To avoid reading .v files several times for computing dependencies,
    once for .vo, once for .vio, and once for .vos extensions, the
    following code performs a single pass and produces a structured
    list of dependencies, separating dependencies on compiled Coq files
    (those loaded by [Require]) from other dependencies, e.g. dependencies
    on ".v" files (for [Load]) or ".cmx", ".cmo", etc... (for [Declare]). *)

type dependency =
  | DepRequire of string (* one basename, to which we later append .vo or .vio or .vos *)
  | DepOther of string   (* filenames of dependencies, separated by spaces *)

let string_of_dependency_list suffix_for_require deps =
  let string_of_dep = function
    | DepRequire basename -> basename ^ suffix_for_require
    | DepOther s -> s
    in
  String.concat " " (List.map string_of_dep deps)

let rec find_dependencies basename =
  let verbose = true in (* for past/future use? *)
  try
    (* Visited marks *)
    let visited_ml = ref StrSet.empty in
    let visited_v = ref VCache.empty in
    let should_visit_v_and_mark from str =
       if not (VCache.mem (from, str) !visited_v) then begin
          visited_v := VCache.add (from, str) !visited_v;
          true
       end else false
       in
    (* Output: dependencies found *)
    let dependencies = ref [] in
    let add_dep dep =
       dependencies := dep::!dependencies in
    let add_dep_other s =
       add_dep (DepOther s) in

    (* Reading file contents *)
    let f = basename ^ ".v" in
    let chan = open_in f in
    let buf = Lexing.from_channel chan in
    try
      while true do
        let tok = coq_action buf in
        match tok with
        | Require (from, strl) ->
            List.iter (fun str ->
              if should_visit_v_and_mark from str then begin
              try
                let file_str = safe_assoc from verbose f str in
                add_dep (DepRequire (canonize file_str))
              with Not_found ->
                  if verbose && not (is_in_coqlib ?from str) then
                  warning_module_notfound from f str
              end) strl
        | Declare sl ->
            let declare suff dir s =
              let base = escape (file_name s dir) in
              match !option_dynlink with
              | No -> ()
              | Byte -> add_dep_other (sprintf "%s%s" base suff)
              | Opt -> add_dep_other (sprintf "%s.cmxs" base)
              | Both -> add_dep_other (sprintf "%s%s" base suff);
                        add_dep_other (sprintf "%s.cmxs" base)
              | Variable -> add_dep_other (sprintf "%s%s" base
                  (if suff=".cmo" then "$(DYNOBJ)" else "$(DYNLIB)"))
              in
            let decl str =
              let s = basename_noext str in
              if not (StrSet.mem s !visited_ml) then begin
                visited_ml := StrSet.add s !visited_ml;
                match search_mllib_known s with
                  | Some mldir -> declare ".cma" mldir s
                  | None ->
                    match search_mlpack_known s with
                  | Some mldir -> declare ".cmo" mldir s
                  | None -> warning_declare f str
                end
                in
              List.iter decl sl
        | Load str ->
            let str = Filename.basename str in
            if should_visit_v_and_mark None [str] then begin
              try
                let (file_str, _) = Hashtbl.find vKnown [str] in
                let canon = canonize file_str in
                add_dep_other (sprintf "%s.v" canon);
                let deps = find_dependencies canon in
                List.iter add_dep deps
              with Not_found -> ()
            end
        | AddLoadPath _ | AddRecLoadPath _ -> (* TODO: will this be handled? *) ()
      done;
      List.rev !dependencies
    with
    | Fin_fichier ->
        close_in chan;
        List.rev !dependencies
    | Syntax_error (i,j) ->
        close_in chan;
        error_cannot_parse f (i,j)
  with Sys_error msg -> error_cannot_open (basename ^ ".v") msg


let write_vos = ref false

let coq_dependencies () =
  List.iter
    (fun (name,_) ->
       let ename = escape name in
       let glob = if !option_noglob then "" else ename^".glob " in
       let deps = find_dependencies name in
       printf "%s.vo %s%s.v.beautified %s.required_vo: %s.v %s\n" ename glob ename ename ename
        (string_of_dependency_list ".vo" deps);
       printf "%s.vio: %s.v %s\n" ename ename
         (string_of_dependency_list ".vio" deps);
       if !write_vos then
         printf "%s.vos %s.vok %s.required_vos: %s.v %s\n" ename ename ename ename
           (string_of_dependency_list ".vos" deps);
       printf "%!")
    (List.rev !vAccu)

let rec suffixes = function
  | [] -> assert false
  | [name] -> [[name]]
  | dir::suffix as l -> l::suffixes suffix

let add_caml_known phys_dir _ f =
  let basename,suff =
    get_extension f [".mllib"; ".mlpack"] in
  match suff with
    | ".mllib" -> add_mllib_known basename (Some phys_dir) suff
    | ".mlpack" -> add_mlpack_known basename (Some phys_dir) suff
    | _ -> ()

let add_coqlib_known recur phys_dir log_dir f =
  match get_extension f [".vo"; ".vio"; ".vos"] with
    | (basename, (".vo" | ".vio" | ".vos")) ->
        let name = log_dir@[basename] in
        let paths = if recur then suffixes name else [name] in
        List.iter (fun f -> Hashtbl.add coqlibKnown f ()) paths
    | _ -> ()

let add_known recur phys_dir log_dir f =
  match get_extension f [".v"; ".vo"; ".vio"; ".vos"] with
    | (basename,".v") ->
        let name = log_dir@[basename] in
        let file = phys_dir//basename in
        let () = safe_hash_add compare_file clash_v vKnown (name, (file, true)) in
        if recur then
          let paths = List.tl (suffixes name) in
          let iter n = safe_hash_add compare_file clash_v vKnown (n, (file, false)) in
          List.iter iter paths
    | (basename, (".vo" | ".vio" | ".vos")) when not(!option_boot) ->
        let name = log_dir@[basename] in
        let paths = if recur then suffixes name else [name] in
        List.iter (fun f -> Hashtbl.add coqlibKnown f ()) paths
    | _ -> ()

(* Visits all the directories under [dir], including [dir] *)

let is_not_seen_directory phys_f =
  not (StrSet.mem phys_f !norec_dirs)

let rec add_directory recur add_file phys_dir log_dir =
  if exists_dir phys_dir then
    begin
      register_dir_logpath phys_dir log_dir;
      let f = function
        | FileDir (phys_f,f) ->
            if is_not_seen_directory phys_f && recur then
              add_directory true add_file phys_f (log_dir @ [f])
        | FileRegular f ->
            add_file phys_dir log_dir f
      in
      process_directory f phys_dir
    end
  else
    warning_cannot_open_dir phys_dir

(** Simply add this directory and imports it, no subdirs. This is used
    by the implicit adding of the current path (which is not recursive). *)
let add_norec_dir_import add_file phys_dir log_dir =
  try add_directory false (add_file true) phys_dir log_dir with Unix_error _ -> ()

(** -Q semantic: go in subdirs but only full logical paths are known. *)
let add_rec_dir_no_import add_file phys_dir log_dir =
  try add_directory true (add_file false) phys_dir log_dir with Unix_error _ -> ()

(** -R semantic: go in subdirs and suffixes of logical paths are known. *)
let add_rec_dir_import add_file phys_dir log_dir =
  add_directory true (add_file true) phys_dir log_dir

(** -I semantic: do not go in subdirs. *)
let add_caml_dir phys_dir =
  add_directory false add_caml_known phys_dir []

let rec treat_file old_dirname old_name =
  let name = Filename.basename old_name
  and new_dirname = Filename.dirname old_name in
  let dirname =
    match (old_dirname,new_dirname) with
      | (d, ".") -> d
      | (None,d) -> Some d
      | (Some d1,d2) -> Some (d1//d2)
  in
  let complete_name = file_name name dirname in
  let stat_res =
    try stat complete_name
    with Unix_error(error, _, _) -> error_cannot_stat complete_name error
  in
  match stat_res.st_kind
  with
    | S_DIR ->
        (if name.[0] <> '.' then
           let newdirname =
             match dirname with
               | None -> name
               | Some d -> d//name
           in
           Array.iter (treat_file (Some newdirname)) (Sys.readdir complete_name))
    | S_REG ->
      (match get_extension name [".v"] with
       | base,".v" ->
         let name = file_name base dirname
         and absname = absolute_file_name base dirname in
         addQueue vAccu (name, absname)
       | _ -> ())
    | _ -> ()

(* "[sort]" outputs `.v` files required by others *)
let sort () =
  let seen = Hashtbl.create 97 in
  let rec loop file =
    let file = canonize file in
    if not (Hashtbl.mem seen file) then begin
      Hashtbl.add seen file ();
      let cin = open_in (file ^ ".v") in
      let lb = Lexing.from_channel cin in
      try
        while true do
          match coq_action lb with
            | Require (from, sl) ->
                List.iter
                  (fun s ->
                    match search_v_known ?from s with
                    | None -> ()
                    | Some f -> loop f)
                sl
            | _ -> ()
        done
      with Fin_fichier ->
        close_in cin;
        printf "%s.v " file
    end
  in
  List.iter (fun (name,_) -> loop name) !vAccu

let usage () =
  eprintf " usage: coqdep [options] <filename>+\n";
  eprintf " options:\n";
  eprintf "  -boot : For coq developers, prints dependencies over coq library files (omitted by default).\n";
  eprintf "  -sort : output the given file name ordered by dependencies\n";
  eprintf "  -noglob | -no-glob : \n";
  eprintf "  -noinit : currently no effect\n";
  eprintf "  -f file : read -I, -Q, -R and filenames from _CoqProject-formatted FILE.\n";
  eprintf "  -I dir : add (non recursively) dir to ocaml path\n";
  eprintf "  -R dir logname : add and import dir recursively to coq load path under logical name logname\n";
  eprintf "  -Q dir logname : add (recursively) and open (non recursively) dir to coq load path under logical name logname\n";
  eprintf "  -vos : also output dependencies about .vos files\n";
  eprintf "  -exclude-dir dir : skip subdirectories named 'dir' during -R/-Q search\n";
  eprintf "  -coqlib dir : set the coq standard library directory\n";
  eprintf "  -dyndep (opt|byte|both|no|var) : set how dependencies over ML modules are printed\n";
  exit 1

let option_sort = ref false

let split_period = Str.split (Str.regexp (Str.quote "."))

let add_q_include path l = add_rec_dir_no_import add_known path (split_period l)
let add_r_include path l = add_rec_dir_import add_known path (split_period l)

let treat_coqproject f =
  let open CoqProject_file in
  let iter_sourced f = List.iter (fun {thing} -> f thing) in
  let warning_fn x = coqdep_warning "%s" x in
  let project =
    try read_project_file ~warning_fn f
    with
    | Parsing_error msg -> error_cannot_parse_project_file f msg
    | UnableToOpenProjectFile msg -> error_cannot_open_project_file msg
  in
  iter_sourced (fun { path } -> add_caml_dir path) project.ml_includes;
  iter_sourced (fun ({ path }, l) -> add_q_include path l) project.q_includes;
  iter_sourced (fun ({ path }, l) -> add_r_include path l) project.r_includes;
  iter_sourced (fun f -> treat_file None f) (all_files project)

let rec parse = function
  | "-boot" :: ll -> option_boot := true; parse ll
  | "-sort" :: ll -> option_sort := true; parse ll
  | "-vos" :: ll -> write_vos := true; parse ll
  | ("-noglob" | "-no-glob") :: ll -> option_noglob := true; parse ll
  | "-noinit" :: ll -> (* do nothing *) parse ll
  | "-f" :: f :: ll -> treat_coqproject f; parse ll
  | "-I" :: r :: ll -> add_caml_dir r; parse ll
  | "-I" :: [] -> usage ()
  | "-R" :: r :: ln :: ll -> add_r_include r ln; parse ll
  | "-Q" :: r :: ln :: ll -> add_q_include r ln; parse ll
  | "-R" :: ([] | [_]) -> usage ()
  | "-exclude-dir" :: r :: ll -> System.exclude_directory r; parse ll
  | "-exclude-dir" :: [] -> usage ()
  | "-coqlib" :: r :: ll -> Envars.set_user_coqlib r; parse ll
  | "-coqlib" :: [] -> usage ()
  | "-dyndep" :: "no" :: ll -> option_dynlink := No; parse ll
  | "-dyndep" :: "opt" :: ll -> option_dynlink := Opt; parse ll
  | "-dyndep" :: "byte" :: ll -> option_dynlink := Byte; parse ll
  | "-dyndep" :: "both" :: ll -> option_dynlink := Both; parse ll
  | "-dyndep" :: "var" :: ll -> option_dynlink := Variable; parse ll
  | ("-h"|"--help"|"-help") :: _ -> usage ()
  | opt :: ll when String.length opt > 0 && opt.[0] = '-' ->
    coqdep_warning "unknown option %s" opt;
    parse ll
  | f :: ll -> treat_file None f; parse ll
  | [] -> ()

let init () =
  if Array.length Sys.argv < 2 then usage ();
  if not Coq_config.has_natdynlink then option_dynlink := No;
  parse (List.tl (Array.to_list Sys.argv))
