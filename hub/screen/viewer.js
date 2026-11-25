import RFB from './assets/core/rfb.js';

const status = document.querySelector('#status');
const take = document.querySelector('#take');
const release = document.querySelector('#release');
const keyboard = document.querySelector('#keyboard');
const text = document.querySelector('#text');
const endpoint = new URL('screen/ws', location.href);
endpoint.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
endpoint.searchParams.set('ticket', document.body.dataset.ticket);
delete document.body.dataset.ticket;

const socket = new WebSocket(endpoint);
socket.binaryType = 'arraybuffer';
let connected = false;
let ownsControl = false;
let pending = false;
let failure = '';

function update() {
  take.disabled = !connected || ownsControl || pending;
  release.disabled = !connected || !ownsControl || pending;
  keyboard.hidden = !connected || !ownsControl;
  if (client) client.viewOnly = !ownsControl;
  status.textContent = failure || (connected ? (ownsControl ? 'You have control' : 'Watching Hermes') : 'Connecting…');
}

const channel = {
  binaryType: 'arraybuffer', protocol: '', onopen: null, onmessage: null, onclose: null, onerror: null,
  get readyState() { return socket.readyState; },
  send(data) { socket.send(data); },
  close() { socket.close(1000); }
};
const client = new RFB(document.querySelector('#display'), channel, { shared: true });
client.viewOnly = true;
client.scaleViewport = true;
client.resizeSession = false;
client.addEventListener('connect', () => { connected = true; update(); });

socket.addEventListener('open', event => channel.onopen?.(event));
socket.addEventListener('error', event => channel.onerror?.(event));
socket.addEventListener('close', event => {
  connected = false;
  ownsControl = false;
  failure ||= event.code === 4000 ? 'Control was taken in another viewer. Reconnect to watch.' : 'Disconnected. Tap Reconnect to open a new stream.';
  channel.onclose?.(event);
  update();
});
socket.addEventListener('message', event => {
  if (typeof event.data !== 'string') {
    channel.onmessage?.(event);
    return;
  }
  const message = JSON.parse(event.data);
  if (typeof message.controls === 'boolean') ownsControl = message.controls;
  if (message.error) failure = message.error;
  if (message.reply) pending = false;
  update();
});

function changeControl(action) {
  if (!connected || pending) return;
  pending = true;
  failure = '';
  socket.send(JSON.stringify({ action }));
  update();
}

take.onclick = () => changeControl('take');
release.onclick = () => changeControl('release');
document.querySelector('#enter').onclick = () => client.sendKey(0xff0d, 'Enter');
keyboard.addEventListener('submit', event => {
  event.preventDefault();
  if (!ownsControl) return;
  for (const character of text.value) {
    const code = character.codePointAt(0);
    client.sendKey(code > 255 ? 0x01000000 | code : code);
  }
  text.value = '';
});
window.addEventListener('pagehide', () => socket.close(1000));
