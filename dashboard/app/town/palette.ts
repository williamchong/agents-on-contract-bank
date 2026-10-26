// The colour of each entity by what it does, the same in the passbook, the story's sentences and the town, so
// who took part in a line can be told at a glance. Alike roles share a hue: blue for customers, orange for the
// branch, the lending office and the cash, violet for head office and governance, teal for payments and other
// banks, and red for the attacker. Money keeps its gold. See docs/architecture.md#bank-map.

import type { Deployment, Line } from '~/lib/story'
import { parse, staffId, type EntityId } from './entities'
import { actorEntity, addressEntity } from './focus'
import { buildings, staffPosts } from './layout'

export type Tone = 'customer' | 'branch' | 'head-office' | 'payments' | 'attacker'

// Each tone's colour in the town, on map labels and in the key, which are always light; text in the panels
// takes the theme's --tone-* instead.
export const tones: Record<Tone, { color: string; key: string }> = {
  customer: { color: '#3f6fa8', key: 'Blue: customers' },
  branch: { color: '#d0702c', key: 'Orange: the branch and the lending office, their cash and their staff' },
  'head-office': { color: '#8a63c2', key: 'Violet: head office, governance and their staff' },
  payments: { color: '#2a9d8f', key: 'Teal: payments and other banks' },
  attacker: { color: '#c0392b', key: 'Red: the red team, an attacker' },
}

export function toneOf(id: EntityId | undefined): Tone | undefined {
  if (!id) return undefined
  const p = parse(id)
  if (p.kind === 'customer') return 'customer'
  if (p.kind === 'staff') {
    if (p.name === 'red team') return 'attacker'
    const building = staffPosts.find((x) => x.name === p.name)?.building
    return buildings.find((b) => b.id === building)?.tone
  }
  return buildings.find((b) => b.id === p.id)?.tone
}

// The tone of a movement's side: where the map has it, else the rest of the world's customers or the member
// of staff whose account it is.
export function addressTone(d: Deployment, address: string, other: string, channel: string): Tone | undefined {
  const a = address.toLowerCase()
  if (a === d.customers['other customers']?.toLowerCase()) return 'customer'
  const id = addressEntity(d, address, other, channel)
  if (id) return toneOf(id)
  const staff = Object.keys(d.staff).find((n) => d.staff[n]!.toLowerCase() === a)
  if (!staff) return undefined
  // The ATM signs as staff but is a building on the map.
  return staff === 'ATM' ? toneOf('atm') : toneOf(staffId(staff))
}

// addressTone for one deployment, as passbook takes it.
export const addressToner = (d: Deployment) => (address: string, other: string, channel: string) => addressTone(d, address, other, channel)

// The classes that colour a name by its tone.
export function toneClass(tone: Tone | undefined) {
  return tone && ['who', `tone-${tone}`]
}

export function actorTone(d: Deployment, line: Line): Tone | undefined {
  return toneOf(actorEntity(d, line))
}
