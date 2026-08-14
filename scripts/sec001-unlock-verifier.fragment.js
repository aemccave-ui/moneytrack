// MONEYTRACK_UNLOCK_CONTRACT_VERSION=sec001-v1
// Canonical Class B credential preparation.
// This function never returns the raw MoneyTrack unlock token.
function moneytrackPrepareUnlockHash({ crypto, headers }) {
  const source = headers || {};
  const rawValue = source["x-moneytrack-unlock-token"] ?? source["X-MoneyTrack-Unlock-Token"] ?? null;
  if (rawValue === null || rawValue === undefined || rawValue === "") {
    return { unlock_contract_version: "sec001-v1", unlock_token_hash: null };
  }
  const raw = String(rawValue);
  if (!/^[A-Za-z0-9_-]{43}$/.test(raw)) {
    return { unlock_contract_version: "sec001-v1", unlock_token_hash: "INVALID" };
  }
  return {
    unlock_contract_version: "sec001-v1",
    unlock_token_hash: crypto.createHash("sha256").update(raw, "utf8").digest("hex"),
  };
}
