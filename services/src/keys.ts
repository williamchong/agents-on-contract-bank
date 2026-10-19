// P-256 keys, the key type of hardware security modules, chip cards and passkeys. Every key in the
// simulation is derived from a name, as the contract tests derive theirs, so a run can be replayed and a
// test and a script name the same key. See docs/plan.md open question 12.

import { p256 } from '@noble/curves/nist.js'
import { concat, keccak256, numberToHex, toBytes, toHex, type Address, type Hex } from 'viem'

const N = p256.Point.CURVE().n

export interface Key {
  name: string
  secret: bigint
}

export function keyOf(name: string): Key {
  return { name, secret: (BigInt(keccak256(toBytes(name))) % (N - 1n)) + 1n }
}

function secretBytes(key: Key): Uint8Array {
  return toBytes(numberToHex(key.secret, { size: 32 }))
}

// An ERC-7913 signer: the verifier's address followed by the key's coordinates.
export function signerOf(verifier: Address, key: Key): Hex {
  const point = p256.getPublicKey(secretBytes(key), false)
  return concat([verifier, toHex(point.slice(1))])
}

// Signs a digest as it is, in the low-s form the contracts accept: r followed by s.
export function signDigest(key: Key, digest: Hex): Hex {
  return toHex(p256.sign(toBytes(digest), secretBytes(key), { prehash: false, lowS: true }))
}
