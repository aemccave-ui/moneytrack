import { useEffect, useState } from "react";
import "./App.css";

const API_BASE = "https://n8n.moneytrackapp.xyz/webhook";

function App() {
  const [dashboard, setDashboard] = useState(null);
  const [accountsData, setAccountsData] = useState(null);
  const [accountDetails, setAccountDetails] = useState(null);
  const [texts, setTexts] = useState({});
  const [languageCode, setLanguageCode] = useState("en");
  const [view, setView] = useState("dashboard");
  const [error, setError] = useState(null);
  const [updatedAt, setUpdatedAt] = useState(null);
  const [showTextInput, setShowTextInput] = useState(false);
  const [operationText, setOperationText] = useState("");
  const [toast, setToast] = useState(null);

  const [showVoiceRecorder, setShowVoiceRecorder] = useState(false);
  const [recording, setRecording] = useState(false);
  const [mediaRecorder, setMediaRecorder] = useState(null);

  const [hideBalances, setHideBalances] = useState(() => {
    return localStorage.getItem("moneytrack_hide_balances") !== "false";
  });

  const t = (key, fallback) => texts[key] || fallback;

  function locale() {
    return languageCode || "en";
  }

  function apiUrl(path) {
    return `${API_BASE}${path}`;
  }

  function headers() {
    const tg = window.Telegram?.WebApp;

    return {
      "X-Telegram-Init-Data": tg?.initData || "",
    };
  }

  function showToast(message, timeout = 2500) {
    setToast(message);

    if (timeout) {
      setTimeout(() => setToast(null), timeout);
    }
  }

  function toggleBalances() {
    const next = !hideBalances;
    setHideBalances(next);
    localStorage.setItem("moneytrack_hide_balances", String(next));
  }

  function formatMoney(value) {
    return new Intl.NumberFormat(locale(), {
      maximumFractionDigits: 0,
    }).format(Number(value || 0));
  }

  function privateMoney(value, currency = "") {
    if (hideBalances) {
      return currency ? `*** ${currency}` : "***";
    }

    return currency ? `${formatMoney(value)} ${currency}` : formatMoney(value);
  }

  function privateSignedMoney(value, currency, sign = "") {
    if (hideBalances) {
      return `*** ${currency}`;
    }

    return `${sign}${formatMoney(value)} ${currency}`;
  }

  function formatDate(value) {
    return new Date(value).toLocaleDateString(locale());
  }

  function formatDateTime(value) {
    return new Date(value).toLocaleString(locale(), {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  function txSign(type) {
    return type === "income" ? "+" : "-";
  }

  async function reloadData() {
    const dashboardResponse = await fetch(apiUrl("/api/v1/dashboard"), {
      headers: headers(),
    });

    if (!dashboardResponse.ok) {
      throw new Error(`Dashboard API error: ${dashboardResponse.status}`);
    }

    const dashboardJson = await dashboardResponse.json();

    const accountsResponse = await fetch(apiUrl("/api/v1/accounts"), {
      headers: headers(),
    });

    if (!accountsResponse.ok) {
      throw new Error(`Accounts API error: ${accountsResponse.status}`);
    }

    const accountsJson = await accountsResponse.json();

    setDashboard(dashboardJson.data);
    setAccountsData(accountsJson.data);
    setUpdatedAt(new Date());
  }

  async function uploadReceipt(event) {
    const file = event.target.files?.[0];
    event.target.value = "";

    if (!file) return;

    setToast(t("receipt_processing", "Receipt accepted for processing..."));

    try {
      const formData = new FormData();
      formData.append("receipt", file);

      const response = await fetch(apiUrl("/api/v1/transaction/photo"), {
        method: "POST",
        headers: headers(),
        body: formData,
      });

      const responseText = await response.text();

      console.log("PHOTO STATUS", response.status);
      console.log("PHOTO RESPONSE", responseText);

      if (!response.ok) {
        throw new Error(`Photo API error: ${response.status}: ${responseText}`);
      }

      await reloadData();
      setToast(null);
    } catch (e) {
      console.error(e);
      setToast(null);
      setError(e.message);
    }
  }

  async function startRecording() {
    try {
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error("Microphone is not available in this browser");
      }

      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      const chunks = [];

      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
          chunks.push(event.data);
        }
      };

      recorder.onstop = async () => {
        const blob = new Blob(chunks, { type: "audio/webm" });
        stream.getTracks().forEach((track) => track.stop());
        await sendVoiceBlob(blob);
      };

      setMediaRecorder(recorder);
      setRecording(true);
      recorder.start();
    } catch (e) {
      console.error(e);
      setShowVoiceRecorder(false);
      setRecording(false);
      setError(e.message);
    }
  }

  function stopRecording() {
    if (mediaRecorder && recording) {
      mediaRecorder.stop();
      setRecording(false);
      setShowVoiceRecorder(false);
    }
  }

  function cancelRecording() {
    if (mediaRecorder && recording) {
      mediaRecorder.stream?.getTracks?.().forEach((track) => track.stop());
    }

    setRecording(false);
    setMediaRecorder(null);
    setShowVoiceRecorder(false);
  }

  async function sendVoiceBlob(blob) {
    setToast(t("voice_processing", "Voice accepted for processing..."));

    try {
      const formData = new FormData();
      formData.append("voice", blob, "voice.webm");

      const response = await fetch(apiUrl("/api/v1/transaction/voice"), {
        method: "POST",
        headers: headers(),
        body: formData,
      });

      const responseText = await response.text();

      console.log("VOICE STATUS", response.status);
      console.log("VOICE RESPONSE", responseText);

      if (!response.ok) {
        throw new Error(`Voice API error: ${response.status}: ${responseText}`);
      }

      await reloadData();
      showToast(t("operation_added", "Operation added"));
    } catch (e) {
      console.error(e);
      setToast(null);
      setError(e.message);
    } finally {
      setMediaRecorder(null);
    }
  }

  async function saveTextOperation() {
    const text = operationText.trim();

    if (!text) return;

    setShowTextInput(false);
    setOperationText("");
    setToast(t("processing", "Processing..."));

    try {
      const response = await fetch(apiUrl("/api/v1/transaction/text"), {
        method: "POST",
        headers: {
          ...headers(),
          "Content-Type": "text/plain",
        },
        body: JSON.stringify({ text }),
      });

      const responseText = await response.text();

      console.log("TEXT OP STATUS", response.status);
      console.log("TEXT OP RESPONSE", responseText);

      if (!response.ok) {
        throw new Error(
          `Text operation API error: ${response.status}: ${responseText}`
        );
      }

      await reloadData();
      showToast(t("operation_added", "Operation added"));
    } catch (e) {
      console.error(e);
      setToast(null);
      setError(e.message);
    }
  }

  async function openAccount(accountId) {
    try {
      const response = await fetch(apiUrl(`/api/v1/account?id=${accountId}`), {
        headers: headers(),
      });

      if (!response.ok) {
        throw new Error(`Account API error: ${response.status}`);
      }

      const json = await response.json();

      setAccountDetails(json.data);
      setView("account");
    } catch (e) {
      console.error(e);
      setError(e.message);
    }
  }

  useEffect(() => {
    async function loadData() {
      try {
        const i18nResponse = await fetch(apiUrl("/api/v1/i18n"), {
          headers: headers(),
        });

        if (!i18nResponse.ok) {
          throw new Error(`i18n API error: ${i18nResponse.status}`);
        }

        const i18nJson = await i18nResponse.json();

        setTexts(i18nJson.data?.messages || {});
        setLanguageCode(i18nJson.data?.language_code || "en");

        await reloadData();
      } catch (e) {
        console.error(e);
        setError(e.message);
      }
    }

    loadData();
  }, []);

  if (error) {
    return (
      <div className="loading">
        {t("error", "Error")}: {error}
      </div>
    );
  }

  if (!dashboard || !accountsData) {
    return <div className="loading">{t("loading", "Loading...")}</div>;
  }

  const result = Number(dashboard.summary.result_month || 0);
  const accounts = accountsData.accounts || [];

  return (
    <main>
      {toast && <div className="toast">{toast}</div>}




	<header className="app-header">
	  <div className="top-bar compact">
	    <div className="updated-at">
	      {t("updated_at", "Updated")}: {formatDateTime(updatedAt)}
	    </div>

	    <button
	      className="privacy-toggle"
	      onClick={toggleBalances}
	      title={
	        hideBalances
	          ? t("show_balances", "Show balances")
	          : t("hide_balances", "Hide balances")
	      }
	    >
	      {hideBalances ? "👁️‍🗨️" : "👁️"}
	    </button>
	  </div>

	  {view !== "account" && (
	    <nav className="tabs">
	      <button
	        className={view === "dashboard" ? "tab active" : "tab"}
	        onClick={() => setView("dashboard")}
	      >
	        {t("summary", "Summary")}
	      </button>

	      <button
	        className={view === "accounts" ? "tab active" : "tab"}
	        onClick={() => setView("accounts")}
	      >
	        {t("accounts", "Accounts")}
	      </button>
	    </nav>
	  )}
	</header>




      {view === "dashboard" && (
        <>
          <section>
            <h2>{t("add_operation_title", "Add transaction")}</h2>

            <div className="quick-actions">
              <button
                className="quick-action"
                onClick={() => document.getElementById("receipt-gallery").click()}
                title={t("choose_photo", "Choose photo")}
              >
                🖼️
              </button>

              <button
                className="quick-action"
                onClick={() => setShowVoiceRecorder(true)}
                title={t("add_voice", "Voice")}
              >
                🎤
              </button>

              <button
                className="quick-action"
                onClick={() => setShowTextInput(true)}
                title={t("add_text_operation", "Text")}
              >
                ⌨️
              </button>

              <input
                id="receipt-gallery"
                type="file"
                accept="image/*"
                style={{ display: "none" }}
                onChange={uploadReceipt}
              />
            </div>

            {showTextInput && (
              <div className="modal-overlay">
                <div className="modal">
                  <h3>{t("add_text_operation", "Text operation")}</h3>

                  <textarea
                    className="text-operation-input"
                    value={operationText}
                    onChange={(e) => setOperationText(e.target.value)}
                    placeholder="coffee 5 eur"
                  />

                  <div className="modal-buttons">
                    <button
                      className="secondary-button"
                      onClick={() => {
                        setShowTextInput(false);
                        setOperationText("");
                      }}
                    >
                      {t("cancel", "Cancel")}
                    </button>

                    <button className="primary-button" onClick={saveTextOperation}>
                      {t("save", "Save")}
                    </button>
                  </div>
                </div>
              </div>
            )}

            {showVoiceRecorder && (
              <div className="modal-overlay">
                <div className="modal">
                  <h3>{t("add_voice", "Voice")}</h3>

                  <div className="voice-recorder">
                    {recording
                      ? t("recording", "Recording...")
                      : t("ready_to_record", "Ready to record")}
                  </div>

                  <div className="modal-buttons">
                    <button className="secondary-button" onClick={cancelRecording}>
                      {t("cancel", "Cancel")}
                    </button>

                    {!recording ? (
                      <button className="primary-button" onClick={startRecording}>
                        {t("start_recording", "Start")}
                      </button>
                    ) : (
                      <button className="primary-button" onClick={stopRecording}>
                        {t("stop_recording", "Stop")}
                      </button>
                    )}
                  </div>
                </div>
              </div>
            )}
          </section>

          <section>
            <h2>{t("period_summary", "Period")}</h2>

            <div className="period">
              {formatDate(dashboard.period.date_from)} —{" "}
              {formatDate(dashboard.period.date_to)}
            </div>

            <div className="cards">
              <div className="card">
                <div className="label">💰 {t("income", "Income")}</div>
                <div className="value positive">
                  {privateSignedMoney(
                    dashboard.summary.income_month,
                    dashboard.summary.currency,
                    "+"
                  )}
                </div>
              </div>

              <div className="card">
                <div className="label">💸 {t("expenses", "Expenses")}</div>
                <div className="value negative">
                  {privateMoney(
                    dashboard.summary.expenses_month,
                    dashboard.summary.currency
                  )}
                </div>
              </div>

              <div className="card">
                <div className="label">
                  📈 {t("period_balance", "Period balance")}
                </div>
                <div className={`value ${result >= 0 ? "positive" : "negative"}`}>
                  {privateSignedMoney(
                    result,
                    dashboard.summary.currency,
                    result >= 0 ? "+" : ""
                  )}
                </div>
              </div>
            </div>
          </section>

          <section>
            <h2>{t("today_status", "Today")}</h2>

            <div className="cards cards-single">
              <div className="card">
                <div className="label">
                  🏦 {t("net_worth_today", "Net worth today")}
                </div>
                <div className="value">
                  {privateMoney(
                    dashboard.summary.net_worth,
                    dashboard.summary.currency
                  )}
                </div>
              </div>
            </div>
          </section>

          <section>
            <h2>{t("currency_balances", "Balances by currency")}</h2>

            <div className="accounts">
              {(dashboard.balances_by_currency || [])
                .filter((item) => Number(item.balance) !== 0)
                .map((item) => (
                  <div className="account compact-account" key={item.currency}>
                    <div className="account-name">{item.currency}</div>
                    <div className="account-balance">
                      {privateMoney(item.balance)}
                    </div>
                  </div>
                ))}
            </div>
          </section>

          <section>
            <h2>{t("latest_operations", "Latest operations")}</h2>

            <div className="transactions">
              {(dashboard.latest_operations || []).slice(0, 5).map((tx) => (
                <div className="transaction" key={tx.id}>
                  <div className="tx-icon">
                    {tx.transaction_type === "income" ? "●" : "○"}
                  </div>

                  <div className="tx-main">
                    <div className="tx-title">{tx.description || "-"}</div>
                    <div className="tx-meta">
                      #{tx.id} · {tx.account_name || "-"}
                    </div>
                  </div>

                  <div
                    className={`tx-amount ${
                      tx.transaction_type === "income" ? "positive" : "negative"
                    }`}
                  >
                    {hideBalances
                      ? `*** ${tx.currency_original}`
                      : `${txSign(tx.transaction_type)}${formatMoney(
                          tx.amount_original
                        )} ${tx.currency_original}`}
                  </div>
                </div>
              ))}
            </div>
          </section>
        </>
      )}

      {view === "accounts" && (
        <section>
          <h2>{t("accounts", "Accounts")}</h2>

          <div className="cards cards-single">
            <div className="card">
              <div className="label">🏦 {t("net_worth_today", "Total")}</div>
              <div className="value">
                {privateMoney(accountsData.total_base, accountsData.base_currency)}
              </div>
            </div>
          </div>

          <div className="account-tree">
            {accounts.map((account) => (
              <div
                className={`account-row level-${account.level}`}
                key={account.id}
                onClick={() => openAccount(account.id)}
              >
                <div className="account-left">
                  <div className="account-title">
                    {account.level === 0 ? "📁" : "▫️"} {account.name}
                  </div>

                  <div className="tx-meta">{account.currency_code}</div>
                </div>

                <div className="account-right">
                  <div className="account-balance">
                    {privateMoney(account.balance, account.currency_code)}
                  </div>

                  {account.currency_code !== accountsData.base_currency && (
                    <div className="tx-meta">
                      ≈{" "}
                      {privateMoney(
                        account.balance_base,
                        accountsData.base_currency
                      )}
                    </div>
                  )}
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

      {view === "account" && accountDetails && (
        <section>
          <button className="back-button" onClick={() => setView("accounts")}>
            ← {t("accounts", "Accounts")}
          </button>

          <h2>{accountDetails.account.name}</h2>

          <div className="cards cards-single">
            <div className="card">
              <div className="label">{t("balance", "Balance")}</div>
              <div className="value">
                {privateMoney(
                  accountDetails.account.balance,
                  accountDetails.account.currency_code
                )}
              </div>
            </div>
          </div>

          <h3>{t("latest_operations", "Latest operations")}</h3>

          <div className="account-operations">
            {(accountDetails.operations || []).map((tx) => (
              <div className="account-operation" key={tx.id}>
                <div className="op-main">
                  <div className="op-title">{tx.description || "Операция"}</div>
                  <div className="op-date">{formatDate(tx.transaction_date)}</div>
                </div>

                <div
                  className={`op-amount ${
                    tx.transaction_type === "income" ? "positive" : "negative"
                  }`}
                >
                  {hideBalances
                    ? "***"
                    : `${tx.transaction_type === "income" ? "+" : "-"}${formatMoney(
                        tx.amount_original
                      )}`}
                </div>
              </div>
            ))}
          </div>
        </section>
      )}
    </main>
  );
}

export default App;
