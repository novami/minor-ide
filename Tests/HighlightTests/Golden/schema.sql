-- Users table
CREATE TABLE `users` (
	id SERIAL PRIMARY KEY,
	email VARCHAR(255) NOT NULL UNIQUE,
	note TEXT DEFAULT 'it''s \'ok\'
second line',
	created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP /* block
	comment */
);
SELECT u.id, COUNT(*) AS n FROM users u WHERE u.email LIKE ? AND id > :min OR id = $1 # mysql comment
	AND created_at::date > '2026-01-01' LIMIT 10.5;
