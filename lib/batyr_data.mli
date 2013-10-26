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

open Batyr_xmpp

module Node : sig
  type t
  val create : domain_name: string -> ?node_name: string -> unit -> t
  val domain_name : t -> string
  val node_name : t -> string
  val of_jid : JID.t -> t
  val jid : t -> JID.t
  val to_string : t -> string
  val of_string : string -> t
  val cached_id : t -> int
  val of_id : int -> t Lwt.t
  val id : t -> int Lwt.t
end

module Resource : sig
  type t
  val create : domain_name: string -> ?node_name: string ->
	       ?resource_name: string -> unit -> t
  val domain_name : t -> string
  val node_name : t -> string
  val resource_name : t -> string
  val node : t -> Node.t
  val of_jid : JID.t -> t
  val jid : t -> JID.t
  val to_string : t -> string
  val of_string : string -> t
  val of_id : int -> t Lwt.t
  val id : t -> int Lwt.t
end

module Muc_user : sig
  type t
  val make : nick: string -> ?jid: JID.t -> role: Chat_muc.role ->
	     affiliation: Chat_muc.affiliation -> unit -> t
  val nick : t -> string
  val jid : t -> JID.t option
  val role : t -> Chat_muc.role
  val affiliation : t -> Chat_muc.affiliation
  val to_string : t -> string
end

module Muc_room : sig
  type t
  val of_node : Node.t -> t Lwt.t
  val node : t -> Node.t
  val alias : t -> string option
  val description : t -> string option
  val min_message_time : t -> float option
  val users_by_nick : t -> (string, Muc_user.t) Hashtbl.t
end
