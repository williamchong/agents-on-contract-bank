// Where each building of the bank map stands. The layout is fixed: what the contracts report changes only
// what is drawn on and between the buildings. See docs/architecture.md#bank-map.

export type Vec3 = [number, number, number]

export type BuildingShape = 'block' | 'tower' | 'lot'

export type BuildingId =
  | 'head-office'
  | 'town-hall'
  | 'water-tower'
  | 'branch'
  | 'vault'
  | 'atm'
  | 'custodian'
  | 'post-office'
  | 'compliance-yard'
  | 'suspense-lot'
  | 'clearing-house'

export interface Building {
  id: BuildingId
  label: string
  shape: BuildingShape
  position: Vec3
  // Width, height and depth; a tower uses the width as its diameter.
  size: Vec3
  color: string
}

export interface Road {
  from: [number, number]
  to: [number, number]
}

export const buildings: Building[] = [
  { id: 'head-office', label: 'Head office', shape: 'block', position: [0, 0, 0], size: [3, 3, 3], color: '#d9c9a3' },
  { id: 'town-hall', label: 'Town hall', shape: 'block', position: [-6, 0, -6], size: [3, 2.2, 2.5], color: '#c7b8d9' },
  { id: 'water-tower', label: 'Water tower', shape: 'tower', position: [5, 0, -5], size: [1.6, 4, 1.6], color: '#8fb8d9' },
  { id: 'branch', label: 'Branch', shape: 'block', position: [-5, 0, 4], size: [2.5, 1.8, 2.5], color: '#e0a87c' },
  { id: 'vault', label: 'Vault', shape: 'block', position: [-9, 0, 1.5], size: [1.6, 1.2, 1.6], color: '#9a9a9a' },
  { id: 'atm', label: 'ATM', shape: 'block', position: [-2.5, 0, 4], size: [0.6, 1, 0.4], color: '#5f7f9a' },
  { id: 'custodian', label: 'Custodian', shape: 'block', position: [-11, 0, -1], size: [2.5, 2.5, 2.5], color: '#a3b59a' },
  { id: 'post-office', label: 'Post office', shape: 'block', position: [6, 0, 4], size: [2.5, 1.8, 2.2], color: '#d98f8f' },
  { id: 'compliance-yard', label: 'Compliance yard', shape: 'lot', position: [9.5, 0, 6], size: [2.5, 0.05, 2], color: '#e6d27a' },
  { id: 'suspense-lot', label: 'Suspense lot', shape: 'lot', position: [9.5, 0, 2], size: [2.5, 0.05, 2], color: '#bfbfbf' },
  { id: 'clearing-house', label: 'Clearing house', shape: 'block', position: [17, 0, 4], size: [3, 2.2, 2.5], color: '#9aa3c7' },
]

// Customers' houses stand in a street south of the branch; the map sizes each one by its balance.
export const houseLots: Vec3[] = [-6, -3, 0, 3, 6].map((x): Vec3 => [x, 0, 9])

export const roads: Road[] = [
  // The road out of town, from the clearing house to the post office.
  { from: [15.5, 4], to: [7.5, 4] },
  // The main street, from the post office past the head office to the branch.
  { from: [4.5, 4], to: [-6.5, 4] },
  // The street of houses.
  { from: [-7, 7.5], to: [7, 7.5] },
  { from: [0, 4], to: [0, 7.5] },
]

// Staff work inside the building they belong to: the branch's people at the branch, the vault custodian at
// the vault and head office's people at head office. Each building's label counts them, and its details
// list them. The red team, whose teller role is at another branch, stands alone on the edge of town.
export interface StaffPost {
  name: string
  building?: BuildingId
}

const at = (building: BuildingId, names: string[]): StaffPost[] => names.map((name) => ({ name, building }))

export const staffPosts: StaffPost[] = [
  ...at('branch', ['teller', 'replacement teller', 'supervisor', 'branch manager', 'account opening officer']),
  ...at('vault', ['vault custodian']),
  ...at('head-office', ['compliance', 'back office', 'finance', 'risk', 'support', 'IT security']),
  { name: 'red team' },
]

export const redTeamSpot: Vec3 = [13, 0, -6]
