<?php
// posts.php — the feeds, and the four things you can do to a post or a person.

declare(strict_types=1);

/**
 * How far either side of the slider counts as "people like this" before the
 * band is widened to reach a usable number of them.
 */
const REP_BAND = 90;

/** The smallest number of accounts a feed will draw from. */
const REP_MIN_MATCHES = 5;

/**
 * The accounts whose reputation sits near where the slider is.
 *
 * Everyone inside the tight band qualifies; if that is fewer than five people
 * — which it always is on a young site, and often is at the ends of the
 * scale — the nearest five are taken instead. Without that floor the slider
 * has dead zones that look like the site is broken.
 *
 * @return list<int>
 */
function matched_user_ids(int $rep): array
{
    $rows = query(
        'WITH target AS (SELECT :rep::int AS rep),
              tight AS (
                  SELECT count(*) AS n
                    FROM user_reputation, target
                   WHERE abs(reputation - target.rep) <= ' . REP_BAND . '
              )
         SELECT ur.user_id
           FROM user_reputation ur, target
          ORDER BY abs(ur.reputation - target.rep), ur.user_id
          LIMIT (SELECT greatest(' . REP_MIN_MATCHES . ', n) FROM tight)',
        ['rep' => $rep]
    );

    return array_map(static fn (array $row): int => (int) $row['user_id'], $rows);
}

/**
 * Which accounts a given feed draws from.
 *
 * You are always in your own feeds — seeing your own saves sitting among
 * other people's is how you tell where you stand.
 *
 * @return list<int>
 */
function feed_user_ids(string $view, ?int $viewerId, int $rep): array
{
    $ids = matched_user_ids($rep);

    if ($view === 'follows') {
        if ($viewerId === null) {
            return [];
        }

        $followed = array_map(
            static fn (array $row): int => (int) $row['followee_id'],
            query('SELECT followee_id FROM follows WHERE follower_id = :id', ['id' => $viewerId])
        );

        // The reputation filter still applies to people you follow. That is
        // deliberate: the slider is how you narrow a big follow list down to
        // the part of it you are in the mood for.
        $ids = array_values(array_intersect($ids, $followed));
    }

    if ($viewerId !== null && !in_array($viewerId, $ids, true)) {
        $ids[] = $viewerId;
    }

    return $ids;
}

/**
 * A page of a feed.
 *
 * @return list<array<string,mixed>>
 */
function feed_posts(string $view, ?int $viewerId, int $rep): array
{
    $ids = feed_user_ids($view, $viewerId, $rep);

    if ($ids === []) {
        return [];
    }

    $order = match ($view) {
        'popular' => 'likes DESC, created_at DESC',
        'random'  => 'random()',
        default   => 'created_at DESC',
    };

    // The popular feed folds the same video down to one entry. Two people
    // saving it independently is the interesting signal, but seeing it listed
    // twice in a row is just noise, so the best-liked save represents it.
    $source = $view === 'popular'
        ? 'SELECT DISTINCT ON (video_id) * FROM visible ORDER BY video_id, likes DESC, created_at DESC'
        : 'SELECT * FROM visible';

    return query(
        'WITH me AS (SELECT :viewer::bigint AS id),
              visible AS (
                  SELECT s.id, s.user_id, s.video_id, s.title, s.created_at,
                         s.author, s.likes,
                         (s.user_id = me.id)::int AS mine,
                         EXISTS (
                             SELECT 1 FROM likes l
                              WHERE l.post_id = s.id AND l.user_id = me.id
                         )::int AS liked
                    FROM post_stats s, me
                   WHERE s.reports < ' . REPORT_THRESHOLD . '
                     AND s.user_id = ANY (string_to_array(:ids, \',\')::bigint[])
              )
         SELECT * FROM (' . $source . ') feed
          ORDER BY ' . $order . '
          LIMIT ' . PAGE_SIZE,
        [
            // No user has id 0, so a signed-out visitor matches nothing and
            // every post comes back as neither mine nor liked.
            'viewer' => $viewerId ?? 0,
            'ids'    => implode(',', $ids),
        ]
    );
}

/**
 * @return array<string,mixed>|null
 */
function user_by_name(string $name): ?array
{
    return query_one(
        'SELECT u.id, u.name, u.created_at,
                coalesce(r.reputation, 0) AS reputation,
                coalesce(r.score, 0) AS score
           FROM users u
           LEFT JOIN user_reputation r ON r.user_id = u.id
          WHERE u.name = :name',
        ['name' => $name]
    );
}

/**
 * One page of somebody's saves, newest first.
 *
 * $includeHidden is on only when you are looking at your own page: a post of
 * yours that reports have hidden should still be visible to you, marked, so
 * that it disappearing from the site is something you can find out about.
 *
 * @return list<array<string,mixed>>
 */
function posts_by_user(int $userId, ?int $viewerId, int $page, bool $includeHidden): array
{
    return query(
        'WITH me AS (SELECT :viewer::bigint AS id)
         SELECT s.id, s.user_id, s.video_id, s.title, s.created_at, s.author,
                s.likes,
                (s.user_id = me.id)::int AS mine,
                (s.reports >= ' . REPORT_THRESHOLD . ')::int AS hidden,
                EXISTS (
                    SELECT 1 FROM likes l
                     WHERE l.post_id = s.id AND l.user_id = me.id
                )::int AS liked
           FROM post_stats s, me
          WHERE s.user_id = :author
            AND (s.reports < ' . REPORT_THRESHOLD . ' OR :include_hidden)
          ORDER BY s.created_at DESC
          LIMIT ' . PAGE_SIZE . ' OFFSET ' . ($page * PAGE_SIZE),
        [
            'viewer'         => $viewerId ?? 0,
            'author'         => $userId,
            'include_hidden' => $includeHidden ? 'true' : 'false',
        ]
    );
}

function post_count_for_user(int $userId, bool $includeHidden): int
{
    $row = query_one(
        'SELECT count(*) AS n
           FROM post_stats
          WHERE user_id = :author
            AND (reports < ' . REPORT_THRESHOLD . ' OR :include_hidden)',
        ['author' => $userId, 'include_hidden' => $includeHidden ? 'true' : 'false']
    );

    return (int) ($row['n'] ?? 0);
}

/**
 * Save a video. Returns the post id, or null if this account already has it.
 */
function create_post(int $userId, string $videoId, string $title): ?int
{
    $row = query_one(
        'INSERT INTO posts (user_id, video_id, title)
              VALUES (:user, :video, :title)
         ON CONFLICT (user_id, video_id) DO NOTHING
           RETURNING id',
        ['user' => $userId, 'video' => $videoId, 'title' => $title]
    );

    return $row === null ? null : (int) $row['id'];
}

function delete_post(int $postId, int $userId): bool
{
    // The user_id in the WHERE clause is the authorisation check — there is
    // no separate "is this yours" query that could fall out of step with it.
    return execute(
        'DELETE FROM posts WHERE id = :id AND user_id = :user',
        ['id' => $postId, 'user' => $userId]
    ) > 0;
}

/**
 * Like or unlike, returning the state afterwards.
 *
 * Written as delete-then-insert-if-nothing-was-deleted so that a double click
 * cannot leave a row behind: whichever request arrives second undoes the
 * first, rather than both trying to insert and one failing.
 */
function toggle_like(int $postId, int $userId): bool
{
    if (execute('DELETE FROM likes WHERE post_id = :p AND user_id = :u', ['p' => $postId, 'u' => $userId]) > 0) {
        return false;
    }

    execute(
        // The SELECT ... FROM posts is what enforces "you cannot like your
        // own save": no matching row means no insert, with no round trip
        // spent asking who the author is. The EXISTS is the same trick for
        // "you must have saved something first" — the routes check it too, to
        // say so out loud, but this is what makes it true.
        'INSERT INTO likes (post_id, user_id)
              SELECT :p::bigint, :u::bigint FROM posts
               WHERE id = :p2 AND user_id <> :u2
                 AND EXISTS (SELECT 1 FROM posts mine WHERE mine.user_id = :u3)
         ON CONFLICT DO NOTHING',
        ['p' => $postId, 'u' => $userId, 'p2' => $postId, 'u2' => $userId, 'u3' => $userId]
    );

    return liked($postId, $userId);
}

/**
 * Has this account saved anything yet?
 *
 * Voting, repping and reporting all wait on this. An account is free and takes
 * one click, which makes accounts the cheapest thing on the site — and votes
 * and reports are both denominated in accounts. Requiring one real saved video
 * first does not make accounts harder to create; it makes empty ones worthless,
 * which is the part that actually matters. A person saves something anyway. A
 * script has to find a real video id and survive a round trip to YouTube for
 * every account it wants to vote with.
 */
function has_saved_anything(int $userId): bool
{
    return query_one(
        'SELECT 1 AS yes FROM posts WHERE user_id = :id LIMIT 1',
        ['id' => $userId]
    ) !== null;
}

function liked(int $postId, int $userId): bool
{
    return query_one(
        'SELECT 1 AS yes FROM likes WHERE post_id = :p AND user_id = :u',
        ['p' => $postId, 'u' => $userId]
    ) !== null;
}

function like_count(int $postId): int
{
    $row = query_one('SELECT count(*) AS n FROM likes WHERE post_id = :p', ['p' => $postId]);

    return (int) ($row['n'] ?? 0);
}

function toggle_follow(int $followerId, int $followeeId): bool
{
    if ($followerId === $followeeId) {
        return false;
    }

    if (execute(
        'DELETE FROM follows WHERE follower_id = :a AND followee_id = :b',
        ['a' => $followerId, 'b' => $followeeId]
    ) > 0) {
        return false;
    }

    execute(
        'INSERT INTO follows (follower_id, followee_id) VALUES (:a, :b) ON CONFLICT DO NOTHING',
        ['a' => $followerId, 'b' => $followeeId]
    );

    return true;
}

function follows(int $followerId, int $followeeId): bool
{
    return query_one(
        'SELECT 1 AS yes FROM follows WHERE follower_id = :a AND followee_id = :b',
        ['a' => $followerId, 'b' => $followeeId]
    ) !== null;
}

function toggle_rep(int $voterId, int $subjectId): bool
{
    if ($voterId === $subjectId) {
        return false;
    }

    if (execute(
        'DELETE FROM rep_votes WHERE voter_id = :a AND subject_id = :b',
        ['a' => $voterId, 'b' => $subjectId]
    ) > 0) {
        return false;
    }

    execute(
        'INSERT INTO rep_votes (voter_id, subject_id)
              SELECT :a::bigint, :b::bigint
               WHERE EXISTS (SELECT 1 FROM posts mine WHERE mine.user_id = :a2)
         ON CONFLICT DO NOTHING',
        ['a' => $voterId, 'b' => $subjectId, 'a2' => $voterId]
    );

    return gave_rep($voterId, $subjectId);
}

function gave_rep(int $voterId, int $subjectId): bool
{
    return query_one(
        'SELECT 1 AS yes FROM rep_votes WHERE voter_id = :a AND subject_id = :b',
        ['a' => $voterId, 'b' => $subjectId]
    ) !== null;
}

function reputation_of(int $userId): int
{
    $row = query_one('SELECT reputation FROM user_reputation WHERE user_id = :id', ['id' => $userId]);

    return (int) ($row['reputation'] ?? 0);
}

/** Reporting is one-way. There is no unreport, so there is nothing to game. */
function report_post(int $postId, int $userId): void
{
    execute(
        'INSERT INTO reports (post_id, user_id)
              SELECT :p::bigint, :u::bigint FROM posts
               WHERE id = :p2 AND user_id <> :u2
                 AND EXISTS (SELECT 1 FROM posts mine WHERE mine.user_id = :u3)
         ON CONFLICT DO NOTHING',
        ['p' => $postId, 'u' => $userId, 'p2' => $postId, 'u2' => $userId, 'u3' => $userId]
    );
}

/**
 * Everything the site holds about one account, for the export link.
 *
 * The key is not in here and cannot be — only its hash was ever stored.
 *
 * @return array<string,mixed>
 */
function export_account(int $userId): array
{
    $user = query_one(
        'SELECT u.name, u.created_at,
                coalesce(r.reputation, 0) AS reputation,
                coalesce(r.score, 0) AS score
           FROM users u
           LEFT JOIN user_reputation r ON r.user_id = u.id
          WHERE u.id = :id',
        ['id' => $userId]
    ) ?? [];

    return [
        'account'   => $user,
        'saved'     => query(
            'SELECT video_id, title, created_at, likes
               FROM post_stats WHERE user_id = :id ORDER BY created_at',
            ['id' => $userId]
        ),
        'liked'     => query(
            'SELECT s.video_id, s.title, s.author, l.created_at AS liked_at
               FROM likes l JOIN post_stats s ON s.id = l.post_id
              WHERE l.user_id = :id ORDER BY l.created_at',
            ['id' => $userId]
        ),
        'following' => query(
            'SELECT u.name, f.created_at
               FROM follows f JOIN users u ON u.id = f.followee_id
              WHERE f.follower_id = :id ORDER BY f.created_at',
            ['id' => $userId]
        ),
        'exported'  => date('c'),
    ];
}
