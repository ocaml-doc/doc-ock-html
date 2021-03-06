(*
 * Copyright (c) 2016 Thomas Refis <trefis@janestreet.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open StdLabels
open Tyxml.Html

type kind = [ `Arg | `Mod | `Mty | `Class | `Cty | `Page ]

type t = {
  name : string;
  content : [ `Html ] elt;
  children : t list
}

let path = Stack.create ()

let stack_to_list s =
  let acc = ref [] in
  Stack.iter (fun x -> acc := x :: !acc) s;
  !acc

let enter ?kind name = Stack.push (name, kind) path
let leave () = ignore @@ Stack.pop path

(* FIXME: reuse [Url.kind] *)
let stack_elt_to_path_fragment = function
  | (name, None)
  | (name, Some `Page) -> name (* fixme? *)
  | (name, Some `Mod) -> name
  | (name, Some `Mty) -> "module-type-" ^ name
  | (name, Some `Arg) -> "argument-" ^ name
  | (name, Some `Class) -> "class-" ^ name
  | (name, Some `Cty) -> "class-type-" ^ name

module Relative_link = struct
  open DocOck.Paths

  let semantic_uris = ref false

  module Id : sig
    exception Not_linkable
    exception Can't_stop_before

    val href : get_package:('a -> string) -> stop_before:bool ->
      ('a, _) Identifier.t -> string
  end = struct
    exception Not_linkable

    let rec drop_shared_prefix l1 l2 =
      match l1, l2 with
      | l1 :: l1s, l2 :: l2s when l1 = l2 ->
        drop_shared_prefix l1s l2s
      | _, _ -> l1, l2

    exception Can't_stop_before

    let href ~get_package ~stop_before id =
      match Url.from_identifier ~get_package ~stop_before id with
      | Ok { Url. page; anchor; kind } ->
        let target =
          List.rev (
            if !semantic_uris || kind = "page" then
              page
            else
              "index.html" :: page
          )
        in
        let current_loc =
          let path =
            match Stack.top path with
            | (_, Some `Page) ->
              (* Sadness. *)
              let s = Stack.copy path in
              ignore (Stack.pop s);
              s
            | _ -> path
          in
          List.map ~f:stack_elt_to_path_fragment (stack_to_list path)
        in
        let current_from_common_ancestor, target_from_common_ancestor =
          drop_shared_prefix current_loc target
        in
        let relative_target =
          List.map current_from_common_ancestor ~f:(fun _ -> "..")
          @ target_from_common_ancestor
        in
        let page = String.concat ~sep:"/" relative_target in
        begin match anchor with
        | "" -> page
        | anchor -> page ^ "#" ^ anchor
        end
      | Error e ->
        (* TODO: handle errors better, perhaps by returning a [result] *)
        match e with
        | Not_linkable _ -> raise Not_linkable
        | otherwise ->
          Printf.eprintf "%s\n%!" (Url.Error.to_string otherwise);
          exit 1
  end

  module Of_path = struct
    let rec to_html : type a. get_package:('b -> string) -> stop_before:bool ->
      ('b, a) Path.t -> _ =
      fun ~get_package ~stop_before path ->
        let open Path in
        match path with
        | Root root -> [ pcdata root ]
        | Forward root -> [ pcdata root ] (* FIXME *)
        | Dot (prefix, suffix) ->
          let link = to_html ~get_package ~stop_before:true prefix in
          link @ [ pcdata ("." ^ suffix) ]
        | Apply (p1, p2) ->
          let link1 = to_html ~get_package ~stop_before p1 in
          let link2 = to_html ~get_package ~stop_before p2 in
          link1 @ pcdata "(":: link2 @ [ pcdata ")" ]
        | Resolved rp ->
          let id = Path.Resolved.identifier rp in
          let txt = Url.render_path path in
          begin match Id.href ~get_package ~stop_before id with
          | href -> [ a ~a:[ a_href href ] [ pcdata txt ] ]
          | exception Id.Not_linkable -> [ pcdata txt ]
          | exception exn ->
            Printf.eprintf "Id.href failed: %S\n%!" (Printexc.to_string exn);
            [ pcdata txt ]
          end
  end

  module Of_fragment = struct
    let dot prefix suffix =
      match prefix with
      | "" -> suffix
      | _  -> prefix ^ "." ^ suffix

    let rec render_raw : type a. (_, a, _) Fragment.raw -> string =
      fun fragment ->
        let open Fragment in
        match fragment with
        | Resolved rr -> render_resolved rr
        | Dot (prefix, suffix) -> dot (render_raw prefix) suffix

    and render_resolved : type a. (_, a, _) Fragment.Resolved.raw -> string =
      fun fragment ->
        let open Fragment.Resolved in
        match fragment with
        | Root -> ""
        | Subst (_, rr) -> render_resolved (any_sort rr)
        | SubstAlias (_, rr) -> render_resolved (any_sort rr)
        | Module (rr, s) -> dot (render_resolved rr) s
        | Type (rr, s) -> dot (render_resolved rr) s
        | Class (rr, s) -> dot (render_resolved rr) s
        | ClassType (rr, s) -> dot (render_resolved rr) s

    let rec to_html : type a. get_package:('b -> string) -> stop_before:bool ->
      _ Identifier.signature -> ('b, a, _) Fragment.raw -> _ =
      fun ~get_package ~stop_before id fragment ->
        let open Fragment in
        match fragment with
        | Resolved Resolved.Root ->
          begin match Id.href ~get_package ~stop_before:true id with
          | href ->
            [ a ~a:[ a_href href ] [ pcdata (Identifier.name id) ] ]
          | exception Id.Not_linkable -> [ pcdata (Identifier.name id) ]
          | exception exn ->
            Printf.eprintf "[FRAG] Id.href failed: %S\n%!" (Printexc.to_string exn);
            [ pcdata (Identifier.name id) ]
          end
        | Resolved rr ->
          let id = Resolved.identifier id (Obj.magic rr : (_, a) Resolved.t) in
          let txt = render_resolved rr in
          begin match Id.href ~get_package ~stop_before id with
          | href ->
            [ a ~a:[ a_href href ] [ pcdata txt ] ]
          | exception Id.Not_linkable -> [ pcdata txt ]
          | exception exn ->
            Printf.eprintf "[FRAG] Id.href failed: %S\n%!" (Printexc.to_string exn);
            [ pcdata txt ]
          end
        | Dot (prefix, suffix) ->
          let link = to_html ~get_package ~stop_before:true id prefix in
          link @ [ pcdata ("." ^ suffix) ]
  end

  let of_path ~get_package ~stop_before p =
    Of_path.to_html ~get_package ~stop_before p

  let of_fragment ~get_package ~base frag =
    Of_fragment.to_html ~get_package ~stop_before:false base frag

  let to_sub_element ~kind name =
    (* FIXME: Reuse [Url]. *)
    let prefix =
      match kind with
      | `Mod   -> ""
      | `Mty   -> "module-type-"
      | `Arg   -> "argument-"
      | `Class -> "class-"
      | `Cty   -> "class-type-"
      | `Page  -> assert false
    in
    a_href (prefix ^ name ^ (if !semantic_uris then "" else "/index.html"))
end

let render_fragment = Relative_link.Of_fragment.render_raw

class page_creator ?kind ~path content =
  let rec add_dotdot ~n acc =
    if n = 0 then
      acc
    else
      add_dotdot ~n:(n - 1) ("../" ^ acc)
  in
  object(self)
    val has_parent = List.length path > 1

    method name = List.hd @@ List.rev path

    method title_string =
      Printf.sprintf "%s (%s)" self#name (String.concat ~sep:"." path)

    method css_url =
        let n =
          List.length path - (
            (* This is just horrible. *)
            match kind with
            | Some `Page -> 1
            | _ -> 0
          )
        in
      add_dotdot "odoc.css" ~n

    method header : Html_types.head elt =
      head (title (pcdata self#title_string)) [
        link ~rel:[`Stylesheet] ~href:self#css_url () ;
        meta ~a:[ a_charset "utf-8" ] () ;
        meta ~a:[ a_name "viewport";
                  a_content "width=device-width,initial-scale=1.0"; ] ();
        meta ~a:[ a_name "generator";
                  a_content "doc-ock-html v1.0.0-1-g1fc9bf0" ] ();
      ]

    method heading : Html_types.flow5_without_header_footer elt list =
      match kind with
      | Some `Page -> []
      | _ -> [
          h1 (
            Markup.keyword (
              match kind with
              | None
              | Some `Mod -> "Module"
              | Some `Arg -> "Parameter"
              | Some `Mty -> "Module type"
              | Some `Cty -> "Class type"
              | Some `Class -> "Class"
              | Some `Page  -> assert false
            ) :: pcdata " " ::
            [Markup.module_path (List.tl path)]
          )
        ]

    method content : Html_types.div_content_fun elt list =
      let up_href =
        if !Relative_link.semantic_uris then ".." else "../index.html"
      in
      let pkg_href =
        let n =
          List.length path - (
            (* This is just horrible. *)
            match kind with
            | Some `Page -> 2
            | _ -> 1
          )
        in
        add_dotdot ~n (if !Relative_link.semantic_uris then "" else "index.html")
      in
      let article = header self#heading :: content in
      if not has_parent then
        article
      else
        nav ~a:[ a_id "top" ]
          [ a ~a:[ a_href up_href ] [ pcdata "Up" ]
          ; pcdata " "; entity "mdash"; pcdata " "
          ; span ~a:[ a_class ["package"]]
              [ pcdata "package ";
                a ~a:[ a_href pkg_href] [ pcdata (List.hd path) ]]
          ]
        :: article

    method html : [ `Html ] elt =
      html self#header (body self#content)
  end

let page_creator_maker = ref (new page_creator)

let set_page_creator f = page_creator_maker := f

let make (content, children) =
  assert (not (Stack.is_empty path));
  let name    = stack_elt_to_path_fragment (Stack.top path) in
  let kind    = snd (Stack.top path) in
  let path    = List.map ~f:fst (stack_to_list path) in
  let creator = !page_creator_maker content ?kind ~path in
  let content = creator#html in
  { name; content; children }

let traverse ~f t =
  let rec aux parents node =
    f ~parents node.name node.content;
    List.iter node.children ~f:(aux (node.name :: parents))
  in
  aux [] t

let open_details = ref true
