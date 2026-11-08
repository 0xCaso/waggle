"use strict";

// A tiny checkout prototype: toggling Monthly/Annual updates the price and the
// pay button confirms in place. No network, no external URLs.
const prices = {
  monthly: "$9/mo",
  annual: "$90/yr",
};

const options = document.querySelectorAll(".toggle-option");
const price = document.getElementById("price");
const pay = document.getElementById("pay");
const note = document.getElementById("note");

for (const option of options) {
  option.addEventListener("click", () => {
    for (const other of options) {
      other.classList.remove("is-active");
    }
    option.classList.add("is-active");
    price.textContent = prices[option.dataset.period];
  });
}

pay.addEventListener("click", () => {
  note.textContent = "Paid. This prototype takes no payment.";
});
