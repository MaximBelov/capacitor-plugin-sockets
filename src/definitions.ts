import type { PluginListenerHandle } from '@capacitor/core';

/** The transport of a socket, fixed when it is created. */
export type SocketProtocol = 'tcp' | 'udp';

/**
 * Why a call was rejected, or why a socket reported a `receiveError`. A rejected promise carries it as `error.code`.
 *
 * - `CLOSED_BY_PEER`: the other end closed the TCP connection.
 * - `TIMED_OUT`: a TCP connect did not complete within its timeout.
 * - `REFUSED`: nothing listens on that address and port.
 * - `UNREACHABLE`: no route to the address, typically after the network the socket is on went away.
 * - `NOT_CONNECTED`: a TCP send on a socket that is not connected.
 * - `INVALID_SOCKET`: no socket has that id (it was closed, or never existed).
 * - `INVALID_ARGUMENT`: an option is missing or out of range.
 * - `IO`: any other operating system error; `message` says which.
 */
export type SocketErrorCode =
  | 'CLOSED_BY_PEER'
  | 'TIMED_OUT'
  | 'REFUSED'
  | 'UNREACHABLE'
  | 'NOT_CONNECTED'
  | 'INVALID_SOCKET'
  | 'INVALID_ARGUMENT'
  | 'IO';

export interface CreateOptions {
  /** `tcp` for a client connection, `udp` for datagrams. */
  protocol: SocketProtocol;
  /**
   * The largest chunk read at once, in bytes. A UDP datagram larger than this is truncated.
   *
   * @default 32768 for tcp, 65535 for udp
   */
  bufferSize?: number;
  /** A free-form label, returned by `getInfo` and `getSockets`. */
  name?: string;
}

export interface CreateResult {
  socketId: number;
}

export interface SocketIdOptions {
  socketId: number;
}

export interface ConnectOptions {
  socketId: number;
  /** A host name or an IP address. */
  address: string;
  port: number;
  /**
   * How long to wait for the connection, in milliseconds.
   *
   * @default 5000
   */
  timeout?: number;
}

export interface BindOptions {
  socketId: number;
  /**
   * The local IPv4 address to bind to.
   *
   * @default '0.0.0.0'
   */
  address?: string;
  /** The local port; `0` picks a free one. */
  port: number;
}

export interface SendOptions {
  socketId: number;
  /** The bytes to send, base64 encoded. `bytesToBase64` and `textToBase64` make it. */
  data: string;
  /** UDP only: the IPv4 address (or host name) to send the datagram to. */
  address?: string;
  /** UDP only: the port to send the datagram to. */
  port?: number;
}

export interface SendResult {
  bytesSent: number;
}

export interface SetBroadcastOptions {
  socketId: number;
  enabled: boolean;
}

export interface SocketInfo {
  socketId: number;
  protocol: SocketProtocol;
  name: string;
  bufferSize: number;
  /** TCP: a connection is open. UDP: the socket is bound to a local port. */
  connected: boolean;
  localAddress?: string;
  localPort?: number;
  /** TCP only. */
  peerAddress?: string;
  /** TCP only. */
  peerPort?: number;
}

export interface GetSocketsResult {
  sockets: SocketInfo[];
}

export interface ReceiveEvent {
  socketId: number;
  protocol: SocketProtocol;
  /** The bytes received, base64 encoded. `base64ToBytes` and `base64ToText` read it. */
  data: string;
  /** Who sent it: the peer of a TCP socket, the sender of a UDP datagram (an IPv4 address in dotted form). */
  remoteAddress: string;
  remotePort: number;
}

export interface ReceiveErrorEvent {
  socketId: number;
  protocol: SocketProtocol;
  code: SocketErrorCode;
  message: string;
}

/**
 * TCP client and UDP sockets.
 *
 * Every socket is closed by the native side when the web view navigates (a reload, a live update) and when the plugin
 * is destroyed, so a new page never inherits sockets it cannot see.
 *
 * On Android, a socket is bound to the network the process is bound to (`ConnectivityManager.bindProcessToNetwork`)
 * when it opens, and a UDP socket is bound again before a send if the process has since been bound to another network.
 */
export interface SocketsPlugin {
  /** Creates a socket. A TCP socket opens a connection on `connect`; a UDP socket can `bind` and `send`. */
  create(options: CreateOptions): Promise<CreateResult>;

  /** TCP: opens a connection. Resolves once it is established. A socket that was disconnected can connect again. */
  connect(options: ConnectOptions): Promise<void>;

  /** TCP: closes the connection and keeps the socket id, so `connect` can be called again. */
  disconnect(options: SocketIdOptions): Promise<void>;

  /** UDP: binds to a local port and starts delivering `receive` events. The address is reusable (`SO_REUSEADDR`). */
  bind(options: BindOptions): Promise<void>;

  /** Sends bytes: on the connection for TCP, as one datagram to `address`:`port` for UDP. */
  send(options: SendOptions): Promise<SendResult>;

  /** UDP: allows or forbids sending to a broadcast address (`SO_BROADCAST`). */
  setBroadcast(options: SetBroadcastOptions): Promise<void>;

  /** Closes the socket and forgets its id. Closing an id that does not exist resolves. */
  close(options: SocketIdOptions): Promise<void>;

  /** Closes every socket. */
  closeAll(): Promise<void>;

  /** Describes one socket. Rejects with `INVALID_SOCKET` for an unknown id. */
  getInfo(options: SocketIdOptions): Promise<SocketInfo>;

  /** Describes every open socket. */
  getSockets(): Promise<GetSocketsResult>;

  /** Bytes arrived on a socket: a chunk of a TCP stream, or one UDP datagram. */
  addListener(eventName: 'receive', listenerFunc: (event: ReceiveEvent) => void): Promise<PluginListenerHandle>;

  /** A socket failed while nobody was waiting on a call: the peer closed the connection, or a read failed. */
  addListener(
    eventName: 'receiveError',
    listenerFunc: (event: ReceiveErrorEvent) => void,
  ): Promise<PluginListenerHandle>;

  /** Removes every listener. It does not close any socket. */
  removeAllListeners(): Promise<void>;
}
