// Deploys the bank to a running local chain and serves the control service the dashboard reads and drives.
// Start the chain with `pnpm hardhat node`, then run `pnpm demo`, then the dashboard with
// `pnpm --filter dashboard dev`.
import { network } from 'hardhat'
import { connect, Control, serve } from '@bank/services'

const { provider } = await network.getOrCreate('localhost')
const control = new Control(await connect(provider))
await control.listen()
serve(control)
console.log('The bank is open. The control service listens on http://127.0.0.1:8546; stop it with Ctrl-C.')
// Hardhat ends the script when it returns, so it waits here while the control service serves.
await new Promise(() => {})
