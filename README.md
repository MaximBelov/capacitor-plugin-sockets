# capacitor-plugin-sockets

TCP client and UDP sockets for Capacitor 8 apps on iOS and Android, in one plugin.

It is written for talking to devices on a local network: readers, scales and other hardware that speak a small protocol over
a TCP connection and send UDP datagrams (keepalives, discovery broadcasts) to a fixed port. It is not a TLS client and it
does not listen for TCP connections.

## Install

```bash
npm install capacitor-plugin-sockets
npx cap sync
```

Requires Capacitor 8. Android 8.0 (API 26) or newer, iOS 15 or newer. On iOS the plugin is a Swift package; CocoaPods
works too. There is no web implementation: a browser has no raw sockets, so every call rejects with `UNAVAILABLE`.

On iOS, an app that reaches devices on the local network needs `NSLocalNetworkUsageDescription` in its `Info.plist`;
without it iOS refuses the traffic and raises no prompt.

## Use

```typescript
import { Sockets, base64ToText, textToBase64 } from 'capacitor-plugin-sockets';

// UDP: listen on a port and answer a keepalive from the port it came from.
const { socketId: udp } = await Sockets.create({ protocol: 'udp' });
await Sockets.bind({ socketId: udp, address: '0.0.0.0', port: 15000 });
await Sockets.addListener('receive', async (event) => {
  if (event.socketId === udp && base64ToText(event.data) === 'P') {
    await Sockets.send({ socketId: udp, data: textToBase64('p'), address: event.remoteAddress, port: event.remotePort });
  }
});

// TCP: connect, send a line, read what comes back on the same `receive` event.
const { socketId: tcp } = await Sockets.create({ protocol: 'tcp' });
await Sockets.connect({ socketId: tcp, address: '192.168.4.1', port: 15001, timeout: 5000 });
await Sockets.send({ socketId: tcp, data: textToBase64('!\r\n') });
```

### Bytes are base64

The bridge between the web view and native code carries JSON, so bytes cross it as base64: `send` takes `data` as a base64
string and the `receive` event delivers one. Base64 costs a third more than the bytes and both platforms encode and decode it
natively; an array of numbers would cost three to four times as much and a parse per byte. The package exports
`bytesToBase64`, `base64ToBytes`, `textToBase64` and `base64ToText` (UTF-8) for the conversions. Nothing is trimmed: a line
ending the device sends arrives as it was sent.

### A TCP stream arrives in chunks

A `receive` event for a TCP socket is whatever the operating system had ready: part of a line, or several lines. Split the
stream into messages yourself. A UDP `receive` event is always one whole datagram.

### Errors

A rejected call carries a `code` (`SocketErrorCode`): `CLOSED_BY_PEER`, `TIMED_OUT`, `REFUSED`, `UNREACHABLE`,
`NOT_CONNECTED`, `INVALID_SOCKET`, `INVALID_ARGUMENT` or `IO`. A failure that happens while no call is waiting (the peer closes
the connection, a read fails) arrives as a `receiveError` event with the same codes. A TCP socket whose peer closed is
disconnected; `connect` can be called on it again.

### Sockets do not outlive the page

The native side closes every socket when the web view starts loading a page (a reload, a live update that swaps the web
bundle, any navigation) and when the plugin is destroyed. A new page therefore never inherits a connection it cannot see,
and there is no need to list and close leftover sockets at start-up. `removeAllListeners()` called from JavaScript removes
listeners only and closes nothing.

### Android: sockets follow the process network

An app that joins a device's own Wi-Fi network (one with no internet behind it) usually binds the whole process to it with
`ConnectivityManager.bindProcessToNetwork`, so that traffic goes there instead of to mobile data. That binding reaches only
sockets made after it. The plugin therefore binds each socket to `getBoundNetworkForProcess()` itself: a TCP socket when it
connects, a UDP socket when it binds, and a UDP socket again before a send whenever the process has since been bound to a
different network. Without that, a UDP socket made before the join keeps sending on the old network and every send fails
with "Network is unreachable". When the process is not bound to any network, sockets use the default network as usual.

### Details that differ from Chrome Apps sockets

The API keeps the shape of `chrome.sockets.tcp` and `chrome.sockets.udp` (ids, `create`, `connect`, `bind`, `send`,
`getSockets`), merged into one plugin with a `protocol` on each socket. UDP sockets are IPv4 and are bound with
`SO_REUSEADDR`. A TCP connect gives up after `timeout` (5 seconds unless given). A UDP socket that sends before it is bound
is bound to a free port and delivers replies to that port.

## Development

- `npm test` runs the TypeScript unit tests, `npm run test:parity` checks that both platforms implement exactly the API.
- `npm run test:android` runs the JVM tests: the socket registry against real TCP and UDP sockets on 127.0.0.1.
- `npm run test:ios:core` runs the Swift socket core on a Mac (`swift test`); `npm run test:ios` runs it and the plugin
  tests on an iOS simulator.
- `example-app/` is a self-test page: a UDP ping and reply between two sockets, a TCP round trip to an echo server, and a
  reload that must leave no socket open.

## API

<docgen-index>

* [`create(...)`](#create)
* [`connect(...)`](#connect)
* [`disconnect(...)`](#disconnect)
* [`bind(...)`](#bind)
* [`send(...)`](#send)
* [`setBroadcast(...)`](#setbroadcast)
* [`close(...)`](#close)
* [`closeAll()`](#closeall)
* [`getInfo(...)`](#getinfo)
* [`getSockets()`](#getsockets)
* [`addListener('receive', ...)`](#addlistenerreceive-)
* [`addListener('receiveError', ...)`](#addlistenerreceiveerror-)
* [`removeAllListeners()`](#removealllisteners)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

TCP client and UDP sockets.

Every socket is closed by the native side when the web view navigates (a reload, a live update) and when the plugin
is destroyed, so a new page never inherits sockets it cannot see.

On Android, a socket is bound to the network the process is bound to (`ConnectivityManager.bindProcessToNetwork`)
when it opens, and a UDP socket is bound again before a send if the process has since been bound to another network.

### create(...)

```typescript
create(options: CreateOptions) => Promise<CreateResult>
```

Creates a socket. A TCP socket opens a connection on `connect`; a UDP socket can `bind` and `send`.

| Param         | Type                                                    |
| ------------- | ------------------------------------------------------- |
| **`options`** | <code><a href="#createoptions">CreateOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#createresult">CreateResult</a>&gt;</code>

--------------------


### connect(...)

```typescript
connect(options: ConnectOptions) => Promise<void>
```

TCP: opens a connection. Resolves once it is established. A socket that was disconnected can connect again.

| Param         | Type                                                      |
| ------------- | --------------------------------------------------------- |
| **`options`** | <code><a href="#connectoptions">ConnectOptions</a></code> |

--------------------


### disconnect(...)

```typescript
disconnect(options: SocketIdOptions) => Promise<void>
```

TCP: closes the connection and keeps the socket id, so `connect` can be called again.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#socketidoptions">SocketIdOptions</a></code> |

--------------------


### bind(...)

```typescript
bind(options: BindOptions) => Promise<void>
```

UDP: binds to a local port and starts delivering `receive` events. The address is reusable (`SO_REUSEADDR`).

| Param         | Type                                                |
| ------------- | --------------------------------------------------- |
| **`options`** | <code><a href="#bindoptions">BindOptions</a></code> |

--------------------


### send(...)

```typescript
send(options: SendOptions) => Promise<SendResult>
```

Sends bytes: on the connection for TCP, as one datagram to `address`:`port` for UDP.

| Param         | Type                                                |
| ------------- | --------------------------------------------------- |
| **`options`** | <code><a href="#sendoptions">SendOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#sendresult">SendResult</a>&gt;</code>

--------------------


### setBroadcast(...)

```typescript
setBroadcast(options: SetBroadcastOptions) => Promise<void>
```

UDP: allows or forbids sending to a broadcast address (`SO_BROADCAST`).

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#setbroadcastoptions">SetBroadcastOptions</a></code> |

--------------------


### close(...)

```typescript
close(options: SocketIdOptions) => Promise<void>
```

Closes the socket and forgets its id. Closing an id that does not exist resolves.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#socketidoptions">SocketIdOptions</a></code> |

--------------------


### closeAll()

```typescript
closeAll() => Promise<void>
```

Closes every socket.

--------------------


### getInfo(...)

```typescript
getInfo(options: SocketIdOptions) => Promise<SocketInfo>
```

Describes one socket. Rejects with `INVALID_SOCKET` for an unknown id.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#socketidoptions">SocketIdOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#socketinfo">SocketInfo</a>&gt;</code>

--------------------


### getSockets()

```typescript
getSockets() => Promise<GetSocketsResult>
```

Describes every open socket.

**Returns:** <code>Promise&lt;<a href="#getsocketsresult">GetSocketsResult</a>&gt;</code>

--------------------


### addListener('receive', ...)

```typescript
addListener(eventName: 'receive', listenerFunc: (event: ReceiveEvent) => void) => Promise<PluginListenerHandle>
```

Bytes arrived on a socket: a chunk of a TCP stream, or one UDP datagram.

| Param              | Type                                                                      |
| ------------------ | ------------------------------------------------------------------------- |
| **`eventName`**    | <code>'receive'</code>                                                    |
| **`listenerFunc`** | <code>(event: <a href="#receiveevent">ReceiveEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### addListener('receiveError', ...)

```typescript
addListener(eventName: 'receiveError', listenerFunc: (event: ReceiveErrorEvent) => void) => Promise<PluginListenerHandle>
```

A socket failed while nobody was waiting on a call: the peer closed the connection, or a read failed.

| Param              | Type                                                                                |
| ------------------ | ----------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'receiveError'</code>                                                         |
| **`listenerFunc`** | <code>(event: <a href="#receiveerrorevent">ReceiveErrorEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

Removes every listener. It does not close any socket.

--------------------


### Interfaces


#### CreateResult

| Prop           | Type                |
| -------------- | ------------------- |
| **`socketId`** | <code>number</code> |


#### CreateOptions

| Prop             | Type                                                      | Description                                                                             | Default                                   |
| ---------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------- |
| **`protocol`**   | <code><a href="#socketprotocol">SocketProtocol</a></code> | `tcp` for a client connection, `udp` for datagrams.                                     |                                           |
| **`bufferSize`** | <code>number</code>                                       | The largest chunk read at once, in bytes. A UDP datagram larger than this is truncated. | <code>32768 for tcp, 65535 for udp</code> |
| **`name`**       | <code>string</code>                                       | A free-form label, returned by `getInfo` and `getSockets`.                              |                                           |


#### ConnectOptions

| Prop           | Type                | Description                                           | Default           |
| -------------- | ------------------- | ----------------------------------------------------- | ----------------- |
| **`socketId`** | <code>number</code> |                                                       |                   |
| **`address`**  | <code>string</code> | A host name or an IP address.                         |                   |
| **`port`**     | <code>number</code> |                                                       |                   |
| **`timeout`**  | <code>number</code> | How long to wait for the connection, in milliseconds. | <code>5000</code> |


#### SocketIdOptions

| Prop           | Type                |
| -------------- | ------------------- |
| **`socketId`** | <code>number</code> |


#### BindOptions

| Prop           | Type                | Description                           | Default                |
| -------------- | ------------------- | ------------------------------------- | ---------------------- |
| **`socketId`** | <code>number</code> |                                       |                        |
| **`address`**  | <code>string</code> | The local IPv4 address to bind to.    | <code>'0.0.0.0'</code> |
| **`port`**     | <code>number</code> | The local port; `0` picks a free one. |                        |


#### SendResult

| Prop            | Type                |
| --------------- | ------------------- |
| **`bytesSent`** | <code>number</code> |


#### SendOptions

| Prop           | Type                | Description                                                                    |
| -------------- | ------------------- | ------------------------------------------------------------------------------ |
| **`socketId`** | <code>number</code> |                                                                                |
| **`data`**     | <code>string</code> | The bytes to send, base64 encoded. `bytesToBase64` and `textToBase64` make it. |
| **`address`**  | <code>string</code> | UDP only: the IPv4 address (or host name) to send the datagram to.             |
| **`port`**     | <code>number</code> | UDP only: the port to send the datagram to.                                    |


#### SetBroadcastOptions

| Prop           | Type                 |
| -------------- | -------------------- |
| **`socketId`** | <code>number</code>  |
| **`enabled`**  | <code>boolean</code> |


#### SocketInfo

| Prop               | Type                                                      | Description                                                          |
| ------------------ | --------------------------------------------------------- | -------------------------------------------------------------------- |
| **`socketId`**     | <code>number</code>                                       |                                                                      |
| **`protocol`**     | <code><a href="#socketprotocol">SocketProtocol</a></code> |                                                                      |
| **`name`**         | <code>string</code>                                       |                                                                      |
| **`bufferSize`**   | <code>number</code>                                       |                                                                      |
| **`connected`**    | <code>boolean</code>                                      | TCP: a connection is open. UDP: the socket is bound to a local port. |
| **`localAddress`** | <code>string</code>                                       |                                                                      |
| **`localPort`**    | <code>number</code>                                       |                                                                      |
| **`peerAddress`**  | <code>string</code>                                       | TCP only.                                                            |
| **`peerPort`**     | <code>number</code>                                       | TCP only.                                                            |


#### GetSocketsResult

| Prop          | Type                      |
| ------------- | ------------------------- |
| **`sockets`** | <code>SocketInfo[]</code> |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### ReceiveEvent

| Prop                | Type                                                      | Description                                                                                           |
| ------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **`socketId`**      | <code>number</code>                                       |                                                                                                       |
| **`protocol`**      | <code><a href="#socketprotocol">SocketProtocol</a></code> |                                                                                                       |
| **`data`**          | <code>string</code>                                       | The bytes received, base64 encoded. `base64ToBytes` and `base64ToText` read it.                       |
| **`remoteAddress`** | <code>string</code>                                       | Who sent it: the peer of a TCP socket, the sender of a UDP datagram (an IPv4 address in dotted form). |
| **`remotePort`**    | <code>number</code>                                       |                                                                                                       |


#### ReceiveErrorEvent

| Prop           | Type                                                        |
| -------------- | ----------------------------------------------------------- |
| **`socketId`** | <code>number</code>                                         |
| **`protocol`** | <code><a href="#socketprotocol">SocketProtocol</a></code>   |
| **`code`**     | <code><a href="#socketerrorcode">SocketErrorCode</a></code> |
| **`message`**  | <code>string</code>                                         |


### Type Aliases


#### SocketProtocol

The transport of a socket, fixed when it is created.

<code>'tcp' | 'udp'</code>


#### SocketErrorCode

Why a call was rejected, or why a socket reported a `receiveError`. A rejected promise carries it as `error.code`.

- `CLOSED_BY_PEER`: the other end closed the TCP connection.
- `TIMED_OUT`: a TCP connect did not complete within its timeout.
- `REFUSED`: nothing listens on that address and port.
- `UNREACHABLE`: no route to the address, typically after the network the socket is on went away.
- `NOT_CONNECTED`: a TCP send on a socket that is not connected.
- `INVALID_SOCKET`: no socket has that id (it was closed, or never existed).
- `INVALID_ARGUMENT`: an option is missing or out of range.
- `IO`: any other operating system error; `message` says which.

<code>'CLOSED_BY_PEER' | 'TIMED_OUT' | 'REFUSED' | 'UNREACHABLE' | 'NOT_CONNECTED' | 'INVALID_SOCKET' | 'INVALID_ARGUMENT' | 'IO'</code>

</docgen-api>
