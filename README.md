# manuserver

**[The quickstart](https://www.manujarvinen.com/manuserver)** — the short
version, on the website. Start here.

A small Arch Linux server, the installer that puts it on a machine, and the
website it runs. One script drives all three.

The website is **tastehopping**: an anonymous place to keep the YouTube videos
other people found worth keeping, and to vote on them. No email, no password,
no profile — joining is one button, and you get a made-up name and one long key
that *is* the account.

```sh
git clone https://github.com/manujarvinen/manuserver.git
cd manuserver

./manuserver.sh build_iso     # -> ./manuserver-*.iso   (~20 min, sudo)
./manuserver.sh vm_install    # install that ISO into a VM
```

Then the VM is the server, and `manuserver` runs it from anywhere:

```sh
manuserver              # start it (backgrounded, no window)
manuserver vm_stop      # shut it down cleanly
manuserver ssh mj       # shell on it, or http://localhost:8080
manuserver tunnel       # put it on the public internet
manuserver backup       # database -> ~/Downloads
manuserver site_dev     # run the website here instead, no VM involved
```

`./manuserver.sh --help` lists the rest.

- **[INSTALL.md](INSTALL.md)** — every step in plain English, including
  Cloudflare.
- **[CLAUDE.md](CLAUDE.md)** — how it is put together, and why.
- **[files/iso/README.md](files/iso/README.md)** — what is inside the ISO.

## Layout

```
manuserver.sh              the only command
files/lib/                 the parts it is made of
files/iso/                 ISO build inputs + the TUI installer
files/site/                the website — public_html, app, db/schema.sql
files/deploy/              what runs on the server after it is installed
files/dev/                 helpers for running the site without the VM
files/promo/               a page describing this project, hosted elsewhere
files/references/          the layout the website was drawn from
```
