#!/bin/sh
# The slow tool of the timeout tests (03 §6.2): while the flag exists, df
# hangs as on a stale NFS mount until the sampler's `timeout 10` stops it;
# otherwise it is BusyBox's df. `exec` leaves no child holding the
# sampler's pipe once the guard kills the sleep.
if [ -e /run/klabautermann-fixture/slow-df ]; then
  exec sleep 3600
fi
exec /bin/df "$@"
