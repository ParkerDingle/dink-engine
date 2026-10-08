/**
 * Fetch a binary asset. Hosts that won't serve some binary types (e.g. .glb, .onnx) can ship the same
 * file base64-encoded next to it as `<name>.b64.txt`; this falls back to that copy automatically.
 */
export async function fetchBinary(url: string): Promise<ArrayBuffer> {
  try {
    const r = await fetch(url);
    if (r.ok) return await r.arrayBuffer();
  } catch { /* fall through to the text copy */ }
  const t = await fetch(url + '.b64.txt');
  if (!t.ok) throw new Error(`Missing asset: ${url}`);
  const bin = atob((await t.text()).trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}
