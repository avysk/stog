(*********************************************************************************)
(*                Stog                                                           *)
(*                                                                               *)
(*    Copyright (C) 2012-2015 INRIA All rights reserved.                         *)
(*    Author: Maxence Guesdon, INRIA Saclay                                      *)
(*                                                                               *)
(*    This program is free software; you can redistribute it and/or modify       *)
(*    it under the terms of the GNU General Public License as                    *)
(*    published by the Free Software Foundation, version 3 of the License.       *)
(*                                                                               *)
(*    This program is distributed in the hope that it will be useful,            *)
(*    but WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the               *)
(*    GNU General Public License for more details.                               *)
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

(** *)

module S = Cohttp_lwt_unix.Server
open Stog_url
open Stog_types
open Stog_server_types
open Stog_server_run

let (>>=) = Lwt.bind

let client_js = "stog_server_client.js";;

let default_css = "stog-server-style.css" ;;

let respond_css body =
  let headers = Cohttp.Header.init_with "Content-Type" "text/css" in
  S.respond_string ~headers ~status: `OK ~body ()

let respond_js body =
  let headers = Cohttp.Header.init_with "Content-Type" "text/javscript" in
  S.respond_string ~headers ~status: `OK ~body ()

let respond_server_client_js = respond_js Stog_server_files.server_client_js
let respond_default_css = respond_css Stog_server_files.server_style_css

let rec preview_file stog = function
| [file] when file = client_js -> respond_server_client_js
| path ->
    let rec iter tree = function
      [] -> S.respond_file ~fname: "" ()
    | [f] ->
        if Stog_types.Str_set.mem f tree.files then
          let fname = Filename.concat stog.stog_dir (String.concat Filename.dir_sep path) in
          S.respond_file ~fname ()
        else
          (
           (* maybe this was a generated file in stog output directory *)
           let fname = Filename.concat stog.stog_outdir (String.concat Filename.dir_sep path) in
           prerr_endline ("fname="^fname);
           S.respond_file ~fname ()
          )
    | d :: q ->
        match
          try Some (Stog_types.Str_map.find d tree.dirs)
          with Not_found ->
           None
        with
          Some tree -> iter tree q
        | None ->
            (* maybe this was a generated file in stog output directory *)
             let fname = Filename.concat stog.stog_outdir (String.concat Filename.dir_sep path) in
             prerr_endline ("fname="^fname);
             S.respond_file ~fname ()
    in
    iter stog.stog_files path

let handle_preview ~http_url ~ws_url current_state req path =
  match !current_state with
    None -> Lwt.fail (Failure "No state yet!")
  | Some state ->
      match
        let s_path = "/" ^ (String.concat "/" path) in
        let path = Stog_path.of_string s_path in
        try Some(Stog_types.doc_by_path state.stog path)
        with _  ->
            try Some(Stog_types.doc_by_path state.stog (Stog_path.of_string (s_path^"/index.html")))
            with _ -> None
      with
        Some (doc_id, doc) ->
          let body =
            match doc.doc_out with
              None ->
                String.concat "\n"
                  [ "Document not computed yet";
                    String.concat "\n" state.stog_errors ;
                    String.concat "\n" state.stog_warnings ;
                  ]
            | Some xmls ->
                let doc_path = Stog_path.to_string doc.doc_path in
                let title = Printf.sprintf "Loading preview of %s" doc_path in
                let script_url = Stog_url.append http_url.pub [client_js] in
                let http_root_url =
                  let path =
                    match List.rev (Stog_url.path http_url.pub) with
                      _ :: q -> List.rev q
                    | [] -> []
                  in
                  let url = Stog_url.with_path http_url.pub path in
                  Stog_url.to_string url
                in
                "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><header>
                  <meta charset=\"utf-8\"/>
                  <meta http-equiv=\"Content-Type\" content=\"application/xhtml+xml; charset=utf-8\"/>
                  <title>"^title^"</title>"^
                "<script type=\"text/javascript\">
                  stog_server = {
                    wsUrl: '"^(Stog_url.to_string ws_url.pub)^"',
                    doc: '"^doc_path^"', httpUrl: '"^http_root_url^"' };
                </script>"^
                "<script src=\""^(Stog_url.to_string script_url)^"\"
                         type=\"text/javascript\"> </script>"^
                "</header><body><h1>"^title^"</h1></body></html>"
          in
          let headers = Cohttp.Header.init_with "Content-Type" "application/xhtml+xml; charset=utf-8" in
          S.respond_string ~headers ~status:`OK ~body ()
      | None -> preview_file state.stog path

let new_stog_session stog stog_base_url =
  let active_cons = ref [] in
  let current_state = ref None in
  let stog =
    (* if modifying another field, update also Stog_server_run.refresh *)
    { stog with Stog_types.stog_base_url }
  in
  let on_update = Stog_server_ws.send_patch active_cons in
  let on_error = Stog_server_ws.send_errors active_cons in
  let _watcher = Stog_server_run.watch stog current_state ~on_update ~on_error in
  (current_state, active_cons)
