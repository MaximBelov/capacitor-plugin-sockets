import { WebPlugin } from '@capacitor/core';

import type { CreateResult, GetSocketsResult, SendResult, SocketInfo, SocketsPlugin } from './definitions';

/** A browser has no raw TCP or UDP sockets: every call rejects with Capacitor's `UNAVAILABLE`. */
export class SocketsWeb extends WebPlugin implements SocketsPlugin {
  private fail(): never {
    throw this.unavailable('Raw TCP and UDP sockets are not available on the web.');
  }

  async create(): Promise<CreateResult> {
    this.fail();
  }

  async connect(): Promise<void> {
    this.fail();
  }

  async disconnect(): Promise<void> {
    this.fail();
  }

  async bind(): Promise<void> {
    this.fail();
  }

  async send(): Promise<SendResult> {
    this.fail();
  }

  async setBroadcast(): Promise<void> {
    this.fail();
  }

  async close(): Promise<void> {
    this.fail();
  }

  async closeAll(): Promise<void> {
    this.fail();
  }

  async getInfo(): Promise<SocketInfo> {
    this.fail();
  }

  async getSockets(): Promise<GetSocketsResult> {
    this.fail();
  }
}
