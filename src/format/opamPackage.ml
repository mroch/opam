(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamCompat
open OpamStd.Op

let log fmt = OpamConsole.log "PACKAGE" fmt
let slog = OpamConsole.slog

module Version = struct

  type version = string

  type t = version

  let to_string x = x

  let of_string x =
    if String.length x = 0 then failwith "Package version can't be empty";
    String.iter (function
        | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' | '+' | '.' | '~' -> ()
        | c ->
          failwith
            (Printf.sprintf "Invalid character '%c' in package version %S" c x))
      x;
    x


  let compare = OpamVersionCompare.compare

  let to_json x =
    `String (to_string x)

  module O = struct
    type t = version
    let to_string = to_string
    let compare = compare
    let to_json = to_json
  end

  module Set = OpamStd.Set.Make(O)

  module Map = OpamStd.Map.Make(O)

end

module Name = struct

  type t = string

  let to_string x = x

  let of_string x =
    match
      OpamStd.String.fold_left (fun acc c ->
          if acc = Some false then acc else match c with
            | 'a'..'z' | 'A'..'Z' -> Some true
            | '0'..'9' | '-' | '_' | '+' -> acc
            | _ -> Some false)
        None x
    with
    | Some false ->
      failwith
        (Printf.sprintf "Invalid character in package name %S" x)
    | None ->
      failwith
        (Printf.sprintf "Package name %S should contain at least one letter" x)
    | Some true ->
      x

  let compare n1 n2 =
    match compare (String.lowercase_ascii n1) (String.lowercase_ascii n2) with
    | 0 -> compare n1 n2
    | i -> i

  let to_json x = `String x

  module O = struct
    type t = string
    let to_string = to_string
    let compare = compare
    let to_json = to_json
  end

  module Set = OpamStd.Set.Make(O)

  module Map = OpamStd.Map.Make(O)

end

type t = {
  name   : Name.t;
  version: Version.t;
}

let create name version = { name; version }

let name_to_string t = Name.to_string t.name
let version_to_string t = Version.to_string t.version

let name t = t.name

let version t = t.version

let sep = '.'

let of_string_opt s =
  if OpamStd.String.contains_char s ' ' ||
     OpamStd.String.contains_char s '\n' then
    None
  else match OpamStd.String.cut_at s sep with
    | None        -> None
    | Some (n, v) ->
      try Some { name = Name.of_string n; version = Version.of_string v }
      with Failure _ -> None

let of_string s = match of_string_opt s with
  | Some x -> x
  | None   -> failwith "OpamPackage.of_string"

let to_string t =
  match Version.to_string t.version with
  | "" -> Name.to_string t.name
  | _ -> Printf.sprintf "%s%c%s" (Name.to_string t.name) sep (Version.to_string t.version)

let compare nv1 nv2 =
  match Name.compare nv1.name nv2.name with
  | 0 -> Version.compare nv1.version nv2.version
  | i -> i

let hash nv = Hashtbl.hash nv

let equal nv1 nv2 =
  compare nv1 nv2 = 0

let to_json nv =
  `O [ ("name", Name.to_json (name nv));
       ("version", Version.to_json (version nv));
     ]

module O = struct
  type tmp = t
  type t = tmp
  let compare = compare
  let hash = hash
  let equal = equal
  let to_string = to_string
  let to_json = to_json
end

module Set = OpamStd.Set.Make (O)

module Map = OpamStd.Map.Make (O)

let to_map nv =
  Set.fold (fun nv map ->
      let name = name nv in
      let version = version nv in
      try Name.Map.add name
            (Version.Set.add version (Name.Map.find name map)) map
      with Not_found -> Name.Map.add name (Version.Set.singleton version) map
    ) nv Name.Map.empty

let keys map =
  Map.fold (fun nv _ set -> Set.add nv set) map Set.empty

(* $DIR/$NAME.$VERSION/ *)
let of_dirname f =
  f
  |> OpamFilename.basename_dir
  |> OpamFilename.Base.to_string
  |> of_string_opt

(* $DIR/$NAME.$VERSION/opam *)
let of_filename f =
  if OpamFilename.basename f = OpamFilename.Base.of_string "opam" then
    of_dirname (OpamFilename.dirname f)
  else if OpamFilename.check_suffix f ".opam" then
    of_string_opt OpamFilename.(Base.to_string (basename (chop_extension f)))
  else
    None

(* $NAME.$VERSION+opam.tar.gz *)
let of_archive f =
  let base = OpamFilename.basename f in
  match OpamStd.String.cut_at (OpamFilename.Base.to_string base) '+' with
  | None       -> None
  | Some (s,_) -> of_string_opt s

let list dir =
  log "list %a" (slog OpamFilename.Dir.to_string) dir;
  if OpamFilename.exists_dir dir then (
    let files = OpamFilename.rec_files dir in
    List.fold_left (fun set f ->
        match of_filename f with
        | None   -> set
        | Some p ->
          if not (Set.mem p set) then Set.add p set
          else
            let suffix = Filename.concat (to_string p) "opam" in
            let files = List.filter (OpamFilename.ends_with suffix) files in
            OpamConsole.error_and_exit "Multiple definition of package %s in %s:\n%s"
              (to_string p) (OpamFilename.Dir.to_string dir)
              (OpamStd.Format.itemize ~bullet:"" OpamFilename.to_string files);
      ) Set.empty files
  ) else
    Set.empty

let prefixes repodir =
  log "prefixes %a" (slog OpamFilename.Dir.to_string) repodir;
  if OpamFilename.exists_dir repodir then (
    let files = OpamFilename.rec_files repodir in
    List.fold_left (fun map f ->
        match of_filename f with
        | None   -> map
        | Some p ->
          let pkgdir = OpamFilename.dirname_dir (OpamFilename.dirname f) in
          let prefix =
            match OpamFilename.remove_prefix_dir repodir pkgdir with
            | "" -> None
            | p  -> Some p
          in
          Map.add p prefix map
      ) Map.empty files
  ) else
    Map.empty

let versions_of_packages nvset =
  Set.fold
    (fun nv vset -> Version.Set.add (version nv) vset)
    nvset
    Version.Set.empty

let has_name nvset n =
  Set.exists (fun nv -> name nv = n) nvset

let names_of_packages nvset =
  Set.fold
    (fun nv vset -> Name.Set.add (name nv) vset)
    nvset
    Name.Set.empty

let packages_of_name nvset n =
  if n = "" then Set.empty else
  let inf = {name = String.sub n 0 (String.length n - 1); version= ""} in
  let sup = {name = n^"\000"; version = ""} in
  let _, _, nvset = Set.split inf nvset in
  let nvset, _, _ = Set.split sup nvset in
  Set.filter (fun nv -> nv.name = n) nvset

let package_of_name nvset n =
  Set.choose (packages_of_name nvset n)

let package_of_name_opt nvset n =
  try Some (package_of_name nvset n) with Not_found -> None

let packages_of_names nvset nameset =
  Name.Set.fold
    (fun name acc ->
       Set.union acc (packages_of_name nvset name))
    nameset Set.empty

let versions_of_name packages n =
  versions_of_packages
    (packages_of_name packages n)

let filter_name_out packages name =
  Set.diff packages (packages_of_name packages name)

let max_version set name =
  let versions = versions_of_name set name in
  let version = Version.Set.max_elt versions in
  create name version

let unknown name version =
  match version with
  | None   ->
    OpamConsole.error_and_exit
      "%s is not a valid package."
      (Name.to_string name)
  | Some v ->
    OpamConsole.error_and_exit
      "The package %s has no version %s."
      (Name.to_string name)
      (Version.to_string v)

module Graph = (OpamParallel.MakeGraph (O) : OpamParallel.GRAPH with type V.t = t)
