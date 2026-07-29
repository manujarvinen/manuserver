<?php
// auth.php — accounts without identity.
//
// Signing up asks for nothing. The server invents a name, mints a key, shows
// the key once and forgets it. The key is the account: whoever holds it is
// that user, and nobody — including this server — can recover it.

declare(strict_types=1);

/**
 * Consonants that survive being stuck on the front of a syllable. No q, c, w,
 * x or y: each of them reads two or three different ways depending on what
 * follows, and these names have to be sayable at a glance.
 */
const NAME_ONSETS = ['b', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm', 'n', 'p', 'r', 's', 't', 'v', 'z'];

/** Consonants that end a syllable cleanly. */
const NAME_CODAS = ['b', 'd', 'f', 'k', 'l', 'm', 'n', 'p', 'r', 's', 't', 'z'];

const NAME_VOWELS = ['a', 'e', 'i', 'o', 'u'];

/** How many colliding names to shrug off before giving up. */
const NAME_ATTEMPTS = 40;

/**
 * One syllable, either consonant-vowel-consonant (tul, pal, fon) or
 * vowel-consonant-vowel (ori, ika, ale). Mixing the two shapes is what stops
 * every name on the site sounding like the same name.
 */
function name_syllable(): string
{
    if (random_int(0, 1) === 0) {
        return pick(NAME_ONSETS) . pick(NAME_VOWELS) . pick(NAME_CODAS);
    }

    return pick(NAME_VOWELS) . pick(NAME_CODAS) . pick(NAME_VOWELS);
}

/** @param list<string> $set */
function pick(array $set): string
{
    return $set[random_int(0, count($set) - 1)];
}

function generate_name(): string
{
    return name_syllable() . '-' . name_syllable();
}

/**
 * Create an account.
 *
 * The key is returned to the caller and never stored. What goes in the
 * database is sha256(key), which is enough to check a later login and no use
 * at all for producing one.
 *
 * @return array{id:int,name:string,key:string}
 */
function create_account(): array
{
    $key = bin2hex(random_bytes(32));
    $hash = hash('sha256', $key);

    // The name space is ~4 million and the retry loop handles the birthday
    // problem, but the uniqueness is enforced by the database, not by a
    // check-then-insert that two simultaneous signups could both pass.
    for ($attempt = 0; $attempt < NAME_ATTEMPTS; $attempt++) {
        $name = generate_name();

        try {
            $row = query_one(
                'INSERT INTO users (name, key_hash) VALUES (:name, :hash) RETURNING id, name',
                ['name' => $name, 'hash' => $hash]
            );

            return ['id' => (int) $row['id'], 'name' => $row['name'], 'key' => $key];
        } catch (PDOException $e) {
            if (!is_unique_violation($e)) {
                throw $e;
            }
        }
    }

    throw new RuntimeException('could not find a free name');
}

function is_unique_violation(PDOException $e): bool
{
    return ($e->errorInfo[0] ?? '') === '23505';
}

/**
 * Strip a pasted key back to what it should be. People paste keys out of
 * emails and notes apps, which is exactly where stray spaces and line breaks
 * come from, so tolerating them is not laxness — it is the normal case.
 */
function normalise_key(string $input): string
{
    return strtolower(preg_replace('/\s+/', '', $input) ?? '');
}

/**
 * Look up the account a key belongs to.
 *
 * @return array<string,mixed>|null
 */
function account_for_key(string $key): ?array
{
    $key = normalise_key($key);

    if (!preg_match('/^[0-9a-f]{64}$/', $key)) {
        return null;
    }

    return query_one(
        'SELECT id, name FROM users WHERE key_hash = :hash',
        ['hash' => hash('sha256', $key)]
    );
}

function log_in(int $userId): void
{
    // A new session id on every login, so a session cookie captured before
    // sign-in cannot be used after it.
    session_regenerate_id(true);
    $_SESSION['user_id'] = $userId;
}

function log_out(): void
{
    $_SESSION = [];
    session_regenerate_id(true);
}

/**
 * The signed-in account, or null. Cached per request.
 *
 * @return array<string,mixed>|null
 */
function current_user(): ?array
{
    static $user = null;
    static $looked = false;

    if ($looked) {
        return $user;
    }

    $looked = true;
    $id = $_SESSION['user_id'] ?? null;

    if (!is_int($id)) {
        return null;
    }

    $user = query_one(
        'SELECT u.id, u.name, r.reputation
           FROM users u
           JOIN user_reputation r ON r.user_id = u.id
          WHERE u.id = :id',
        ['id' => $id]
    );

    // The row is gone but the cookie is not: treat it as signed out rather
    // than blowing up on every page.
    if ($user === null) {
        unset($_SESSION['user_id']);
    }

    return $user;
}

function current_user_id(): ?int
{
    $user = current_user();

    return $user === null ? null : (int) $user['id'];
}

/**
 * For the actions that need an account. Sends anyone else to the sign-up page
 * with an explanation rather than an error.
 *
 * @return array<string,mixed>
 */
function require_user(): array
{
    $user = current_user();

    if ($user === null) {
        flash('you need an account to do that. it takes one click.');
        redirect('/join');
    }

    return $user;
}

function touch_last_seen(int $userId): void
{
    execute('UPDATE users SET last_seen = now() WHERE id = :id', ['id' => $userId]);
}
