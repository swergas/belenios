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

open Lwt
open Platform
open Serializable_j
open Signatures
open Common
open Web_serializable_j
open Web_common
open Web_signatures
open Web_services

let source_file = ref "belenios.tar.gz"
let spool_dir = ref "."

let rec list_remove x = function
  | [] -> []
  | y :: ys -> if x = y then ys else y :: (list_remove x ys)

let get_single_line x =
  match_lwt Lwt_stream.get x with
  | None -> return None
  | Some _ as line ->
    lwt b = Lwt_stream.is_empty x in
    if b then (
      return line
    ) else (
      Lwt_stream.junk_while (fun _ -> true) x >>
      return None
    )

let ( / ) = Filename.concat

let delete_shallow_directory dir =
  lwt () =
    Lwt_unix.files_of_directory dir |>
    Lwt_stream.filter (fun x -> x <> "." && x <> "..") |>
    Lwt_stream.iter_s (fun x -> Lwt_unix.unlink (dir/x))
  in
  Lwt_unix.rmdir dir

  open Eliom_service
  open Eliom_registration

  module LwtRandom = MakeLwtRandom (struct let rng = make_rng () end)

  let store = Ocsipersist.open_store "site"

  (* Persistent table, used to initialize the server. *)
  let election_ptable = Ocsipersist.open_table "site_elections"

  (* Table with elections in setup mode. *)
  let election_stable = Ocsipersist.open_table "site_setup"

  (* Table with tokens given to trustees. *)
  let election_pktokens = Ocsipersist.open_table "site_pktokens"

  (* Table with tokens given to credential authorities. *)
  let election_credtokens = Ocsipersist.open_table "site_credtokens"

  (* In-memory table, indexed by UUID, contains closures. *)
  let election_table = ref SMap.empty

  lwt main_election =
    Ocsipersist.make_persistent store "main_election" None

  lwt featured =
    Ocsipersist.make_persistent store "featured_elections" []

  (* The following reference is there to cut a dependency loop:
     S.register_election depends on S (via Templates). It will be set
     to a proper value once we have called Templates.Make. *)

  let import_election_ref = ref (fun _ -> assert false)

  (* Forward reference *)
  let install_authentication_ref = ref (fun _ -> assert false)

    include Web_site_auth

    let import_election f = !import_election_ref f

    let add_featured_election x =
      lwt the_featured = Ocsipersist.get featured in
      if List.mem x the_featured then (
        return ()
      ) else if SMap.mem x !election_table then (
        Ocsipersist.set featured (x :: the_featured)
      ) else (
        Lwt.fail Not_found
      )

    let remove_featured_election x =
      lwt the_featured = Ocsipersist.get featured in
      Ocsipersist.set featured (list_remove x the_featured)

    let is_featured_election x =
      lwt the_featured = Ocsipersist.get featured in
      return (List.mem x the_featured)

    let set_main_election x =
      if SMap.mem x !election_table then (
        Ocsipersist.set main_election (Some x)
      ) else (
        Lwt.fail Not_found
      )

    let unset_main_election () =
      Ocsipersist.set main_election None

    let install_authentication xs = !install_authentication_ref xs

  module T = Web_templates

  let register_election params web_params =
    let module P = (val params : ELECTION_PARAMS) in
    let uuid = Uuidm.to_string P.params.e_uuid in
    let module D = struct
      module G = P.G
      let election = {
        e_params = P.params;
        e_pks = None;
        e_fingerprint = P.fingerprint;
      }
    end in
    let module P = (val web_params : WEB_PARAMS) in
    let module R = Web_election.Make (D) (P) in
    (module R : Web_election.REGISTRABLE), fun () ->
      (* starting from here, we do side-effects on the running server *)
      let module R = R.Register (struct end) in
      let module W = R.W in
      let module X : ELECTION_HANDLERS = R.Register (T) in
      let module W = struct
        include W
        module Z = X
      end in
      let election = (module W : WEB_ELECTION) in
      election_table := SMap.add uuid election !election_table;
      election

  (* Mutex to avoid simultaneous registrations of the same election *)
  let registration_mutex = Lwt_mutex.create ()

  let () = import_election_ref := fun f ->
    Lwt_mutex.lock registration_mutex >>
    try_lwt
      lwt raw_election =
        Lwt_io.lines_of_file f.f_election |>
        get_single_line >>=
        (function
        | Some e -> return e
        | None -> Printf.ksprintf
          failwith "election.json must contain a single line"
        )
      in
      let params = Group.election_params_of_string raw_election in
      let module P = (val params : ELECTION_PARAMS) in
      let uuid = Uuidm.to_string P.params.e_uuid in
      lwt exists =
        try_lwt
          lwt _ = Ocsipersist.find election_ptable uuid in
          return true
        with Not_found -> return false
      in
      if exists then (
        Lwt_mutex.unlock registration_mutex;
        return None
      ) else (
        let dir = !spool_dir/uuid in
        lwt metadata =
          Lwt_io.chars_of_file f.f_metadata |>
          Lwt_stream.to_string >>=
          wrap1 metadata_of_string
        in
        let module X = struct
          let metadata = metadata
          let dir = dir
          let state = ref `Open
        end in
        let web_params = (module X : WEB_PARAMS) in
        let r, do_register = register_election params web_params in
        let module R = (val r : Web_election.REGISTRABLE) in
        let module G = R.W.G in
        let module KG = Election.MakeSimpleDistKeyGen (G) (LwtRandom) in
        let public_keys = Lwt_io.lines_of_file f.f_public_keys in
        lwt pks = Lwt_stream.(
          clone public_keys |>
          map (trustee_public_key_of_string G.read) |>
          to_list >>= wrap1 Array.of_list
        ) in
        if not (Array.forall KG.check pks) then
          failwith "Public keys are invalid.";
        if not G.(R.W.election.e_params.e_public_key =~ KG.combine pks) then
          failwith "Public keys mismatch with election public key.";
        let public_creds = Lwt_io.lines_of_file f.f_public_creds in
        lwt () = Lwt_stream.(
          clone public_creds |>
          iter_s (fun x ->
            if not G.(check @@ of_string x) then (
              Lwt.fail @@ Failure "Public credentials are invalid."
            ) else return ()
          )
        ) in
        let module R = struct
          let discard () = Lwt_mutex.unlock registration_mutex
          let register () =
            if not (Lwt_mutex.is_locked registration_mutex) then
              failwith "This election can no longer be registered.";
            try_lwt
              Lwt_unix.mkdir dir 0o700 >>
              Lwt_io.(with_file Output (dir/"election.json") (fun oc ->
                write_line oc raw_election
              )) >>
              Lwt_io.(with_file Output (dir/"public_keys.jsons") (fun oc ->
                write_lines oc public_keys
              )) >>
              let election = do_register () in
              let module W = (val election : WEB_ELECTION) in
              let () =
                Ocsigen_messages.debug (fun () ->
                  Printf.sprintf "Injecting credentials for %s" uuid
                )
              in
              public_creds |>
              Lwt_stream.iter_s W.B.inject_cred >>
              W.B.update_files () >>
              Ocsipersist.add election_ptable uuid (raw_election, web_params) >>
              let () = Lwt_mutex.unlock registration_mutex in
              return election
            with e ->
              lwt () =
                try_lwt delete_shallow_directory dir
                with e ->
                  Printf.ksprintf
                    (fun s ->
                     return (Ocsigen_messages.unexpected_exception e s))
                    "error while deleting %s after failure of %s"
                    dir uuid
              in
              Lwt_mutex.unlock registration_mutex;
              Lwt.fail e
        end in
        (* until here, no side-effects on the running server *)
        return @@ Some (module R : REGISTRABLE_ELECTION)
      )
    with e ->
      Lwt_mutex.unlock registration_mutex;
      Lwt.fail e

  lwt () =
    Ocsipersist.iter_step (fun uuid (raw_election, web_params) ->
      let params = Group.election_params_of_string raw_election in
      let _, do_register = register_election params web_params in
      let election = do_register () in
      let module W = (val election : WEB_ELECTION) in
      assert (uuid = Uuidm.to_string W.election.e_params.e_uuid);
      Ocsigen_messages.debug (fun () ->
        Printf.sprintf "Initialized election %s from persistent store" uuid
      );
      return ()
    ) election_ptable

  module L = struct
    let login x = Eliom_service.preapply site_login x
    let logout = Eliom_service.preapply site_logout ()
  end

  let () = install_authentication_ref := fun auth_configs ->
    let module T = T.Login (Web_site_auth) (L) in
    let templates = (module T : LOGIN_TEMPLATES) in
    Web_site_auth.register templates auth_configs

  let () = Any.register ~service:home
    (fun () () ->
      Eliom_reference.unset cont >>
      match_lwt Ocsipersist.get main_election with
      | None ->
        lwt featured =
          Ocsipersist.get featured >>=
          Lwt_list.map_p (fun x -> return @@ SMap.find x !election_table)
        in
        T.home ~featured () >>= Html5.send
      | Some x ->
        let module W = (val SMap.find x !election_table : WEB_ELECTION) in
        Redirection.send
          (preapply election_home (W.election.e_params.e_uuid, ()))
    )

  let () = Html5.register ~service:admin
    (fun () () ->
      let cont () () = Redirection.send admin in
      Eliom_reference.set Web_services.cont cont >>
      lwt elections =
        match_lwt get_user () with
        | None -> return []
        | Some u ->
          SMap.fold (fun _ w accu ->
            let module W = (val w : WEB_ELECTION) in
            if W.metadata.e_owner = Some u then (
              w :: accu
            ) else (
              accu
            )
          ) !election_table [] |> List.rev |> return
      in
      T.admin ~elections ()
    )

  let () = File.register
    ~service:source_code
    ~content_type:"application/x-gzip"
    (fun () () -> return !source_file)

  let do_get_randomness =
    let prng = Lazy.lazy_from_fun (Lwt_preemptive.detach (fun () ->
      pseudo_rng (random_string secure_rng 16)
    )) in
    let mutex = Lwt_mutex.create () in
    fun () ->
      Lwt_mutex.with_lock mutex (fun () ->
        lwt prng = Lazy.force prng in
        return (random_string prng 32)
      )

  let () = String.register
    ~service:get_randomness
    (fun () () ->
      lwt r = do_get_randomness () in
      b64_encode_compact r |>
      (fun x -> string_of_randomness { randomness=x }) |>
      (fun x -> return (x, "application/json"))
    )

  let () = Html5.register ~service:new_election
    (fun () () ->
      match_lwt get_user () with
      | None -> forbidden ()
      | Some _ -> T.new_election ()
    )

  let () = Any.register ~service:new_election_post
    (fun () (election, (metadata, (public_keys, public_creds))) ->
      match_lwt get_user () with
      | Some u ->
        let open Ocsigen_extensions in
        let files = {
          f_election = election.tmp_filename;
          f_metadata = metadata.tmp_filename;
          f_public_keys = public_keys.tmp_filename;
          f_public_creds = public_creds.tmp_filename;
        } in
        begin try_lwt
          begin match_lwt import_election files with
          | None ->
            T.new_election_failure `Exists () >>= Html5.send
          | Some w ->
            let module W = (val w : REGISTRABLE_ELECTION) in
            lwt w = W.register () in
            let module W = (val w : WEB_ELECTION) in
            Redirection.send
              (preapply election_admin (W.election.e_params.e_uuid, ()))
          end
        with e ->
          T.new_election_failure (`Exception e) () >>= Html5.send
        end
      | None -> forbidden ()
    )

  let generate_uuid = Uuidm.v4_gen (Random.State.make_self_init ())

  let () = Html5.register ~service:election_setup_index
    (fun () () ->
     match_lwt get_user () with
     | Some u ->
        lwt uuids =
          Ocsipersist.fold_step (fun k v accu ->
            if v.se_owner = u
            then return (uuid_of_string k :: accu)
            else return accu
          ) election_stable []
        in T.election_setup_index uuids ()
     | None -> forbidden ()
    )

  let () = Redirection.register ~service:election_setup_new
    (fun () () ->
     match_lwt get_user () with
     | Some u ->
        let uuid = generate_uuid () in
        let uuid_s = Uuidm.to_string uuid in
        lwt token = generate_token () in
        let se_metadata = {
          e_voting_starts_at = None;
          e_voting_ends_at = None;
          e_readers = Some `Any;
          e_voters = Some `Any;
          e_owner = Some u;
          e_auth_config = Some [{auth_system = "dummy"; auth_instance = "demo"; auth_config = []}];
        } in
        let question = {
          q_answers = [| "Answer 1"; "Answer 2" |];
          q_min = 0;
          q_max = 1;
          q_question = "Question 1?";
        } in
        let se_questions = {
          t_description = "Description of the election.";
          t_name = "Name of the election";
          t_questions = [| question |];
          t_short_name = "short_name";
        } in
        let se = {
          se_owner = u;
          se_group = "{\"g\":\"14887492224963187634282421537186040801304008017743492304481737382571933937568724473847106029915040150784031882206090286938661464458896494215273989547889201144857352611058572236578734319505128042602372864570426550855201448111746579871811249114781674309062693442442368697449970648232621880001709535143047913661432883287150003429802392229361583608686643243349727791976247247948618930423866180410558458272606627111270040091203073580238905303994472202930783207472394578498507764703191288249547659899997131166130259700604433891232298182348403175947450284433411265966789131024573629546048637848902243503970966798589660808533\",\"p\":\"16328632084933010002384055033805457329601614771185955389739167309086214800406465799038583634953752941675645562182498120750264980492381375579367675648771293800310370964745767014243638518442553823973482995267304044326777047662957480269391322789378384619428596446446984694306187644767462460965622580087564339212631775817895958409016676398975671266179637898557687317076177218843233150695157881061257053019133078545928983562221396313169622475509818442661047018436264806901023966236718367204710755935899013750306107738002364137917426595737403871114187750804346564731250609196846638183903982387884578266136503697493474682071\",\"q\":\"61329566248342901292543872769978950870633559608669337131139375508370458778917\"}";
          se_questions;
          se_public_keys = [];
          se_metadata;
          se_public_creds = token;
        } in
        lwt () = Ocsipersist.add election_stable uuid_s se in
        lwt () = Ocsipersist.add election_credtokens token uuid_s in
        return (preapply election_setup uuid)
    | None -> forbidden ()
    )

  let () = Html5.register ~service:election_setup
    (fun uuid () ->
     match_lwt get_user () with
     | Some u ->
        let uuid_s = Uuidm.to_string uuid in
        lwt se = Ocsipersist.find election_stable uuid_s in
        if se.se_owner = u
        then T.election_setup uuid se ()
        else forbidden ()
     | None -> forbidden ()
    )

  let election_setup_mutex = Lwt_mutex.create ()

  let handle_setup f uuid x =
    match_lwt get_user () with
    | Some u ->
       let uuid_s = Uuidm.to_string uuid in
       Lwt_mutex.with_lock election_setup_mutex (fun () ->
         lwt se = Ocsipersist.find election_stable uuid_s in
         if se.se_owner = u then (
           try_lwt
             f se x u;
             Ocsipersist.add election_stable uuid_s se >>
             Redirection.send (preapply election_setup uuid)
           with e ->
             T.generic_error_page (Printexc.to_string e) () >>= Html5.send
         ) else forbidden ()
       )
    | None -> forbidden ()

  let () =
    Any.register
      ~service:election_setup_group
      (handle_setup
         (fun se x _ ->
          let _group = Group.of_string x in
          (* we keep it as a string since it contains a type *)
          se.se_group <- x))

  let () =
    Any.register
      ~service:election_setup_metadata
      (handle_setup
         (fun se x u ->
          let metadata = metadata_of_string x in
          if metadata.e_owner <> Some u then failwith "wrong owner";
          se.se_metadata <- metadata))

  let () =
    Any.register
      ~service:election_setup_questions
      (handle_setup
         (fun se x _ ->
          se.se_questions <- template_of_string x))

  let () =
    Redirection.register
      ~service:election_setup_trustee_add
      (fun uuid () ->
       match_lwt get_user () with
       | Some u ->
          let uuid_s = Uuidm.to_string uuid in
          Lwt_mutex.with_lock election_setup_mutex (fun () ->
            lwt se = Ocsipersist.find election_stable uuid_s in
            if se.se_owner = u
            then (
              lwt token = generate_token () in
              se.se_public_keys <- (token, ref "") :: se.se_public_keys;
              Ocsipersist.add election_stable uuid_s se >>
              Ocsipersist.add election_pktokens token uuid_s
            ) else forbidden ()
          ) >>
          return (preapply election_setup uuid)
       | None -> forbidden ()
      )

  let () =
    Html5.register
      ~service:election_setup_credentials
      (fun token () ->
       lwt uuid = Ocsipersist.find election_credtokens token in
       lwt se = Ocsipersist.find election_stable uuid in
       T.election_setup_credentials token uuid se ()
      )

  let () =
    File.register
      ~service:election_setup_credentials_download
      ~content_type:"text/plain"
      (fun token () ->
       lwt uuid = Ocsipersist.find election_credtokens token in
       return (!spool_dir / uuid ^ ".public_creds.txt")
      )

  let wrap_handler f =
    try_lwt f ()
    with
    | e -> T.generic_error_page (Printexc.to_string e) () >>= Html5.send

  let handle_credentials_post token creds =
    lwt uuid = Ocsipersist.find election_credtokens token in
    lwt se = Ocsipersist.find election_stable uuid in
    let module G = (val Group.of_string se.se_group : GROUP) in
    let fname = !spool_dir / uuid ^ ".public_creds.txt" in
    Lwt_mutex.with_lock
      election_setup_mutex
      (fun () ->
       Lwt_io.with_file
         ~flags:(Unix.([O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC]))
         ~perm:0o600 ~mode:Lwt_io.Output fname
         (fun oc -> Lwt_io.write_chars oc creds)
      ) >>
    lwt () =
      let i = ref 1 in
      Lwt_stream.iter
        (fun x ->
         try
           let x = G.of_string x in
           if not (G.check x) then raise Exit;
           incr i
         with _ ->
           Printf.ksprintf failwith "invalid credential at line %d" !i)
        (Lwt_io.lines_of_file fname)
    in
    Redirection.send (preapply election_setup_credentials token)

  let () =
    Any.register
      ~service:election_setup_credentials_post
      (fun token creds ->
       let s = Lwt_stream.of_string creds in
       wrap_handler (fun () -> handle_credentials_post token s))

  let () =
    Any.register
      ~service:election_setup_credentials_post_file
      (fun token creds ->
       let s = Lwt_io.chars_of_file creds.Ocsigen_extensions.tmp_filename in
       wrap_handler (fun () -> handle_credentials_post token s))

  let () =
    Html5.register
      ~service:election_setup_trustee
      (fun token () ->
       lwt uuid = Ocsipersist.find election_pktokens token in
       lwt se = Ocsipersist.find election_stable uuid in
       T.election_setup_trustee token uuid se ()
      )

  let () =
    Any.register
      ~service:election_setup_trustee_post
      (fun token public_key ->
       wrap_handler
         (fun () ->
          lwt uuid = Ocsipersist.find election_pktokens token in
          Lwt_mutex.with_lock
            election_setup_mutex
            (fun () ->
             lwt se = Ocsipersist.find election_stable uuid in
             let pkref = List.assoc token se.se_public_keys in
             let module G = (val Group.of_string se.se_group : GROUP) in
             let pk = trustee_public_key_of_string G.read public_key in
             let module KG = Election.MakeSimpleDistKeyGen (G) (LwtRandom) in
             if not (KG.check pk) then failwith "invalid public key";
             (* we keep pk as a string because of G.t *)
             pkref := public_key;
             Ocsipersist.add election_stable uuid se
            ) >> Redirection.send (preapply election_setup_trustee token)
         )
      )

  let () =
    Any.register
      ~service:election_setup_create
      (fun uuid () ->
       match_lwt get_user () with
       | None -> forbidden ()
       | Some u ->
          begin try_lwt
            let uuid_s = Uuidm.to_string uuid in
            Lwt_mutex.with_lock election_setup_mutex (fun () ->
              lwt se = Ocsipersist.find election_stable uuid_s in
              if se.se_owner <> u then forbidden () else
              let group = Group.of_string se.se_group in
              let module G = (val group : GROUP) in
              let module M = Election.MakeSimpleMonad (G) in
              (* FIXME: KG does not actually need M here *)
              let module KG = Election.MakeSimpleDistKeyGen (G) (M) in
              (* construct election data in memory *)
              let () =
                match se.se_public_keys with
                | [] -> failwith "trustee public keys are missing"
                | _ :: _ -> ()
              in
              let public_keys =
                List.map
                  (fun (_, r) ->
                   if !r = "" then failwith "some public keys are missing";
                   trustee_public_key_of_string G.read !r
                  ) se.se_public_keys
              in
              let y = KG.combine (Array.of_list public_keys) in
              let template = se.se_questions in
              let params = {
                e_description = template.t_description;
                e_name = template.t_name;
                e_public_key = G.wrap_pubkey y;
                e_questions = template.t_questions;
                e_uuid = uuid;
                e_short_name = template.t_short_name;
              } in
              let files = {
                f_election = !spool_dir / uuid_s ^ ".election.json";
                f_metadata = !spool_dir / uuid_s ^ ".metadata.json";
                f_public_keys = !spool_dir / uuid_s ^ ".public_keys.jsons";
                f_public_creds = !spool_dir / uuid_s ^ ".public_creds.txt";
              } in
              lwt _ =
                try_lwt Lwt_unix.stat files.f_public_creds
                with _ -> failwith "public credentials are missing"
              in
              (* write election files to disk *)
              let create_file fname what =
                Lwt_io.with_file
                  ~flags:(Unix.([O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC]))
                  ~perm:0o600 ~mode:Lwt_io.Output fname
                  (fun oc -> Lwt_io.write oc what >> Lwt_io.write oc "\n")
              in
              create_file files.f_election (string_of_params G.write_wrapped_pubkey params) >>
              create_file files.f_metadata (string_of_metadata se.se_metadata) >>
              Lwt_io.with_file
                ~flags:(Unix.([O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC]))
                ~perm:0o600
                ~mode:Lwt_io.Output
                files.f_public_keys
                (fun oc ->
                 Lwt_list.iter_s
                   (fun pk ->
                    Lwt_io.write oc (string_of_trustee_public_key G.write pk) >>
                    Lwt_io.write oc "\n"
                   ) public_keys
                ) >>
              (* actually create the election *)
              begin match_lwt import_election files with
              | None ->
                 T.new_election_failure `Exists () >>= Html5.send
              | Some w ->
                 let module W = (val w : REGISTRABLE_ELECTION) in
                 lwt w = W.register () in
                 let module W = (val w : WEB_ELECTION) in
                 (* clean up temporary files *)
                 Lwt_unix.unlink files.f_election >>
                 Lwt_unix.unlink files.f_metadata >>
                 Lwt_unix.unlink files.f_public_keys >>
                 Lwt_unix.unlink files.f_public_creds >>
                 (* clean up tokens *)
                 Ocsipersist.remove election_credtokens se.se_public_creds >>
                 Lwt_list.iter_s
                   (fun (token, _) ->
                    Ocsipersist.remove election_pktokens token)
                   se.se_public_keys >>
                 Ocsipersist.remove election_stable uuid_s >>
                 Redirection.send
                   (preapply election_admin (W.election.e_params.e_uuid, ()))
              end
            )
          with e ->
            T.new_election_failure (`Exception e) () >>= Html5.send
          end
      )

  let () =
    Any.register
      ~service:election_home
      (fun (uuid, ()) () ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.home () ())

  let () =
    Any.register
      ~service:election_set_featured
      (fun (uuid, ()) featured ->
       let uuid_s = Uuidm.to_string uuid in
       lwt () =
         if featured then add_featured_election uuid_s
         else remove_featured_election uuid_s
       in
       Redirection.send
         (preapply election_admin (uuid, ())))

  let () =
    Any.register
      ~service:election_admin
      (fun (uuid, ()) () ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       lwt user = get_user () in
       lwt is_featured = is_featured_election uuid_s in
       W.Z.admin user is_featured () ())

  let () =
    Any.register
      ~service:election_set_state
      (fun (uuid, ()) state ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       match_lwt get_user () with
       | Some u when W.metadata.e_owner = Some u ->
          W.state := if state then `Open else `Closed;
          Redirection.send (preapply election_admin (uuid, ()))
       | _ -> forbidden ())

  let () =
    Any.register
      ~service:election_login
      (fun ((uuid, ()), service) () ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.login service ())

  let () =
    Any.register
      ~service:election_logout
      (fun (uuid, ()) () ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.logout () ())

  let () =
    Any.register
      ~service:election_update_credential
      (fun (uuid, ()) () ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       lwt user = get_user () in
       W.Z.election_update_credential user () ())

  let () =
    Any.register
      ~service:election_update_credential_post
      (fun (uuid, ()) x ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       lwt user = get_user () in
       W.Z.election_update_credential_post user () x)

  let () =
    Any.register
      ~service:election_vote
      (fun (uuid, ()) x ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.election_vote () x)

  let () =
    Any.register
      ~service:election_cast
      (fun (uuid, ()) x ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.election_cast () x)

  let () =
    Any.register
      ~service:election_cast_post
      (fun (uuid, ()) x ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.election_cast_post () x)

  let () =
    Any.register
      ~service:election_cast_confirm
      (fun (uuid, ()) x ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       W.Z.election_cast_confirm () x)

let () =
  Any.register
    ~service:election_pretty_ballots
    (fun ((uuid, ()), start) () ->
     let uuid_s = Uuidm.to_string uuid in
     let w = SMap.find uuid_s !election_table in
     let module W = (val w : WEB_ELECTION) in
     W.Z.election_pretty_ballots start ())

let () =
  Any.register
    ~service:election_pretty_ballot
    (fun ((uuid, ()), hash) () ->
     let uuid_s = Uuidm.to_string uuid in
     let w = SMap.find uuid_s !election_table in
     let module W = (val w : WEB_ELECTION) in
     W.Z.election_pretty_ballot hash ())

  let () =
    Any.register
      ~service:election_dir
      (fun (uuid, f) x ->
       let uuid_s = Uuidm.to_string uuid in
       let w = SMap.find uuid_s !election_table in
       let module W = (val w : WEB_ELECTION) in
       lwt user = get_user () in
       W.Z.election_dir user f x)
