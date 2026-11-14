import { CapacitorException, ExceptionCode } from '@capacitor/core';
import { describe, expect, it } from 'vitest';

import { Sockets } from '../../src';
import { SocketsWeb } from '../../src/web';

// No native bridge on globalThis, so Capacitor reports the platform as 'web' and loads src/web.ts.
describe('on the web', () => {
  it('rejects every call with UNAVAILABLE through the registered plugin', async () => {
    await expect(Sockets.create({ protocol: 'tcp' })).rejects.toMatchObject({ code: ExceptionCode.Unavailable });
    await expect(Sockets.getSockets()).rejects.toMatchObject({ code: ExceptionCode.Unavailable });
  });

  it('rejects with a CapacitorException for each method', async () => {
    const web = new SocketsWeb();
    const calls: Promise<unknown>[] = [
      web.create({ protocol: 'udp' }),
      web.connect({ socketId: 1, address: 'a', port: 1 }),
      web.disconnect({ socketId: 1 }),
      web.bind({ socketId: 1, port: 0 }),
      web.send({ socketId: 1, data: '' }),
      web.setBroadcast({ socketId: 1, enabled: true }),
      web.close({ socketId: 1 }),
      web.closeAll(),
      web.getInfo({ socketId: 1 }),
      web.getSockets(),
    ];
    for (const call of calls) {
      expect(await call.catch((e: unknown) => e)).toBeInstanceOf(CapacitorException);
    }
  });
});
