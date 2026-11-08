"use strict";

// A tiny pricing-card prototype: choosing Pro on either layout confirms in
// place. No network, no external URLs.
const buttons = document.querySelectorAll(".cta");
const note = document.getElementById("note");

for (const button of buttons) {
  button.addEventListener("click", () => {
    const card = button.closest(".card");
    const layout = card ? card.dataset.layout : "?";
    note.textContent = `Chose Pro on layout ${layout}. This prototype takes no payment.`;
  });
}
