#!/usr/bin/env bash
## cluster-monitor.sh -- minimal single-window CPU/RAM monitor for SSH nodes.
##
## A no-dependency, non-blocking counterpart to crew.ssh::crew_ssh_monitor():
## polls every node over SSH in parallel, reads /proc directly (no remote tooling
## needed beyond a shell), and redraws one compact line per host in place. Use it
## when you want the monitor in its own terminal rather than the R Viewer pane.
##
## Copy it out of the package and run it:
##   Rscript -e 'file.copy(system.file("templates/cluster-monitor.sh", package="crew.ssh"), ".")'
##   chmod +x cluster-monitor.sh
##
## Usage:
##   ./cluster-monitor.sh host1 host2 host3      # explicit host list
##   HOSTS="host1 host2" ./cluster-monitor.sh    # host list via env
##   ./cluster-monitor.sh -n 5 host1 host2       # 5s refresh
##
## In a targets/renv project that sets the crew.ssh.nodes option, feed it the
## node names:
##   ./cluster-monitor.sh $(Rscript -e 'cat(names(getOption("crew.ssh.nodes")))')
##
## Hosts must be reachable as bare `ssh <host>` (uses your ~/.ssh/config aliases
## and keys). Nodes must be Linux (stats come from /proc). Quit with q or Ctrl-C.

set -u

INTERVAL=2

## --- args ---------------------------------------------------------------
hosts=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) INTERVAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *)  hosts+=("$1"); shift ;;
  esac
done
if [ "${#hosts[@]}" -eq 0 ]; then
  # shellcheck disable=SC2206
  hosts=(${HOSTS:-})
fi
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "cluster-monitor: no hosts. Pass them as arguments or set \$HOSTS." >&2
  echo "  e.g. ./cluster-monitor.sh host1 host2" >&2
  exit 1
fi

## --- ssh: reuse connections so each poll is fast -------------------------
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ControlMaster=auto
  -o ControlPersist=60s
  -o "ControlPath=/tmp/crew-ssh-mon-%r@%h:%p"
)

## remote collector: prints "CPU MEMUSED_KB MEMTOTAL_KB LOAD1 NCPU"
read -r -d '' REMOTE <<'EOF'
read -r _ u1 n1 s1 i1 w1 q1 sq1 _ < /proc/stat
b1=$((u1+n1+s1+q1+sq1)); t1=$((u1+n1+s1+i1+w1+q1+sq1))
sleep 0.25
read -r _ u2 n2 s2 i2 w2 q2 sq2 _ < /proc/stat
b2=$((u2+n2+s2+q2+sq2)); t2=$((u2+n2+s2+i2+w2+q2+sq2))
db=$((b2-b1)); dt=$((t2-t1)); cpu=0
[ "$dt" -gt 0 ] && cpu=$((100*db/dt))
mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
read -r l1 _ < /proc/loadavg
echo "$cpu $((mt-ma)) $mt $l1 $(nproc)"
EOF

TMP=$(mktemp -d /tmp/crew-ssh-mon.XXXXXX)
cleanup() {
  tput cnorm 2>/dev/null
  rm -rf "$TMP"
  for h in "${hosts[@]}"; do
    ssh "${SSH_OPTS[@]}" -O exit "$h" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

## --- rendering helpers ---------------------------------------------------
C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
bar() { ## $1=pct $2=width -> colored [####....] pct%
  local pct=$1 w=$2 fill i out="" col
  [ "$pct" -gt 100 ] && pct=100
  fill=$(( pct * w / 100 ))
  if   [ "$pct" -ge 90 ]; then col=$'\033[31m'   # red
  elif [ "$pct" -ge 60 ]; then col=$'\033[33m'   # yellow
  else                          col=$'\033[32m'; fi # green
  for ((i=0;i<w;i++)); do [ "$i" -lt "$fill" ] && out+="#" || out+="."; done
  printf '%s[%s]%s %3d%%' "$col" "$out" "$C_RESET" "$pct"
}

tput civis 2>/dev/null   # hide cursor

while true; do
  ## poll all hosts in parallel
  for h in "${hosts[@]}"; do
    {
      if out=$(ssh "${SSH_OPTS[@]}" "$h" bash -s <<<"$REMOTE" 2>/dev/null); then
        printf '%s\n' "$out" > "$TMP/$h"
      else
        echo "DOWN" > "$TMP/$h"
      fi
    } &
  done
  wait

  ## draw
  buf="${C_DIM}crew.ssh monitor  $(date '+%H:%M:%S')  (every ${INTERVAL}s, q/Ctrl-C to quit)${C_RESET}\n\n"
  buf+=$(printf '%-12s %-26s %-26s %s\n' "HOST" "CPU" "RAM" "LOAD/CORES")
  buf+=$'\n'
  for h in "${hosts[@]}"; do
    line=$(cat "$TMP/$h" 2>/dev/null)
    if [ "$line" = "DOWN" ] || [ -z "$line" ]; then
      buf+=$(printf '%-12s \033[31m%s\033[0m\n' "$h" "unreachable")
      buf+=$'\n'
      continue
    fi
    read -r cpu memu memt load ncpu <<<"$line"
    mempct=$(( memt>0 ? 100*memu/memt : 0 ))
    gu=$(awk "BEGIN{printf \"%.0f\", $memu/1048576}")
    gt=$(awk "BEGIN{printf \"%.0f\", $memt/1048576}")
    buf+=$(printf '%-12s %b %b %s\n' \
      "$h" "$(bar "$cpu" 16)" "$(bar "$mempct" 16) ${gu}/${gt}G" "${load} / ${ncpu}")
    buf+=$'\n'
  done

  ## repaint from top without flicker
  printf '\033[H\033[J%b' "$buf"

  ## interruptible sleep; quit on 'q'
  if read -rsn1 -t "$INTERVAL" key 2>/dev/null; then
    [ "$key" = "q" ] && break
  fi
done
