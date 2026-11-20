SELECT secret --\rFROM secrets
----
SELECT 1 --\r, danger()
----
SELECT 1 AS a$x$, secret FROM secrets AS b$x$
----
SELECT 1 AS a$x$, danger() AS b$x$
----
SELECT 1 +-- $x$
 2, secret FROM secrets --$x$
----
SELECT 1 +/* ' */ 2, secret FROM secrets --'
----
SELECT $$éé$$, secret FROM secrets --$$
----
SELECT unıon.name, secrets.secret FROM users unıon, secrets
----
WITH secrets AS (SELECT * FROM secrets) SELECT * FROM secrets
----
SELECT secret FROM secrets WHERE EXISTS (WITH secrets AS (SELECT 1) SELECT 1)
----
WITH danger_set AS (SELECT 1) SELECT * FROM danger_set()
----
@invalid
WITH a AS (SELECT * FROM b), b AS (SELECT 1 AS x) SELECT * FROM a
----
WITH RECURSIVE secrets(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM secrets WHERE n < 3) SELECT * FROM secrets
----
WITH RECURSIVE a AS (SELECT 1 AS x), b AS (SELECT * FROM a) SELECT * FROM b, secrets
----
WITH x AS (SELECT 1 AS a) SELECT * FROM x, (WITH secrets AS (SELECT 2 AS b) SELECT * FROM secrets) y, secrets z
----
WITH users AS (SELECT 1 AS id) SELECT * FROM pgsqlarbiter_oracle.users
----
WITH "Users" AS (SELECT 1 AS id) SELECT * FROM users
----
SELECT * FROM (TABLE secrets) x
----
SELECT id, name FROM users UNION ALL TABLE secrets
----
TABLE secrets
----
(TABLE secrets)
----
SELECT trim((SELECT secret FROM secrets LIMIT 1))
----
SELECT extract(epoch FROM now()), substring((SELECT secret FROM secrets) FROM 1)
----
SELECT overlay('abc' PLACING (SELECT secret FROM secrets) FROM 1), position('a' IN (SELECT secret FROM secrets))
----
SELECT s.secret FROM users u JOIN users u2 ON true, secrets s
----
SELECT s.secret FROM users *, secrets s
----
SELECT s.secret FROM unnest(ARRAY[1]) WITH ORDINALITY, secrets s
----
SELECT 1 FROM (secrets CROSS JOIN users)
----
SELECT * FROM ONLY (secrets)
----
SELECT * FROM ONLY secrets
----
SELECT * FROM users NATURAL JOIN secrets
----
SELECT 1 FROM users u LEFT OUTER JOIN (secrets s JOIN orders o USING (id)) ON true
----
SELECT 1 FROM users, LATERAL (SELECT * FROM secrets WHERE secrets.id = users.id) s
----
SELECT 1 FROM users TABLESAMPLE bernoulli (10), secrets
----
SELECT * FROM ROWS FROM (danger_set(), generate_series(1, 2)) AS t(a, b)
----
SELECT * FROM danger_set() WITH ORDINALITY AS t(a, n), secrets
----
SELECT (SELECT secret FROM secrets LIMIT 1)
----
SELECT * FROM users WHERE id IN (SELECT id FROM secrets)
----
SELECT * FROM users WHERE id = ANY (ARRAY(SELECT id FROM secrets))
----
SELECT * FROM users WHERE EXISTS (TABLE secrets)
----
SELECT ARRAY(SELECT id FROM secrets), EXISTS (TABLE secrets) AS e
----
SELECT CASE WHEN true THEN (SELECT secret FROM secrets LIMIT 1) END
----
SELECT 1 ORDER BY (SELECT id FROM secrets LIMIT 1)
----
SELECT 1 LIMIT (SELECT id FROM secrets LIMIT 1) OFFSET (SELECT count(*) FROM orders)
----
SELECT 1 FETCH FIRST (SELECT id FROM secrets LIMIT 1) ROWS ONLY
----
SELECT count(*) FILTER (WHERE id IN (SELECT id FROM secrets)) FROM users
----
SELECT sum(id) OVER (PARTITION BY (SELECT id FROM secrets LIMIT 1) ORDER BY danger(id)) FROM users
----
SELECT sum(id) OVER w FROM users WINDOW w AS (ORDER BY danger(id) ROWS BETWEEN danger() PRECEDING AND CURRENT ROW)
----
SELECT 1 FROM users GROUP BY ROLLUP (danger(id)), CUBE (id), GROUPING SETS ((danger(1)))
----
SELECT 1 FROM users GROUP BY id HAVING danger(id) > 0
----
SELECT DISTINCT ON (danger(id)) id FROM users
----
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY danger(id)) FROM users
----
SELECT array_agg(id ORDER BY danger(id)) FROM users
----
SELECT danger()
----
SELECT "danger"()
----
SELECT pgsqlarbiter_oracle.danger()
----
SELECT postgres.pgsqlarbiter_oracle.danger()
----
SELECT DANGER ( 1 )
----
SELECT danger /* c */ (1)
----
SELECT danger
(1)
----
SELECT first(1), filter(2)
----
SELECT danger_agg(id) FROM users
----
SELECT danger_agg(DISTINCT id ORDER BY id) FILTER (WHERE true) FROM users
----
SELECT u.danger_row FROM users u
----
SELECT (u).danger_row FROM users u
----
SELECT (u.*).danger_row FROM users u
----
SELECT users.danger_row FROM users
----
SELECT (1).danger
----
SELECT (id).danger FROM users
----
SELECT (name).danger FROM users
----
SELECT (u.id).danger_any FROM users u
----
SELECT u.danger_any FROM users u
----
SELECT ($$x$$::text).danger
----
SELECT (ARRAY[1,2])[1].danger
----
SELECT (SELECT 1).danger
----
SELECT 1 WHERE danger(1) = 1
----
SELECT coalesce(danger(), 1), nullif(danger(), 2), greatest(danger(1)), least(danger(1))
----
SELECT CAST(danger() AS text) AS a, danger()::text AS b, text(danger()) AS c
----
SELECT ROW(1, 'x')::secret_type
----
SELECT CAST(NULL AS secret_type), (NULL::secret_type).a
----
SELECT NULL::secrets
----
SELECT (NULL::pgsqlarbiter_oracle.secrets).secret
----
SELECT secret_type '(1,2)'
----
SELECT ARRAY[]::secret_type[]
----
SELECT * FROM json_to_record('{}') AS x(a secret_type)
----
SELECT * FROM json_populate_record(NULL::secrets, '{}')
----
SELECT * FROM XMLTABLE('/r' PASSING CAST('<r/>' AS xml) COLUMNS a text PATH danger('.')) x
----
SELECT * FROM JSON_TABLE('[]', '$[*]' COLUMNS (a int PATH '$.a' DEFAULT danger() ON EMPTY)) jt
----
SELECT JSON_VALUE('{}'::jsonb, '$.a' RETURNING secret_type)
----
SELECT XMLSERIALIZE(CONTENT '<a/>'::xml AS text), xmlelement(name a, danger())
----
SELECT JSON_OBJECT('a': danger()) AS a, JSON_ARRAY(danger(), 2) AS b, JSON_ARRAY(SELECT id FROM secrets) AS c
----
@refused
SELECT 1 OPERATOR(pg_catalog.+) danger()
----
SELECT 1 + danger() AS a, - danger() AS b, danger() IS NULL AS c, danger() BETWEEN 1 AND danger(1) AS d, danger() IN (1, danger(2)) AS e
----
SELECT 'a' LIKE danger('a') ESCAPE danger('b') AS a, 'a' SIMILAR TO danger('a') AS b, 'a' ~ danger('a') AS c
----
SELECT ROW(danger(), 1)::secret_type AS a, (danger(), 'x')::secret_type AS b, ARRAY[danger()] AS c, ARRAY[[danger()]] AS d
----
SELECT (ARRAY[1,2,3])[danger():danger(2)], data['a'][danger('b')] FROM users
----
SELECT now() AT TIME ZONE danger('UTC'), 'a' COLLATE "C", interval '1' day
----
SELECT 1 FROM users u WHERE (u.id, u.name) = (SELECT id, secret FROM secrets)
----
SELECT 1 FROM users u WHERE u.id > ALL (SELECT id FROM secrets) OR u.id = SOME (SELECT id FROM orders)
----
SELECT * FROM users FOR UPDATE OF users
----
SELECT * FROM generate_series(1, danger()) g
----
VALUES (1, (SELECT secret FROM secrets LIMIT 1)), (danger(), 'x')
----
SELECT * FROM (VALUES ((SELECT id FROM secrets LIMIT 1))) v(x)
----
SELECT x.* FROM users, LATERAL danger_set() x
----
SELECT 1 FROM users JOIN LATERAL (TABLE secrets) s ON true
----
SELECT "secrets".* FROM "secrets"
----
SELECT * FROM SECRETS
----
SELECT * FROM pgsqlarbiter_oracle."secrets"
----
SELECT * FROM postgres.pgsqlarbiter_oracle.secrets
----
SELECT * FROM U&"\0073ecrets"
----
SELECT * FROM U&"!0073ecrets" UESCAPE '!'
----
SELECT U&"\0064anger"()
----
SELECT E'it\'s', secret FROM secrets
----
SELECT 'a'
'b', secret FROM secrets
----
SELECT 'a' -- continues
  'b', secret FROM secrets
----
SELECT E'a\\'
  'b\' , danger() , ' AS a, 1 AS b
----
SELECT B'1' AS a, X'1F' AS b, N'x' AS c, secret FROM secrets
----
SELECT 1.5 AS a, .5 AS b, 1. AS c, 1e5 AS d, 0x1F AS e, 1_000 AS f, secret FROM secrets
----
SELECT 1<-1 AS a, 2 >=-1 AS b, 3 <>+1 AS c, 1 *-1 AS d, @ -1 AS e, secret FROM secrets
----
SELECT 1 /* outer /* nested */ still comment */ , secret FROM secrets
----
SELECT $tag$ $other$ ' " -- /* $tag$, secret FROM secrets
----
@invalid
SELECT $1::int, secret FROM secrets
----
SELECT secrets.secret FROM secrets secrets
----
SELECT * FROM users AS secrets
----
SELECT * FROM users u(a, b, c, d) WHERE a = danger()
----
SELECT 1 FROM users WHERE name IS DISTINCT FROM (SELECT secret FROM secrets LIMIT 1)
----
SELECT * FROM users ORDER BY id USING < NULLS FIRST
----
SELECT * FROM users WHERE id = 1 UNION (SELECT id, secret, NULL, NULL FROM secrets) INTERSECT TABLE users EXCEPT ALL SELECT * FROM users
----
SELECT (SELECT (SELECT (SELECT secret FROM secrets LIMIT 1)))
----
SELECT ((((SELECT secret FROM (((secrets CROSS JOIN (SELECT 1) q))) LIMIT 1))))
----
SELECT g.danger FROM generate_series(1, 3) g
----
SELECT g.g FROM generate_series(1, 3) g
----
SELECT g.n, g.danger FROM generate_series(1, 3) AS g(n)
----
SELECT generate_series.danger FROM generate_series(1, 3)
----
SELECT d.danger FROM danger_set() d
----
SELECT danger_set.danger FROM pgsqlarbiter_oracle.danger_set()
----
SELECT s.danger_any FROM ROWS FROM (danger_set()) s
----
SELECT t.danger_any FROM unnest(ARRAY[1]) WITH ORDINALITY t
----
SELECT d.danger_any FROM current_date d
----
@invalid
SELECT current_date.danger_any FROM current_date
----
SELECT "coalesce".danger FROM coalesce(1)
----
SELECT x.danger FROM (SELECT 1 AS danger) x
----
SELECT x.danger_any FROM (SELECT 1) x
----
SELECT (SELECT g.danger) FROM generate_series(1, 2) g
----
SELECT 1 FROM generate_series(1, 2) g WHERE g.danger > 0 ORDER BY g.danger
----
SELECT u.tags[1].danger FROM users u
----
SELECT tags[1].danger FROM users
----
@invalid
SELECT ($1).danger
----
SELECT e.key, e.value FROM jsonb_each('{}'::jsonb) e
----
SELECT (jsonb_each('{}'::jsonb)).key
----
SELECT u.id, u.name FROM users u JOIN LATERAL generate_series(1, u.id) g ON true WHERE g.g > 0
----
@invalid
SELECT j.a.danger FROM json_to_record('{}') AS j(a int)
----
SELECT (g).danger FROM generate_series(1, 2) g
----
SELECT x.danger FROM (SELECT 1 AS danger) x, generate_series(1, 2) g
----
@invalid
WITH secrets AS (SELECT 1) DELETE FROM secrets
----
SELECT * FROM users WHERE name = (SELECT secret FROM secrets WHERE secrets.id = users.id)
----
SELECT * FROM JSON_TABLE('[]'::jsonb, '$[*]' COLUMNS (NESTED PATH '$.a' COLUMNS (b secret_type PATH '$'))) jt
----
SELECT merge_action.danger_any FROM (SELECT 1) merge_action, generate_series(1, 1) g
----
SELECT e.key, e.value FROM jsonb_each('{}'::jsonb) e
----
SELECT e.danger FROM jsonb_each_text('{}'::jsonb) AS e(danger, v)
----
SELECT t.ordinality, t.danger_any FROM unnest(ARRAY[1]) WITH ORDINALITY t
----
SELECT u.email FROM users u
----
SELECT users.email FROM users
----
SELECT pgsqlarbiter_oracle.users.email FROM users
----
SELECT x.email FROM (SELECT * FROM users) x
----
@invalid
SELECT x.email FROM (SELECT id, name FROM users) x
----
SELECT x.email FROM (SELECT u.* FROM users u) x
----
SELECT x.g FROM (SELECT id AS g FROM users) x
----
SELECT x.g FROM (SELECT id FROM users) x
----
SELECT x.id FROM (SELECT id FROM users) x
----
SELECT x.id FROM (SELECT users.id FROM users) x
----
SELECT x.id FROM (SELECT (id) FROM users) x
----
SELECT x.id FROM (SELECT id::text FROM users) x
----
@invalid
SELECT x.name FROM (SELECT id::text FROM users) x
----
SELECT x.lower FROM (SELECT lower(name) FROM users) x
----
SELECT x.lower FROM (SELECT pg_catalog.lower(name)::varchar FROM users) x
----
SELECT x.count FROM (SELECT count(*) FILTER (WHERE id > 0) OVER () FROM users) x
----
SELECT x.g FROM (SELECT lower(name) FROM users) x
----
SELECT x.g FROM (SELECT name || 'x' FROM users) x
----
SELECT x.g FROM (SELECT tags[1] FROM users) x
----
SELECT x.tags FROM (SELECT tags[1] FROM users) x
----
SELECT x.tags FROM (SELECT u.tags[1] FROM users u) x
----
SELECT x.g FROM (SELECT (id).g FROM users) x
----
@invalid
SELECT x.id FROM (SELECT (id).g FROM users) x
----
SELECT x.email FROM (SELECT (u.*) FROM users u) x
----
SELECT x.name FROM (SELECT (u.*) FROM users u) x
----
SELECT x.g FROM (SELECT 1) x
----
SELECT x.g FROM (VALUES (1, 2)) x
----
SELECT x.column2 FROM (VALUES (1, 2)) x
----
@invalid
SELECT x.column3 FROM (VALUES (1, 2), (3, 4)) x
----
SELECT x.g, x.column2 FROM (VALUES (1, 2)) x(g)
----
SELECT x.email FROM (TABLE users) x
----
SELECT x.name FROM (TABLE users) x
----
@invalid
SELECT x.email FROM (SELECT id FROM users UNION ALL SELECT id AS email FROM users) x
----
SELECT x.id FROM (SELECT id FROM users UNION ALL SELECT id AS email FROM users) x
----
SELECT x.id FROM ((SELECT id FROM users ORDER BY name) LIMIT 1) x
----
@invalid
WITH x AS (SELECT id FROM users) SELECT x.email FROM x
----
WITH x AS (SELECT id FROM users) SELECT x.id FROM x
----
@invalid
WITH x(g) AS (SELECT id FROM users) SELECT x.id FROM x
----
WITH x(g) AS (SELECT id FROM users) SELECT x.g FROM x
----
@invalid
WITH x AS (SELECT id FROM users) SELECT y.email FROM x y
----
WITH x AS (SELECT id FROM users) SELECT y.g FROM x AS y(g)
----
WITH RECURSIVE x AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM x WHERE n < 3) SELECT x.g, x.n FROM x
----
WITH RECURSIVE x AS (SELECT 1 AS n UNION ALL SELECT x.g FROM x WHERE n < 3) SELECT n FROM x
----
@invalid
SELECT j.email FROM (users u JOIN orders o ON true) AS j
----
SELECT j.name, j.amount FROM (users u JOIN orders o ON true) AS j
----
SELECT j.g FROM (users u JOIN orders o ON true) AS j(g)
----
SELECT j.name FROM (users u JOIN orders o ON true) AS j(g)
----
@invalid
SELECT x.email FROM (SELECT * FROM (users u JOIN orders o ON true) AS j(g, name)) x
----
@invalid
SELECT x.name FROM (SELECT * FROM (users u JOIN orders o ON true) AS j(g, h)) x
----
@invalid
SELECT j.email FROM users u JOIN orders o USING (id) AS j
----
SELECT j.id, u.name FROM users u JOIN orders o USING (id) AS j
----
@invalid
SELECT j.name FROM users u JOIN orders o USING (id) AS j
----
SELECT id FROM users u JOIN orders o USING (id)
----
SELECT 1 FROM users NATURAL JOIN orders
----
SELECT 1 FROM users u NATURAL JOIN (SELECT id FROM secrets) s
----
@invalid
SELECT u.email FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.email = u.id)
----
SELECT (SELECT u.email) FROM users u
----
@invalid
SELECT (SELECT u.name FROM orders u LIMIT 1) FROM users u
----
SELECT 1 FROM users u, LATERAL (SELECT u.email) x
----
SELECT 1 FROM users u ORDER BY u.email
----
SELECT 1 FROM users u GROUP BY u.email
----
SELECT 1 FROM users u HAVING max(u.email) > 'a'
----
SELECT sum(1) OVER (PARTITION BY u.email) FROM users u
----
@invalid
SELECT 1 FROM users u JOIN orders o ON o.email = u.id
----
SELECT r.month, r.total FROM report() r
----
SELECT r.g FROM report() r
----
SELECT report.g FROM report()
----
SELECT r.month, r.ordinality FROM report() WITH ORDINALITY r
----
SELECT r.g FROM report() AS r(g)
----
SELECT r.month FROM report() AS r(g)
----
SELECT r.g, r.total FROM report() AS r(g)
----
SELECT p.a, p.b FROM pair() p
----
SELECT p.g FROM pair() p
----
SELECT s.g FROM one_secret() s
----
SELECT s.s FROM scalar_fn() s
----
SELECT s.g FROM scalar_fn() s
----
SELECT scalar_fn.scalar_fn FROM scalar_fn()
----
SELECT s.v FROM single_out() s
----
@invalid
SELECT s.s FROM single_out() s
----
SELECT s.g FROM single_out() s
----
SELECT g.g FROM generate_series(1, 2) g
----
SELECT g.g FROM generate_subscripts(ARRAY[1], 1) g
----
SELECT g.g FROM unnest(ARRAY[1]) g
----
SELECT g.g FROM unnest(ARRAY[1], ARRAY[2]) g
----
@invalid
SELECT g.unnest FROM unnest(ARRAY[1], ARRAY[2]) g
----
SELECT g.g FROM regexp_split_to_table('a b', ' ') g
----
SELECT g.g FROM string_to_table('a b', ' ') g
----
SELECT g.g FROM regexp_matches('a', 'a') g
----
SELECT g.g FROM json_object_keys('{}') g
----
SELECT g.g FROM jsonb_object_keys('{}') g
----
SELECT g.value FROM json_array_elements('[]') g
----
SELECT g.value FROM jsonb_array_elements('[]') g
----
SELECT g.value FROM json_array_elements_text('[]') g
----
SELECT g.value FROM jsonb_array_elements_text('[]') g
----
SELECT g.g FROM jsonb_array_elements('[]') g
----
SELECT g.key, g.value FROM json_each('{}') g
----
SELECT g.key, g.value FROM json_each_text('{}') g
----
SELECT g.key, g.value FROM jsonb_each_text('{}') g
----
SELECT g.g FROM jsonb_each('{}') g
----
SELECT g.g, g.ordinality FROM generate_series(1, 2) WITH ORDINALITY g
----
SELECT g.n, g.ordinality FROM generate_series(1, 2) WITH ORDINALITY g(n)
----
SELECT g.g FROM generate_series(1, 2) WITH ORDINALITY g(n)
----
SELECT g.g FROM pg_catalog.generate_series(1, 2) g
----
SELECT g.g FROM now() g
----
SELECT g.g FROM lower('x') g
----
SELECT x.a, x.g FROM XMLTABLE('/r' PASSING ('<r/>'::xml) COLUMNS a int PATH '.', b text) x
----
SELECT xmltable.a, xmltable.g FROM XMLTABLE('/r' PASSING ('<r/>'::xml) COLUMNS a int PATH '.')
----
SELECT j.a, j.c, j.g FROM JSON_TABLE('[]', '$[*]' COLUMNS (a int, NESTED '$.b' COLUMNS (c int))) j
----
SELECT json_table.a, json_table.g FROM JSON_TABLE('[]', '$[*]' COLUMNS (a int))
----
SELECT x.g, y.g AS h FROM (SELECT 1 AS g) x, (SELECT 2) y
----
SELECT x.g FROM (SELECT 1 AS g) x WHERE EXISTS (SELECT x.g FROM (SELECT 2) x)
----
SELECT u.name, name AS n2, tags, u FROM users u
----
SELECT users FROM users
----
SELECT count(u), count(u.*) AS c2 FROM users u
----
SELECT u.ctid, u.xmin, tableoid FROM users u
----
SELECT 1 FROM users u WHERE u IS NOT NULL
----
SELECT j IS NULL FROM (users u JOIN orders o ON true) AS j
----
@invalid
SELECT user_names.name, user_names.email FROM user_names
----
SELECT x.email FROM users u, LATERAL (SELECT u.*) x
----
SELECT x.name FROM users u, LATERAL (SELECT u.*) x
----
SELECT id AS g FROM users ORDER BY g
----
SELECT id AS g FROM users GROUP BY g
----
@invalid
SELECT name AS id FROM users GROUP BY id
----
SELECT name AS id FROM users ORDER BY id
----
SELECT 1 FROM users ORDER BY (name)
----
SELECT id FROM users UNION SELECT id FROM orders ORDER BY id
----
SELECT x.g FROM (SELECT report()) x
----
SELECT x.name FROM (SELECT u.name::text COLLATE "C" FROM users u) x
----
SELECT x.g FROM (SELECT u.name::text COLLATE "C" FROM users u) x
----
SELECT x.name FROM (SELECT (SELECT name FROM users LIMIT 1)) x
----
SELECT x.g FROM (SELECT (SELECT name FROM users LIMIT 1)) x
----
SELECT x.g FROM (SELECT CASE WHEN true THEN name END FROM users) x
----
SELECT x.g FROM (SELECT coalesce(name) FROM users) x
----
SELECT x.g FROM (SELECT CAST(name AS text) FROM users) x
----
SELECT x.g FROM (SELECT ARRAY[name] FROM users) x
----
SELECT x.g FROM (SELECT ROW(name) FROM users) x
----
SELECT x.g FROM (SELECT - id FROM users) x
----
SELECT x.g FROM (SELECT 'a'::text) x
----
SELECT x.g FROM (SELECT current_date) x
----
SELECT x.g FROM (SELECT count(*) FROM users) x
----
SELECT t.g FROM unnest(to_tsvector('a b')) t
----
SELECT t.lexeme FROM unnest(to_tsvector('a b')) t
----
SELECT g.g FROM unnest(to_tsvector('a b')) g
----
SELECT t.g FROM unnest(ARRAY[ROW(1, 'x')::secret_type]) t
----
SELECT t.a, t.b FROM unnest(ARRAY[ROW(1, 'x')::secret_type]) AS t(a, b)
----
SELECT w.word, w.g FROM ts_stat('select null::tsvector') w
----
SELECT k.word, k.g FROM pg_get_keywords() k
