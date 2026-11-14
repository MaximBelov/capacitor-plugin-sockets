import { registerPlugin } from '@capacitor/core';

import type { SocketsPlugin } from './definitions';

const Sockets = registerPlugin<SocketsPlugin>('Sockets', {
  web: () => import('./web').then((m) => new m.SocketsWeb()),
});

export * from './definitions';
export * from './encoding';
export { Sockets };
