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
3. **Password.** You type it twice. Press `Ctrl-R` to show what you typed, in
   case you are unsure.
4. **Disk.** Inside the virtual machine there is only one disk, so it picks it
   for you. It then asks you to confirm that it may erase it. Use the arrow
   keys to choose **Yes, format disk**, then press enter.

Then it installs. This takes a few minutes. When it finishes, press enter and
the machine restarts.

At the end you are asked whether to delete the ISO file. It is about 1 GB and
you do not need it anymore, unless you want to install again later or put it on
a USB stick. If you are unsure, just press enter to keep it.

Close the virtual machine window when the install is done.

## Step 4: Start the server

```sh
./run-manuserver-in-vm.sh
```

That is all. There is no window and no login. The server starts on its own.

## Using it day to day

Run these from the `manuserver_bootable_iso` folder:

| What you want | What to type |
| --- | --- |
| Start the server | `./run-manuserver-in-vm.sh` |
| Stop the server | `./run-manuserver-in-vm.sh stop` |
| Check if it is running | `./run-manuserver-in-vm.sh status` |
| Open a terminal on it | `./run-manuserver-in-vm.sh ssh yourname` |
| Watch it start up in a window | `./run-manuserver-in-vm.sh console` |

Replace `yourname` with the username you chose in step 3.

Always use `stop` to shut it down. It tells the server to close everything
properly first.

## How to tell it worked

Near the end of the install you should see a line saying **provisioning the
server**. That means the installer downloaded this repo onto the new machine
and ran the setup script inside it.

To check afterwards, look at the machine's screen:

```sh
./run-manuserver-in-vm.sh console
```

A window opens, the machine starts, and it logs itself in. You should see:

```
  manuserver provisioning begins here
```

If that text is there, everything worked. Close the window when you are done
(the machine keeps running; use `stop` if you want it off).

You can also check from a terminal instead:

```sh
./run-manuserver-in-vm.sh ssh yourname
cat /var/log/manuserver-provision.log
```

**Important:** that setup script lives in this repo on GitHub, and the
installer downloads it from there. If you change it on your computer, you must
push the change to GitHub before it makes any difference to a new install.

## Reaching it from a browser

Once there is a website on it, it will be at `http://localhost:8080` on this
computer.

**Right now there is no website on it.** The part that installs the web server
has not been written yet, so your browser will say it cannot connect. This is
expected. The rest of the system is installed and working, which is what the
"begins here" message above tells you.

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
