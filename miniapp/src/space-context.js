import { createContext, useContext } from 'react'

let activeSpaceId = null

export function setActiveSpaceId(spaceId) {
  const numeric = Number(spaceId)
  activeSpaceId = Number.isSafeInteger(numeric) && numeric > 0 ? numeric : null
}

export function clearActiveSpaceId() {
  activeSpaceId = null
}

export function getActiveSpaceId() {
  return activeSpaceId
}

export const SpaceContext = createContext({
  activeSpace: null,
  spaces: [],
  switching: false,
  switchSpace: async () => {},
  reloadSpaces: async () => {},
})

export function useSpace() {
  return useContext(SpaceContext)
}
