/** The UTF-16 index in `text` of UTF-8 byte offset `byte`. */
export function utf16Index(text: string, byte: number): number {
  let bytes = 0;
  let i = 0;
  while (i < text.length && bytes < byte) {
    const c = text.codePointAt(i) ?? 0;
    bytes += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
    i += c < 0x10000 ? 1 : 2;
  }
  return i;
}
