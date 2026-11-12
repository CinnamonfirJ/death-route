const button = document.querySelector("[data-sign-url]");
const status = document.getElementById("wallet-status");
let popup;
let timer;

async function submit(proof) {
  if (popup && !popup.closed) popup.close();
  clearInterval(timer);
  const { state, accountId, publicKey, signature, error } = proof;
  try {
    const reply = await fetch("/wallet/complete", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ state, accountId, publicKey, signature, canceled: Boolean(error) }),
    });
    status.textContent = (await reply.json()).message;
  } catch {
    status.textContent = "Could not reach the wallet bridge. Return to the game to retry.";
  }
}

if (button) {
  const signUrl = new URL(button.dataset.signUrl);
  button.onclick = () => {
    popup = window.open(signUrl.href, "dead-route-near", "popup,width=500,height=700");
    if (!popup) {
      status.textContent = "Allow pop-ups for this site, then try again.";
      return;
    }
    button.disabled = true;
    status.textContent = "Approve the sign-in message in MyNearWallet.";
    timer = setInterval(() => {
      if (popup.closed) {
        clearInterval(timer);
        button.disabled = false;
        status.textContent = "Wallet window closed. You can retry or return to the game.";
      }
    }, 500);
  };
  window.addEventListener("message", (event) => {
    if (event.origin !== signUrl.origin || event.source !== popup) return;
    const state = signUrl.searchParams.get("state");
    if (event.data?.status === "success") submit({ ...event.data.signedRequest, state });
    if (event.data?.status === "failure") submit({ state, error: true });
  });
} else {
  const proof = Object.fromEntries(new URLSearchParams(location.hash.slice(1)));
  history.replaceState(null, "", location.pathname);
  submit(proof);
}
