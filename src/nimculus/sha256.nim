## Small, dependency-free SHA-256 and HMAC-SHA256 implementation.
##
## The REPL wire protocol needs the raw digest as well as its hexadecimal
## spelling, so both forms are kept in the public API. Strings are treated as
## byte sequences; callers that have text should pass its UTF-8 encoding.

type
  Sha256Digest* = array[32, uint8]

const Sha256RoundConstants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

const Sha256InitialState: array[8, uint32] = [
  0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
  0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

proc rotateRight(value: uint32, amount: uint32): uint32 {.inline.} =
  (value shr amount) or (value shl (32'u32 - amount))

proc readBigEndian(data: string, offset: int): uint32 {.inline.} =
  (uint32(ord(data[offset])) shl 24) or
  (uint32(ord(data[offset + 1])) shl 16) or
  (uint32(ord(data[offset + 2])) shl 8) or
  uint32(ord(data[offset + 3]))

proc digestBytes*(digest: Sha256Digest): string =
  result = newString(digest.len)
  for index, value in digest:
    result[index] = char(value)

proc digestToHex*(digest: Sha256Digest): string =
  const digits = "0123456789abcdef"
  result = newString(digest.len * 2)
  for index, value in digest:
    result[index * 2] = digits[int(value shr 4)]
    result[index * 2 + 1] = digits[int(value and 0x0f'u8)]

proc sha256*(data: string): Sha256Digest =
  var padded = data
  padded.add(char(0x80))
  while padded.len mod 64 != 56:
    padded.add('\0')

  let bitLength = uint64(data.len) * 8'u64
  for shift in countdown(56, 0, 8):
    padded.add(char((bitLength shr uint64(shift)) and 0xff'u64))

  var state = Sha256InitialState
  for chunkStart in countup(0, padded.len - 1, 64):
    var schedule: array[64, uint32]
    for index in 0 .. 15:
      schedule[index] = readBigEndian(padded, chunkStart + index * 4)
    for index in 16 .. 63:
      let s0 = rotateRight(schedule[index - 15], 7) xor
        rotateRight(schedule[index - 15], 18) xor (schedule[index - 15] shr 3)
      let s1 = rotateRight(schedule[index - 2], 17) xor
        rotateRight(schedule[index - 2], 19) xor (schedule[index - 2] shr 10)
      schedule[index] = schedule[index - 16] + s0 + schedule[index - 7] + s1

    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for index in 0 .. 63:
      let s1 = rotateRight(e, 6) xor rotateRight(e, 11) xor rotateRight(e, 25)
      let choose = (e and f) xor ((not e) and g)
      let temporary1 = h + s1 + choose + Sha256RoundConstants[index] + schedule[index]
      let s0 = rotateRight(a, 2) xor rotateRight(a, 13) xor rotateRight(a, 22)
      let majority = (a and b) xor (a and c) xor (b and c)
      let temporary2 = s0 + majority
      h = g
      g = f
      f = e
      e = d + temporary1
      d = c
      c = b
      b = a
      a = temporary1 + temporary2
    state[0] += a
    state[1] += b
    state[2] += c
    state[3] += d
    state[4] += e
    state[5] += f
    state[6] += g
    state[7] += h

  for index, value in state:
    result[index * 4] = uint8((value shr 24) and 0xff'u32)
    result[index * 4 + 1] = uint8((value shr 16) and 0xff'u32)
    result[index * 4 + 2] = uint8((value shr 8) and 0xff'u32)
    result[index * 4 + 3] = uint8(value and 0xff'u32)

proc sha256Hex*(data: string): string =
  digestToHex(sha256(data))

proc hmacSha256*(key, data: string): Sha256Digest =
  var normalizedKey = key
  if normalizedKey.len > 64:
    normalizedKey = digestBytes(sha256(normalizedKey))
  normalizedKey.setLen(64)

  var inner = newString(64)
  var outer = newString(64)
  for index in 0 ..< 64:
    inner[index] = char(ord(normalizedKey[index]) xor 0x36)
    outer[index] = char(ord(normalizedKey[index]) xor 0x5c)
  let innerDigest = digestBytes(sha256(inner & data))
  sha256(outer & innerDigest)

proc hmacSha256Hex*(key, data: string): string =
  digestToHex(hmacSha256(key, data))
