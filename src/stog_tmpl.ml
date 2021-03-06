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

open Stog_types;;

exception Template_file_not_found of string Xtmpl_xml.with_loc

type contents = Stog_types.stog -> Stog_types.stog * Xtmpl_rewrite.tree list

let parse = Xtmpl_rewrite.from_string ;;

let from_includes =
  let rec iter ?loc file = function
    [] -> raise (Template_file_not_found (file, loc))
  | dir :: q ->
    let f = Filename.concat dir file in
    if Sys.file_exists f then f else iter ?loc file q
  in
  fun stog ?loc file -> iter ?loc file stog.stog_tmpl_dirs
;;

let get_template_file stog doc ?loc file =
  if Filename.is_relative file then
    begin
      if Filename.is_implicit file then
        from_includes stog ?loc file
      else
        Filename.concat (Filename.dirname doc.doc_src) file
    end
  else
    file
;;

let read_template_file stog doc ?(depend=true) ?(raw=false) ?loc file =
  let file = get_template_file stog doc ?loc file in
  let stog =
    if depend then Stog_deps.add_dep stog doc (Stog_types.File file) else stog
  in
  let xmls =
    if raw then
      [Xtmpl_rewrite.cdata (Stog_misc.string_of_file file)]
    else
      (Xtmpl_rewrite.doc_from_file file).Xml.elements
  in
  (stog, xmls)
;;

let create_template stog file contents =
  match stog.stog_tmpl_dirs with
    [] -> assert false
  | dir :: _ ->
      let file = Filename.concat dir file in
      Stog_misc.safe_mkdir (Filename.dirname file) ;
      Stog_msg.warning
       (Printf.sprintf "Creating default template file %S" file);
      let header = "<!-- this template was generated by Stog -->\n" in
      Stog_misc.file_of_string ~file (header ^ Xtmpl_rewrite.to_string contents);
      file
;;

let get_template_ from_file stog ?doc contents name =
  let (stog, contents) = contents stog in
  let file =
    try from_includes stog name
    with Template_file_not_found _ ->
        create_template stog name contents
  in
  let stog =
    match doc with
      None -> stog
    | Some doc -> Stog_deps.add_dep stog doc (Stog_types.File file)
  in
  (stog, from_file file)
;;

let get_template = get_template_
  (fun file -> (Xtmpl_rewrite.doc_from_file file).Xml.elements)
let get_template_doc = get_template_ Xtmpl_rewrite.doc_from_file

let default_page_tempalte =
 parse
  "<html>
    <head>
      <title><if site-title=\"\"><dummy_/><dummy_><site-title/> : </dummy_></if><doc-title/></title>
      <meta http-equiv=\"Content-Type\" content=\"application/xhtml+xml; charset=utf-8\"/>
      <link href=\"&lt;site-url/&gt;/style.css\" rel=\"stylesheet\" type=\"text/css\"/>
    </head>
    <body>
      <div id=\"page\">
        <div id=\"header\">
          <div class=\"page-title\"><doc-title/></div>
        </div>
        <if doc-type=\"post\"><div class=\"date\"><doc-date/></div></if>
        <doc-body/>
      </div>
    </body>
  </html>"
;;

(* As default contents, use the contents of the first page.tmpl file
  found in templates directory, if any. Else use a builtin contents. *)
let page stog =
  let xml =
    try
      let file = from_includes stog "page.tmpl" in
      (Xtmpl_rewrite.doc_from_file file).Xml.elements
    with Template_file_not_found _-> default_page_tempalte

  in
  (stog, xml)

let by_keyword stog =
  let t = parse
    "<include file=\"page.tmpl\" doc-title=\"Posts for keyword '&lt;doc-title/&gt;'\"/>"
  in
  let (stog,_) = get_template stog page "page.tmpl" in
  (stog, t)
;;

let by_topic stog =
  let t = parse
    "<include file=\"page.tmpl\" doc-title=\"Posts for topic '&lt;doc-title/&gt;'\"/>"
  in
  let (stog,_) = get_template stog page "page.tmpl" in
  (stog, t)
;;

let by_month stog =
  let t = parse
    "<include file=\"page.tmpl\" doc-title=\"Posts of &lt;doc-title/&gt;\"/>"
  in
  let (stog,_) = get_template stog page "page.tmpl" in
  (stog, t)
;;

let doc_in_list stog =
  let xml = parse
  {|<div itemprop="blogPosts" itemscope="" itemtype="http://schema.org/BlogPosting" class="doc-item">
     <div class="doc-item-title">
       <link itemprop="url" href="&lt;doc-url/&gt;"/>
       <doc href="&lt;doc-path/&gt;"/>
     </div>
     <div class="date"><doc-date/></div>
     <div itemprop="headline" class="doc-intro">
       <doc-intro/>
       <a href="&lt;doc-url/&gt;"><img alt="read more" src="&lt;site-url/&gt;/next.png"/></a>
     </div>
  </div>
  |}
  in
  (stog, xml)
;;

let keyword stog = (stog, parse "<span itemprop=\"keywords\"><keyword/></span>");;
let topic stog = (stog, parse "<span itemprop=\"keywords\"><topic/></span>");;

let default_date =
  Netdate.format ~fmt: "%d %b %Y %T %z"
    (Netdate.create (Unix.time()));;

let rss stog =
  let xml = parse
    ("<rss version=\"2.0\">
       <channel>
         <title><site-title/> : <doc-title/></title>
         <link><site-url/></link>
         <description><late-cdata><site-description/></late-cdata></description>
         <managingEditor><site-email/></managingEditor>
         <pubDate>"^default_date^"</pubDate>"^
         "<lastBuildDate><date-now format=\"%d %b %Y %T %z\"/></lastBuildDate>
         <generator>Stog</generator>
         <image><url><site-url/>/logo.png</url>
           <title><site-title/></title><link><site-url/></link>
         </image>
         <doc-body/>
       </channel>
     </rss>")
  in
  (stog, xml)
;;

(* TODO: add a way to map topics and keywords to <category> nodes *)
let rss_item stog =
  let xml = parse
    "<item>
      <title><doc-title/></title>
      <link><doc-url/></link>
      <description><late-cdata><doc-intro/></late-cdata></description>
      <pubDate><doc-date format=\"%d %b %Y %T %z\"/></pubDate>
      <guid isPermaLink=\"true\"><doc-url/></guid>
    </item>"
  in
  (stog, xml)
;;
