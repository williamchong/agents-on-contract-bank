// The signer service: holds every key and signs for the device, card, staff token or partner that owns
// it. It stands in for the secure hardware in each device and for a hardware security module, so agents
// and scripts ask it to sign and never see a key. Each use is logged. Milestone 6 adds the key inventory
// and rotation; see docs/plan.md.

import {
  encodeAbiParameters,
  hashTypedData,
  zeroHash,
  type Address,
  type Hex,
  type TypedData,
  type TypedDataDefinition,
} from 'viem'
import { hashTypedData as hashNested, wrapTypedDataSignature } from 'viem/experimental/erc7739'
import { keyOf, signDigest, signerOf, type Key } from './keys.ts'

export interface KeyUse {
  key: string
  purpose: string
}

// A multi-signer account's EIP-712 domain, as MultiSignerAccount.sol declares it, with no salt.
function accountDomain(chainId: number, account: Address) {
  return { name: 'MultiSignerAccount', version: '1', chainId, verifyingContract: account } as const
}

export class Signer {
  readonly log: KeyUse[] = []
  // The P-256 verifier every key is registered through.
  readonly verifier: Address
  readonly chainId: number
  // Mixed into every key's name on a public chain; see keys.ts.
  private readonly seed: Hex | undefined
  private readonly keys = new Map<string, Key>()

  constructor(verifier: Address, chainId: number, seed?: Hex) {
    this.verifier = verifier
    this.chainId = chainId
    this.seed = seed
  }

  key(name: string): Key {
    let key = this.keys.get(name)
    if (!key) {
      key = keyOf(name, this.seed)
      this.keys.set(name, key)
    }
    return key
  }

  // The key in the form an account or the partner register holds it.
  signerBytes(name: string): Hex {
    return signerOf(this.verifier, this.key(name))
  }

  // A batch of calls for a multi-signer account to run, signed by `names` under its next one-use number.
  signExecution(account: Address, names: string[], executionData: Hex, nonce: bigint): Hex {
    const digest = hashTypedData({
      domain: accountDomain(this.chainId, account),
      types: { Execute: [{ name: 'executionData', type: 'bytes' }, { name: 'nonce', type: 'uint256' }] },
      primaryType: 'Execute',
      message: { executionData, nonce },
    })
    return this.encodeSigners(names, digest, 'batch for its account')
  }

  // A typed message an account's signer authorises for another contract, such as a card's authorisation
  // of a transfer, nested under ERC-7739 so it is good for that one account only.
  signForAccount<const T extends TypedData, P extends keyof T & string>(
    account: Address,
    names: string[],
    definition: TypedDataDefinition<T, P>,
  ): Hex {
    const verifierDomain = { ...accountDomain(this.chainId, account), salt: zeroHash }
    const digest = hashNested({ ...definition, verifierDomain } as never)
    const signature = this.encodeSigners(names, digest, `${definition.primaryType} for ${account}`)
    return wrapTypedDataSignature({ ...definition, signature } as never)
  }

  // A partner's own signature over its message, checked against its registered key.
  signAsPartner<const T extends TypedData, P extends keyof T & string>(name: string, definition: TypedDataDefinition<T, P>): Hex {
    this.log.push({ key: name, purpose: definition.primaryType })
    return signDigest(this.key(name), hashTypedData(definition as never))
  }

  // A multi-signer account checks the signers it is given and one signature from each.
  private encodeSigners(names: string[], digest: Hex, purpose: string): Hex {
    for (const name of names) this.log.push({ key: name, purpose })
    return encodeAbiParameters(
      [{ type: 'bytes[]' }, { type: 'bytes[]' }],
      [names.map((n) => this.signerBytes(n)), names.map((n) => signDigest(this.key(n), digest))],
    )
  }
}
