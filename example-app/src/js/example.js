import { Sockets, base64ToText, textToBase64 } from 'capacitor-sockets';

// Each test writes its verdict into #result as `<name>: PASS` or `<name>: FAIL <why>`, and into window.socketsResults,
// so a person can read it and a script can poll it.
window.socketsResults = {};
const log = (line) => (document.getElementById('log').textContent += `${line}\n`);
const verdict = (name, error) => {
  window.socketsResults[name] = error ? `FAIL ${error}` : 'PASS';
  document.getElementById('result').textContent = Object.entries(window.socketsResults)
    .map(([key, value]) => `${key}: ${value}`)
    .join('\n');
};

const received = [];
Sockets.addListener('receive', (event) => {
  received.push(event);
  log(`receive ${event.protocol}#${event.socketId} from ${event.remoteAddress}:${event.remotePort} ${JSON.stringify(base64ToText(event.data))}`);
});
Sockets.addListener('receiveError', (event) => log(`receiveError ${event.protocol}#${event.socketId} ${event.code} ${event.message}`));

const waitFor = async (predicate, ms = 5000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const hit = received.find(predicate);
    if (hit) return hit;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error('timed out waiting for data');
};

// The keepalive of a Gallagher HR5 reader, played between two sockets: `P` in, the single byte `p` back.
async function udpTest() {
  const ids = [];
  try {
    const { socketId: app } = await Sockets.create({ protocol: 'udp' });
    const { socketId: reader } = await Sockets.create({ protocol: 'udp' });
    ids.push(app, reader);
    await Sockets.bind({ socketId: app, address: '0.0.0.0', port: 0 });
    await Sockets.bind({ socketId: reader, address: '127.0.0.1', port: 0 });
    const { localPort } = await Sockets.getInfo({ socketId: app });
    await Sockets.setBroadcast({ socketId: app, enabled: true });
    await Sockets.send({ socketId: reader, data: textToBase64('P'), address: '127.0.0.1', port: localPort });
    const ping = await waitFor((e) => e.socketId === app);
    await Sockets.send({ socketId: app, data: textToBase64('p'), address: ping.remoteAddress, port: ping.remotePort });
    const pong = await waitFor((e) => e.socketId === reader);
    if (base64ToText(pong.data) !== 'p' || pong.remotePort !== localPort) throw new Error(`unexpected reply ${JSON.stringify(pong)}`);
    verdict('udp');
  } catch (error) {
    verdict('udp', error.code ?? error.message);
  } finally {
    await Promise.all(ids.map((socketId) => Sockets.close({ socketId })));
  }
}

async function tcpTest() {
  let socketId;
  try {
    ({ socketId } = await Sockets.create({ protocol: 'tcp' }));
    const address = document.getElementById('host').value;
    const port = Number(document.getElementById('port').value);
    await Sockets.connect({ socketId, address, port, timeout: 3000 });
    const { bytesSent } = await Sockets.send({ socketId, data: textToBase64('[!]\r\n') });
    let text = '';
    await waitFor((e) => {
      if (e.socketId === socketId) text += base64ToText(e.data);
      return text.length >= bytesSent;
    });
    if (text !== '[!]\r\n') throw new Error(`echo was ${JSON.stringify(text)}`);
    verdict('tcp');
  } catch (error) {
    verdict('tcp', error.code ?? error.message);
  } finally {
    if (socketId) await Sockets.close({ socketId });
  }
}

// A reload has to leave no socket behind: the native side closes them when the page starts loading.
async function reloadTest() {
  const { socketId } = await Sockets.create({ protocol: 'udp' });
  await Sockets.bind({ socketId, port: 0 });
  sessionStorage.setItem('socketsReloadPending', '1');
  location.reload();
}

async function afterReload() {
  if (!sessionStorage.getItem('socketsReloadPending')) return;
  sessionStorage.removeItem('socketsReloadPending');
  const { sockets } = await Sockets.getSockets();
  verdict('reload', sockets.length === 0 ? undefined : `${sockets.length} sockets survived the reload`);
}

document.getElementById('udp').addEventListener('click', udpTest);
document.getElementById('tcp').addEventListener('click', tcpTest);
document.getElementById('reload').addEventListener('click', reloadTest);
window.socketsTests = { udpTest, tcpTest, reloadTest };
afterReload();
