# How to install manuserver

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
git clone git@github-manujarvinen:manujarvinen/manuserver.git
cd manuserver/manuserver_bootable_iso
```

## Step 2: Build the ISO

```sh
./build_manuserver_iso.sh
```

This takes about 20 minutes. It will ask for your password, because it needs
administrator rights.

The finished file appears in the `out/` folder.

**If it says you were added to the `kvm` group:** log out of your computer and
log back in before doing step 3. If you skip this, everything still works, but
the virtual machine will be very slow.

## Step 3: Install it into a virtual machine

```sh
./run-manuserver-in-vm.sh install
```

A window opens and the installer starts by itself. It asks you four things:

1. **Network.** If you are on a cable, it connects on its own and moves on. If
   not, it shows a list of wifi networks to pick from and asks for the
   password.
2. **Username.** Lowercase letters, numbers, dash and underscore only. Must
   start with a letter or underscore.
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
| Put it on the internet | `manuserver tunnel` |
| Save a copy of the database | `manuserver backup` |
| Put a saved copy back | `manuserver restore` |
| Watch it start up in a window | `manuserver console` |

Replace `yourname` with the username you chose in step 3.

Always use `stop` to shut it down. It tells the server to close everything
properly first.

If you skipped the `manuserver` command, run these from inside the
`manuserver_bootable_iso` folder as `./run-manuserver-in-vm.sh` instead — or
install it now with `./run-manuserver-in-vm.sh install-command`.

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
text. Copy it to a USB stick now and then and you cannot lose your work.

To put a saved copy back:

```sh
manuserver restore
```

That uses the newest `manuserver-*.sql` in Downloads — other `.sql` files you
happen to have there are ignored. To pick a different one, name the file:

```sh
manuserver restore ~/Downloads/manuserver-2026-07-28-2101.sql
```

Restoring replaces what is on the server, so it asks you to confirm first.

Both commands ask for the server password, and both need the server running.

## Careful with `install`

Running `install` again wipes the virtual machine and starts from scratch — the
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
./server/dev/run-local.sh          # add `seed` to fill it with test accounts
```

It builds its own small database in `server/dev/.cluster` and touches nothing
else. Needs `postgresql` and `php-pgsql`; it says so if they are missing.

## Putting it on the public internet

A **tunnel** does this without touching your router: the server dials out to
Cloudflare, and visitors are passed back down that connection. It is free, and
`cloudflared` is already installed on your machine, switched off, waiting for a
token.

### 1. Get a token, in a browser

1. Free account at [cloudflare.com](https://cloudflare.com) → **Add a site** →
   `manujarvinen.com`, Free plan.
2. It gives you **two nameservers**. Replace the ones at your registrar with
   those. Check the DNS records Cloudflare copied over first, or your existing
   website and email will break. Then wait for **Active** — minutes to a day.
   This is the slow part and the only annoying one.
3. **Zero Trust → Networks → Tunnels → Create a tunnel** → *Cloudflared*, name
   it `manuserver`, save.
4. Copy the long string starting `eyJhIjoi` out of the command it shows you.
   That is the token. Treat it like a password.
5. On the same tunnel, add a **Public Hostname**: subdomain `manuserver`,
   domain `manujarvinen.com`, service type `HTTP`, URL `localhost:80`.

### 2. Turn it on

```sh
manuserver tunnel   # virtual machine
sudo manuserver-tunnel             # real server, over ssh
```

Paste the token at the prompt — nothing appears as you paste, which is
deliberate. It tells you within a few seconds whether the tunnel came up. On a
real server, its address is on its own screen, next to **on this network**.

`https://manuserver.manujarvinen.com` now works from anywhere, with a valid
certificate. `tunnel status` and `tunnel off` do what they say; `off` deletes
the token and the site keeps running locally.

- Only that one hostname and port are public. SSH stays unreachable.
- The server has to be running, or visitors get a Cloudflare error page.
- It survives reboots. `install` erases the token along with everything else.

## Installing on a real computer instead of a virtual machine

Do step 1 and step 2 as above, then put the ISO on a USB stick:

```sh
lsblk
```

Look at the list and find your USB stick. Be careful: the next command erases
whatever you point it at.

```sh
sudo dd bs=4M status=progress oflag=sync if=out/manuserver-*.iso of=/dev/sdX
```

Replace `/dev/sdX` with your USB stick from the list above.

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
