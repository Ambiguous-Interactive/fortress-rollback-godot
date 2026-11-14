//! Actual upstream multiplayer session, fake transport and application callbacks.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, FortressRequest, InputQueueConfig, InputStatus, PlayerHandle, SessionBuilder, Message, NonBlockingSocket, PlayerType,
 ProtocolConfig, SyncConfig, DesyncDetection, FortressEvent, FortressError, InvalidRequestKind};
use fortress_rollback::network::compression::decode_with_max_len;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::{self, Read}, sync::{Arc, Mutex}, collections::BTreeMap, time::Duration};
const REVISION: &str = "d124c89080004d96971a629bb0427056ee1805e3";
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scenario { format:u32, players:usize, input_delay:usize, max_prediction:usize, operations:Vec<Operation>,
 // An omitted field stays None (the 128-row default); an explicit null is rejected.
 #[serde(default, deserialize_with="present_capacity")] queue_capacity:Option<usize>,
 #[serde(default, deserialize_with="present_layout")] layout:Option<Vec<usize>>,
 #[serde(default, deserialize_with="present_lifecycle")] lifecycle:Option<Lifecycle> }
fn present_lifecycle<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<Lifecycle>, D::Error> {
    Lifecycle::deserialize(deserializer).map(Some)
}
fn present_capacity<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<usize>, D::Error> {
    usize::deserialize(deserializer).map(Some)
}
fn present_layout<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<Vec<usize>>, D::Error> {
    Vec::<usize>::deserialize(deserializer).map(Some)
}
/// Local slot lists per machine address; an omitted layout stays one slot per endpoint.
fn slots_of(players:usize, layout:&Option<Vec<usize>>)->Vec<Vec<usize>>{match layout {
    None=>(0..players).map(|slot|vec![slot]).collect(),
    Some(sizes)=>{let mut slots=Vec::new();let mut start=0;for size in sizes{slots.push((start..start+size).collect());start+=size;}slots}}}
fn owner_of(slots_of:&[Vec<usize>])->Vec<usize>{let mut owner=Vec::new();for (machine,slots) in slots_of.iter().enumerate(){
    for _slot in slots{owner.push(machine);}}owner}
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

/// Per-endpoint encoder references, mirroring the pinned session exactly: every
/// flight XOR-deltas each of its rows against the row of the highest frame the
/// destination has acknowledged, flights join the sender's pending queue at
/// creation, and a carried `ack_frame` pops the receiving endpoint's own
/// pending rows when the packet is delivered. One row per frame, four bytes
/// per local slot the sender owns, so a multi-local machine's rows are the
/// ascending concatenation of its slots' inputs.
#[derive(Default)]
struct MeshReferences {
    row_bytes: Vec<usize>,
    acked: BTreeMap<(usize,usize),(i32,Vec<u8>)>,
    pending: BTreeMap<(usize,usize),Vec<(i32,Vec<u8>)>>,
}
impl MeshReferences {
    fn new(slots_of:&[Vec<usize>])->Self{Self{row_bytes:slots_of.iter().map(|slots|4*slots.len()).collect(),..Default::default()}}
    fn reference(&mut self,peer:usize,destination:usize)->Vec<u8>{
        self.acked.entry((peer,destination)).or_insert((-1,vec![0;self.row_bytes[peer]])).1.clone()
    }
    fn send(&mut self,peer:usize,destination:usize,start:i32,frames:&[Vec<u8>]){
        let flight:Vec<(i32,Vec<u8>)>=(0..frames.len() as i32).map(|offset|(start+offset,frames[offset as usize].clone())).collect();
        self.pending.entry((peer,destination)).or_default().extend(flight);
    }
    /// A delivered packet's `ack_frame` acknowledges the sender's own sends;
    /// the receiving endpoint pops its own pending rows toward the sender.
    /// The pinned engine admits gameplay packets only while Running; every
    /// corpus schedule delivers to Running endpoints only, so this model —
    /// like the frame-range guard below, which mirrors validate()'s frame
    /// bound — never observes the other protocol states.
    fn deliver(&mut self,sender:usize,destination:usize,raw:&Value){
        let Some(body)=raw["body"].as_object() else {return};
        let Some((kind,value))=body.iter().next() else {return};
        if kind!="Input" && kind!="InputAck" {return}
        let Some(ack)=value.get("ack_frame").and_then(|ack|ack.as_i64()) else {return};
        if !(0..=10000).contains(&ack) {return}
        let ack=ack as i32;
        let (receiver,sender)=(destination,sender);
        let acked=self.acked.entry((receiver,sender)).or_insert((-1,vec![0;self.row_bytes[receiver]]));
        if acked.0>=0 && ack<=acked.0 {return}
        let Some(queue)=self.pending.get_mut(&(receiver,sender)) else {return};
        let Some(newest)=queue.last() else {return};
        if ack>newest.0 {return}
        while let Some(front)=queue.first() {
            if front.0>ack {break}
            let popped=queue.remove(0);
            *acked=(popped.0,popped.1);
        }
    }
}


fn apply(session:&mut fortress_rollback::P2PSession<OracleConfig>, game:&mut Game)->Result<(Vec<Value>,Option<String>),String>{
 let mut records=Vec::new();
 let requests=match session.advance_frame(){Ok(v)=>v,Err(e)=>return Ok((records,Some(advance_error(e))))};
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

/// Compared advance refusals: Godot's own code names; everything else keeps its Debug shape.
fn advance_error(e:FortressError)->String{match e {
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::MissingLocalInput{..}}=>"MissingLocalInput".into(),
 other=>format!("{other:?}")}}
fn project_packet(raw:&Value,peer:usize,destination:usize,references:&mut MeshReferences,slots_of:&[Vec<usize>])->Result<Value,String>{
   if raw["body"]=="KeepAlive" {return Ok(json!({"kind":"keep_alive"}));}
   let body=raw["body"].as_object().ok_or("message body")?;let (kind,body)=body.iter().next().ok_or("empty body")?;
   let semantic=match kind.as_str(){
    "Input"=>{
     let start=body["start_frame"].as_i64().ok_or("start frame")? as i32;
     let compressed=body["bytes"].as_array().ok_or("input bytes")?.iter().map(|v|v.as_u64().unwrap() as u8).collect::<Vec<_>>();
     let reference=references.reference(peer,destination);
     let frames=decode_with_max_len(&reference,&compressed,4096).map_err(|e|format!("{e:?}"))?;
     references.send(peer,destination,start,&frames);
     json!({"kind":"input","start_frame":start,"ack_frame":body["ack_frame"],"statuses":body["peer_connect_status"],
      "players":slots_of[peer].clone(),"frames":frames.iter().map(|v|hex(v)).collect::<Vec<_>>()})
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
/// Compared delays: Godot's peer bound (per configured queue) or above upstream's bound; the band between them differs by design.
fn godot_max_delay(max_prediction:isize,capacity:isize)->isize{(capacity-2*max_prediction-2)/2}
fn comparable_delay(delay:usize,max_prediction:usize,capacity:usize)->bool{let godot=godot_max_delay(max_prediction as isize,capacity as isize);
 delay as isize<=godot||delay>capacity-1-max_prediction&&delay<=1000}
fn delay_error(e:FortressError)->String{match e {
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::InputDelayDecreaseUnsupported{..}}=>"InputDelayDecreaseUnsupported".into(),
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::FrameDelayTooLarge{..}}=>"FrameDelayTooLarge".into(),
 FortressError::InvalidRequestStructured{kind:InvalidRequestKind::ConfigValueOutOfRange{..}}=>"ConfigValueOutOfRange".into(),
 other=>format!("{other:?}")}}
fn run(original:Value,profile_audit:bool)->Result<Value,String>{
 let scenario:Scenario=serde_json::from_value(original.clone()).map_err(|e|e.to_string())?;
 if scenario.format!=1 || !(2..=8).contains(&scenario.players)||scenario.input_delay>2||!((if profile_audit {0}else{2})..=8).contains(&scenario.max_prediction)
 ||scenario.operations.is_empty()||scenario.operations.len()>10000{return Err("scenario bounds".into());}
 // An omitted profile keeps the 128-row default; an explicit one configures both adapters' rings.
 let capacity=match scenario.queue_capacity {None=>128,Some(n)=>n};
 if !(2..=128).contains(&capacity)||capacity<scenario.input_delay+scenario.max_prediction+2
 ||(scenario.input_delay as isize)>godot_max_delay(scenario.max_prediction as isize,capacity as isize){return Err("scenario bounds".into());}
 if let Some(l)=&scenario.lifecycle {if l.quality_us<1000||l.keepalive_us<1000||l.notify_us==0||l.notify_us>=l.timeout_us||l.timeout_us>10000000
  ||l.quality_us>100000000||l.keepalive_us>100000000||l.checksum_interval>60||l.divergent_peer< -1
  ||l.divergent_peer>=scenario.players as i32{return Err("lifecycle bounds".into());}}
 let slots_of=slots_of(scenario.players,&scenario.layout);let owner=owner_of(&slots_of);let machines=slots_of.len();
 // Lifecycle timers stay a single-local slice, exactly like the shared Python grammar.
 if let Some(sizes)=&scenario.layout {if sizes.is_empty()||machines<2||sizes.iter().any(|size|*size==0)||sizes.iter().sum::<usize>()!=scenario.players
  ||scenario.lifecycle.is_some()
  ||scenario.operations.iter().any(|op|matches!(op,Operation::Delay{..})){return Err("layout bounds".into());}}
 let mut previous=0;let mut stepped=vec![false;scenario.players];let mut addressed=None;
 for op in &scenario.operations {
  let (peer,time)=match op {Operation::Step{peer,now_us,bytes}=>{input_bytes(bytes)?;(*peer,*now_us)},Operation::Poll{peer,now_us}=>(*peer,*now_us),
   Operation::Deliver{now_us,..}=>(0,*now_us),Operation::Delay{peer,delay}=>{
    // Godot's agreed config owns the pre-input delay, so only changes after the peer's first step compare.
    if *peer>=scenario.players||!stepped[*peer]||addressed!=Some(*peer)
    ||!comparable_delay(*delay,scenario.max_prediction,capacity){return Err("delay bounds".into());}(*peer,previous)}};
  if peer>=scenario.players||time<previous||time>10000000{return Err("operation bounds".into());}previous=time;
  if let Operation::Step{peer,..}=op{stepped[*peer]=true;}
  // The shared source clock equals Godot's per-peer clock only after an operation addressed to that peer.
  addressed=match op {Operation::Deliver{..}=>None,_=>Some(peer)};
 }
 let time=Arc::new(Mutex::new(0u64));let origin=web_time::Instant::now();
 let mut sessions=Vec::new();let mut buffers=Vec::new();let mut games=Vec::new();
 for machine in 0..machines {
  let clock=time.clone();let protocol=ProtocolConfig{clock:Some(Arc::new(move||origin+Duration::from_micros(*clock.lock().unwrap()))),
   protocol_rng_seed:Some(1701+machine as u64),quality_report_interval:Duration::from_micros(scenario.lifecycle.as_ref().map_or(100000000,|l|l.quality_us)),..Default::default()};
  let sync=SyncConfig{num_sync_packets:1,keepalive_interval:Duration::from_micros(scenario.lifecycle.as_ref().map_or(100000000,|l|l.keepalive_us)),..Default::default()};
  let mut builder=SessionBuilder::<OracleConfig>::new().with_num_players(scenario.players).map_err(|e|format!("{e:?}"))?
   .with_input_queue_config(InputQueueConfig{queue_length:capacity})
   .with_max_prediction_window(scenario.max_prediction).with_input_delay(scenario.input_delay).map_err(|e|format!("{e:?}"))?
   .with_protocol_config(protocol).with_sync_config(sync);
  if let Some(l)=&scenario.lifecycle {builder=builder.with_disconnect_timeout(Duration::from_micros(l.timeout_us))
   .with_disconnect_notify_delay(Duration::from_micros(l.notify_us))
   .with_desync_detection_mode(if l.checksum_interval==0{DesyncDetection::Off}else{DesyncDetection::On{interval:l.checksum_interval}});}
  else {builder=builder.with_disconnect_timeout(Duration::from_secs(100)).with_disconnect_notify_delay(Duration::from_secs(50));}
  for slot in 0..scenario.players {builder=builder.add_player(if owner[slot]==machine {PlayerType::Local}else{PlayerType::Remote(owner[slot].to_string())},slot.into()).unwrap();}
  let queue=Arc::new(Mutex::new(Buffers::default()));sessions.push(builder.start_p2p_session(Socket(queue.clone())).unwrap());buffers.push(queue);
  let mut game=Game{frame:0,accumulators:vec![0;scenario.players],version:2,rng:8173,pending:0};
  if scenario.lifecycle.as_ref().is_some_and(|l|l.divergent_peer==machine as i32){game.accumulators[0]=1;}games.push(game);
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
 let mut references=MeshReferences::new(&slots_of);
 for (index,op) in scenario.operations.iter().enumerate(){
  // Step and poll operations address one local slot; the driven session is the owning
  // machine's. Deliveries address the destination machine directly.
  let (peer,now)=match op {Operation::Step{peer,now_us,..}|Operation::Poll{peer,now_us}=>(owner[*peer],*now_us),
   Operation::Delay{peer,..}=>(*peer,*time.lock().unwrap()),
   Operation::Deliver{packet,now_us}=>{let (sender,destination,message)=packets.get(*packet).ok_or("unknown observed packet")?;
    let raw=serde_json::to_value(message).map_err(|e|format!("{e:?}"))?;
    references.deliver(*sender,*destination,&raw);
    buffers[*destination].lock().unwrap().incoming.push((sender.to_string(),message.clone()));(*destination,*now_us)}};
  *time.lock().unwrap()=now;let before=sessions[peer].current_frame().as_i32();let pre_state=hex(&games[peer].bytes());
  let pre_confirmed=sessions[peer].confirmed_frame().as_i32();let mut requests=Vec::new();let mut error=None;
  match op {Operation::Step{peer:slot,bytes,..}=>{
   error=sessions[peer].add_local_input(PlayerHandle::new(*slot),input_bytes(bytes)?).err().map(|e|format!("{e:?}"));
   if error.is_none(){(requests,error)=apply(&mut sessions[peer],&mut games[peer])?;}
  },Operation::Delay{delay,..}=>{error=sessions[peer].set_input_delay(PlayerHandle::new(peer),*delay).err().map(delay_error);},
  _=>sessions[peer].poll_remote_clients()}
  let mut outgoing=Vec::new();
  for (destination,message) in std::mem::take(&mut buffers[peer].lock().unwrap().outgoing){
   let destination=destination.parse::<usize>().unwrap();let raw=serde_json::to_value(&message).unwrap();
   let semantic=project_packet(&raw,peer,destination,&mut references,&slots_of)?;
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
/// Validated packet endpoints; a hostile machine index fails the replay cleanly.
fn packet_endpoints(packet:&Value,slots_of:&[Vec<usize>])->Result<(usize,usize),String>{
 let from=packet["from"].as_u64().ok_or("from")? as usize;
 let to=packet["to"].as_u64().ok_or("to")? as usize;
 if from>=slots_of.len()||to>=slots_of.len() {return Err("packet machine bounds".into());}
 Ok((from,to))}
fn main(){let result=(||{let mut input=String::new();io::stdin().take(4000001).read_to_string(&mut input).map_err(|e|e.to_string())?;
 if input.len()>4000000{return Err("input bounds".into());}let value:Value=serde_json::from_str(&input).map_err(|e|e.to_string())?;
 if std::env::args().skip(1).collect::<Vec<_>>()==vec!["--validate-trace"] {
  let scenario_players=value["scenario"]["players"].as_u64().ok_or("players")? as usize;
   let scenario_layout=value["scenario"].get("layout").and_then(|l|serde_json::from_value::<Vec<usize>>(l.clone()).ok());
   // Mirror the scenario grammar so a trace replayed against a wrong or hostile layout fails
   // cleanly instead of indexing a missing machine.
   if let Some(sizes)=&scenario_layout {if sizes.is_empty()||sizes.iter().any(|size|*size==0)||sizes.iter().sum::<usize>()!=scenario_players
    ||sizes.len()<2 {return Err("layout bounds".into());}}
   let slots_of=slots_of(scenario_players,&scenario_layout);
   let mut references=MeshReferences::new(&slots_of);let packets=value["packets"].as_array().ok_or("packets")?;
  let operations=value["scenario"]["operations"].as_array().ok_or("operations")?;
  let records=value["records"].as_array().ok_or("records")?;
  if operations.len()!=records.len() {return Err("operation bounds".into());}
  let mut visited=vec![false;packets.len()];
  for (index,op) in operations.iter().enumerate() {
   if op["kind"]=="deliver" {let id=op["packet"].as_u64().ok_or("packet")? as usize;
    let packet=packets.get(id).ok_or("unknown observed packet")?;
    let (from,to)=packet_endpoints(packet,&slots_of)?;
    references.deliver(from,to,&packet["raw"]);}
   for id in records[index]["outgoing"].as_array().ok_or("outgoing")? {
    let packet_id=id.as_u64().ok_or("id")? as usize;
    if packet_id>=packets.len() {return Err("unknown observed packet".into());}
    if visited[packet_id] {return Err("packet observed twice".into());}
    visited[packet_id]=true;
    let packet=&packets[packet_id];
    let raw=&packet["raw"];let _:Message=serde_json::from_value(raw.clone()).map_err(|e|e.to_string())?;
    let (from,to)=packet_endpoints(packet,&slots_of)?;
    let semantic=project_packet(raw,from,to,&mut references,&slots_of)?;
    if semantic!=packet["semantic"] {return Err("raw compressed semantic mismatch".into());}
   }
  }
  if visited.iter().any(|visited|!visited) {return Err("packet outside every operation outgoing".into());}
  Ok(json!({"complete":true,"packets":packets.len()}))
 }else if std::env::args().len()==1 {run(value,false)}
 else if std::env::args().skip(1).collect::<Vec<_>>()==vec!["--profile-audit"] {run(value,true)}
 else{return Err("unknown argument".into());}})();
 match result{Ok(v)=>println!("{v}"),Err(e)=>{eprintln!("p2p oracle: {e}");std::process::exit(2);}}}
