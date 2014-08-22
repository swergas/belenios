(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2014 Inria                                           *)
(*                                                                        *)
(*  This program is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Affero General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version, with the additional   *)
(*  exemption that compiling, linking, and/or using OpenSSL is allowed.   *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Affero General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Affero General Public      *)
(*  License along with this program.  If not, see                         *)
(*  <http://www.gnu.org/licenses/>.                                       *)
(**************************************************************************)

open Serializable_builtin_t
open Serializable_t
open Signatures
open Common
open Web_serializable_t

module type AUTH_SERVICES = sig

  val auth_realm : string

  val get_auth_systems : unit -> string list
  val get_user : unit -> user option Lwt.t

end

module type AUTH_LINKS = sig

  val login :
    string option ->
    (unit, unit,
     [> `Attached of
          ([> `Internal of [> `Service ] ], [> `Get ])
          Eliom_service.a_s ],
     [ `WithoutSuffix ], unit, unit,
     [< Eliom_service.registrable > `Unregistrable ],
     [> Eliom_service.http_service ])
    Eliom_service.service

  val logout :
    (unit, unit,
     [> `Attached of
          ([> `Internal of [> `Service ] ], [> `Get ])
          Eliom_service.a_s ],
     [ `WithoutSuffix ], unit, unit,
     [< Eliom_service.registrable > `Unregistrable ],
     [> Eliom_service.http_service ])
    Eliom_service.service

end

type content =
    Eliom_registration.browser_content Eliom_registration.kind Lwt.t

module type ELECTION_HANDLERS =
  sig
    val login : string option -> unit -> content
    val logout : unit -> unit -> content
    val home : unit -> unit -> content
    val admin : user option -> bool -> unit -> unit -> content
    val election_dir : user option -> Web_common.election_file -> unit -> content
    val election_update_credential : user option -> unit -> unit -> content
    val election_update_credential_post : user option -> unit -> string * string -> content
    val election_vote : unit -> unit -> content
    val election_cast : unit -> unit -> content
    val election_cast_post :
      unit -> string option * Eliom_lib.file_info option -> content
    val election_cast_confirm : unit -> unit -> content
  end

module type AUTH_HANDLERS_RAW =
  sig
    val login : string option -> unit -> content
    val logout : unit -> unit -> content
  end

type service_handler = unit ->
  Eliom_registration.browser_content Eliom_registration.kind Lwt.t

type 'a service_cont = ('a -> service_handler) -> service_handler

module type AUTH_HANDLERS = sig
  val login : string service_cont
  val logout : unit service_cont
end

module type AUTH_HANDLERS_PUBLIC = sig
  val do_login : string option -> unit service_cont
  val do_logout : unit service_cont
end

module type WEB_BALLOT_BOX = sig
  module Ballots : MONADIC_MAP_RO
    with type 'a m = 'a Lwt.t
    and type elt = string
    and type key = string
  module Records : MONADIC_MAP_RO
    with type 'a m = 'a Lwt.t
    and type elt = datetime * string
    and type key = string

  val cast : string -> string * datetime -> string Lwt.t
  val inject_cred : string -> unit Lwt.t
  val update_files : unit -> unit Lwt.t
  val update_cred : old:string -> new_:string -> unit Lwt.t
end

module type ELECTION_TEMPLATES = sig

  val home :
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val admin :
    is_featured:bool ->
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val update_credential :
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val cast_raw :
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val cast_confirmation :
    can_vote:bool ->
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val cast_confirmed :
    result:[< `Error of Web_common.error | `Valid of string ] ->
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

end

module type WEB_PARAMS = sig
  val metadata : metadata
  val dir : string
end

module type WEB_ELECTION_ = sig
  include ELECTION_DATA
  include WEB_PARAMS
  module E : ELECTION with type elt = G.t
  module S : AUTH_SERVICES
  module B : WEB_BALLOT_BOX
  module H : AUTH_HANDLERS_PUBLIC
end

module type WEB_ELECTION = sig
  include WEB_ELECTION_
  module Z : ELECTION_HANDLERS
end

type election_files = {
  f_election : string;
  f_metadata : string;
  f_public_keys : string;
  f_public_creds : string;
}

module type REGISTRABLE_ELECTION = sig
  val discard : unit -> unit
  val register : unit -> (module WEB_ELECTION) Lwt.t
end

module type LOGIN_TEMPLATES = sig

  val dummy :
    service:(unit, 'a, [< Eliom_service.post_service_kind ],
             [< Eliom_service.suff ], 'b,
             [< string Eliom_parameter.setoneradio ]
             Eliom_parameter.param_name,
             [< Eliom_service.registrable ],
             [< Eliom_service.non_ocaml_service ])
            Eliom_service.service ->
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val password :
    service:(unit, 'a, [< Eliom_service.post_service_kind ],
             [< Eliom_service.suff ], 'b,
             [< string Eliom_parameter.setoneradio ]
             Eliom_parameter.param_name *
             [< string Eliom_parameter.setoneradio ]
             Eliom_parameter.param_name,
             [< Eliom_service.registrable ],
             [< Eliom_service.non_ocaml_service ])
            Eliom_service.service ->
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val upload_password_db :
    service:(unit, 'a, [< Eliom_service.post_service_kind ],
             [< Eliom_service.suff ], 'b,
             [< Eliom_lib.file_info Eliom_parameter.setoneradio ]
             Eliom_parameter.param_name,
             [< Eliom_service.registrable ],
             [< Eliom_service.non_ocaml_service ])
            Eliom_service.service ->
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

  val choose :
    unit -> [> `Html ] Eliom_content.Html5.F.elt Lwt.t

end

module type NAME = sig
  val name : string
  val path : string list
  val kind : [ `Site | `Election of string ]
end

module type AUTH_SERVICE =
  functor (N : NAME) ->
  functor (T : LOGIN_TEMPLATES) ->
  AUTH_HANDLERS

module type AUTH_SYSTEM = sig
  type config

  val name : string

  val parse_config :
    instance:string ->
    attributes:(string * string) list ->
    config

  val make : config -> (module AUTH_SERVICE)
end
