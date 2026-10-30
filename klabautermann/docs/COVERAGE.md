# What Klabautermann covers

Klabautermann watches your servers from your own device, over SSH, and
only while it is open. It installs nothing on a server unless you ask it
to. That keeps it agentless and portless, and it has a cost: whenever
Klabautermann is not running, nothing is watching. The app says so
wherever it matters; this page says it once, in full.

## The tier you have: T0

Every server in v1 is a **T0** server: "SSH while Klabautermann is open".
The badge on each server's coverage card and the chip in its header ("T0:
sampled only while open") mean exactly that.

Covered:

- **Live readings while open.** Metrics, processes, services, logs, jobs
  and Docker of the servers you have open, at the cadence Settings >
  General's polling budget allows.
- **Continuous watching of the servers you pick.** The servers in this
  device's monitor set are read continuously while Klabautermann is open,
  even when you are looking at another one; the others are read only while
  you have them open. The fleet header's chip counts them: "Watching 4 of
  12 servers on this device, only while open".
- **Alerts while open.** Alert rules sync with your account, but each
  device evaluates them itself, on the readings it takes. A raised alert
  shows in the alert center, and as a system notification once you turn
  notifications on.

Not covered:

- **While Klabautermann is closed.** Nothing checks your servers, so
  nothing can warn you about them. No alert raises and no history is
  recorded.
- **A server going down.** If a server stops while Klabautermann is
  closed, you find out the next time you open it.
- **History before you connected.** Charts cover only the time this
  device was connected. Each device keeps its own history; another
  device's readings do not fill your gaps.

## Gaps are marked, never filled in

A chart never draws a line across time it did not see. A hatched band
names why the readings stopped: the app was closed, it was in the
background, or the connection was lost. Values that stopped updating say
how old they are ("Updated 4 s ago", "Stale: updated 2 min ago",
"Disconnected 3 min ago", "Not watched on this device").
Docker's events list marks where the event stream was lost and whether the
engine replayed what it still held; the engine keeps only a limited
buffer.

## Phones

iOS and Android stop apps in the background. Klabautermann stops reading
while it is in the background and resumes when you return; the return
banner says how long the pause lasted ("Paused 12:01 to 12:14 while in
background. No data for that period."), and the charts mark the gap.
Admin mode also ends when the app goes to the background. A phone is a
good way to look at your servers and act on them; it is not a monitor.

## What Klabautermann does on a server

Reading changes nothing on a server. Klabautermann runs a short shell
program over SSH, as your login user, that prints the readings and exits
with the session; reads that need root ask for admin mode first.

Actions are opt-in per server (Allow actions in the server header's Safety
menu), each one shows a preview naming the commands it runs and every file
it writes, and the dangerous ones ask you to type the target's name. What
an action leaves behind (a backup of a file you edited, its manifest, one
line per action in the server's system log) is listed under Safety >
Footprint, where you can remove it.

## When you need more

If you need alerts while no device is open, run a monitor on the server
or beside it today. Klabautermann recognizes node_exporter, Netdata, the
Zabbix agent, Telegraf, collectd, Prometheus and Grafana's agents by their
systemd units and names them on the server's coverage card.

Later releases add tiers that keep checking while the app is closed. Each
one is opt-in, and the app shows no control for a tier before it exists:

- **T1 (planned for v1.x):** plain scripts and timers you install on a
  server from the app, after a preview, that check your alert rules every
  few minutes and keep or deliver what they find.
- **T2 (planned later):** an optional companion program on the server for
  deeper collection.

The design behind this page is in
[`03-ARCHITECTURE.md`](../../docs/design/klabautermann/03-ARCHITECTURE.md)
section 9.5.
