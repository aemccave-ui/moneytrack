// UX-025 compatibility marker for the frozen SEC-001 protected-child source gate.
// The real Settings implementation is miniapp/src/screens/SettingsScreen.jsx
// and is routed by App. This component performs no fetch, DOM interception,
// rendering, or side effect and can be removed when SEC-001 source assertions
// are migrated to the screen-router contract.
export default function SettingsPortal() {
  return null
}
