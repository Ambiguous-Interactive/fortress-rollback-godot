"""Keep the v3 delivery stamp through the staged SDK and relay queue."""


def replace_once(path, anchor, replacement):
    body = path.read_text(encoding='utf-8')
    if body.count(anchor) != 1:
        raise ValueError(f'relay trace anchor changed in {path.name}')
    path.write_text(body.replace(anchor, replacement), encoding='utf-8')


def instrument_relay_delivery(project):
    sdk = project / 'addons/signal_fish'
    decoder = sdk / 'protocol/sf_binary_frames.gd'
    replace_once(decoder, '\tresult["ok"] = true\n', '''\tif is_v3:
\t\tresult["fortress_trace_stamp"] = [fields["epoch"], fields["seq"]]
\tresult["ok"] = true
''')
    client = sdk / 'signal_fish_client.gd'
    emit = 'game_data_binary_received.emit(from_player, frame_encoding, frame_payload)'
    body = client.read_text(encoding='utf-8')
    # Addressed carriers moved delivery into a top-level handler. Its successful
    # decode already enforced capability and route before exposing the payload.
    addressed = '\n\t' + emit + '\n' in body
    if addressed and '\n\tvar allow_addressed :=' not in body:
        raise ValueError(f'relay trace carrier anchor changed in {client.name}')
    indent = '\t' if addressed else '\t\t'
    anchor = '\n' + indent + emit + '\n'
    lines = [
        'var trace_stamp: Array = frame.get("fortress_trace_stamp", [])',
        'if trace_stamp.size() == 2:',
        '\ttrace_stamp.append(allow_addressed and payload[0] == 1)' if addressed else '\ttrace_stamp.append(false)',
        'set_meta("fortress_trace_stamp", trace_stamp)',
        'if trace_stamp.size() == 3 and frame_payload.size() >= 85 and frame_payload.decode_u32(0) == 0x31525346:',
        '\tif frame_payload.slice(37, 53).hex_encode() == _player_id.replace("-", ""):',
        '\t\tvar trace: JavaScriptObject = JavaScriptBridge.get_interface("fortressNativeRelayTrace")',
        '\t\ttrace.recordEngine("sdk", from_player, frame_payload.hex_encode(),',
        '\t\t\ttrace_stamp[0], str(trace_stamp[1]), null, trace_stamp[2])',
        emit,
        'remove_meta("fortress_trace_stamp")',
    ]
    replace_once(client, anchor, '\n' + '\n'.join(indent + line for line in lines) + '\n')

    relay = project / 'addons/fortress_rollback/transport/signalfish_relay.gd'
    replace_once(relay, '\tvar payload: PackedByteArray\n', '\tvar payload: PackedByteArray\n\tvar trace_stamp: Array\n')
    replace_once(relay, '\t_received.append(Incoming.new(from_uuid, bytes.slice(Envelope.HEADER_BYTES)))', '''\tvar incoming: Incoming = Incoming.new(
\t\tfrom_uuid, bytes.slice(Envelope.HEADER_BYTES)
\t)
\tvar trace_client: Object = _client.get_ref()
\tincoming.trace_stamp = trace_client.get_meta("fortress_trace_stamp", [])
\t_received.append(incoming)''')
    receive = '\t\t\tresult.peer_code = _receive_packet.call(incoming.sender, incoming.payload.duplicate())'
    replace_once(relay, receive, receive + '''
\t\t\tif incoming.trace_stamp.size() == 3:
\t\t\t\tvar trace: JavaScriptObject = JavaScriptBridge.get_interface("fortressNativeRelayTrace")
\t\t\t\ttrace.recordEngine("native", incoming.sender, incoming.payload.hex_encode(),
\t\t\t\t\tincoming.trace_stamp[0], str(incoming.trace_stamp[1]), result.peer_code, incoming.trace_stamp[2])
'''.rstrip())
