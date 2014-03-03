(* Copyright (C) 2013  Petter Urkedal <paurkedal@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)

{shared{
  open Batyrweb_prereq
  open Eliom_content
  open Eliom_pervasives
  open Unprime
  open Unprime_option
}}

(* Accounts *)

{shared{
  module Account_shared = struct
    type t = {
      account_jid : string;
      server_port : int;
      client_password : string;
      is_active : bool;
    } deriving (Json)

    let compare acA acB = compare acA.account_jid acB.account_jid
  end
}}
{client{
  module Account = struct
    include Account_shared

    type edit_dom = {
      ed_jid : Dom_html.inputElement Js.t;
      ed_password : Dom_html.inputElement Js.t;
      ed_server_port : Dom_html.inputElement Js.t;
      ed_is_active : Dom_html.inputElement Js.t;
    }

    let render_headers () =
      let open Html5.D in
      [ th [pcdata "JID"]; th [pcdata "Password"];
	th [pcdata "Server Port"]; th [pcdata "Active"] ]

    let render_row ac =
      let open Html5.D in
      [ td [pcdata ac.account_jid]; td [pcdata ac.client_password];
	td [pcdata (string_of_int ac.server_port)];
	td [pcdata (string_of_bool ac.is_active)] ]

    let render_edit_row ac_opt =
      let open Html5.D in
      let jid_input = input ~input_type:`Text () in
      let password_input = input ~input_type:`Text () in
      let server_port_input = input ~input_type:`Text () in
      let is_active_input = input ~input_type:`Checkbox () in
      let edit_dom = {
	ed_jid = Html5.To_dom.of_input jid_input;
	ed_password = Html5.To_dom.of_input password_input;
	ed_server_port = Html5.To_dom.of_input server_port_input;
	ed_is_active = Html5.To_dom.of_input is_active_input;
      } in
      let tds =
	[ td [jid_input];
	  td [password_input];
	  td [server_port_input];
	  td [is_active_input] ] in
      (edit_dom, tds)

    let decode_row _ ed =
      { account_jid = Js.to_string ed.ed_jid##value;
	client_password = Js.to_string ed.ed_password##value;
	server_port = int_of_string (Js.to_string ed.ed_server_port##value);
	is_active = Js.to_bool ed.ed_is_active##checked; }
  end
}}
{server{
  open Batyr_data

  module Account = struct
    include Account_shared

    let which_type = "account"

    let fetch_all () =
      lwt entries =
	Batyr_db.use begin fun dbh ->
	  dbh#query_list
	    Batyr_db.Decode.(int ** string ** int ** bool)
	    "SELECT resource_id, client_password, server_port, is_active \
	     FROM batyr.accounts"
	  end in
      let account_of_entry
	    (resource_id, (client_password, (server_port, is_active))) =
	lwt resource = Resource.stored_of_id resource_id in
	let account_jid = Resource.to_string resource in
	Lwt.return {account_jid; client_password; server_port; is_active} in
      Lwt_list.map_p account_of_entry entries

    let add account =
      lwt resource = Lwt.wrap1 Resource.of_string account.account_jid in
      lwt resource_id = Resource.store resource in
      let account = {account with account_jid = Resource.to_string resource} in
      Batyr_db.use begin fun dbh ->
	dbh#command
	  ~params:[|
	    string_of_int resource_id;
	    string_of_int account.server_port;
	    account.client_password;
	    string_of_bool account.is_active;
	  |]
	  "INSERT INTO batyr.accounts \
	    (resource_id, server_port, client_password, is_active) \
	   VALUES ($1, $2, $3, $4)"
      end

    let remove account =
      lwt resource = Lwt.wrap1 Resource.of_string account.account_jid in
      lwt resource_id =
	match_lwt Resource.stored_id resource with
	| None -> Lwt.fail Eliom_common.Eliom_404
	| Some id -> Lwt.return id in
      Batyr_db.use begin fun dbh ->
	dbh#command
	  ~params:[|string_of_int resource_id|]
	  "DELETE FROM batyr.accounts WHERE resource_id = $1" >|= konst ()
      end
  end
}}
{shared{ module Accounts_editor = Bwl_table_editor.Make (Account) }}

(* Chatrooms *)

{shared{
  type 'a item_update = Item_added of 'a | Item_removed of 'a deriving (Json)

  module Chatroom_shared = struct

    type t = {
      room_jid : string;
      room_alias : string option;
      room_description : string option;
      transcribe : bool;
    } deriving (Json)

    let compare r0 r1 = compare r0.room_jid r1.room_jid
  end

}}
{server{
  open Batyr_data
  open Batyr_prereq
  open Batyr_xmpp
  open Batyrweb_server
  open Printf

  module type COLL_SHARED = sig
    type t deriving (Json)
  end

  module type COLL_SERVER = sig
    type t
    val which_type : string
    val fetch_all : unit -> t list Lwt.t
    val add : t -> unit Lwt.t
    val remove : t -> unit Lwt.t
  end

  module Server_functions (H : COLL_SHARED)
			  (S : COLL_SERVER with type t := H.t) = struct

    let update_stream, emit = Lwt_stream.create ()
    let update_comet : H.t item_update Eliom_comet.Channel.t =
      Eliom_comet.Channel.create ~scope:Eliom_common.site_scope update_stream

    let fetch_all = server_function Json.t<unit>
      begin fun () ->
	try_lwt S.fetch_all () >|= fun entries -> Ok entries
	with xc ->
	  let msg = sprintf "Failed to fetch %s list." S.which_type in
	  Lwt_log.error msg >> Lwt.return (Failed msg)
      end

    let add = server_function Json.t<H.t>
      begin fun entry ->
	try_lwt
	  S.add entry >|= fun () -> emit (Some (Item_added entry)); Ok ()
	with xc ->
	  let msg = sprintf "Failed to add %s." S.which_type in
	  Lwt_log.error msg >> Lwt.return (Failed msg)
      end

    let remove = server_function Json.t<H.t>
      begin fun entry ->
	try_lwt
	  S.remove entry >|= fun () -> emit (Some (Item_removed entry)); Ok ()
	with xc ->
	  let msg = sprintf "Failed to remove %s." S.which_type in
	  Lwt_log.error msg >> Lwt.return (Failed msg)
      end

  end

  module Chatroom = struct
    open Chatroom_shared

    let which_type = "chat room"

    let fetch_all () =
      lwt entries =
	Batyr_db.use begin fun dbh ->
	  dbh#query_list
	    Batyr_db.Decode.(int ** option string ** option string ** bool)
	    "SELECT node_id, room_alias, room_description, transcribe \
	     FROM batyr.muc_rooms"
	  end in
      let chatroom_of_entry
	    (node_id, (room_alias, (room_description, transcribe))) =
	lwt node = Node.stored_of_id node_id in
	let room_jid = Node.to_string node in
	Lwt.return {room_jid; room_alias; room_description; transcribe} in
      Lwt_list.map_p chatroom_of_entry entries

    let add room =
      lwt node = Lwt.wrap1 Node.of_string room.room_jid in
      lwt node_id = Node.store node in
      let room = {room with room_jid = Node.to_string node} in
      Batyr_db.use begin fun dbh ->
	dbh#query_single Batyr_db.Decode.bool
	  ~params:[|
	    string_of_int node_id;
	    Batyr_db.or_null room.room_alias;
	    Batyr_db.or_null room.room_description;
	    string_of_bool room.transcribe;
	  |]
	  "SELECT batyr.update_muc_room($1, $2, $3, $4)" >|= konst ()
      end

    let remove room =
      lwt node = Lwt.wrap1 Node.of_string room.room_jid in
      lwt node_id =
	match_lwt Node.stored_id node with
	| None -> Lwt.fail Eliom_common.Eliom_404
	| Some id -> Lwt.return id in
      Batyr_db.use begin fun dbh ->
	dbh#command
	  ~params:[|string_of_int node_id|]
	  "DELETE FROM batyr.muc_rooms WHERE node_id = $1" >|= konst ()
      end
  end

  module Chatroom_sf = Server_functions (Chatroom_shared) (Chatroom)

}}

{client{
  open Batyrweb_client

  let input_value_opt inp =
    match String.trim (Js.to_string inp##value) with
    | "" -> None
    | s -> Some s

  module Chatroom = struct
    include Chatroom_shared

    let render_row r =
      let remove_handler ev =
	Lwt.async (fun () -> %Chatroom_sf.remove r) in
      let remove_button =
	Html5.D.(button ~a:[a_onclick remove_handler] ~button_type:`Button
			[pcdata "delete"]) in
      Html5.D.([
	td [pcdata r.room_jid];
	td [pcdata (Option.get_or "-" r.room_alias)];
	td [pcdata (Option.get_or "-" r.room_description)];
	td [pcdata (string_of_bool r.transcribe)];
	td [remove_button];
      ])
  end

  module Chatrooms_live = Live_table (Chatroom)
}}


module Admin_app = Eliom_registration.App
  (struct let application_name = "web-batyrweb_admin" end)

let admin_handler () () =
  let error_td = Html5.D.(td ~a:[a_class ["error"]] []) in
  let jid_inp = Html5.D.(input ~input_type:`Text ()) in
  let alias_inp = Html5.D.(input ~input_type:`Text ()) in
  let description_inp = Html5.D.(input ~input_type:`Text ()) in
  let transcribe_inp = Html5.D.(input ~input_type:`Checkbox ()) in
  let add_handler =
    {{fun ev ->
      let jid_dom = Html5.To_dom.of_input %jid_inp in
      let alias_dom = Html5.To_dom.of_input %alias_inp in
      let description_dom = Html5.To_dom.of_input %description_inp in
      let transcribe_dom = Html5.To_dom.of_input %transcribe_inp in
      let error_dom = Html5.To_dom.of_td %error_td in
      Lwt.async begin fun () ->
	%Chatroom_sf.add Chatroom.({
	  room_jid = Js.to_string jid_dom##value;
	  room_alias = input_value_opt alias_dom;
	  room_description = input_value_opt description_dom;
	  transcribe = Js.to_bool transcribe_dom##checked;
	}) >|=
	function
	| Ok () -> error_dom##innerHTML <- Js.string ""
	| Failed msg -> error_dom##innerHTML <- Js.string msg
      end
    }} in
  let add_button =
    Html5.D.(button ~a:[a_onclick add_handler] ~button_type:`Button
		    [pcdata "add"]) in
  let chatrooms_table =
    Html5.D.(table ~a:[a_class ["edit"]]
      (tr [th [pcdata "JID"]; th [pcdata "Alias"]; th [pcdata "Description"];
	   th [pcdata "Transcribe"]])
      [tr [td [jid_inp]; td [alias_inp]; td [description_inp];
	   td [transcribe_inp]; td [add_button]; error_td]]
    ) in

  ignore {unit{
    let error_dom = Html5.To_dom.of_td %error_td in

    let chatrooms_live =
      Chatrooms_live.create (Html5.To_dom.of_table %chatrooms_table) in

    Lwt.ignore_result
      (%Chatroom_sf.fetch_all () >|= function
	| Ok entries -> List.iter (Chatrooms_live.add chatrooms_live) entries
	| Failed msg -> error_dom##innerHTML <- Js.string msg);

    let update = function
      | Item_added chatroom ->
	Chatrooms_live.add chatrooms_live chatroom
      | Item_removed chatroom ->
	Chatrooms_live.remove chatrooms_live chatroom in
    Lwt.async (fun () -> Lwt_stream.iter update %Chatroom_sf.update_comet)
  }};

  let accounts_table =
    Accounts_editor.create
      {Accounts_editor.clientside{Accounts_editor.clientside}}
      Accounts_editor.serverside in

  Lwt.return Html5.D.(Batyrweb_tools.D.page "Administration" [
    h2 [pcdata "Accounts"];
    accounts_table;
    h2 [pcdata "Chatrooms"];
    chatrooms_table;
  ])

let () =
  Admin_app.register ~service:admin_service admin_handler
