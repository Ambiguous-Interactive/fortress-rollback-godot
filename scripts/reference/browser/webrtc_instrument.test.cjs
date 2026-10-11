// Value: constructor tracking charges orphan connections that never create a data channel.
const assert = require('node:assert/strict');
const test = require('node:test');
const { instrument } = require('./webrtc.cjs');

test('all constructed peer connections must close, including channel-free orphans', () => {
  class Connection {
    constructor() { this.connectionState = 'new'; this.iceConnectionState = 'new'; this.channels = []; }
    addEventListener() {}
    createDataChannel(label, options) {
      const channel = { label, ...options, readyState: 'open', maxPacketLifeTime: null, maxRetransmits: null,
        addEventListener() {}, send() {} };
      this.channels.push(channel);
      return channel;
    }
    close() { this.connectionState = 'closed'; this.channels.forEach(channel => { channel.readyState = 'closed'; }); }
  }
  global.RTCPeerConnection = Connection;
  global.window = { RTCPeerConnection: Connection };
  try {
    instrument({ endpoint: 'wss://localhost', count: 2, index: 0, faults: false, corrupt: false, defaultFactory: false });
    const used = new window.RTCPeerConnection();
    const orphan = new window.RTCPeerConnection();
    used.createDataChannel('unreliable', { id: 3, negotiated: true, ordered: false });
    assert.equal(window.fortressResources.connections.length, 2);
    assert.equal(window.fortressResources.channels.length, 1);
    used.close();
    assert.equal(window.fortressResources.connections.every(connection => connection.connectionState === 'closed'), false);
    orphan.close();
    assert.equal(window.fortressResources.connections.every(connection => connection.connectionState === 'closed'), true);
  } finally {
    delete global.window;
    delete global.RTCPeerConnection;
  }
});
