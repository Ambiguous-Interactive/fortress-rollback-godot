//! Public pinned P2P session handshake observation; no handshake implementation here.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, Message, NonBlockingSocket, PlayerType, ProtocolConfig, SessionBuilder, SyncConfig, FortressEvent};
use fortress_rollback::network::protocol::{HandshakeTraceAction as Action, HandshakeTraceEvent};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::{self, Read}, sync::{Arc, Mutex}, time::Duration};

#[derive(Debug)]
struct Oracle;
impl Config for Oracle { type Input = [u8; 4]; type State = (); type Address = String; }
#[derive(Default)]
struct Buffers { incoming: Vec<(String, Message)>, outgoing: Vec<Message> }
struct Socket(Arc<Mutex<Buffers>>);
impl NonBlockingSocket<String> for Socket {
    fn send_to(&mut self, msg: &Message, _: &String) { self.0.lock().unwrap().outgoing.push(msg.clone()); }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> { std::mem::take(&mut self.0.lock().unwrap().incoming) }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scenario { format: u32, operations: Vec<Operation> }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Operation { now_us: u64, kind: String, token_index: Option<usize>, changes: Option<Value>, connection: Option<u32>, source: Option<String>, echo: Option<u32> }
fn hex(value: u64, width: usize) -> String {
    let mut bytes = value.to_le_bytes().to_vec(); bytes.resize(width, 0);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn mismatch(value: &fortress_rollback::IncompatibleSessionReason) -> Value {
    use fortress_rollback::IncompatibleSessionReason::*;
    match value {
        ProtocolVersion {ours,theirs} => json!({"field":"min_compat_version","ours":ours,"theirs":theirs}),
        NumPlayers {ours,theirs} => json!({"field":"player_count","ours":ours,"theirs":theirs}),
        InputWidth {ours,theirs} => json!({"field":"input_width","ours":ours,"theirs":theirs}),
        Fps {ours,theirs} => json!({"field":"fps","ours":ours,"theirs":theirs}),
        MaxPrediction {ours,theirs} => json!({"field":"max_prediction","ours":ours,"theirs":theirs}),
        DesyncInterval {ours,theirs} => json!({"field":"desync_interval","ours":ours,"theirs":theirs}),
        Features {ours,theirs} => json!({"field":"features","ours":ours,"theirs":theirs}),
        ConfigDigest {ours,theirs} => json!({"field":"config_digest","ours":hex(*ours,8),"theirs":hex(*theirs,8)}),
        _ => panic!("unknown mismatch"),
    }
}
fn trace(event: &HandshakeTraceEvent) -> Value {
    let (action, token, disposition) = match event.action {
        Action::Activated => ("activated", None, None), Action::BeginSynchronization => ("begin", None, None),
        Action::SendRequest { request_id, disposition } => ("send_request", Some(hex(request_id.into(),16)), Some(format!("{disposition:?}").to_lowercase())),
        Action::HandleRequest { request_id, disposition } => ("handle_request", Some(hex(request_id.into(),16)), Some(format!("{disposition:?}").to_lowercase())),
        Action::HandleReply { request_id, disposition } => ("handle_reply", Some(hex(request_id.into(),16)), Some(format!("{disposition:?}").to_lowercase())),
        Action::ReportTimeout { .. } => ("report_timeout", None, None),
    };
    let failure = event.incompatibility.as_ref().map(mismatch).unwrap_or_else(||json!({}));
    let state = format!("{:?}", event.state).to_lowercase();
    json!({"action":action,"token":token,"disposition":disposition,"state":state,"remaining":event.sync_remaining_roundtrips,
        "outstanding":event.outstanding_request_count,"remote_connection":if event.remote_conn_id == 0 { None } else {Some(hex(event.remote_conn_id.into(),8))},
        "timeout_sent":event.timeout_event_sent,"mismatch":failure,
        "elapsed_ms": match event.action { Action::ReportTimeout {elapsed_ms} => json!(elapsed_ms), _=>json!(-1) }})
}
fn events(session: &mut fortress_rollback::P2PSession<Oracle>) -> Vec<Value> {
    session.events().map(|event| match event {
        FortressEvent::Synchronizing { total,count,total_requests_sent,elapsed_ms,.. } =>
            json!({"kind":"synchronizing","total":total,"count":count,"total_requests_sent":total_requests_sent,"elapsed_ms":elapsed_ms}),
        FortressEvent::Synchronized {..} => json!({"kind":"synchronized"}),
        FortressEvent::SyncTimeout {elapsed_ms,..} => json!({"kind":"sync_timeout","elapsed_ms":elapsed_ms}),
        FortressEvent::IncompatibleSession {reason:r,..} => json!({"kind":"incompatible","reason":mismatch(&r)}),
        _ => panic!("unexpected upstream handshake event"),
    }).collect()
}
fn main() {
    let mut input = String::new(); io::stdin().read_to_string(&mut input).unwrap();
    let scenario: Scenario = serde_json::from_str(&input).expect("strict handshake scenario");
    assert_eq!(scenario.format, 1); assert!(!scenario.operations.is_empty() && scenario.operations.len() <= 128);
    let origin = web_time::Instant::now(); let time = Arc::new(Mutex::new(0u64)); let clock = time.clone();
    let protocol = ProtocolConfig {
        quality_report_interval: Duration::from_secs(100), protocol_rng_seed: Some(1701),
        clock: Some(Arc::new(move || origin + Duration::from_micros(*clock.lock().unwrap()))), ..Default::default() };
    let sync = SyncConfig { num_sync_packets: 2, sync_retry_interval: Duration::from_millis(200), sync_timeout: Some(Duration::from_millis(1000)), ..Default::default() };
    let buffers = Arc::new(Mutex::new(Buffers::default()));
    let builder = SessionBuilder::<Oracle>::new().with_num_players(2).unwrap().with_max_prediction_window(8)
        .with_protocol_config(protocol).with_sync_config(sync).with_handshake_trace_capacity(64).unwrap()
        .add_player(PlayerType::Local, 0.into()).unwrap().add_player(PlayerType::Remote("peer".into()), 1.into()).unwrap();
    let mut session = builder.start_p2p_session(Socket(buffers.clone())).unwrap();
    let mut sent = Vec::<Value>::new(); let mut records = Vec::new(); let mut cursor = 0;
    let collect = |session: &fortress_rollback::P2PSession<Oracle>, cursor: &mut usize| {
        let all = session.handshake_trace(1.into()).unwrap().unwrap().unwrap();
        let new = all[*cursor..].iter().map(trace).collect::<Vec<_>>(); *cursor=all.len(); new
    };
    let initial = collect(&session,&mut cursor);
    session.poll_remote_clients();
    let packets = std::mem::take(&mut buffers.lock().unwrap().outgoing).iter()
        .map(|m|serde_json::to_value(m).unwrap()).collect::<Vec<_>>();
    sent.extend(packets.clone());
    records.push(json!({"operation":null,"transitions":initial.into_iter().chain(collect(&session,&mut cursor)).collect::<Vec<_>>(),
        "packets":packets,"events":events(&mut session)}));
    let mut previous = 0;
    for (index, op) in scenario.operations.iter().enumerate() {
        assert!(op.now_us >= previous && op.now_us <= 10000000); previous=op.now_us; *time.lock().unwrap()=op.now_us;
        match op.kind.as_str() {
            "poll" => assert!(op.token_index.is_none() && op.changes.is_none() && op.connection.is_none() && op.source.is_none() && op.echo.is_none()),
            "request" | "reply" => {
                let sent_packet = sent.get(op.token_index.unwrap()).expect("observed packet index");
                let mut packet=sent_packet.clone();
                let mut body = packet["body"]["SyncRequest"].clone(); assert!(body.is_object());
                let token=body.as_object_mut().unwrap().remove("random_request").unwrap();
                body[if op.kind=="reply" {"random_reply"} else {"random_request"}]=op.echo.map_or(token, |v|json!(v));
                if let Some(changes)=&op.changes { for (key,value) in changes.as_object().expect("changes object") {
                    match key.as_str() { "min_compat_version" | "features" | "config_digest" => body[key]=value.clone(),
                    "num_players" | "input_bytes_per_player" | "fps" | "max_prediction" | "desync_interval" => body["config"][key]=value.clone(), _=>panic!("unknown change") }
                }}
                packet["body"]=json!({if op.kind=="reply" {"SyncReply"} else {"SyncRequest"}:body});
                packet["header"]["conn_id"]=json!(op.connection.unwrap_or(77));
                let message:Message=serde_json::from_value(packet).expect("actual upstream message deserialize");
                buffers.lock().unwrap().incoming.push((op.source.clone().unwrap_or_else(||"peer".into()),message));
            }, _=>panic!("unknown operation"),
        }
        session.poll_remote_clients();
        let packets=std::mem::take(&mut buffers.lock().unwrap().outgoing).iter().map(|m|serde_json::to_value(m).unwrap()).collect::<Vec<_>>();
        sent.extend(packets.clone());
        records.push(json!({"operation":index,"transitions":collect(&session,&mut cursor),
        "packets":packets,"events":events(&mut session)}));
    }
    println!("{}",json!({"format":1,"complete":true,"upstream_revision":"d124c89080004d96971a629bb0427056ee1805e3","records":records}));
}
