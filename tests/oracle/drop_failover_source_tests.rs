// Included in the archive candidate's P2P session test module by the oracle launcher.
#[test]
fn scoped_candidate_failover_grace() {
    use std::sync::atomic::{AtomicU64, Ordering};
    let cases = [999_999, 1_000_000, 1_000_001];
    for offset_us in cases {
        for (local, heard_us) in [(1, 0), (1, 10_000), (2, 0)] {
            let mut session = five_player_majority_session(PlayerHandle::new(local));
            let base = web_time::Instant::now();
            let elapsed = Arc::new(AtomicU64::new(0));
            let source = Arc::clone(&elapsed);
            session.protocol_config.clock = Some(Arc::new(move || {
                base + web_time::Duration::from_micros(source.load(Ordering::Relaxed))
            }));
            session.begin_coordinated_drop(PlayerHandle::new(4)).expect("begin drop");
            session.coordinated_drop.active.as_mut().unwrap().coordinator_heard_at =
                Some(base + web_time::Duration::from_micros(heard_us));
            elapsed.store(offset_us, Ordering::Relaxed);
            session.drive_coordinator_fallback();
            let acting = session.coordinated_drop.active.as_ref().unwrap().acting_coordinator;
            assert_eq!(acting, (local == 1 && heard_us == 0 && offset_us >= 1_000_000).then_some(1));
            let evidence = serde_json::json!({"offset_us":offset_us, "local":local, "heard_us":heard_us, "acting":acting});
            eprintln!("SOURCE_FAILOVER_PROBE {evidence}");
        }
    }
}

#[test]
fn scoped_candidate_failover_stale_retry() {
    use crate::network::codec;
    use crate::sessions::config::SyncConfig;

    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;

    type Mailbox = Arc<Mutex<Vec<(SocketAddr, Message)>>>;
    #[derive(Default, Clone)]
    struct Capture {
        sent: Mailbox,
        inbox: Mailbox,
    }
    impl NonBlockingSocket<SocketAddr> for Capture {
        fn send_to(&mut self, message: &Message, to: &SocketAddr) {
            self.sent.lock().unwrap().push((*to, message.clone()));
        }
        fn receive_all_messages(&mut self) -> Vec<(SocketAddr, Message)> {
            std::mem::take(&mut *self.inbox.lock().unwrap())
        }
    }

    let base = web_time::Instant::now();
    let elapsed = Arc::new(AtomicU64::new(0));
    let address = |peer: u16| test_addr(9400 + peer);
    let build = |local: u16, socket: Capture| {
        let source = Arc::clone(&elapsed);
        let mut builder = SessionBuilder::<TestConfig>::new().with_num_players(5).unwrap()
            .with_protocol_config(ProtocolConfig {
                clock: Some(Arc::new(move || base + web_time::Duration::from_micros(source.load(Ordering::Relaxed)))),
                protocol_rng_seed: Some(1701 + u64::from(local)),
                ..Default::default()
            })
            .with_sync_config(SyncConfig { num_sync_packets: 1, ..Default::default() });
        for peer in 0..5 {
            let kind = if peer == local { PlayerType::Local } else { PlayerType::Remote(address(peer)) };
            builder = builder.add_player(kind, PlayerHandle::new(usize::from(peer))).unwrap();
        }
        let mut session = builder.start_p2p_session(socket).unwrap();
        for (remote, endpoint) in &mut session.player_reg.remotes {
            if *remote != address(1 - local) {
                endpoint.force_running_for_tests();
            }
        }
        session
    };
    let leader_socket = Capture::default();
    let follower_socket = Capture::default();
    let mut leader = build(0, leader_socket.clone());
    let mut follower = build(1, follower_socket.clone());
    let route_sync = |sender: u16, from: &Capture, to: &Capture| {
        let sent = std::mem::take(&mut *from.sent.lock().unwrap());
        to.inbox.lock().unwrap().extend(sent.into_iter().filter(|(recipient, _)| *recipient == address(1 - sender))
            .map(|(_, packet)| (address(sender), packet)));
    };
    for _ in 0..7 {
        route_sync(0, &leader_socket, &follower_socket);
        route_sync(1, &follower_socket, &leader_socket);
        leader.poll_remote_clients();
        follower.poll_remote_clients();
    }
    for (session, remote) in [(&mut leader, 1), (&mut follower, 0)] {
        assert!(session.player_reg.remotes[&address(remote)].is_running());
        assert_eq!(session.current_state(), SessionState::Running);
        for status in session.local_connect_status.iter_mut().take(5) {
            *status = ConnectionStatus { disconnected: false, last_frame: Frame::new(10), epoch: 0 };
        }
    }
    let target = PlayerHandle::new(4);
    let receive = |session: &mut P2PSession<TestConfig>, packets: &[&Vec<u8>]| {
        for encoded in packets {
            let (message, used) = codec::decode_message(encoded).unwrap();
            assert_eq!(used, encoded.len());
            follower_socket.inbox.lock().unwrap().push((address(0), message));
        }
        session.poll_remote_clients();
        assert!(follower_socket.inbox.lock().unwrap().is_empty());
    };
    let sent = leader_socket.sent;
    let emit = |session: &mut P2PSession<TestConfig>| {
        sent.lock().unwrap().clear();
        session.begin_coordinated_drop(target).expect("begin the removal");
        let operation = session.coordinated_drop.active.as_ref().unwrap().operation;
        session.poll_remote_clients();
        let packets = sent.lock().unwrap();
        let addressed = packets.iter().filter(|(to, _)| *to == test_addr(9401));
        let prepare = addressed.clone().find(|(_, message)| {
            matches!(&message.body, MessageBody::DropPrepare(prepare) if prepare.operation == operation)
        }).expect("capture the actual Prepare addressed to endpoint 1");
        let inventory = addressed.into_iter().find(|(_, message)| {
            matches!(&message.body, MessageBody::DropReport(report) if report.operation == operation && report.stage == DropReportStage::Inventory)
        }).expect("capture the actual Inventory addressed to endpoint 1");
        (operation, codec::encode(&prepare.1).unwrap(), codec::encode(&inventory.1).unwrap())
    };

    let (old, old_prepare, old_inventory) = emit(&mut leader);
    receive(&mut follower, &[&old_prepare]);
    assert_eq!(follower.coordinated_drop.active.as_ref().unwrap().operation, old);
    let targets = leader.coordinated_drop.active.as_ref().unwrap().targets.clone();
    let abort = DropAbort {
        operation: old, targets, reason: DropAbortReason::Superseded, terminal_epoch: old.terminal_epoch + 1,
    };
    leader.coordinated_drop_accept_abort(abort.clone(), Some(0));
    follower.coordinated_drop_accept_abort(abort, Some(0));
    assert!(leader.coordinated_drop.active.is_none() && follower.coordinated_drop.active.is_none());

    elapsed.store(10_000, Ordering::Relaxed);
    let (retry, retry_prepare, retry_inventory) = emit(&mut leader);
    assert_eq!(retry.terminal_epoch, old.terminal_epoch + 1);
    assert_eq!(retry.sequence, old.sequence);
    assert_eq!(retry.target_set_digest, old.target_set_digest);
    assert_ne!(old_prepare, retry_prepare);
    receive(&mut follower, &[&retry_prepare, &retry_inventory]);
    let frame_state = |session: &P2PSession<TestConfig>| (session.current_frame(), session.confirmed_frame(), session.current_state());
    let before = frame_state(&follower);
    let attempt = follower.coordinated_drop.active.as_ref().unwrap();
    let cut_before = attempt.cut;
    assert_eq!(attempt.reports[&0].operation, retry, "live addressed Inventory is accepted");
    let reports_before = attempt.reports.clone();
    let coordinator_before = (attempt.coordinator_heard_at, attempt.acting_coordinator);
    follower_socket.sent.lock().unwrap().clear();
    elapsed.store(20_000, Ordering::Relaxed);
    receive(&mut follower, &[&old_prepare, &old_inventory]);
    assert!(follower_socket.sent.lock().unwrap().iter().all(|(_, packet)| !matches!(&packet.body, MessageBody::DropCommit(_))));

    let live = follower.coordinated_drop.active.as_ref().unwrap();
    assert_eq!(live.operation, retry);
    assert_eq!(live.cut, cut_before);
    assert_eq!(live.reports, reports_before);
    assert_eq!((live.coordinator_heard_at, live.acting_coordinator), coordinator_before);
    assert_eq!(frame_state(&follower), before);
    assert!(follower.coordinated_drop.certified_dropped.is_empty() && follower.coordinated_drop.committed.is_empty());
    let hex = |bytes: &[u8]| bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let evidence = serde_json::json!({
        "from":0, "to":1, "target":4, "sequence":old.sequence, "first_epoch":old.terminal_epoch, "retry_epoch":live.operation.terminal_epoch,
        "cut":live.cut.map(|frame| frame.as_i32()), "old_prepare":hex(&old_prepare), "old_inventory":hex(&old_inventory),
        "retry_prepare":hex(&retry_prepare), "retry_inventory":hex(&retry_inventory),
    });
    eprintln!("SOURCE_FAILOVER_PROBE {evidence}");
}
