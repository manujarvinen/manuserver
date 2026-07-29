-- schema.sql — the whole Tastehopping database.
--
-- Applied by files/deploy/db-setup.sh at every boot of the server, and by
-- `manuserver.sh site_dev` when it builds a throwaway cluster. That means it
-- has to be safe to run against a database that already has data in it, so
-- every statement here is IF NOT EXISTS or OR REPLACE. Never write a
-- destructive statement in this file.

-- --- accounts --------------------------------------------------------------
--
-- There is no email, no password and no display name. An account is a
-- pronounceable nonsense name the server picked, plus one secret key.
--
-- key_hash holds sha256(key) in hex, and the key itself is 32 bytes from the
-- system CSPRNG. A plain unsalted SHA-256 would be the wrong choice for a
-- human-chosen password — but this is 256 bits of uniform randomness, so
-- there is no dictionary to run and nothing a slow KDF would buy. Hashing at
-- all is what matters: it means a copy of this table cannot log anyone in.
--
-- The consequence, and it is deliberate: the server cannot show you your key
-- a second time. Lose it and the account is gone.
-- last_seen is what decides whether an account still exists: files/deploy/
-- prune.sh deletes anything untouched for three months. It has to mean "last
-- used", not "last logged in" — a session cookie lasts a year, so somebody who
-- visits daily may never log in twice, and pruning on login time would delete
-- the most active accounts first. See touch_activity() in app/auth.php.
CREATE TABLE IF NOT EXISTS users (
    id         bigserial   PRIMARY KEY,
    name       text        NOT NULL UNIQUE
                           CHECK (name ~ '^[a-z]{2,4}-[a-z]{2,4}$'),
    key_hash   text        NOT NULL UNIQUE
                           CHECK (key_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS users_last_seen_idx ON users (last_seen);

-- --- saved videos ----------------------------------------------------------
--
-- video_id is YouTube's own 11-character id, not a URL. Storing the id rather
-- than whatever the poster pasted means youtu.be links, /shorts links and
-- links carrying a playlist or a timestamp all collapse to the same row, so
-- the same video cannot be saved twice by one person through the back door of
-- a differently-shaped URL.
--
-- Two *different* people saving the same video is allowed and is the point:
-- it is the signal that two people arrived at it independently. The popular
-- feed collapses those to one entry at query time.
CREATE TABLE IF NOT EXISTS posts (
    id         bigserial   PRIMARY KEY,
    user_id    bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    video_id   text        NOT NULL CHECK (video_id ~ '^[A-Za-z0-9_-]{11}$'),
    title      text        NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, video_id)
);

CREATE INDEX IF NOT EXISTS posts_user_idx    ON posts (user_id);
CREATE INDEX IF NOT EXISTS posts_created_idx ON posts (created_at DESC);

-- --- the three things one account can do to another ------------------------
--
-- All three are one-per-pair and all three are toggles, so the primary key is
-- the whole row and "already voted" is a uniqueness violation rather than
-- something the application has to check for first.

CREATE TABLE IF NOT EXISTS likes (
    post_id    bigint      NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id    bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, user_id)
);

CREATE INDEX IF NOT EXISTS likes_user_idx ON likes (user_id);

CREATE TABLE IF NOT EXISTS follows (
    follower_id bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    followee_id bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);

CREATE INDEX IF NOT EXISTS follows_followee_idx ON follows (followee_id);

-- Reputation is given to a person, not to a post — it is the "I trust this
-- one's taste generally" button on a profile.
CREATE TABLE IF NOT EXISTS rep_votes (
    voter_id   bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    subject_id bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (voter_id, subject_id),
    CHECK (voter_id <> subject_id)
);

CREATE INDEX IF NOT EXISTS rep_votes_subject_idx ON rep_votes (subject_id);

-- Reports are counted, not read. Nobody moderates this by hand; a post that
-- enough distinct accounts object to simply stops appearing in feeds. See
-- REPORT_THRESHOLD in files/site/app/posts.php for the number.
CREATE TABLE IF NOT EXISTS reports (
    post_id    bigint      NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    user_id    bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, user_id)
);

-- --- derived numbers -------------------------------------------------------

-- One row per post with its like and report counts folded in, so the feed
-- queries can select from a single relation and stay readable.
CREATE OR REPLACE VIEW post_stats AS
SELECT p.id,
       p.user_id,
       p.video_id,
       p.title,
       p.created_at,
       u.name AS author,
       -- Scalar subqueries rather than two LEFT JOINs and a GROUP BY: joining
       -- both tables at once multiplies likes by reports before the aggregate
       -- collapses them again, and the DISTINCT that repairs it hides the
       -- reason it was needed.
       (SELECT count(*) FROM likes   l WHERE l.post_id = p.id) AS likes,
       (SELECT count(*) FROM reports r WHERE r.post_id = p.id) AS reports
FROM posts p
JOIN users u ON u.id = p.user_id;

-- Raw standing: every like your saves collected, plus a heavier weight for
-- someone vouching for you as a person. The weight is the only tunable here
-- and it is arbitrary — one profile vote is worth ten likes because votes are
-- much rarer and cost the voter more thought.
CREATE OR REPLACE VIEW user_score AS
SELECT u.id                                  AS user_id,
       u.name,
       coalesce(l.n, 0) + 10 * coalesce(v.n, 0) AS score
FROM users u
LEFT JOIN (
    SELECT p.user_id, count(*) AS n
    FROM likes lk
    JOIN posts p ON p.id = lk.post_id
    GROUP BY p.user_id
) l ON l.user_id = u.id
LEFT JOIN (
    SELECT subject_id, count(*) AS n
    FROM rep_votes
    GROUP BY subject_id
) v ON v.subject_id = u.id
-- Only accounts that have saved something are ranked at all.
--
-- This is what stops a pile of empty accounts distorting the scale. Reputation
-- is a percentile, so a million registrations with nothing in them would push
-- every real person into the top of the range and leave the slider selecting
-- the same handful of people everywhere you moved it. An account that has not
-- saved anything has expressed no taste, so it has no position among people
-- who have.
WHERE EXISTS (SELECT 1 FROM posts p WHERE p.user_id = u.id);

-- The number the reputation slider filters on, and the only reputation the
-- site ever displays.
--
-- It is a percentile, not the raw score, and that is the important design
-- choice. A raw score would sit near zero for everyone on a young site and
-- the slider would select nothing, all the way to 1000. A percentile always
-- spreads the population across the full 0-1000 range, so "show me what
-- people around 200 are saving" means something on day one and still means
-- the same thing after a year. It also means reputation is relative: you go
-- down when others go up, without anything being taken from you.
CREATE OR REPLACE VIEW user_reputation AS
SELECT user_id,
       name,
       score,
       round(1000 * percent_rank() OVER (ORDER BY score))::int AS reputation
FROM user_score;
