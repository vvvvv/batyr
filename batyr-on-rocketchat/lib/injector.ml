(* Copyright (C) 2022  Petter A. Urkedal <paurkedal@gmail.com>
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

open Lwt.Syntax
open Unprime

open Batyr_core.Prereq

module R = Rockettime

module Req = struct
  include Caqti_type.Std
  include Caqti_request.Infix
end

module type S = sig

  type resource

  val store_message :
    recipient: resource -> R.Message.t ->
    (unit, [> Caqti_error.t]) result Lwt.t

  val delete_message :
    recipient: resource -> string ->
    (unit, [> Caqti_error.t]) result Lwt.t

end

module Make (B : Batyr_core.Data_sig.S) = struct

  let infer_sender ~recipient user =
    let node = B.Resource.node recipient in
    B.Resource.create_on_node node user.R.User.username
      ~foreign_resource_id:user.R.User.uid

  let store_message =
    let q = let open Req in
      tup3 (tup2 int string) (tup4 ptime (option ptime) int (option int)) string
        -->. unit @:-
      {|INSERT INTO batyr.messages (
          recipient_id, foreign_message_id,
          seen_time, edit_time, sender_id, editor_id,
          body, message_type
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'groupchat')
        ON CONFLICT (recipient_id, foreign_message_id) DO
        UPDATE SET
          seen_time = $3, edit_time = $4, sender_id = $5, editor_id = $6,
          body = $7|}
    in
    fun ~recipient (message : R.Message.t) ->
      let* recipient_id = B.Resource.store recipient in
      let foreign_message_id = message.id in
      let seen_time = message.ts in
      let edit_time = message.edited_at in
      let* sender_id = B.Resource.store (infer_sender ~recipient message.u) in
      let* editor_id =
        Lwt_option.map_s
          (B.Resource.store % infer_sender ~recipient)
          message.edited_by
      in
      let body = message.msg in
      let param =
        (recipient_id, foreign_message_id),
        (seen_time, edit_time, sender_id, editor_id),
        body
      in
      B.Db.use (fun (module Db) -> Db.exec q param)

  let delete_message =
    let q = let open Req in
      tup2 int string -->. unit @:-
      "DELETE FROM batyr.messages \
       WHERE recipient_id = $1 AND foreign_message_id = $2"
    in
    fun ~recipient message_id ->
      let* recipient_id = B.Resource.store recipient in
      B.Db.use (fun (module Db) -> Db.exec q (recipient_id, message_id))
end