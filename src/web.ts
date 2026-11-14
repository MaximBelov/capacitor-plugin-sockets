import { WebPlugin } from '@capacitor/core';

import type { SocketsPlugin } from './definitions';

export class SocketsWeb extends WebPlugin implements SocketsPlugin {
  async echo(options: { value: string }): Promise<{ value: string }> {
    console.log('ECHO', options);
    return options;
  }
}
