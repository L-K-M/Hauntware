# The ABI-tag → GCC mapping the Linux packagers use for their Depends
# floors. Sourced by planchette/scripts/package-linux.sh and
# poltergeist/scripts/package-linux.sh; their tests source it directly.

# A Depends floor must be a Debian package version: dpkg compares versions
# by its own lexical rules, and a raw ABI tag (`libstdc++6 (>=
# GLIBCXX_3.4.30)` — a leading letter — or `libgcc-s1 (>= GCC_12.0.0)`) can
# never be satisfied by a real package version, making the .deb
# uninstallable. glibc's symbol tags already are release numbers
# (GLIBC_2.34 → glibc 2.34 → `libc6 (>= 2.34)`); the libstdc++/libgcc tags
# map through the upstream GCC release that introduced them, per GCC's ABI
# policy table: https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html

# GLIBCXX_x.y.z → the first GCC release shipping the tag; empty for the
# pre-3.4.21 family — those predate every libstdc++6 still installable, and
# the soname map already emits an unversioned libstdc++6 dependency.
glibcxx_gcc() {  # $1 = tag without the GLIBCXX_ prefix → GCC version
  case "$1" in
    3.4.21) echo 5.1  ;;  3.4.22) echo 6.1  ;;  3.4.23) echo 7.1  ;;
    3.4.24) echo 7.2  ;;  3.4.25) echo 8.1  ;;  3.4.26) echo 9.1  ;;
    3.4.27) echo 9.2  ;;  3.4.28) echo 9.3  ;;  3.4.29) echo 11.1 ;;
    3.4.30) echo 12.1 ;;  3.4.31) echo 13.1 ;;  3.4.32) echo 13.2 ;;
    3.4.33) echo 14.1 ;;  3.4.34) echo 15.1 ;;
    3.4|3.4.[1-9]|3.4.1[0-9]|3.4.20) ;;
    *) return 1 ;;
  esac
}

# GCC_x.y.z → the first GCC release shipping the tag; empty for tags older
# than the libgcc-s1 package itself (every libgcc-s1 build provides them).
gcc_gcc() {  # $1 = tag without the GCC_ prefix
  case "$1" in
    7.0.0) echo 7.1 ;;  9.0.0) echo 9.1 ;;  11.0)  echo 11.1 ;;
    12.0.0) echo 12.1 ;; 13.0.0) echo 13.1 ;;
    3.*|4.*) ;;
    *) return 1 ;;
  esac
}
