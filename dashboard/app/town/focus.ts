// What a story line involves on the bank map: whoever acted, where they acted and the places its money moved
// between. The map follows the latest line by framing these and fading the rest of the town. See
// docs/architecture.md#bank-map.

import { holder, movements, type Deployment, type Line } from '~/lib/story'
import { concerns, customerId, parse, staffId, type EntityId } from './entities'
import { buildings, houseLots, redTeamSpot, staffPosts, type BuildingId, type Vec3 } from './layout'

// The customers who have a house, in street order; the rest are "other customers", off the edge of town.
export function housedCustomers(d: Deployment): string[] {
  return Object.keys(d.customers).filter((n) => n !== 'other customers')
}

// Where a movement's side stands: a customer's house or the building holding the money. The rest of the
// world's customers stand nowhere on the map, so have no entity.
export function addressEntity(d: Deployment, address: string, other: string, channel: string): EntityId | undefined {
  const a = address.toLowerCase()
  const customer = housedCustomers(d).find((n) => d.customers[n]!.toLowerCase() === a)
  if (customer) return customerId(customer)
  if (a === d.customers['other customers']?.toLowerCase()) return undefined
  switch (holder(d, address, other, channel)) {
    case 'Another bank':
      return 'clearing-house'
    case 'Cash':
    case 'ATM':
      return channel === 'atm' ? 'atm' : 'branch'
    case 'Branch':
      return 'branch'
    case 'Post office':
      return 'post-office'
  }
  return 'head-office'
}

// Where a refusal stands: at the channel it came through, or the house of the customer who tried it.
export function refusalEntity(d: Deployment, line: Line): EntityId {
  const byChannel: Record<string, BuildingId> = { atm: 'atm', branch: 'branch', partner: 'clearing-house', admin: 'town-hall' }
  if (byChannel[line.channel]) return byChannel[line.channel]!
  return housedCustomers(d).includes(line.actor) ? customerId(line.actor) : 'head-office'
}

// Head office posts nearly every line's entry, so it is involved only when it acts or money moves there.
const involvable = buildings.map((b) => b.id).filter((id) => id !== 'head-office')

export function involved(d: Deployment, line: Line): Set<EntityId> {
  const ids = new Set<EntityId>()
  if (line.kind === 'operator') return ids
  // The ATM signs as staff but is a building on the map, which its channel lights.
  if (d.staff[line.actor] !== undefined && line.actor !== 'ATM') ids.add(staffId(line.actor))
  if (housedCustomers(d).includes(line.actor)) ids.add(customerId(line.actor))
  if (line.channel === 'head office') ids.add('head-office')
  if (line.kind === 'refused') ids.add(refusalEntity(d, line))
  for (const m of movements(line)) {
    const from = addressEntity(d, m.from, m.to, m.channel)
    const to = addressEntity(d, m.to, m.from, m.channel)
    if (from) ids.add(from)
    if (to) ids.add(to)
  }
  for (const id of involvable) if (concerns(id, line, d)) ids.add(id)
  // A member of staff stands in their building, so it is involved with them.
  for (const id of [...ids]) {
    const p = parse(id)
    const building = p.kind === 'staff' && staffPosts.find((x) => x.name === p.name)?.building
    if (building) ids.add(building)
  }
  return ids
}

// The points that frame an entity on the map: its footprint's corners at ground level and above its label.
export function framePoints(d: Deployment, id: EntityId): Vec3[] {
  const p = parse(id)
  let at: Vec3 | undefined
  let half = 0.6
  let top = 1.6
  if (p.kind === 'customer') {
    at = houseLots[housedCustomers(d).indexOf(p.name)]
    half = 0.8
    top = 3.2
  } else if (p.kind === 'staff') {
    // Staff are framed by their building; only the red team stands alone.
    if (p.name === 'red team') at = redTeamSpot
  } else {
    const b = buildings.find((x) => x.id === p.id)
    if (b) {
      at = b.position
      half = Math.max(b.size[0], b.size[2]) / 2
      top = b.size[1] + 1.2
    }
  }
  if (!at) return []
  const [x, , z] = at
  return [
    [x - half, 0, z - half],
    [x + half, 0, z + half],
    [x - half, top, z + half],
    [x + half, top, z - half],
  ]
}
