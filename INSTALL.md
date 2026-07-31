# How to install manuserver

> This is the elaborate documentation. Feel free to start with checking the
> quickstart guide on the website:
> <https://www.manujarvinen.com/manuserver>
>
> If it lacks any info you need, come back here.

Follow these steps in order. You need a computer running Arch Linux and about
an hour, most of which is waiting.

## What you need

- A computer running Arch Linux.
- About 15 GB of free disk space.
- An internet connection.

You do not need to install anything first. The build script installs what it
needs.

## Step 1: Get the code

```sh
git clone https://github.com/manujarvinen/manuserver.git
cd manuserver
```

## Step 2: Build the ISO

```sh
./manuserver.sh build_iso
```

This takes 5 to 20 minutes, depending on your machine and how fast its package
mirror is. It will ask for your password, because it needs administrator
rights.

The finished `.iso` appears right next to `manuserver.sh`, in the folder you cloned.

**If it says you were added to the `kvm` group:** log out of your computer and
log back in before doing step 3. If you skip this, everything still works, but
the virtual machine will be very slow.

## Step 3: Install it into a virtual machine

```sh
./manuserver.sh vm_install
```

A window opens and the installer starts by itself. It asks you four things:

1. **Network.** If you are on a cable, it connects on its own and moves on. If
   not, it shows a list of wifi networks to pick from and asks for the
   password.
2. **Username.** Lowercase letters, numbers, dash and underscore only. Must
   start with a letter or underscore.

   **Pick a different one from the username on your own computer.** Commands
   like `manuserver backup` reach across to the server and ask for a password
   partway through — the server's, not this machine's. When both accounts are
   called the same thing there is nothing in the prompt to tell you which, and
   the natural guess is the wrong one. Two different names and the prompt
   answers the question by itself.
3. **Password.** You type it twice, and it must be at least 8 characters.
   Press `Ctrl-R` to show what you typed, in case you are unsure. Three or four
   unrelated words are far stronger than one clever word, and this is the only
   thing protecting the machine from anyone who can reach it.
4. **Disk.** Inside the virtual machine there is only one disk, so it picks it
   for you. It then asks you to confirm that it may erase it. Use the arrow
   keys to choose **Yes, format disk**, then press enter.

Then it installs. This takes a few minutes. When it finishes, press enter. The
virtual machine window closes on its own — that is normal, and it is how the
install disk gets out of the way.

Close the virtual machine window when the install is done.

## Step 4: Tidy up

The installer then asks you three things. Pressing enter to each gives a sensible
answer, so you can ignore this section if you want to.

1. **Delete the ISO?** About 1 GB, and only worth keeping if you plan to install
   again or write a USB stick. Defaults to keeping it.
2. **Install the `manuserver` command?** Says yes by default, and puts
   `manuserver` on your PATH so every command below works from any folder,
   instead of only from inside this one.
3. **Delete the cloned repo?** Only offered once the command is installed, and
   never if you have uncommitted or unpushed work in it. Defaults to keeping it.

Saying yes to all three leaves you with a working server, a `manuserver`
command, and nothing in your Downloads folder.

**Your server does not live in the clone.** The virtual machine is in
`~/.local/share/manuserver`, and database backups go to your **Downloads**
folder where you can see them. Moving or deleting the clone cannot take either
with it. If you had installed before this change, the first command you run
moves them for you and says so.

The one thing that does need the clone is installing again, because that needs an
ISO. Clone it back from GitHub if you ever want to.

## Step 5: Start the server

```sh
manuserver
```

That is all. There is no window and no login. The server starts on its own.

## Using it day to day

| What you want | What to type |
| --- | --- |
| Start the server | `manuserver` |
| Stop the server | `manuserver stop` |
| Check if it is running | `manuserver status` |
| Open a terminal on it | `manuserver ssh yourname` |
| Put it on the internet | `manuserver tunnel yourname` |
| Save a copy of the database | `manuserver backup` |
| Put a saved copy back | `manuserver restore` |
| Watch it start up in a window | `manuserver console` |

Replace `yourname` with the username you chose in step 3.

Always use `stop` to shut it down. It tells the server to close everything
properly first.

If you skipped the `manuserver` command, run these from inside the clone as
`./manuserver.sh` instead, or install it now with
`./manuserver.sh install_command`.

## Reaching it from other devices

The virtual machine's ports are bound to **this computer only**, so neither the
site nor SSH is visible to the rest of your network. To let other devices on the
network open the site:

```sh
MANUSERVER_HTTP_BIND=0.0.0.0 manuserver
```

SSH stays on this computer either way. `manuserver status` tells you which of
the two you are running. For reaching it from outside the house, use the tunnel
further down — it needs none of this.

On a real home server there is no such wrapper: it is on your network, and its
SSH accepts a password. Once you can log in, copying a key over and turning
passwords off takes two commands:

```sh
ssh-copy-id yourname@the-server
ssh yourname@the-server "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/20-no-passwords.conf && sudo systemctl restart sshd"
```

Keep your existing session open until you have confirmed a new one works.

## Saving a copy of the database

The database lives inside the virtual machine. To save a copy onto your own
computer:

```sh
manuserver backup
```

A file appears in your **Downloads** folder, named by date, like
`manuserver-2026-07-28-2101.sql`. That file is the whole database as plain
text. Copy it to a USB stick now and then and you cannot lose your work:

```sh
lsblk -f                                          # find the stick
sudo mount /dev/sdb1 /mnt
cp ~/Downloads/manuserver-*.sql /mnt/
sudo umount /mnt                                  # before pulling it out
```

`umount` before unplugging, or the copy may still be in memory and not on the
stick. Most desktops will mount a stick for you when you plug it in and show it
in the file manager, in which case drag the file across and use the eject
button — the same thing with fewer words.

To put a saved copy back:

```sh
manuserver restore
```

That uses the newest `manuserver-*.sql` in Downloads — other `.sql` files you
happen to have there are ignored. To pick a different one, name the file:

```sh
manuserver restore ~/Downloads/manuserver-2026-07-28-2101.sql
```

If the username on the server is not the one on this computer, both commands
take it: `manuserver backup yourname`, `manuserver restore yourname`. A single
word that is not a file it can find is read as a username, so `restore yourname`
does what it looks like it does — with the newest backup, as above.

Restoring replaces what is on the server, so it asks you to confirm first.

Both need the server running, and both ask for the server password twice: once
for `ssh` and once for `sudo` on the far end. That is the whole of it — the
connection is reused for the several round trips a backup takes, rather than
authenticating again for each.

**Every password these ask for is the server's**, never this computer's, even
though you are sitting at this computer and typed the command here. If the two
machines use the same username the prompt says the same word either way and
gives you no way to tell them apart. Different usernames on the two machines
and this stops being a question you have to think about.

To stop the `ssh` half asking at all, give the server a key of its own:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_manuserver -N '' -C manuserver
ssh-copy-id -i ~/.ssh/id_ed25519_manuserver.pub -p 2222 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null yourname@localhost
```

`manuserver` picks that path up on its own, and offers **only** that key. Name
`-i` explicitly as above: without it `ssh-copy-id` installs whichever key it
finds first, which on a machine holding more than one identity is unlikely to
be the one you meant.

Use a key you already have by pointing at it instead:

```sh
MANUSERVER_SSH_KEY=~/.ssh/some_other_key manuserver backup
```

`sudo` still asks, which is correct — it is what stops anyone who finds your
terminal unlocked from reading the database out of the machine.

**On a real computer** there is no `manuserver` command to do this for you, so
it is Postgres directly, over `ssh`:

```sh
sudo -u postgres pg_dumpall --clean > backup.sql   # save it
sudo -u postgres psql -f backup.sql                # put it back
```

Copy that file off the machine afterwards — a backup sitting on the disk it is
a backup of is not one. Either `scp yourname@the-server:backup.sql .` from
another computer, or a stick at the server's own keyboard, mounted the same way
as above. Restoring replaces everything currently in the database, and nothing
asks you to confirm.

A backup is readable text and holds every saved video and every account name,
so treat it as private. It does **not** let anyone log in as those accounts:
only the SHA-256 of each key is stored, never the key. Nor does it contain the
tunnel token, which lives in `/etc/manuserver/` and not in the database.

## Careful with `vm_install`

Running `vm_install` again wipes the virtual machine and starts from scratch — the
database goes with it. It asks you to type `ERASE` first, so it cannot happen by
accident. Take a backup before you do it anyway.

This is the one command that needs the cloned repo and an ISO, so if you deleted
them in step 4, clone it back and build one first.

## How to tell it worked

Open <http://localhost:8080>. A black page saying **tastehopping** means all of
it worked — web server, PHP and database.

If it does not load:

```sh
manuserver ssh yourname
systemctl status nginx php-fpm postgresql manuserver-db
```

All four should say **active**. `manuserver-db` says `active (exited)`, which
is correct — it is a setup job that finishes. `journalctl -u manuserver-db`
says why if the database did not come up.

**Note:** the setup script comes from this repo on GitHub, so changes on your
own computer do nothing until you push them.

## The website

It is called **tastehopping**: an anonymous place to keep YouTube videos other
people found worth keeping, and to vote on them.

No usernames, no passwords. Press **join** and you get a made-up name and one
long key. **The key is your account** — save it the moment you see it. It is
shown once; the server keeps only a scrambled copy, so it cannot show it again
or send it to you. Lose it and you start a new account.

Paste a YouTube link under **add** and the title is fetched for you. Click a
name to see what that person kept, and follow them. The slider under each feed
filters by reputation: everyone sits somewhere from 0 to 1000, and you pick the
part of the range you want to hear from.

## Changing the website

No reinstall needed. The machine has a copy of this repo at `/srv/manuserver`,
and that copy is what it serves.

```sh
manuserver ssh yourname
cd /srv/manuserver && sudo git pull
sudo systemctl restart manuserver-db   # only if the database schema changed
```

To try changes first, run the site on your own computer — from the top of the
repo, then open <http://localhost:8000>:

```sh
./manuserver.sh site_dev     # add site_seed to fill it with test accounts
```

It builds its own small database in `server/dev/.cluster` and touches nothing
else. Needs `postgresql` and `php-pgsql`; it says so if they are missing.

## Putting it on the public internet

A **tunnel** does this without touching your router: the server dials out to
Cloudflare, and visitors are passed back down that connection. It is free, and
`cloudflared` is already installed on your machine, switched off, waiting for a
token.

### 1. Move the domain to Cloudflare

**This step is not optional and cannot be done anywhere else.** A tunnel is
reached by hostname, and the record that points a hostname at a tunnel only
resolves inside Cloudflare's own DNS. You cannot add it at your registrar, and
you cannot add it in cPanel — so `tastehopping.com` has to be served by
Cloudflare's nameservers before any of the rest works.

1. Free account at [cloudflare.com](https://cloudflare.com) → **Add a site** →
   `tastehopping.com`, Free plan.
2. It gives you **two nameservers**. Replace the ones at your registrar with
   those. If the domain was already serving anything, check the DNS records
   Cloudflare copied over first, or that website and its email will break.
3. Wait until Cloudflare says **Active**. Minutes to a day. This is the slow
   part and the only annoying one, and nothing below works until it is done —
   Cloudflare is now where you edit this domain's DNS, not cPanel.

### 2. Make the tunnel and get its token

4. **Networks → Tunnels & Mesh → Create a tunnel**. Name it `manuserver` and select
   **Create Tunnel**.
5. It offers you an install command for your operating system. You do not run
   it — the long string starting `eyJhIjoi` inside it is the token, and that is
   all you need. Copy it, and treat it like a password. Copying the whole
   command is fine as well; the prompt takes the token out of it.

### 3. Turn it on

There is one command that asks for the token, and it runs **on the server**.
Which of these you type is decided by where you are sitting, not by what you
want to happen:

| Where you are | What to type |
| --- | --- |
| At your own computer, server in the virtual machine | `manuserver tunnel yourname` |
| At your own computer, server is a real machine elsewhere | `ssh yourname@the-server` first, then the line below |
| At the server's own keyboard, or in that ssh session | `sudo manuserver-tunnel` |

`yourname` is the username you chose during the install, **on the server**. If
you leave it out, `manuserver tunnel` uses your name on this computer, which is
usually a different account — see below.

Paste the token at the prompt — nothing appears as you paste, which is
deliberate. It tells you within a few seconds whether the tunnel came up. On a
real server, its address is on its own screen, next to **on this network**.

Afterwards, `manuserver tunnel status yourname` and
`manuserver tunnel off yourname` — the username goes last, after the word.

#### Bringing the token on a USB stick

At a real server's own keyboard there is nothing to paste from — no browser, no
clipboard, and a tunnel token is far too long to read off a phone and type. Put
it in a file on a stick instead. `manuserver-tunnel` reads the token from
standard input, so a file works with no change to anything:

```sh
lsblk -f                              # find the stick
sudo mount /dev/sdb1 /mnt
sudo manuserver-tunnel < /mnt/token.txt
sudo umount /mnt
```

`lsblk -f` lists the disks with their sizes and labels; the stick is the one
that appeared when you plugged it in, and `/dev/sdb1` above is a guess at its
name, not a fact. Whole file or just the token, wrapped across lines or not —
the spaces and newlines are collapsed, and an install command pasted in whole
has the token taken out of it, exactly as at the prompt.

Then **delete the file and take the stick away.** The token is the one secret
on the server; a copy of it on a stick left in a drawer is a copy of it, and
anyone holding it can publish their own machine at your domain until you make a
new tunnel. It is also the one thing here you can always throw away and replace:
`sudo manuserver-tunnel off` forgets it, and Cloudflare will issue another.

#### If it asks for a password and refuses every one you try

Both passwords it could be asking for are the **server's**, asked down the
connection and typed into your terminal. Neither is this computer's login. In
order:

- **The first prompt is the server's ssh login.** If it will not take your
  password — the right one, typed carefully — the account is almost certainly
  not there. `manuserver tunnel` with no name asks to log in as *your name on
  this computer*, and the documents deliberately tell you to choose a different
  one for the server, so on most installs that account does not exist and no
  password can be correct. Give the server's name: `manuserver tunnel yourname`.
  Check a name works with `manuserver ssh yourname`, which fails the same way
  for the same reason.
- **The second prompt is `sudo`, on the server, after you are already logged
  in.** Same password as the one you just used to get in. Nothing on screen
  distinguishes it from the first, which is the whole reason this is confusing.
- Neither prompt shows anything as you type. That is normal for both.

If you set up a key with `ssh-copy-id`, the first prompt disappears and only
the `sudo` one is left.

**"Healthy" in Cloudflare's dashboard does not mean the site is reachable.** It
means `cloudflared` connected to Cloudflare and nothing more. A tunnel has no
public IP address — there is no number to visit, ever. Until a route
exists in an Active zone, there is no address at all.

To see it working before the DNS move lands, run a throwaway tunnel on the
server by hand:

```sh
sudo systemctl stop manuserver-tunnel
cloudflared tunnel --url http://localhost:80
```

That prints a random `https://….trycloudflare.com` address that works
immediately, with no account and no domain. It is for testing only — a new
address every run, and rate limited. `Ctrl-C`, then
`sudo systemctl start manuserver-tunnel`, to put things back.

### 4. Point the domain at it

Only now, with the tunnel connected, does it get an address.

6. Go to **Networks → Tunnels & Mesh**, click your tunnel, and open
   **Published application routes**. Add one.
7. Fill it in:

   | Field | Value |
   | --- | --- |
   | Subdomain | *leave empty* |
   | Domain | `tastehopping.com` |
   | Path | *leave empty* — matches every path |
   | Service · Type | `HTTP` |
   | Service · URL | `localhost:80` |

   The **Full hostname** line under the two boxes should read
   `tastehopping.com`. Save.

> **Port 80, not the 8080 the placeholder suggests.** `cloudflared` runs on the
> server, where nginx listens on 80. The 8080 you use on your own computer is
> the virtual machine's port forward, and the tunnel never sees it.

**If it says "A DNS record with this name already exists":** when you added the
site, Cloudflare imported the records it found at your old provider — including
whatever was at the root. A tunnel needs a `CNAME` there, and DNS will not hold
both. Go to the main dashboard (not Zero Trust) → **tastehopping.com** → **DNS →
Records**, delete the `A`, `AAAA` or `CNAME` whose name is the bare domain, and
save the route again.

Delete only that one. Leave the `MX` records alone or the domain stops
receiving mail, and leave the `TXT` records alone — they are SPF and domain
verification. If that `A` record was serving a real page from cPanel, removing
it takes that page down, which is the intention but worth knowing first.

`www.tastehopping.com` is not included. If you want it, add a second route with
`www` in the Subdomain box.

The **Domain** dropdown only lists domains that are an **active zone in your
Cloudflare account** — which is step 1 doing its work, and why there is no way
to skip it. Saving the route makes Cloudflare write the proxied CNAME itself;
there is nothing to add by hand, in cPanel or anywhere else.

> **Not the Routes page in the left-hand menu.** `Networks → Routes`, with its
> CIDR and Hostname tabs, is for reaching private IP ranges through the WARP
> client. Every form there carries a "requires traffic to pass via Cloudflare
> Gateway" banner, and none of them can publish a website. Published
> application routes live *inside* a tunnel, not in that menu.

`https://tastehopping.com` now works from anywhere, with a valid certificate.
Afterwards `tunnel status` and `tunnel off` do what they say; `off` deletes the
token and the site keeps running locally.

- Only that one hostname and port are public. SSH stays unreachable.
- The server has to be running, or visitors get a Cloudflare error page — see
  below for replacing that with something friendlier.
- It survives reboots. `install` erases the token along with everything else.
- The token is stored on the server, in `/etc/manuserver/tunnel.env`, readable
  only by root. It is never in this repo, never in your shell history and never
  in a database backup — but it is part of the disk. Copying the whole disk, or
  the virtual machine's `.qcow2` image, copies the token with it. If you ever
  hand either to someone, run `tunnel off` first or take a new token afterwards.

## A page for when the server is off

With the server switched off, visitors get Cloudflare's **error 1033**: grey,
branded, and worded as though the site is broken rather than resting. Custom
error pages are a paid feature, but a Worker does the same job on the free plan
and there is one ready in `files/deploy/offline-worker.js`.

It passes every request straight through to your server, and only steps in when
Cloudflare cannot reach it at all. Then it serves the manuserver wordmark and a
short note saying the machine is off and nothing has been lost. The whole page
is self-contained — no stylesheet, no font, no image — because it has to render
on the one occasion your server cannot be asked for anything.

Because it can fetch nothing, the wordmark is a copy of the one in
`files/promo/manuserver.svg` pasted into the Worker. Run this first and it
stays a copy of the current one:

```sh
./manuserver.sh wordmark
```

It says so if the two already match, and rewrites the Worker if they do not.

1. In the Cloudflare dashboard go to **Workers & Pages → Create → Worker**.
   Name it `tastehopping-offline` and deploy the starter.
2. **Edit code**, replace all of it with the contents of
   `files/deploy/offline-worker.js`, and deploy.
3. On the Worker, go to **Settings → Domains & Routes → Add → Route** and add
   `tastehopping.com/*`. Add `www.tastehopping.com/*` as a second route if you
   published www as well.

Test it by stopping the server — `manuserver stop` — and loading the site.

**This is code in front of a working system**, there to handle the times it is
not working. A mistake in the Worker takes the site down even while the server
is up, and Cloudflare lists overlapping Worker routes among the usual reasons a
tunnel appears broken. If the site ever misbehaves in a way the server cannot
explain, remove the route first and see if it goes away.

## Installing on a real computer instead of a virtual machine

Do step 1 and step 2 as above, then write the `.iso` to a whole USB disk. On
Linux use **Caligula**; on Mac or Windows use **balenaEtcher**. The device you
select is completely overwritten.

```sh
sudo pacman -S --needed caligula
```

Then, from the folder you cloned — the one the `.iso` is in:

```sh
caligula burn -z none manuserver-*.iso
```

Naming no device is the safe way round: Caligula shows you the disks it found
and you pick from the list, so there is no `/dev/sd…` path to mistype onto the
wrong drive. It asks for your password when it is ready to write.

`-z none` tells it the file is not compressed, which this one is not.

Then start the other computer from that USB stick. The installer runs by
itself, and asks the same four questions as in step 3.

Two requirements for the other computer:

- It must start in UEFI mode. Old BIOS mode does not work.
- Secure Boot must be turned off.

Both are settings in that computer's firmware menu.

## If something goes wrong

**The build stops with an error.** Check that you have 15 GB free, then run it
again. It starts over cleanly.

**The installer stops with an error.** It shows the last few lines of its log.
The full log is on the installed machine at `/tmp/manuserver-install.log`. To
try again, type `bash /root/installer.sh`.

**You need a plain terminal during the install.** Press `Alt-F2`.

**The server will not stop.** If `stop` gives up after a minute, the machine is
probably still starting. Wait a moment and try again.

## Where the rest of it is written down

This document is how to *use* it. Two others cover the parts this one leaves
out, and both matter if you intend to change anything:

- **[CLAUDE.md](CLAUDE.md)** — how it is put together and why, including the
  rules that break quietly if you do not know them. It is written for whoever
  changes this next, human or otherwise.
- **[TODO.md](TODO.md)** — what has actually been tested and what has not, and
  the decisions behind things that look arbitrary. It is the only record of
  state: the machine this was developed on is expected to be wiped, so
  anything not written there is gone.
