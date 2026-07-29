<?php
// seed.php — plausible nonsense, so the local database is not empty.
//
// Run through `manuserver.sh site_seed`, which sets the DB_* variables
// first. It prints the key for every account it makes, because a key that is
// not written down at the moment it is created is gone — that is true of the
// real site and it is true here.
//
// The video ids are invented. They are the right shape and they are unique,
// but clicking one goes nowhere on YouTube. Saving a real link through /add
// is the only way to get a working one, and that path fetches the title for
// real.

declare(strict_types=1);

require dirname(__DIR__) . '/site/app/bootstrap.php';

if (PHP_SAPI !== 'cli') {
    exit("seed.php is a command-line script\n");
}

const ACCOUNTS = 14;

const FIRST = ['midnight', 'glass', 'rust', 'velour', 'paper', 'echo', 'porcelain', 'hollow',
    'cinder', 'neon', 'lilac', 'tin', 'horizon', 'brass', 'amber', 'sidewalk', 'violet',
    'pearl', 'coral', 'quiet', 'gold', 'aurora', 'chrome', 'minty', 'burnt', 'silver'];

const SECOND = ['lens', 'harbor', 'ribbon', 'syntax', 'signal', 'ladder', 'station', 'marble',
    'meadow', 'orchard', 'relay', 'postcard', 'archive', 'lantern', 'cathedral', 'soda',
    'freight', 'engine', 'motel', 'pinball', 'stairwell', 'ticket', 'cassette', 'radio'];

const THIRD = ['parade', 'lullaby', 'loop', 'diary', 'reflection', 'tape', 'bloom', 'cinema',
    'tide', 'glow', 'psalm', 'sketch', 'rhythm', 'hush', 'swim', 'drift', 'sermon', 'dream',
    'choir', 'prayer', 'refrain', 'shimmer', 'orbit', 'halo', 'aria', 'ritual'];

const ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-';

function fake_video_id(): string
{
    $id = '';

    for ($i = 0; $i < 11; $i++) {
        $id .= ID_ALPHABET[random_int(0, strlen(ID_ALPHABET) - 1)];
    }

    return $id;
}

function fake_title(): string
{
    return FIRST[array_rand(FIRST)] . ' ' . SECOND[array_rand(SECOND)] . ' ' . THIRD[array_rand(THIRD)];
}

$existing = query_one('SELECT count(*) AS n FROM users');

if ((int) $existing['n'] > 0) {
    echo "there are already accounts in this database — seeding on top of them\n\n";
}

/** @var list<array{id:int,name:string,key:string}> $accounts */
$accounts = [];
$postIds = [];

foreach (range(1, ACCOUNTS) as $ignored) {
    $account = create_account();
    $accounts[] = $account;

    foreach (range(1, random_int(3, 7)) as $ignoredToo) {
        $id = create_post($account['id'], fake_video_id(), fake_title());

        if ($id !== null) {
            $postIds[] = ['post' => $id, 'author' => $account['id']];
        }
    }
}

// Likes are what spread reputation out, so there have to be enough of them
// for the slider to have anything to select between.
foreach ($accounts as $account) {
    foreach ($postIds as $post) {
        if ($post['author'] === $account['id']) {
            continue;
        }

        if (random_int(1, 100) <= 22) {
            toggle_like($post['post'], $account['id']);
        }
    }
}

foreach ($accounts as $account) {
    foreach ($accounts as $other) {
        if ($other['id'] === $account['id']) {
            continue;
        }

        if (random_int(1, 100) <= 18) {
            toggle_follow($account['id'], $other['id']);
        }

        if (random_int(1, 100) <= 12) {
            toggle_rep($account['id'], $other['id']);
        }
    }
}

printf("%d accounts, %d saves\n\n", count($accounts), count($postIds));
printf("%-10s %-5s %s\n", 'name', 'rep', 'key — sign in with any of these');
printf("%s\n", str_repeat('-', 86));

foreach ($accounts as $account) {
    printf("%-10s %-5d %s\n", $account['name'], reputation_of($account['id']), $account['key']);
}

printf("\n");
