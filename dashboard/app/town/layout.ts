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

// Where each member of staff stands, marked with a short code for their role: the branch's people in a row
// west of the branch, head office's in a row behind head office, and the red team, whose teller role is at
// the second branch, out on the edge of town.
export interface StaffPost {
  name: string
  code: string
  position: Vec3
  color: string
}

const branchStaff = '#d9822b'
const headOfficeStaff = '#5f7f9a'
const row = (names: [string, string][], z: number, x0: number, color: string): StaffPost[] =>
  names.map(([name, code], i) => ({ name, code, position: [x0 + i * 1.3, 0, z] as Vec3, color }))

export const staffPosts: StaffPost[] = [
  ...row(
    [
      ['teller', 'T'],
      ['replacement teller', 'T2'],
      ['supervisor', 'S'],
      ['branch manager', 'BM'],
      ['vault custodian', 'VC'],
      ['account opening officer', 'AO'],
    ],
    6.4,
    -13.4,
    branchStaff,
  ),
  ...row(
    [
      ['compliance', 'C'],
      ['back office', 'BO'],
      ['finance', 'F'],
      ['risk', 'R'],
      ['support', 'Su'],
      ['IT security', 'IT'],
    ],
    -3.2,
    -3.2,
    headOfficeStaff,
  ),
  { name: 'red team', code: 'RT', position: [13, 0, -6], color: '#c0392b' },
]
