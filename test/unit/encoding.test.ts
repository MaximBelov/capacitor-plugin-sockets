import { describe, expect, it } from 'vitest';

import { base64ToBytes, base64ToText, bytesToBase64, textToBase64 } from '../../src';

describe('encoding', () => {
  it('round-trips every byte value', () => {
    const all = new Uint8Array(256).map((_, i) => i);
    expect(base64ToBytes(bytesToBase64(all))).toEqual(all);
  });

  it('takes an ArrayBuffer, a typed array and a view onto part of a buffer', () => {
    const buffer = new Uint8Array([0x50, 0x70, 0x21]).buffer;
    expect(bytesToBase64(buffer)).toBe('UHAh');
    expect(bytesToBase64(new Uint8Array(buffer))).toBe('UHAh');
    expect(bytesToBase64(new Uint8Array(buffer, 1, 1))).toBe('cA==');
    expect(bytesToBase64(new DataView(buffer, 0, 1))).toBe('UA==');
  });

  it('encodes the HR5 keepalive reply as the single byte p', () => {
    expect(base64ToBytes(textToBase64('p'))).toEqual(new Uint8Array([0x70]));
  });

  it('keeps line endings and whitespace: nothing is trimmed', () => {
    expect(base64ToText(textToBase64(' [!]\r\n'))).toBe(' [!]\r\n');
  });

  it('encodes text as UTF-8', () => {
    expect(base64ToBytes(textToBase64('é'))).toEqual(new Uint8Array([0xc3, 0xa9]));
    expect(base64ToText(textToBase64('Mère'))).toBe('Mère');
  });

  it('handles payloads larger than one chunk of String.fromCharCode', () => {
    const big = new Uint8Array(100_000).map((_, i) => i % 251);
    expect(base64ToBytes(bytesToBase64(big))).toEqual(big);
  });

  it('encodes nothing as an empty string', () => {
    expect(bytesToBase64(new Uint8Array(0))).toBe('');
    expect(base64ToBytes('')).toEqual(new Uint8Array(0));
  });
});
