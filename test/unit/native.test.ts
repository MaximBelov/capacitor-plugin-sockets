import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

import type { SocketsPlugin } from '../../src';

// What the native side of Capacitor injects into the web view: a bridge object that makes the platform 'android', the
// headers of the installed plugins, and nativePromise, which every promise method of a plugin goes through.
const methods = [
  'create',
  'connect',
  'disconnect',
  'bind',
  'send',
  'setBroadcast',
  'close',
  'closeAll',
  'getInfo',
  'getSockets',
];
const nativePromise = vi.fn<(...args: unknown[]) => Promise<unknown>>(async () => undefined);
const g = globalThis as Record<string, unknown>;

let Sockets: SocketsPlugin;

beforeAll(async () => {
  g.androidBridge = {};
  g.Capacitor = {
    PluginHeaders: [{ name: 'Sockets', methods: methods.map((name) => ({ name, rtype: 'promise' })) }],
    nativePromise,
  };
  ({ Sockets } = await import('../../src'));
});

afterAll(() => {
  delete g.androidBridge;
  delete g.Capacitor;
});

describe('on a native platform', () => {
  it('sends each call with its options to the native plugin named Sockets', async () => {
    nativePromise.mockResolvedValueOnce({ socketId: 7 });
    await expect(Sockets.create({ protocol: 'udp' })).resolves.toEqual({ socketId: 7 });
    expect(nativePromise).toHaveBeenLastCalledWith('Sockets', 'create', { protocol: 'udp' });

    await Sockets.bind({ socketId: 7, address: '0.0.0.0', port: 15000 });
    expect(nativePromise).toHaveBeenLastCalledWith('Sockets', 'bind', { socketId: 7, address: '0.0.0.0', port: 15000 });

    await Sockets.send({ socketId: 7, data: 'cA==', address: '192.168.4.1', port: 15000 });
    expect(nativePromise).toHaveBeenLastCalledWith('Sockets', 'send', {
      socketId: 7,
      data: 'cA==',
      address: '192.168.4.1',
      port: 15000,
    });
  });

  it('passes on what the native side rejects with, code included', async () => {
    nativePromise.mockRejectedValueOnce(Object.assign(new Error('Connection refused'), { code: 'REFUSED' }));
    await expect(Sockets.connect({ socketId: 1, address: '192.168.4.1', port: 15001 })).rejects.toMatchObject({
      code: 'REFUSED',
    });
  });

  it('reaches every method of the API', async () => {
    for (const method of methods) {
      nativePromise.mockClear();
      await (Sockets as unknown as Record<string, (o?: unknown) => Promise<unknown>>)[method]({ socketId: 1 });
      expect(nativePromise).toHaveBeenCalledWith('Sockets', method, expect.anything());
    }
  });
});
