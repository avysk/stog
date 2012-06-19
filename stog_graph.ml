(*********************************************************************************)
(*                Stog                                                           *)
(*                                                                               *)
(*    Copyright (C) 2012 Maxence Guesdon. All rights reserved.                   *)
(*                                                                               *)
(*    This program is free software; you can redistribute it and/or modify       *)
(*    it under the terms of the GNU General Public License as                    *)
(*    published by the Free Software Foundation, version 3 of the License.       *)
(*                                                                               *)
(*    This program is distributed in the hope that it will be useful,            *)
(*    but WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the               *)
(*    GNU Library General Public License for more details.                       *)
(*                                                                               *)
(*    You should have received a copy of the GNU General Public                  *)
(*    License along with this program; if not, write to the Free Software        *)
(*    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA                   *)
(*    02111-1307  USA                                                            *)
(*                                                                               *)
(*    As a special exception, you have permission to link this program           *)
(*    with the OCaml compiler and distribute executables, as long as you         *)
(*    follow the requirements of the GNU GPL in regard to all of the             *)
(*    software in the executable aside from the OCaml compiler.                  *)
(*                                                                               *)
(*    Contact: Maxence.Guesdon@inria.fr                                          *)
(*                                                                               *)
(*********************************************************************************)

(** Structure de graphe creux. *)

module type GMap = sig
    type key
    type 'a t
    val create : unit -> 'a t
    val get : 'a t -> key -> 'a
    val set : 'a t -> key -> 'a -> 'a t
    val remove : 'a t -> key -> 'a t
    val fold : (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b
    val iter : (key -> 'a -> unit) -> 'a t -> unit
  end

module type S =
  sig
    type t
    type key
    type edge_data
    val create : unit -> t
    val marshal : t -> string
    val unmarshal : string -> t
    val succ : t -> key -> (key * edge_data) list
    val pred : t -> key -> (key * edge_data) list
    val add : t -> key * key * edge_data -> t
    val rem : t -> key * key -> (edge_data -> bool) -> t
    val rem_all : t -> key * key -> t
    val isolate : t -> key -> t
    val remove_node : t -> key -> t
    val pred_roots : ?ignore_deps: edge_data list -> t -> key list
    val succ_roots : t -> key list
    val recursive_succs : t -> ?pred: (edge_data -> bool) -> key -> key list
    val recursive_preds : t -> ?pred: (edge_data -> bool) -> key -> key list
    val reverse : t -> t
    val fold_succ : t -> (key -> (key * edge_data) list -> 'a -> 'a) -> 'a -> 'a
    val fold_pred : t -> (key -> (key * edge_data) list -> 'a -> 'a) -> 'a -> 'a
    val iter_succ : t -> (key -> (key * edge_data) list -> unit) -> unit
    val iter_pred : t -> (key -> (key * edge_data) list -> unit) -> unit
    val dot_of_graph :
      ?f_edge:(edge_data -> string * (string * string) list) ->
      f_node:(key -> string * string * (string * string) list) ->
      t -> string
    val nodes_by_pred_order : t -> key list
    val shortest_path :
      t ->
      (t -> key * key -> (float * edge_data) option) ->
      key * key -> (key * edge_data * key) list
end
;;

(**
Notre module {!Graph} permet la construction et la manipulation de graphes creux,
avec la possibilit� d'annoter chaque arc reliant deux sommets par un
type donn� par le module le param�tre [Edge].
*)
module Make (M: GMap) (Edge: Map.OrderedType) = struct
(** Pour repr�senter un graphe, nous utilisons deux "maps", l'un pour
   avoir rapidement les successeurs d'un sommet, l'autre pour avoir rapidement
   ses pr�d�cesseurs.

   La structure de ces "maps" est d�finie par le module en param�tre.

   A chaque indice des deux maps, nous avons donc respectivement
   la liste des sucesseurs et des pr�d�cesseurs du sommet correspondant � cet
   indice.

   Les listes des successeurs et pr�d�cesseurs sont des listes de paires
   [(identifiant du sommet, donn�e d'annotation)]. Quand on ajoute un arc [i -> j],
   il est en fait ajout� une fois dans la liste des successeurs de [i] et une
   fois dans la liste des pr�d�cesseurs de [j]. Les donn�es d'annotation sont donc
   en double. Il faut donc veiller � ce qu'elles ne soient pas trop grosses et
   pr�f�rer au besoin l'utilisation d'un identifiant dans une autre structure.

   Le module [Edge] permet d'indiquer le type des annotations.
   Ainsi, on peut comparer les donn�es qui annotent les arcs, pour pouvoir supprimer
   par exemple un arc entre deux sommets et correspondant � une annotation, sans
   supprimer un autre arc entre ces deux m�mes sommets mais ayant une autre annotation.
   *)

    type key = M.key
    type edge_data = Edge.t

    type t = {
        succ : (M.key * edge_data) list M.t; (** successors of a node *)
        pred : (M.key * edge_data) list M.t; (** predecessors of a node *)
      };;

    let create () =
      {
        succ = M.create () ;
        pred = M.create () ;
      };;

    let marshal t = Marshal.to_string t.succ []
    let unmarshal s =
      let succ = Marshal.from_string s 0 in
      let add_one dst map (src, data) =
        try
          let l = M.get map src in
          M.set map src ((dst, data)::l)
        with Not_found -> M.set map src [dst, data]
      in
      let add_list key succs map =
        List.fold_left (add_one key) map succs
      in
      let pred =
        M.fold add_list
        succ
        (M.create ())
      in
      { succ = succ ;
        pred = pred ;
      }

(** Les acc�s aux successeurs et pr�d�cesseurs se font � l'aide des fonctions suivantes,
   et sont obtenus sous la forme de liste de paires
   [(identifiant du successeur/pr�d�cesseur, donn�e d'annotation de l'arc)].
   *)
    let succ g key = try M.get g.succ key with Not_found -> [];;
    let pred g key = try M.get g.pred key with Not_found -> [];;

(** L'ajout dans un graphe se fait en utilisant la fonction {!add} et en pr�cisant
   le graphe et un triplet [(sommet source, sommet destination, donn�e d'annotation)].

   Si le m�me arc est ajout� deux fois avec la m�me annotation, le deuxi�me
   ajout est ignor� (utilisation de la fonction de comparaison pour le d�terminer).
*)
    let add g (i,j,data) =
      (* make sure that i appears in pred and j in succ *)
      let new_succ =
        try ignore(M.get g.succ j); g.succ
        with Not_found -> M.set g.succ j []
      in
      let new_pred =
        try ignore(M.get g.pred i); g.pred
        with Not_found -> M.set g.pred i []
      in
      let g = { succ = new_succ; pred = new_pred } in
      let succ =
        let succs = succ g i in
        if not (List.exists (fun (k,d) -> k = j && Edge.compare d data = 0) succs) then
          M.set g.succ i ((j, data) :: succs)
        else
          g.succ
      in
      let pred =
        let preds = pred g j in
        if not (List.exists (fun (k,d) -> k = i && Edge.compare d data = 0) preds) then
          M.set g.pred j ((i, data) :: preds)
        else
          g.pred
      in
      { succ = succ ; pred = pred }


(** Pour supprimer un arc parmi d'autres entre deux sommets [i] et [j], on utilise la
   fonction {!rem} avec une fonction de pr�dicat prenant en param�tre une annotation
   et qui renvoie [true] si l'arc en question doit �tre supprim�.
   *)
    let rem g (i,j) predic =
      let succ = M.set g.succ i (List.filter (fun (k,d) -> k <> j or not (predic d)) (succ g i)) in
      let pred = M.set g.pred j (List.filter (fun (k,d) -> k <> i or not (predic d)) (pred g j)) in
      { succ = succ ; pred = pred };;

(** Il est �galement possible de supprimer tous les arcs entre deux sommets [i] et [j],
   avec la fonction {!rem_all}. Cela revient � utiliser {!rem} avec un pr�dicat
   retournant toujours [true]. *)
    let rem_all g (i,j) = rem g (i,j) (fun _ -> true);;

(** Isole le sommet indiqu� en supprimant tous les arcs qui l'ont pour source ou pour
   destination. *)
    let isolate g i =
      let g = List.fold_right (fun (j,_) g -> rem_all g (i,j)) (succ g i) g in
      List.fold_right (fun (j,_) g -> rem_all g (j,i)) (pred g i) g;;

   let remove_node g i =
     let g = isolate g i in
     let new_succ = M.remove g.succ i in
     let new_pred = M.remove g.pred i in
      { succ = new_succ; pred = new_pred }

(** Il est possible d'obtenir les "racines" du graphe, soit en tant que pr�d�cesseurs
   (ce sont les sommets n'ayant pas de pr�c�desseurs et pr�c�dant donc tous les autres
   sommets), soit en tant que successeurs (ce sont les sommets qui n'ont pas de
   successeurs), respectivement avec les fonctions {!pred_roots} et {!succ_roots}.
   @param le param�tre ignore depends permet d'indiquer des types d'arcs � ignorer
   pour le calcul.
   *)
    let pred_roots ?(ignore_deps=[]) g =
      match ignore_deps with
        [] ->
          M.fold (fun key l acc -> match l with [] -> key :: acc | _ -> acc) g.pred []
      | deps ->
          let pred_edge (_,dep) = not (List.mem dep deps) in
          let pred edges = not (List.exists pred_edge edges) in
          M.fold (fun key l acc -> if pred l then key :: acc else acc) g.pred []


    let succ_roots g =
      M.fold (fun key l acc -> match l with [] -> key :: acc | _ -> acc) g.succ [];;

(** La fonction {!reverse} permet de changer le sens des arcs, les successeurs devenant
   pr�d�cesseurs et r�ciproquement. Attention, les donn�es d'annotation restent inchang�es. *)
    let reverse g = { pred = g.succ; succ = g.pred };;

   let fold_succ g f = M.fold f g.succ;;
   let fold_pred g f = M.fold f g.pred;;


(** Deux fonctions de convenance existent pour appliquer une fonction � chaque sommet et
   respectivement tous ses successeurs ou tous ses pr�d�cesseurs:
   {!iter_succ} et {!iter_pred}. *)
    let iter_succ g f = M.iter f g.succ;;
    let iter_pred g f = M.iter f g.pred;;

(** Il est possible d'imprimer le graphe au format {{:http://www.graphviz.org}Graphviz},
   en utilisant la fonction {!dot_of_graph}.
   @param f_edge permet d'indiquer quelle cha�ne de caract�res utiliser comme label
   pour une annotation d'arc.
   @param f_node permet d'indiquer quelle cha�ne de caract�res utiliser comme label
   pour un sommet.
   *)
    let dot_of_graph
      ?(f_edge: (Edge.t -> string * (string * string) list) option)
        ~(f_node: (M.key -> string * string * (string * string) list))
        (graph : t) =
      let b = Buffer.create 512 in
      let atts_of_node =
        fun x ->
          let (_, label, atts) = f_node x in
          ("label", label) :: atts
      in
      let atts_of_edge =
        match f_edge with
          None -> (fun _ -> [])
        | Some f ->
            fun x ->
              let (label, atts) = f x in
              ("label", label) :: atts
      in
      Buffer.add_string b
        ("digraph G {ratio=auto;\n"^
         "margin=\"0.1,0.1\";\n");
      let string_of_att (s1,s2) = Printf.sprintf "%s=\"%s\"" s1 s2 in
      let string_of_atts = function
        [] -> ""
      | atts -> Printf.sprintf "[%s]"
          (String.concat "," (List.map string_of_att atts))
      in
      let module S =
        Set.Make (struct type t = M.key let compare = Pervasives.compare end)
      in
      let printed = ref S.empty in
      let print_if_not_yet node_id =
        if not (S.mem node_id !printed) then
          begin
            let (nid,_,_) = f_node node_id in
            Printf.bprintf b "%s %s;\n"
              nid (string_of_atts (atts_of_node node_id));
            printed := S.add node_id !printed
          end
      in
      let f node_id succs =
        print_if_not_yet node_id;
        let (nid,_,_) = f_node node_id in
        List.iter
          (fun (id,data) ->
             print_if_not_yet id;
             let (id,_,_) = f_node id in
             let atts = atts_of_edge data in
             Printf.bprintf b "%s -> %s %s;\n"
               nid id
               (string_of_atts atts);
          )
          succs
      in
      iter_succ graph f;
      Buffer.add_string b "}\n";
      Buffer.contents b
;;

(** La fonction {!nodes_by_pred_order} permet de retourner une liste des sommets
   dans leur ordre (partiel) de pr�c�dence. *)
    let nodes_by_pred_order g =
      let rec iter g acc =
        match pred_roots g with
          [] -> List.rev acc
        | i :: _ -> iter (remove_node g i) (i::acc)
      in
      iter g [];;

    let recursive_next get_next =
      let module S =
      Set.Make (struct type t = M.key let compare = Pervasives.compare end)
      in
      let filter pred l = List.filter (fun (_,edge) -> pred edge) l in
      let rec iter g ?(pred=(fun _ -> true)) acc id =
        let next = get_next g id in
        let _next = filter pred next in
        List.fold_left
          (fun acc (next_id, _) ->
           if S.mem next_id acc then
             acc
           else
             iter g ~pred (S.add next_id acc) next_id)
        acc
        next
      in
      fun g ?pred id ->
        S.elements (iter g ?pred S.empty id)

    let recursive_succs = recursive_next succ
    let recursive_preds = recursive_next pred


(** La fonction {!shortest_path} calcule le plus court chemin entre deux sommets
   [s] et [d], d'apr�s une fonction de co�t en param�tre.
   La fonction de co�t doit retourner une valeur strictement positive ainsi
   que l'annotation de l'arc utilis� pour avoir cette valeur (il est possible
   d'avoir des co�ts diff�rents entre deux sommets s'il y a plusieurs arcs entre
   ces deux sommets). La fonction de co�t retourne [None] s'il n'est pas possible
   d'aller d'un sommet donn� � un autre (les deux sommets ne sont pas connect�s).

   L'algorithme utilis� est celui de
   {{:http://tide4javascript.com/?s=Dijkstra}Djikstra}.
   *)
    let shortest_path g cost (s,d) =
      let p = M.fold
        (fun i _ p ->
           M.set p i (if i = s then 0.0 else infinity))
          g.succ
          (M.create())
      in
      let v_done = M.fold
        (fun i _ acc -> M.set acc i false) g.succ (M.create())
      in
      let v_pred = M.fold
        (fun i _ acc -> M.set acc i None) g.succ (M.create())
      in
      let (_,_,v_pred) = M.fold
        (fun v _ (p, v_done, v_pred) ->
          match pred g v with
             [] ->
               (* do not take this vertice into account any more *)
               (p, v_done, v_pred)
           | _ ->
               let (_mindist, closest) =
                 M.fold
                   (fun i _ (mindist, closest) ->
                      if (not (M.get v_done i)) && M.get p i < mindist then
                        (M.get p i, Some i)
                      else
                        (mindist, closest)
                   )
                   g.succ
                   (infinity, None)
               in
               match closest with
                 None -> (p, v_done, v_pred)
                   (* FIXME ? this means accepting isolated vertices
                      insteaf of
                      raise Not_found*)
               | Some closest ->
                   let v_done = M.set v_done closest true in
                   let (p, v_pred) = M.fold
                     (fun i _ (p, v_pred) ->
                        if not (M.get v_done i) then
                          match cost g (closest, i) with
                          | None -> (p, v_pred)
                          | Some (w, edge_data) ->
                              if (M.get p closest) +. w < M.get p i then
                                (M.set p i (M.get p closest +. w),
                                 M.set v_pred i (Some (closest, edge_data))
                                )
                              else
                                (p, v_pred)
                        else
                          (p, v_pred)
                     )
                       g.succ (p, v_pred)
                   in
                   (p, v_done, v_pred)
        )
        g.succ
        (p, v_done, v_pred)
      in

      let rec build_path acc v =
        match M.get v_pred v with
          None ->  acc
        | Some (v2,edge_data) -> build_path ((v2,edge_data,v) :: acc) v2
      in
      let path = build_path [] d in
      match path with
        [] -> raise Not_found
      | _ ->
(*          let s_path = String.concat " -> " (List.map (fun (_,_,j) -> string_of_int j) path) in
          prerr_endline (Printf.sprintf "shortest path %d -> %d = %d -> %s" s d s s_path);
          *)
          path
  end

module Make_with_map (P:Map.OrderedType) (Edge:Map.OrderedType) =
  Make
    (struct
       module M = Map.Make (P)
       type key = M.key
       type 'a t = 'a M.t
       let create () = M.empty
       let get t k = M.find k t
       let set t k v = M.add k v t
       let remove t k = M.remove k t
       let fold = M.fold
       let iter = M.iter
     end)
     (Edge)
;;