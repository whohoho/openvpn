open State
open Rresult.R.Infix

let guard p e = if p then Ok () else Error e
let opt_guard p x e = match x with None -> Ok () | Some x -> guard (p x) e

let ready f = match f.session.state with
    Ready ip | Rekeying (ip, _) -> Some ip | _ -> None

let next_message_id state =
  { state with my_message_id = Int32.succ state.my_message_id },
  state.my_message_id

let header session transport timestamp =
  let rec acked_message_ids id =
    if transport.their_message_id = id then
      []
    else
      id :: acked_message_ids (Int32.succ id)
  in
  let ack_message_ids = acked_message_ids transport.their_last_acked_message_id in
  let remote_session = match ack_message_ids with [] -> None | _ -> Some session.their_session_id in
  let packet_id = session.my_packet_id
  and their_last_acked_message_id = transport.their_message_id
  in
  let my_packet_id = Int32.succ packet_id in
  { session with my_packet_id }, { transport with their_last_acked_message_id },
  { Packet.local_session = session.my_session_id ;
    hmac = Cstruct.create_unsafe Packet.hmac_len ;
    packet_id ; timestamp ; ack_message_ids ; remote_session }

let ptime_to_ts_exn now =
  match Ptime.(Span.to_int_s (to_span now)) with
  | None -> assert false (* this will break in 2038-01-19 *)
  | Some x -> Int32.of_int x

let compute_hmac key p hmac_key =
  let tbs = Packet.to_be_signed key p in
  Nocrypto.Hash.SHA1.hmac ~key:hmac_key tbs

let hmac_and_out key hmac_key header p =
  let hmac = compute_hmac key p hmac_key in
  let p' = Packet.with_header { header with Packet.hmac } p in
  Packet.encode (key, p')

let client config now ts rng () =
  match Config.find Tls_auth config with
  | None -> Error (`Msg "no tls auth payload in config")
  | Some (_, my_hmac, _, _) ->
    let my_hmac = Cstruct.sub my_hmac 0 Packet.hmac_len in
    let transport = init_transport in
    let my_session_id = Randomconv.int64 rng in
    let session = {
      state = Connecting ;
      my_session_id ;
      my_packet_id = 1l ;
      their_session_id = 0L ;
      their_packet_id = 1l ;
      my_hmac ;
      their_hmac = my_hmac ;
    } in
    let channel = {
      keyid = 0 ;
      channel_st = Expect_server_reset ;
      transport ;
    } in
    let state = {
      config ; linger = Cstruct.empty ; compress = false ; rng ;
      session ; channel ; lame_duck = None ;
      last_received = ts ; last_sent = ts ;
    } in
    let timestamp = ptime_to_ts_exn now in
    let session, transport, header = header session transport timestamp in
    let transport, m_id = next_message_id transport in
    let p = `Control (Packet.Hard_reset_client, (header, m_id, Cstruct.empty)) in
    let out = hmac_and_out channel.keyid my_hmac header p in
    let remote = Config.get Remote config in
    let channel = { channel with transport } in
    Ok ({ state with channel ; session }, remote, out)

let pp_tls_error ppf = function
  | `Eof -> Fmt.string ppf "EOF from other side"
  | `Alert typ -> Fmt.pf ppf "alert from other side %s" (Tls.Packet.alert_type_to_string typ)
  | `Fail f -> Fmt.pf ppf "failure from our side %s" (Tls.Engine.string_of_failure f)

let prf ?sids ~label ~secret ~client_random ~server_random len =
  (* This is the same as TLS_1_0 / TLS_1_1
     (copied from ocaml-tls/lib/handshake_crypto.ml):
     - split secret into upper and lower half
     - compute md5 hmac (with upper half) and sha1 hmac (with lower half)
       - iterate until len reached: H seed ++ H (n-1 ++ seed)
     - XOR the md5 and sha1 output
  *)
  let sids = match sids with
    | None -> Cstruct.empty
    | Some (c, s) ->
      let buf = Cstruct.create 16 in
      Cstruct.BE.set_uint64 buf 0 c;
      Cstruct.BE.set_uint64 buf 8 s;
      buf
  in
  let seed =
    Cstruct.(concat [ of_string label ; client_random ; server_random ; sids ])
  in
  let p_hash (hmac, hmac_len) key =
    let rec expand a to_go =
      let res = hmac ~key (Cstruct.append a seed) in
      if to_go > hmac_len then
        Cstruct.append res (expand (hmac ~key a) (to_go - hmac_len))
      else
        Cstruct.sub res 0 to_go
    in
    expand (hmac ~key seed) len
  in
  let halve secret =
    let size = Cstruct.len secret in
    if size mod 2 <> 0 then assert false;
    Cstruct.split secret (size / 2)
  in
  let s1, s2 = halve secret in
  let md5 = p_hash Nocrypto.Hash.MD5.(hmac, digest_size) s1
  and sha = p_hash Nocrypto.Hash.SHA1.(hmac, digest_size) s2
  in
  Nocrypto.Uncommon.Cs.xor md5 sha

let derive_keys session (key_source : State.key_source) (tls_data : Packet.tls_data) =
  let master_key =
    prf ~label:"OpenVPN master secret" ~secret:key_source.pre_master
      ~client_random:key_source.random1 ~server_random:tls_data.random1 48
  in
  let keys =
    prf ~label:"OpenVPN key expansion" ~secret:master_key
      ~client_random:key_source.random2 ~server_random:tls_data.random2
      ~sids:(session.my_session_id, session.their_session_id)
      (4 * 64)
  in
  keys

let incoming_tls tls data =
  match Tls.Engine.handle_tls tls data with
  | `Fail (f, `Response _) -> Error (`Tls (`Fail f))
  | `Ok (r, `Response out, `Data d) -> match r with
    | `Eof | `Alert _ as e ->
      Logs.err (fun m -> m "response %a, TLS payload %a"
                   Fmt.(option ~none:(unit "no") Cstruct.hexdump_pp) out
                   Fmt.(option ~none:(unit "no") Cstruct.hexdump_pp) d);
      Error (`Tls e)
    | `Ok tls' -> Ok (tls', out, d)

let maybe_kex rng config tls =
  if Tls.Engine.can_handle_appdata tls then
    let pre_master, random1, random2 = rng 48, rng 32, rng 32 in
    Config.client_generate_connect_options config >>= fun options ->
    let user_pass = Config.find Auth_user_pass config in
    let td = { Packet.pre_master ; random1 ; random2 ; options ; user_pass }
    and key_source = { State.pre_master ; random1 ; random2 }
    in
    match Tls.Engine.send_application_data tls [ Packet.encode_tls_data td ] with
    | None -> Error (`Msg "Tls.send application data failed for tls_data")
    | Some (tls', payload) ->
      let client_state = TLS_established (tls', key_source) in
      Ok (client_state, Some payload)
  else
    Ok (TLS_handshake tls, None)

let maybe_kdf config transport key = function
  | None -> Error (`Msg "TLS established, expected data, received nothing")
  | Some data ->
    Logs.debug (fun m -> m "received tls payload %a" Cstruct.hexdump_pp data);
    Packet.decode_tls_data data >>| fun tls_data ->
    let config' =
      match Config.client_merge_server_config config tls_data.options with
      | Ok config -> config
      | Error `Msg msg ->
        Logs.err (fun m -> m "server options (%S) failure: %s"
                     tls_data.options msg);
        config
    in
    (* TODO need to preserve master secret (for subsequent key updates)!? *)
    let keys = derive_keys transport key tls_data in
    Logs.info (fun m -> m "received tls data %a@.key block %a"
                  Packet.pp_tls_data tls_data Cstruct.hexdump_pp keys);
    (* TODO offsets and length depend on some configuration parameters, no? *)
    let my_key, their_key = Cstruct.sub keys 0 32, Cstruct.sub keys 128 32 in
    let keys_ctx = {
      my_key = Nocrypto.Cipher_block.AES.CBC.of_secret my_key ;
      my_hmac = Cstruct.sub keys 64 20 ;
      my_packet_id = 1l ;
      their_key = Nocrypto.Cipher_block.AES.CBC.of_secret their_key ;
      their_hmac = Cstruct.sub keys 192 20 ;
      their_packet_id = 1l ;
    } in
    (config', keys_ctx)

let push_request tls =
  let data = Cstruct.of_string "PUSH_REQUEST\x00" in
  match Tls.Engine.send_application_data tls [data] with
  | None -> Error (`Msg "Tls.send application data failed for push request")
  | Some (tls', payload) -> Ok (tls', payload)

let maybe_push_reply config = function
  | Some data ->
    if Cstruct.len data = 0 then
      Error (`Msg "push request sent: empty TLS reply")
    else
      let str = Cstruct.(to_string (sub data 0 (pred (len data)))) in
      Logs.info (fun m -> m "push request sent, received TLS payload %S" str);
      begin match Astring.String.cut ~sep:"PUSH_REPLY" str with
        | Some ("", opts) -> Config.merge_push_reply config opts
        | _ ->
          Error (`Msg (Fmt.strf "push request expected push_reply, got %S" str))
      end
  | None -> Error (`Msg "push request expected data, received no data")

let incoming_control config rng session channel now op data =
  Logs.info (fun m -> m "incoming client!!! op %a (channel %a)"
                Packet.pp_operation op pp_channel channel);
  match channel.channel_st, op with
  | Expect_server_reset, (Packet.Hard_reset_server | Packet.Soft_reset) ->
    (* for rekey, allow soft_reset as well *)
    (* we reply with ACK + TLS client hello! *)
    let tls, ch =
      let authenticator = match Config.find Ca config with
        | None ->
          Logs.warn (fun m -> m "not authenticating certificate (missing CA)");
          X509.Authenticator.null
        | Some ca ->
          Logs.info (fun m -> m "authenticating using %s"
                        (X509.common_name_to_string ca));
          X509.Authenticator.chain_of_trust ~time:now [ ca ]
      in
      Tls.(Engine.client (Config.client ~authenticator ()))
    in
    Ok (false, config, { channel with channel_st = TLS_handshake tls }, [ ch ])
  | TLS_handshake tls, Packet.Control ->
    (* we reply with ACK + maybe TLS response *)
    incoming_tls tls data >>= fun (tls', tls_response, d) ->
    Logs.debug (fun m -> m "TLS payload is %a"
                   Fmt.(option ~none:(unit "no") Cstruct.hexdump_pp) d);
    maybe_kex rng config tls' >>| fun (channel_st, data) ->
    let out = match tls_response, data with
      | None, None -> [] (* happens while handshake is in process and we're waiting for further messages from the server *)
      | None, Some data -> [ data ]
      | Some res, None -> [ res ]
      | Some res, Some data ->
        Logs.warn (fun m -> m "tls handshake response and application data");
        [ res ; data ]
    in
    false, config, { channel with channel_st }, out
  | TLS_established (tls, key), Packet.Control ->
    incoming_tls tls data >>= fun (tls', tls_response, d) ->
    maybe_kdf config session key d >>= fun (config, keys) ->
    let tls_out = match tls_response with None -> [] | Some x -> [x] in (* warn here as well? *)
    (* ok, two options:
       - initial handshake done, we need push request / reply
       - subsequent handshake, we're ready for data delivery [we already have ip and route in cfg]
    *)
    (* this may be a bit too early since tls_response...  *)
    begin match Config.(find Ifconfig config) with
      | Some _ ->
        Ok (true, config, { channel with channel_st = Established (tls', keys) }, tls_out)
      | None ->
       (* now we send a PUSH_REQUEST\0 and see what happens *)
       push_request tls' >>| fun (tls'', out) ->
       let channel_st = Push_request_sent (tls'', keys) in
       (* first send an ack for the received key data packet (this needs to be
          a separate packet from the PUSH_REQUEST for unknown reasons) *)
       (false, config, { channel with channel_st }, tls_out @ [ Cstruct.empty ; out ])
    end
  | Push_request_sent (tls, keys), Packet.Control ->
    Logs.debug (fun m -> m "in push request sent");
    incoming_tls tls data >>= fun (tls', tls_response, d) ->
    (match tls_response with
     | None -> ()
     | Some _ -> Logs.err (fun m -> m "unexpected TLS response (pr sent)"));
    maybe_push_reply config d >>| fun config' ->
    let channel_st = Established (tls', keys) in
    Logs.info (fun m -> m "channel %d is established now!!!" channel.keyid);
    true, config', { channel with channel_st }, []
  | _ -> Error (`No_transition (channel, op, data))

let expected_packet session transport data =
  (* expects monotonic packet + message id, session ids matching *)
  (* TODO track ack'ed message ids from them (only really important for UDP) *)
  (* there may be rekeying, if this is the case we setup a fresh transport
     (with new key id, msg id, etc.) and don't accept any further messages with
     the old one. we also require to set the client_state so it'll output
     packets... *)
  let hdr = Packet.header data
  and msg_id = Packet.message_id data
  in
  guard (Int32.equal session.their_packet_id hdr.Packet.packet_id)
    (`Non_monotonic_packet_id (transport, hdr)) >>= fun () ->
  guard (Int64.equal session.their_session_id 0L ||
         Int64.equal session.their_session_id hdr.Packet.local_session)
    (`Mismatch_their_session_id (transport, hdr)) >>= fun () ->
  opt_guard (Int64.equal session.my_session_id) hdr.Packet.remote_session
    (`Mismatch_my_session_id (transport, hdr)) >>= fun () ->
  opt_guard (Int32.equal transport.their_message_id) msg_id
    (`Non_monotonic_message_id (transport, msg_id, hdr)) >>| fun () ->
  let session = {
    session with
    their_session_id = hdr.Packet.local_session ;
    their_packet_id = Int32.succ hdr.Packet.packet_id
  } in
  let their_message_id = match msg_id with
    | None -> transport.their_message_id
    | Some x -> Int32.succ x
  in
  (* TODO timestamp? - epsilon-same as ours? monotonically increasing? *)
  let transport = { transport with their_message_id } in
  session, transport

type error = [
    Packet.error
  | `Non_monotonic_packet_id of transport * Packet.header
  | `Non_monotonic_message_id of transport * int32 option * Packet.header
  | `Mismatch_their_session_id of transport * Packet.header
  | `Mismatch_my_session_id of transport * Packet.header
  | `Msg_id_required_in_fresh_key of transport * int * Packet.header
  | `Different_message_id_expected_fresh_key of transport * int * Packet.header
  | `Bad_mac of t * Cstruct.t * Packet.t
  | `No_transition of channel * Packet.operation * Cstruct.t
  | `Tls of [ `Alert of Tls.Packet.alert_type | `Eof | `Fail of Tls.Engine.failure ]
  | `Msg of string
]

let pp_error ppf = function
  | #Packet.error as e -> Fmt.pf ppf "decode %a" Packet.pp_error e
  | `Non_monotonic_packet_id (state, hdr) ->
    Fmt.pf ppf "non monotonic packet id in %a@ (state %a)"
      Packet.pp_header hdr pp_transport state
  | `Non_monotonic_message_id (state, msg_id, hdr) ->
    Fmt.pf ppf "non monotonic message id %a in %a@ (state %a)"
      Fmt.(option ~none:(unit "no") int32) msg_id Packet.pp_header hdr pp_transport state
  | `Mismatch_their_session_id (state, hdr) ->
    Fmt.pf ppf "mismatched their session id in %a@ (state %a)"
      Packet.pp_header hdr pp_transport state
  | `Mismatch_my_session_id (state, hdr) ->
    Fmt.pf ppf "mismatched my session id in %a@ (state %a)"
      Packet.pp_header hdr pp_transport state
  | `Msg_id_required_in_fresh_key (state, key, hdr) ->
    Fmt.pf ppf "no message id in a fresh key (%d) message %a@ (state %a)"
      key Packet.pp_header hdr pp_transport state
  | `Different_message_id_expected_fresh_key (state, key, hdr) ->
    Fmt.pf ppf "different message id expected for fresh key (%d) message %a@ (state %a)"
      key Packet.pp_header hdr pp_transport state
  | `Bad_mac (state, computed, data) ->
    Fmt.pf ppf "bad mac: computed %a, data %a@ (state %a)"
      Cstruct.hexdump_pp computed Packet.pp data pp state
  | `No_transition (channel, op, data) ->
    Fmt.pf ppf "no transition found for typ %a (channel %a)@.data %a"
      Packet.pp_operation op pp_channel channel Cstruct.hexdump_pp data
  | `Tls tls_e -> pp_tls_error ppf tls_e
  | `Msg msg -> Fmt.string ppf msg

let wrap_openvpn session transport ts out =
  let session, transport, header = header session transport ts in
  if Cstruct.equal Cstruct.empty out then
    session, transport, (header, `Ack header)
  else
    let transport, m_id = next_message_id transport in
    session, transport, (header, `Control (Packet.Control, (header, m_id, out)))

let pad block_size cs =
  let pad_len =
    let l = (Cstruct.len cs) mod block_size in
    if l = 0 then block_size else block_size - l
  in
  let out = Cstruct.create pad_len in
  Cstruct.memset out pad_len;
  Cstruct.append cs out

let unpad block_size cs =
  let l = Cstruct.len cs in
  let amount = Cstruct.get_uint8 cs (pred l) in
  let len = l - amount in
  if len >= 0 && amount <= block_size then
    Ok (Cstruct.sub cs 0 len)
  else
    Error (`Msg "bad padding")

let data_out (ctx : keys) compress rng key data =
  (* output is: packed_id 0xfa data, then wrap openvpn partial header
     ~~> well, actually take a random IV, pad and encrypt,
     ~~> prepend IV to encrrypted data
     --> hmac and prepend hash *)
  let hdr = Cstruct.create (4 + if compress then 1 else 0) in
  Cstruct.BE.set_uint32 hdr 0 ctx.my_packet_id;
  if compress then
    (* byte 4 is compression -- 0xFA is "no compression" *)
    Cstruct.set_uint8 hdr 4 0xfa;
  let block_size = 16 in
  let iv = rng block_size
  and data = pad block_size (Cstruct.append hdr data)
  in
  (* Logs.debug (fun m -> m "padded data is %d: %a" (Cstruct.len data) Cstruct.hexdump_pp data); *)
  let enc = Nocrypto.Cipher_block.AES.CBC.encrypt ~key:ctx.my_key ~iv data in
  let payload = Cstruct.append iv enc in
  let hmac = Nocrypto.Hash.SHA1.hmac ~key:ctx.my_hmac payload in
  let payload' = Cstruct.append hmac payload in
  let out = Packet.encode (key, `Data (Packet.Data_v2, payload')) in
  (* Logs.debug (fun m -> m "final out is %a" Cstruct.hexdump_pp out); *)
  let ctx' = { ctx with my_packet_id = Int32.succ ctx.my_packet_id } in
  Logs.debug (fun m -> m "sending %d bytes data (enc %d) out id %lu"
                 (Cstruct.len data) (Cstruct.len out) ctx.my_packet_id);
  (ctx', out)

let outgoing s ts data =
  match keys_opt s.channel with
  | None -> Error `Not_ready
  | Some ctx ->
    let ctx, data = data_out ctx s.compress s.rng s.channel.keyid data in
    let channel = set_keys s.channel ctx in
    Ok ({ s with channel ; last_sent = ts }, [ data ])

let ping =
  Cstruct.of_hex "2a 18 7b f3 64 1e b4 cb  07 ed 2d 0a 98 1f c7 48"

let timer state ts =
  let interval, timeout =
    Config.(get Ping_interval state.config),
    match Config.(get Ping_timeout state.config) with
    | `Restart x -> x
    | `Exit x -> x
  in
  let s_since_recv = Duration.to_sec (Int64.sub ts state.last_received) in
  if s_since_recv > timeout then
    Logs.warn (fun m -> m "should restart or exit (last_received > timeout)");
  if Duration.to_sec (Int64.sub ts state.last_sent) > interval then begin
    Logs.debug (fun m -> m "not enough activity, sending a ping");
    match outgoing state ts ping with
    | Error _ -> state, []
    | Ok (state', data) -> state', data
  end else
    state, []

let incoming_data err (ctx : keys) compress data =
  (* ok, from the spec: hmac(explicit iv, encrypted envelope) ++ explicit iv ++ encrypted envelope *)
  let hmac, data = Cstruct.split data Packet.hmac_len in
  let hmac' = Nocrypto.Hash.SHA1.hmac ~key:ctx.their_hmac data in
  guard (Cstruct.equal hmac hmac') (err hmac') >>= fun () ->
  let iv, data = Cstruct.split data 16 in
  let dec = Nocrypto.Cipher_block.AES.CBC.decrypt ~key:ctx.their_key ~iv data in
  (* dec is: uint32 packet id followed by (lzo-compressed) data and padding *)
  let hdr_len = 4 + if compress then 1 else 0 in
  guard (Cstruct.len dec >= hdr_len)
    (Rresult.R.msgf "payload %a too short (need 5 bytes)"
       Cstruct.hexdump_pp dec) >>= fun () ->
  (* TODO validate packet id and ordering -- do i need to ack it as well? *)
  Logs.debug (fun m -> m "received packet id is %lu" (Cstruct.BE.get_uint32 dec 0));
  let block_size = 16 in
  unpad block_size (Cstruct.shift dec hdr_len) >>= fun data ->
  begin
    if compress then
      (* if dec[4] == 0xfa, then compression is off *)
      match Cstruct.get_uint8 dec 4 with
      | 0xFA -> Ok data
      | 0x66 ->
        Lzo.decompress (Cstruct.to_string data) >>| Cstruct.of_string >>| fun lz ->
        Logs.debug (fun m -> m "decompressed:@.%a" Cstruct.hexdump_pp lz);
        lz
      | comp -> Rresult.R.error_msgf "unknown compression %#X in packet:@.%a"
                  comp Cstruct.hexdump_pp dec
    else
      Ok data
  end >>| fun data' ->
  if Cstruct.equal data' ping then begin
    Logs.warn (fun m -> m "received ping!");
    None
  end else
    Some data'

let check_control_integrity err key p hmac_key =
  let computed_mac, packet_mac =
    compute_hmac key p hmac_key, Packet.((header p).hmac)
  in
  guard (Cstruct.equal computed_mac packet_mac) (err computed_mac) >>| fun () ->
  Logs.info (fun m -> m "mac good")

let wrap_hmac_control now session key transport outs =
  let ts = ptime_to_ts_exn now in
  let session, transport, outs =
    List.fold_left (fun (session, transport, acc) out ->
        (* add the OpenVPN header *)
        let session, transport, (hdr, p) = wrap_openvpn session transport ts out in
        (* hmac each outgoing frame and encode *)
        let out = hmac_and_out key session.my_hmac hdr p in
        session, transport, out :: acc)
      (session, transport, []) outs
  in
  session, transport, List.rev outs

let incoming state now ts buf =
  let state = { state with last_received = ts } in
  let rec multi state buf out appdata =
    match Packet.decode buf with
    | Error `Unknown_operation x -> Error (`Unknown_operation x)
    | Error `Partial -> Ok ({ state with linger = buf }, out, appdata)
    | Ok (key, p, linger) ->
      (* ok, at first find proper channel for key (or create a fresh channel) *)
      match
        match channel_of_keyid key state with
        | None ->
          begin match state.session.state with
            | Rekeying _ | Connecting ->
              Logs.warn (fun m -> m "ignoring bad packet (key %d) in %a"
                            key pp state);
              Error ()
            | Ready ip ->
              let channel = {
                keyid = key ;
                channel_st = Expect_server_reset ;
                transport = init_transport
              }
              in
              Ok (channel, fun s ch ->
                  let session = { s.session with state = Rekeying (ip, ch) } in
                  { s with session })
          end
        | Some (ch, set_ch) -> Ok (ch, set_ch)
      with
      | Error () ->
        Logs.err (fun m -> m "no channel, continue") ;
        Ok (state, [], [])
      | Ok (ch, set_ch) ->
        Logs.debug (fun m -> m "channel %a - received %a"
                       pp_channel ch Packet.pp (key, p));
        let bad_mac hmac' = `Bad_mac (state, hmac', (key, p)) in
        (match p with
         | `Data (_, data) ->
           begin match keys_opt ch with
             | None ->
               Logs.warn (fun m -> m "received data, but session is not keyed yet");
               Ok (state, [], [])
             | Some keys ->
               incoming_data bad_mac keys state.compress data >>| fun data ->
               let data = match data with None -> [] | Some x -> [ x ] in
               state, [], data
           end
         | (`Ack _ | `Control _) as d ->
           check_control_integrity bad_mac key p state.session.their_hmac >>= fun () ->
           (* _first_ update state with last_received_message_id and packet_id *)
           expected_packet state.session ch.transport d >>= fun (session, transport) ->
           let state' = { state with session }
           and ch' = { ch with transport }
           in
           match d with
           | `Ack _ ->
             (* TODO nothing to do for an ack, should bump ack number *)
             Logs.info (fun m -> m "ignoring acknowledgement");
             Ok (set_ch state' ch', [], [])
           | `Control (typ, (_, _, data)) ->
             (* process control in client state machine -- TODO: should receive partial state *)
             incoming_control state.config state.rng state.session ch' now typ data >>| fun (est, config', ch'', outs) ->
             Logs.debug (fun m -> m "out channel %a, pkts %d"
                            pp_channel ch'' (List.length outs));
             (* each control needs to be acked! *)
             let outs = match outs with [] -> [ Cstruct.empty ] | xs -> xs in
             (* now prepare outgoing packets *)
             let session, transport, encs =
               wrap_hmac_control now state'.session key ch''.transport outs
             in
             let ch''' = { ch'' with transport } in
             let state' = { state' with config = config' ; session } in
             let s' = if est then
                 match session.state with
                 | Connecting ->
                   let ip = ip_from_config state'.config in
                   let session = { session with state = Ready ip } in
                   let compress = match Config.find Comp_lzo config' with None -> false | Some () -> true in
                   { state' with compress ; session ; channel = ch''' }
                 | Rekeying (ip, _) ->
                   let session = { session with state = Ready ip } in
                   { state' with session ; channel = ch''' ; lame_duck = Some state'.channel }
                 | Ready _ -> assert false
               else
                 set_ch { state' with config = config' } ch'''
             in
             s', encs, [])
        >>= fun (state', outs, app) ->
        Logs.debug (fun m -> m "out state is %a" State.pp state');
        Logs.debug (fun m -> m "%d outgoing packets" (List.length outs));
        multi state' linger (out @ outs) (appdata @ app)
  in
  multi state (Cstruct.append state.linger buf) [] []
