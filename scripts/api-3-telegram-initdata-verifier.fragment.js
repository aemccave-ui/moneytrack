// MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION=api3b-v1
// Canonical source fragment injected into n8n Code nodes by API-3 tooling.
// Keep this file dependency-free except for the `crypto` object supplied by the caller.

const MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION = "api3b-v1";
const MONEYTRACK_INIT_DATA_DEFAULT_MAX_AGE_SECONDS = 86400;
const MONEYTRACK_INIT_DATA_DEFAULT_MAX_FUTURE_SKEW_SECONDS = 300;

function moneytrackPositiveInteger(value, fallback) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) return fallback;
  return parsed;
}

function moneytrackAuthError(code, httpStatus = 401) {
  return {
    ok: false,
    auth_contract_version: MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION,
    http_status: httpStatus,
    error: { code }
  };
}

function moneytrackParseInitData(initData) {
  const result = {};
  for (const part of String(initData).split("&")) {
    const eqIndex = part.indexOf("=");
    if (eqIndex === -1) continue;
    const key = decodeURIComponent(part.slice(0, eqIndex));
    const value = decodeURIComponent(part.slice(eqIndex + 1));
    result[key] = value;
  }
  return result;
}

function moneytrackVerifyTelegramInitData({
  crypto,
  initData,
  botToken,
  maxAgeSeconds,
  maxFutureSkewSeconds,
  nowSeconds
}) {
  if (!initData) return moneytrackAuthError("INIT_DATA_MISSING", 401);
  if (!botToken) return moneytrackAuthError("BOT_TOKEN_MISSING", 500);

  let params;
  try {
    params = moneytrackParseInitData(initData);
  } catch {
    return moneytrackAuthError("INVALID_INIT_DATA", 401);
  }

  const receivedHash = params.hash;
  if (!receivedHash) return moneytrackAuthError("HASH_MISSING", 401);
  if (!/^[0-9a-fA-F]{64}$/.test(receivedHash)) {
    return moneytrackAuthError("INVALID_INIT_DATA_HASH", 401);
  }

  delete params.hash;

  const dataCheckString = Object.keys(params)
    .sort()
    .map((key) => `${key}=${params[key]}`)
    .join("\n");

  const secretKey = crypto
    .createHmac("sha256", "WebAppData")
    .update(botToken)
    .digest();

  const calculatedHash = crypto
    .createHmac("sha256", secretKey)
    .update(dataCheckString)
    .digest();

  const receivedHashBuffer = Buffer.from(receivedHash, "hex");
  if (
    receivedHashBuffer.length !== calculatedHash.length
    || !crypto.timingSafeEqual(receivedHashBuffer, calculatedHash)
  ) {
    return moneytrackAuthError("INVALID_INIT_DATA_HASH", 401);
  }

  if (params.auth_date === undefined || params.auth_date === null || params.auth_date === "") {
    return moneytrackAuthError("AUTH_DATE_MISSING", 401);
  }

  const authDate = Number(params.auth_date);
  if (!Number.isInteger(authDate) || authDate <= 0) {
    return moneytrackAuthError("AUTH_DATE_INVALID", 401);
  }

  const effectiveNowSeconds = Number.isFinite(Number(nowSeconds))
    ? Math.floor(Number(nowSeconds))
    : Math.floor(Date.now() / 1000);

  const effectiveMaxAgeSeconds = moneytrackPositiveInteger(
    maxAgeSeconds,
    MONEYTRACK_INIT_DATA_DEFAULT_MAX_AGE_SECONDS
  );

  const effectiveMaxFutureSkewSeconds = moneytrackPositiveInteger(
    maxFutureSkewSeconds,
    MONEYTRACK_INIT_DATA_DEFAULT_MAX_FUTURE_SKEW_SECONDS
  );

  if (authDate > effectiveNowSeconds + effectiveMaxFutureSkewSeconds) {
    return moneytrackAuthError("AUTH_DATE_IN_FUTURE", 401);
  }

  if (effectiveNowSeconds - authDate > effectiveMaxAgeSeconds) {
    return moneytrackAuthError("AUTH_DATE_EXPIRED", 401);
  }

  if (!params.user) return moneytrackAuthError("USER_MISSING", 401);

  let user;
  try {
    user = JSON.parse(params.user);
  } catch {
    return moneytrackAuthError("INVALID_USER_DATA", 401);
  }

  const telegramUserId = Number(user?.id);
  if (!Number.isSafeInteger(telegramUserId) || telegramUserId <= 0) {
    return moneytrackAuthError("INVALID_USER_DATA", 401);
  }

  return {
    ok: true,
    auth_contract_version: MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION,
    auth_date: authDate,
    telegram_user_id: telegramUserId,
    user
  };
}
