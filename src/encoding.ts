// The bridge carries JSON, so bytes cross it base64 encoded. These turn bytes and text into the `data` the plugin takes
// and back. They use atob/btoa, which every web view and Node 16+ have.

const CHUNK = 0x8000;

/** Encodes bytes as base64, for `send`. */
export function bytesToBase64(bytes: ArrayBuffer | ArrayBufferView): string {
  const view =
    bytes instanceof ArrayBuffer
      ? new Uint8Array(bytes)
      : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let binary = '';
  for (let i = 0; i < view.length; i += CHUNK) {
    binary += String.fromCharCode(...view.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

/** Decodes the base64 `data` of a `receive` event into bytes. */
export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** Encodes text as UTF-8, then base64, for `send`. */
export function textToBase64(text: string): string {
  return bytesToBase64(new TextEncoder().encode(text));
}

/** Decodes the base64 `data` of a `receive` event as UTF-8 text. Nothing is trimmed. */
export function base64ToText(base64: string): string {
  return new TextDecoder().decode(base64ToBytes(base64));
}
