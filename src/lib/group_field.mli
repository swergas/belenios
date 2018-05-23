(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2018 Inria                                           *)
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

(** Finite field arithmetic *)

open Platform
open Serializable_t

module type GROUP = Signatures.GROUP
  with type t = Z.t
  and type group = ff_params
(** Multiplicative subgroup of a finite field. *)

val check_params : ff_params -> bool
(** Check consistency of finite field parameters. *)

val make : ff_params -> (module GROUP)
(** [finite_field params] builds the multiplicative subgroup of
    F[params.p], generated by [params.g], of order [params.q].  It
    checks the consistency of the parameters. *)
