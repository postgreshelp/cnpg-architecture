-- Test schema, same shape as the original assignment (authors/books FK + a scratch "test" table),
-- retargeted for validating replication/DR/PITR on this build.
CREATE TABLE IF NOT EXISTS authors (
    author_id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    author_id INT REFERENCES authors(author_id)
);

CREATE TABLE IF NOT EXISTS test (
    id  INT,
    val INT
);

INSERT INTO test VALUES (1, 1);
