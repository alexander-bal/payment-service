"use strict";

const PINECREST = "3f1c9a2e-7b4d-4c1e-9a55-2d8e6f0b7c41";
const LOPEZ = "8b2e4c71-0d3a-4f6e-b1c9-5a7d2e9f4c10";
const NAIR = "e5f18b3c-2a9d-4c07-8e6b-1d4a7f9c3b25";

const REQUESTS = {
  sample: {
    // randomUUID exists only in secure contexts (HTTPS or localhost).
    key: `admin-sample-${crypto.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`}`,
    body: {
      payer_firm_uuid: PINECREST,
      payments: [
        { amount: "6250", payee_firm_uuid: NAIR, description: "Overflow returns, August 2026" },
        { amount: "5800.5", payee_firm_uuid: NAIR, description: "Amended returns, August 2026" },
        { amount: "1200.75", payee_firm_uuid: LOPEZ, description: "Bookkeeping cleanup, 3 clients" }
      ]
    }
  },
  insufficient: {
    key: "admin-insufficient-1",
    body: {
      payer_firm_uuid: LOPEZ,
      payments: [{ amount: "5000", payee_firm_uuid: NAIR, description: "More than Lopez can pay" }]
    }
  }
};

const TABS = ["firms", "payments", "bulk-payments", "test-requests"];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// Amounts arrive as "36748.75" strings; grouping the digits as text avoids a round trip through Float.
function formatMoney(amount) {
  const [dollars, cents] = amount.split(".");
  return `$${dollars.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${cents}`;
}

function formatCell(value, kind) {
  if (kind === "time") return new Date(value).toLocaleString();
  if (kind === "money") return formatMoney(value);
  return String(value);
}

async function loadPanel(panel) {
  const tbody = panel.querySelector("tbody");
  const status = panel.querySelector(".status");
  const counter = panel.querySelector(".counter");
  const columns = tbody.dataset.columns.split(" ").map((spec) => spec.split(":"));

  status.textContent = "Loading…";
  status.className = "status";

  try {
    const response = await fetch(panel.dataset.endpoint, { cache: "no-store", headers: { Accept: "application/json" } });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const rows = await response.json();

    tbody.replaceChildren(...rows.map((row) => {
      const tr = el("tr");
      for (const [name, kind] of columns) {
        tr.append(el("td", kind === "num" || kind === "money" ? "num" : "", formatCell(row[name], kind)));
      }
      return tr;
    }));
    counter.textContent = `${rows.length} total`;
    status.textContent = rows.length === 0 ? "No records yet." : "";
  } catch (error) {
    tbody.replaceChildren();
    counter.textContent = "";
    status.textContent = `Could not load ${panel.dataset.endpoint}: ${error.message}`;
    status.className = "status status-error";
  }
}

function describeRequest({ key, body }) {
  return [
    "POST /bulk_payments",
    "Content-Type: application/json",
    `Idempotency-Key: ${key}`,
    "",
    JSON.stringify(body, null, 2)
  ].join("\n");
}

async function sendRequest(card) {
  const { key, body } = REQUESTS[card.dataset.request];
  const button = card.querySelector("[data-send]");
  const result = card.querySelector(".result");

  button.disabled = true;
  result.replaceChildren(el("p", "status", "Sending…"));

  try {
    const response = await fetch("/bulk_payments", {
      method: "POST",
      cache: "no-store",
      headers: { "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify(body)
    });
    const text = await response.text();
    let pretty = text;
    try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch { /* keep the raw body */ }

    const head = el("div", "result-head");
    head.append(el("span", `badge ${response.ok ? "badge-ok" : "badge-error"}`, `${response.status} ${response.statusText}`));
    if (response.headers.get("Idempotent-Replayed") === "true") {
      head.append(el("span", "badge badge-info", "Idempotent-Replayed: true"));
    }
    result.replaceChildren(head, el("pre", "response", pretty));
  } catch (error) {
    result.replaceChildren(el("p", "status status-error", `Request failed: ${error.message}`));
  } finally {
    button.disabled = false;
  }
}

function showTab() {
  const current = TABS.includes(location.hash.slice(1)) ? location.hash.slice(1) : TABS[0];
  for (const id of TABS) {
    const active = id === current;
    document.getElementById(id).hidden = !active;
    const link = document.querySelector(`[data-tab="${id}"]`);
    link.classList.toggle("active", active);
    if (active) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  const panel = document.getElementById(current);
  if (panel.dataset.endpoint) loadPanel(panel);
}

document.querySelectorAll("[data-refresh]").forEach((button) => {
  button.addEventListener("click", () => loadPanel(button.closest(".panel")));
});

document.querySelectorAll("[data-request]").forEach((card) => {
  card.querySelector(".request").textContent = describeRequest(REQUESTS[card.dataset.request]);
  card.querySelector("[data-send]").addEventListener("click", () => sendRequest(card));
});

window.addEventListener("hashchange", showTab);
showTab();
