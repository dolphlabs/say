ALTER TABLE markets
    ADD COLUMN book_mode text NOT NULL DEFAULT 'OPEN'
        CHECK (book_mode IN ('OPEN','SUSPENDED','CLOSED'));
