-- WAG-394: a screenshots round has several images. The names, in order, as JSON. The first is the entry.
ALTER TABLE rounds ADD COLUMN gallery TEXT;
