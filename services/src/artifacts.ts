// The compiled contracts, read from Hardhat's build output. Their ABIs are typed from the declarations
// Hardhat writes beside them, so a call with a wrong function name or argument fails the type check.

import { readFileSync } from 'node:fs'
import type { Abi, Hex } from 'viem'
import type { AccessManager$Type } from '../../artifacts/@openzeppelin/contracts/access/manager/AccessManager.sol/artifacts.js'
import type { TimelockController$Type } from '../../artifacts/@openzeppelin/contracts/governance/TimelockController.sol/artifacts.js'
import type { ERC7913P256Verifier$Type } from '../../artifacts/@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol/artifacts.js'
import type { AccountRecovery$Type } from '../../artifacts/contracts/core/AccountRecovery.sol/artifacts.js'
import type { AssistedOperations$Type } from '../../artifacts/contracts/core/AssistedOperations.sol/artifacts.js'
import type { Attestations$Type } from '../../artifacts/contracts/core/Attestations.sol/artifacts.js'
import type { CashOperations$Type } from '../../artifacts/contracts/core/CashOperations.sol/artifacts.js'
import type { CustomerLimits$Type } from '../../artifacts/contracts/core/CustomerLimits.sol/artifacts.js'
import type { DepositToken$Type } from '../../artifacts/contracts/core/DepositToken.sol/artifacts.js'
import type { DisputeReversal$Type } from '../../artifacts/contracts/core/DisputeReversal.sol/artifacts.js'
import type { GeneralLedger$Type } from '../../artifacts/contracts/core/GeneralLedger.sol/artifacts.js'
import type { HoldRegister$Type } from '../../artifacts/contracts/core/HoldRegister.sol/artifacts.js'
import type { IncidentLog$Type } from '../../artifacts/contracts/core/IncidentLog.sol/artifacts.js'
import type { MultiSignerAccount$Type } from '../../artifacts/contracts/core/MultiSignerAccount.sol/artifacts.js'
import type { PartnerKeys$Type } from '../../artifacts/contracts/core/PartnerKeys.sol/artifacts.js'
import type { Payments$Type } from '../../artifacts/contracts/core/Payments.sol/artifacts.js'
import type { StaffRoles$Type } from '../../artifacts/contracts/core/StaffRoles.sol/artifacts.js'

interface Artifacts {
  AccessManager: AccessManager$Type
  TimelockController: TimelockController$Type
  ERC7913P256Verifier: ERC7913P256Verifier$Type
  AccountRecovery: AccountRecovery$Type
  AssistedOperations: AssistedOperations$Type
  Attestations: Attestations$Type
  CashOperations: CashOperations$Type
  CustomerLimits: CustomerLimits$Type
  DepositToken: DepositToken$Type
  DisputeReversal: DisputeReversal$Type
  GeneralLedger: GeneralLedger$Type
  HoldRegister: HoldRegister$Type
  IncidentLog: IncidentLog$Type
  MultiSignerAccount: MultiSignerAccount$Type
  PartnerKeys: PartnerKeys$Type
  Payments: Payments$Type
  StaffRoles: StaffRoles$Type
}

export type ContractName = keyof Artifacts
export type AbiOf<N extends ContractName> = Artifacts[N]['abi']

const sources: Record<ContractName, string> = {
  AccessManager: '@openzeppelin/contracts/access/manager/AccessManager.sol',
  TimelockController: '@openzeppelin/contracts/governance/TimelockController.sol',
  ERC7913P256Verifier: '@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol',
  AccountRecovery: 'contracts/core/AccountRecovery.sol',
  AssistedOperations: 'contracts/core/AssistedOperations.sol',
  Attestations: 'contracts/core/Attestations.sol',
  CashOperations: 'contracts/core/CashOperations.sol',
  CustomerLimits: 'contracts/core/CustomerLimits.sol',
  DepositToken: 'contracts/core/DepositToken.sol',
  DisputeReversal: 'contracts/core/DisputeReversal.sol',
  GeneralLedger: 'contracts/core/GeneralLedger.sol',
  HoldRegister: 'contracts/core/HoldRegister.sol',
  IncidentLog: 'contracts/core/IncidentLog.sol',
  MultiSignerAccount: 'contracts/core/MultiSignerAccount.sol',
  PartnerKeys: 'contracts/core/PartnerKeys.sol',
  Payments: 'contracts/core/Payments.sol',
  StaffRoles: 'contracts/core/StaffRoles.sol',
}

const root = new URL('../../artifacts/', import.meta.url)

export function abiOf<N extends ContractName>(name: N): Artifacts[N]['abi'] {
  return read(name).abi
}

export function bytecodeOf(name: ContractName): Hex {
  return read(name).bytecode as Hex
}

const cache = new Map<ContractName, Artifacts[ContractName]>()

function read<N extends ContractName>(name: N): Artifacts[N] {
  let artifact = cache.get(name)
  if (!artifact) {
    artifact = JSON.parse(readFileSync(new URL(`${sources[name]}/${name}.json`, root), 'utf8')) as Artifacts[N]
    cache.set(name, artifact)
  }
  return artifact as Artifacts[N]
}

// Every ABI, so a refusal from any contract can be decoded by name.
export function allAbis(): Abi {
  return (Object.keys(sources) as ContractName[]).flatMap((name) => abiOf(name) as Abi)
}
