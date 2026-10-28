//! Actual upstream multiplayer session, fake transport and application callbacks.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, FortressRequest, InputStatus, PlayerHandle, SessionBuilder, Message, NonBlockingSocket, PlayerType,
 ProtocolConfig, SyncConfig, DesyncDetection, FortressEvent, FortressError, InvalidRequestKind};
use fortress_rollback::network::compression::decode_with_max_len;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::{self, Read}, sync::{Arc, Mutex}, collections::BTreeMap, time::Duration};
const REVISION: &str = "d124c89080004d96971a629bb0427056ee1805e3";
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scenario { format:u32, players:usize, input_delay:usize, max_prediction:usize, operations:Vec<Operation>,
 #[serde(default, deserialize_with="present_lifecycle")] lifecycle:Option<Lifecycle> }
fn present_lifecycle<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<Lifecycle>, D::Error> {
    Lifecycle::deserialize(deserializer).map(Some)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Lifecycle { quality_us:u64, keepalive_us:u64, notify_us:u64, timeout_us:u64, checksum_interval:u32, divergent_peer:i32 }
#[derive(Deserialize)]
#[serde(tag="kind", rename_all="snake_case", deny_unknown_fields)]
enum Operation {
 Step {peer:usize, now_us:u64, bytes:String},
 Poll {peer:usize, now_us:u64},
 Deliver {packet:usize, now_us:u64},
 // Runtime set_input_delay; it reuses the previous operation's clock.
 Delay {peer:usize, delay:usize},
}
#[derive(Default)]
struct Buffers { incoming:Vec<(String,Message)>, outgoing:Vec<(String,Message)> }
struct Socket(Arc<Mutex<Buffers>>);
impl NonBlockingSocket<String> for Socket {
 fn send_to(&mut self,msg:&Message,address:&String){self.0.lock().unwrap().outgoing.push((address.clone(),msg.clone()));}
 fn receive_all_messages(&mut self)->Vec<(String,Message)>{std::mem::take(&mut self.0.lock().unwrap().incoming)}
}
#[derive(Clone)]
struct Game {
    frame: i32,
    accumulators: Vec<u32>,
    version: u32,
    rng: u32,
    pending: u32,
}

impl Game {
    fn bytes(&self) -> Vec<u8> {
        let mut bytes = self.frame.to_le_bytes().to_vec();
        for value in &self.accumulators {
            bytes.extend(value.to_le_bytes());
        }
        if self.version == 2 {
            bytes.extend(self.rng.to_le_bytes());
            bytes.extend(self.pending.to_le_bytes());
        }
        bytes
    }

    fn checksum(&self) -> u128 {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in self.bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
        (u128::from(!hash) << 64) | u128::from(hash)
    }
}

#[derive(Debug)]
struct OracleConfig;
impl Config for OracleConfig {
    type Input = [u8; 4];
    type State = Game;
    type Address = String;
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn input_bytes(text: &str) -> Result<[u8; 4], String> {
    if text.len() != 8 || !text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) {
        return Err("input bytes must be exactly eight lowercase hexadecimal digits".into());
    }
    let mut bytes = [0; 4];
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).map_err(|error| error.to_string())?;
    }
    Ok(bytes)
}

fn state_fields(kind: &str, frame: i32, game: &Game, inputs: Value) -> Value {
    json!({"kind":kind,"frame":frame,"state_bytes":hex(&game.bytes()),
        "checksum":format!("{:032x}",game.checksum()),"inputs":inputs})
}


fn apply(session:&mut fortress_rollback::P2PSession<OracleConfig>, game:&mut Game)->Result<(Vec<Value>,Option<String>),String>{
 let mut records=Vec::new();
 let requests=match session.advance_frame(){Ok(v)=>v,Err(e)=>return Ok((records,Some(format!("{e:?}"))))};
 for request in requests { match request {
 FortressRequest::SaveGameState{cell,frame}=>{
  if game.frame!=frame.as_i32() || !cell.save(frame,Some(game.clone()),Some(game.checksum())) {return Err("invalid save boundary".into());}
  records.push(state_fields("save",frame.as_i32(),game,json!([])));
 },
 FortressRequest::LoadGameState{cell,frame}=>{
  *game=cell.load().ok_or("missing saved state")?;
  if game.frame!=frame.as_i32(){return Err("invalid load boundary".into());}
  records.push(state_fields("load",frame.as_i32(),game,json!([])));
 },
 FortressRequest::AdvanceFrame{inputs}=>{
  let frame=game.frame;let mut traced=Vec::new();let mut next_pending=0u32;
  game.rng=game.rng.wrapping_mul(1664525).wrapping_add(1013904223);
  for (player,(input,status)) in inputs.iter().enumerate(){
   let status=match status {InputStatus::Confirmed=>"confirmed",InputStatus::Predicted=>"predicted",InputStatus::Disconnected=>"disconnected"};
   traced.push(json!({"player":player,"bytes":hex(input),"status":status}));
   let value=u32::from_le_bytes(*input);let event=game.pending.wrapping_add((game.rng&255)*(player as u32+1));
   game.accumulators[player]=game.accumulators[player].wrapping_add(value).wrapping_add(event);
   next_pending=next_pending.wrapping_add(value.wrapping_mul(player as u32+1));
  }
  game.pending=next_pending;game.frame+=1;records.push(state_fields("advance",frame,game,json!(traced)));
 }
 }}
 Ok((records,None))
}

fn project_packet(raw:&Value,peer:usize,destination:usize,delay:usize,decoded:&mut BTreeMap<(usize,usize,i32),Vec<u8>>)->Result<Value,String>{
   if raw["body"]=="KeepAlive" {return Ok(json!({"kind":"keep_alive"}));}
   let body=raw["body"].as_object().ok_or("message body")?;let (kind,body)=body.iter().next().ok_or("empty body")?;
   let semantic=match kind.as_str(){
    "Input"=>{
     let start=body["start_frame"].as_i64().ok_or("start frame")? as i32;
     let compressed=body["bytes"].as_array().ok_or("input bytes")?.iter().map(|v|v.as_u64().unwrap() as u8).collect::<Vec<_>>();
     let reference=if start<=delay as i32 {vec![0;4]}else{decoded.get(&(peer,destination,start-1)).ok_or("missing actual compression reference")?.clone()};
     let frames=decode_with_max_len(&reference,&compressed,4096).map_err(|e|format!("{e:?}"))?;
     for (offset,bytes) in frames.iter().enumerate(){decoded.insert((peer,destination,start+offset as i32),bytes.clone());}
     json!({"kind":"input","start_frame":start,"ack_frame":body["ack_frame"],"statuses":body["peer_connect_status"],
      "players":[peer],"frames":frames.iter().map(|v|hex(v)).collect::<Vec<_>>()})
    },"InputAck"=>json!({"kind":"input_ack","ack_frame":body["ack_frame"]}),
    "QualityReport"=>{let ping=body["ping"].to_string().parse::<u128>().map_err(|_|"ping integer")?;
     json!({"kind":"quality_report","frame_advantage":body["frame_advantage"],"ping":format!("{ping:032x}")})},
    "QualityReply"=>{let pong=body["pong"].to_string().parse::<u128>().map_err(|_|"pong integer")?;
     json!({"kind":"quality_reply","pong":format!("{pong:032x}")})},
    "KeepAlive"=>json!({"kind":"keep_alive"}),
    "ChecksumReport"=>{let checksum=body["checksum"].to_string().parse::<u128>().map_err(|_|"checksum integer")?;
     json!({"kind":"checksum_report","frame":body["frame"],"checksum":format!("{checksum:032x}")})},
    _=>return Err(format!("unsupported gameplay packet {kind}")),
   };
   Ok(semantic)
}
fn event(e:FortressEvent<OracleConfig>)->Result<Value,String>{Ok(match e {
 FortressEvent::NetworkInterrupted{addr,disconnect_timeout}=>json!({"kind":"network_interrupted","peer":addr.parse::<usize>().unwrap(),
  "disconnect_timeout":disconnect_timeout as u64}),
 FortressEvent::NetworkResumed{addr}=>json!({"kind":"network_resumed","peer":addr.parse::<usize>().unwrap()}),
 FortressEvent::Disconnected{addr}=>json!({"kind":"disconnected","peer":addr.parse::<usize>().unwrap()}),
 FortressEvent::WaitRecommendation{skip_frames}=>json!({"kind":"wait_recommendation","skip_frames":skip_frames}),
 FortressEvent::DesyncDetected{frame,local_checksum,remote_checksum,addr}=>json!({"kind":"desync_detected","frame":frame.as_i32(),
  "local_checksum":format!("{local_checksum:032x}"),"remote_checksum":format!("{remote_checksum:032x}"),"peer":addr.parse::<usize>().unwrap()}),
 _=>return Err(format!("unmodeled lifecycle event {e:?}")),
})}
/// Compared delays: Godot's peer bound (queue 128) or above upstream's bound; the band between them differs by design.
fn comparable_delay(delay:usize,max_prediction:usize)->bool{delay<=(126-2*max_prediction)/2||(delay>127-max_prediction&&delay<=1000)}
fn delay_error(e:FortressError)->String{match e {
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::InputDelayDecreaseUnsupported{..}}=>"InputDelayDecreaseUnsupported".into(),
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::FrameDelayTooLarge{..}}=>"FrameDelayTooLarge".into(),
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::ConfigValueOutOfRange{..}}=>"ConfigValueOutOfRange".into(),
 other=>format!("{other:?}")}}
fn run(original:Value,profile_audit:bool)->Result<Value,String>{
 let scenario:Scenario=serde_json::from_value(original.clone()).map_err(|e|e.to_string())?;
 if scenario.format!=1 || !(2..=8).contains(&scenario.players)||scenario.input_delay>2||!((if profile_audit {0}else{2})..=8).contains(&scenario.max_prediction)
 ||scenario.operations.is_empty()||scenario.operations.len()>10000{return Err("scenario bounds".into());}
 if let Some(l)=&scenario.lifecycle {if l.quality_us<1000||l.keepalive_us<1000||l.notify_us==0||l.notify_us>=l.timeout_us||l.timeout_us>10000000
  ||l.quality_us>100000000||l.keepalive_us>100000000||l.checksum_interval>60||l.divergent_peer< -1
  ||l.divergent_peer>=scenario.players as i32{return Err("lifecycle bounds".into());}}
 let mut previous=0;let mut stepped=vec![false;scenario.players];let mut addressed=None;
 for op in &scenario.operations {
  let (peer,time)=match op {Operation::Step{peer,now_us,bytes}=>{input_bytes(bytes)?;(*peer,*now_us)},Operation::Poll{peer,now_us}=>(*peer,*now_us),
   Operation::Deliver{now_us,..}=>(0,*now_us),Operation::Delay{peer,delay}=>{
    // Godot's agreed config owns the pre-input delay, so only changes after the peer's first step compare.
    if *peer>=scenario.players||!stepped[*peer]||addressed!=Some(*peer)||!comparable_delay(*delay,scenario.max_prediction){return Err("delay bounds".into());}(*peer,previous)}};
  if peer>=scenario.players||time<previous||time>10000000{return Err("operation bounds".into());}previous=time;
  if let Operation::Step{peer,..}=op{stepped[*peer]=true;}
  // The shared source clock equals Godot's per-peer clock only after an operation addressed to that peer.
  addressed=match op {Operation::Deliver{..}=>None,_=>Some(peer)};
 }
 let time=Arc::new(Mutex::new(0u64));let origin=web_time::Instant::now();
 let mut sessions=Vec::new();let mut buffers=Vec::new();let mut games=Vec::new();
 for peer in 0..scenario.players {
  let clock=time.clone();let protocol=ProtocolConfig{clock:Some(Arc::new(move||origin+Duration::from_micros(*clock.lock().unwrap()))),
   protocol_rng_seed:Some(1701+peer as u64),quality_report_interval:Duration::from_micros(scenario.lifecycle.as_ref().map_or(100000000,|l|l.quality_us)),..Default::default()};
  let sync=SyncConfig{num_sync_packets:1,keepalive_interval:Duration::from_micros(scenario.lifecycle.as_ref().map_or(100000000,|l|l.keepalive_us)),..Default::default()};
  let mut builder=SessionBuilder::<OracleConfig>::new().with_num_players(scenario.players).map_err(|e|format!("{e:?}"))?
   .with_max_prediction_window(scenario.max_prediction).with_input_delay(scenario.input_delay).map_err(|e|format!("{e:?}"))?
   .with_protocol_config(protocol).with_sync_config(sync);
  if let Some(l)=&scenario.lifecycle {builder=builder.with_disconnect_timeout(Duration::from_micros(l.timeout_us))
   .with_disconnect_notify_delay(Duration::from_micros(l.notify_us))
   .with_desync_detection_mode(if l.checksum_interval==0{DesyncDetection::Off}else{DesyncDetection::On{interval:l.checksum_interval}});}
  else {builder=builder.with_disconnect_timeout(Duration::from_secs(100)).with_disconnect_notify_delay(Duration::from_secs(50));}
  for slot in 0..scenario.players {builder=builder.add_player(if slot==peer {PlayerType::Local}else{PlayerType::Remote(slot.to_string())},slot.into()).unwrap();}
  let queue=Arc::new(Mutex::new(Buffers::default()));sessions.push(builder.start_p2p_session(Socket(queue.clone())).unwrap());buffers.push(queue);
  let mut game=Game{frame:0,accumulators:vec![0;scenario.players],version:2,rng:8173,pending:0};
  if scenario.lifecycle.as_ref().is_some_and(|l|l.divergent_peer==peer as i32){game.accumulators[0]=1;}games.push(game);
 }
 // Bootstrap uses real peer sessions and messages; no forged synchronization.
 for _ in 0..8 {
  for session in &mut sessions {session.poll_remote_clients();}
  for (sender,queue) in buffers.iter().enumerate(){for (destination,message) in std::mem::take(&mut queue.lock().unwrap().outgoing){
   buffers[destination.parse::<usize>().unwrap()].lock().unwrap().incoming.push((sender.to_string(),message));
  }}
 }
 for session in &mut sessions {if format!("{:?}",session.current_state())!="Running"{return Err("bootstrap incomplete".into());}session.events().for_each(drop);}
 let mut packets:Vec<(usize,usize,Message)>=Vec::new();let mut packet_values=Vec::new();let mut records=Vec::new();
 let mut decoded:BTreeMap<(usize,usize,i32),Vec<u8>>=BTreeMap::new();
 for (index,op) in scenario.operations.iter().enumerate(){
  let (peer,now)=match op {Operation::Step{peer,now_us,..}|Operation::Poll{peer,now_us}=>(*peer,*now_us),
   Operation::Delay{peer,..}=>(*peer,*time.lock().unwrap()),
   Operation::Deliver{packet,now_us}=>{let (sender,destination,message)=packets.get(*packet).ok_or("unknown observed packet")?;
    buffers[*destination].lock().unwrap().incoming.push((sender.to_string(),message.clone()));(*destination,*now_us)}};
  *time.lock().unwrap()=now;let before=sessions[peer].current_frame().as_i32();let pre_state=hex(&games[peer].bytes());
  let pre_confirmed=sessions[peer].confirmed_frame().as_i32();let mut requests=Vec::new();let mut error=None;
  match op {Operation::Step{bytes,..}=>{
   error=sessions[peer].add_local_input(PlayerHandle::new(peer),input_bytes(bytes)?).err().map(|e|format!("{e:?}"));
   if error.is_none(){(requests,error)=apply(&mut sessions[peer],&mut games[peer])?;}
  },Operation::Delay{delay,..}=>{error=sessions[peer].set_input_delay(PlayerHandle::new(peer),*delay).err().map(delay_error);},
  _=>sessions[peer].poll_remote_clients()}
  let mut outgoing=Vec::new();
  for (destination,message) in std::mem::take(&mut buffers[peer].lock().unwrap().outgoing){
   let destination=destination.parse::<usize>().unwrap();let raw=serde_json::to_value(&message).unwrap();
   let semantic=project_packet(&raw,peer,destination,scenario.input_delay,&mut decoded)?;
   let id=packets.len();packets.push((peer,destination,message));
   packet_values.push(json!({"id":id,"from":peer,"to":destination,"raw":raw,"semantic":semantic}));outgoing.push(id);
  }
  let events=sessions[peer].events().map(|e|if scenario.lifecycle.is_some(){event(e)}else{Ok(json!(format!("{e:?}"))) }).collect::<Result<Vec<_>,_>>()?;
  let mut record=json!({"index":index,"peer":peer,"frame_before":before,"frame_after":sessions[peer].current_frame().as_i32(),
   "confirmed_frame":sessions[peer].confirmed_frame().as_i32(),"error":error,"requests":requests,"events":events,"outgoing":outgoing,
   "state":hex(&games[peer].bytes())});
  if scenario.lifecycle.is_some(){record["pre_state"]=json!(pre_state);record["pre_confirmed"]=json!(pre_confirmed);
   let stats=(0..scenario.players).filter(|r|*r!=peer).map(|remote|{
   match sessions[peer].network_stats(PlayerHandle::new(remote)) {Ok(s)=>json!({"peer":remote,"error":null,"ping":s.ping as u64,
    "local_frames_behind":s.local_frames_behind,"remote_frames_behind":s.remote_frames_behind}),Err(e)=>json!({"peer":remote,"error":format!("{e:?}")})}
  }).collect::<Vec<_>>();record["metrics"]=json!({"frames_ahead":sessions[peer].frames_ahead(),"peers":stats});}
  records.push(record);
 }
 Ok(json!({"format":1,"complete":true,"upstream_revision":REVISION,"scenario":original,"records":records,"packets":packet_values}))
}
fn main(){let result=(||{let mut input=String::new();io::stdin().take(4000001).read_to_string(&mut input).map_err(|e|e.to_string())?;
 if input.len()>4000000{return Err("input bounds".into());}let value:Value=serde_json::from_str(&input).map_err(|e|e.to_string())?;
 if std::env::args().skip(1).collect::<Vec<_>>()==vec!["--validate-trace"] {
  let delay=value["scenario"]["input_delay"].as_u64().ok_or("delay")? as usize;
  let mut decoded=BTreeMap::new();let packets=value["packets"].as_array().ok_or("packets")?;
  for packet in packets {let raw=&packet["raw"];let _:Message=serde_json::from_value(raw.clone()).map_err(|e|e.to_string())?;
   let semantic=project_packet(raw,packet["from"].as_u64().ok_or("from")? as usize,packet["to"].as_u64().ok_or("to")? as usize,delay,&mut decoded)?;
   if semantic!=packet["semantic"] {return Err("raw compressed semantic mismatch".into());}
  }
  Ok(json!({"complete":true,"packets":packets.len()}))
 }else if std::env::args().len()==1 {run(value,false)}
 else if std::env::args().skip(1).collect::<Vec<_>>()==vec!["--profile-audit"] {run(value,true)}
 else{return Err("unknown argument".into());}})();
 match result{Ok(v)=>println!("{v}"),Err(e)=>{eprintln!("p2p oracle: {e}");std::process::exit(2);}}}
