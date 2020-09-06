(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2020 Inria                                           *)
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

let lang = "it"


let mail_credential_subject : ('a, 'b, 'c, 'd, 'e, 'f) format6 =
  "Il suo codice di voto per l'elezione %s"

let mail_credential : ('a, 'b, 'c, 'd, 'e, 'f) format6 =
  "Lei è registrato(a) in quanto elettore(trice) per l'elezione

  %s

%s

Codice di voto : %s
Pagina dell'elezione : %s

Si nota che lei può votare più volte. Ma soltanto l'ultimo voto è
preso in considerazione.%s"

let mail_credential_password =
"Si prega di trovare qui sotto il suo codice di voto.  Per presentare
una scheda elettorale, avrà bisogno di una password, spedita in una
email separata. Faccia attenzione, la password e il codice di voto
sono simili ma hanno un ruolo diverso. Il sistema le domanderà il suo
codice di voto non appena entrato(a) nella cabina elettorale
virtuale. Il nome di utente e la password sono necessari quando la sua
scheda è pronta per essere presentata."

let mail_credential_cas =
"Si prega di trovare qui sotto il suo codice di voto."

let mail_confirmation_subject : ('a, 'b, 'c, 'd, 'e, 'f) format6 =
  "La sua scheda per l'elezione %s"

let mail_confirmation : ('a, 'b, 'c, 'd, 'e, 'f) format6 =
  "%s,

La sua scheda per l'elezione

  %s

è stata registrata. Il suo codice di verifica è

  %s%s


Può verificare la sua presenza nell'urna, accessibile su
  %s

I risultati saranno pubblicati sulla pagina dell'elezione
  %s%s

-- \nBelenios"

let this_vote_replaces = "\n\nThis vote replaces any previous vote."
let please_contact = "To get more information, please contact:"
