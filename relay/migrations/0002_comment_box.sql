-- A comment can point at an area of the page (a box the reader dragged) instead of a text quote.
-- JSON: {"x","y","w","h"} in CSS pixels of the document, "vw" the frame width when it was drawn,
-- and "near" the text under the centre of the box (max 200 characters).
ALTER TABLE comments ADD COLUMN box TEXT;
