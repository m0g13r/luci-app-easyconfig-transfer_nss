#!/bin/sh

#
# (c) 2024 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2024-2026 modified by Rafał Wabik (IceG) <https://github.com/4IceG>
#
# From eko.one.pl forum
#

TIMEISVALID="yes"
# grep -q "time is valid" /tmp/state/dnsmasqsec 2>/dev/null && TIMEISVALID="yes"
# [ -e /dev/rtc0 ] && TIMEISVALID="yes"
# [ -z "$TIMEISVALID" ] && exit 0

DB=/tmp/easyconfig_statistics.json
SDB=/mnt/sda1/easyconfig_statistics.json.gz

LOCK=/var/lock/easyconfig_statistics.lock

lock $LOCK

# --- WAN byte counters: NSS-aware, not plain sysfs ---
#
# The original code read /sys/class/net/$IFNAME/statistics/{tx,rx}_bytes
# directly. Under NSS hardware offload those sysfs counters stay near
# zero, because accelerated flows bypass the kernel's software xmit path
# entirely and never touch the code that increments them - exactly the
# same problem luci.trafficchart's get_qdisc_root_bytes() already solves
# for the traffic-class chart. Mirroring that fix here: read the real,
# post-shaping tc qdisc byte counters instead, which DO get updated from
# the NSS hardware.
get_wan_bytes() {
    # $1 = "rx" (download) or "tx" (upload)
    local dir="$1" dev bytes
    if [ "$dir" = "rx" ]; then
        # Download/ingress always shapes on the fixed nssifb pseudo-device
        # (see ingress()/add_nsstbl in nss-rk.qos), regardless of which
        # physical WAN device is actually configured.
        dev="nssifb"
    else
        # Upload/egress: nss-rk.qos strips any VLAN suffix (eth0.7 ->
        # eth0) before attaching the egress shaper, so read from that
        # same stripped device - not from whatever interface name this
        # WAN zone happens to report.
        dev=$(echo "$IFNAME" | sed 's/\.[0-9]*//g')
    fi
    if [ -n "$dev" ] && [ -e "/sys/class/net/${dev}" ] && command -v tc >/dev/null 2>&1; then
        bytes=$(tc -s qdisc show dev "$dev" 2>/dev/null | grep -m1 'Sent ' | awk '{print $2}')
        case "$bytes" in ''|*[!0-9]*) bytes="" ;; esac
    fi
    if [ -z "$bytes" ]; then
        # Fallback for non-NSS routers, or if ingress/egress shaping is
        # disabled - this is the raw/unshaped counter, the best available
        # signal in that case (same fallback logic as luci.trafficchart).
        if [ "$dir" = "rx" ] && [ -e "/sys/class/net/${IFNAME}/statistics/rx_bytes" ]; then
            bytes=$(cat "/sys/class/net/${IFNAME}/statistics/rx_bytes" 2>/dev/null)
        elif [ "$dir" = "tx" ] && [ -e "/sys/class/net/${IFNAME}/statistics/tx_bytes" ]; then
            bytes=$(cat "/sys/class/net/${IFNAME}/statistics/tx_bytes" 2>/dev/null)
        fi
    fi
    echo "${bytes:-0}"
}

# --- Wired client byte counters: switch-port MIB (hardware), conntrack as fallback ---
#
# ar8xxx_mib_poll_interval was 0 (disabled) -> "mib: ???" for every port,
# forcing the conntrack-snapshot approach below, which loses everything
# from short-lived flows (measured ~74% loss on this router comparing
# WAN total vs. summed clients). With MIB polling enabled, each switch
# port exposes RxGoodByte/TxGoodByte as TRUE monotonic hardware counters
# - same category as `iw station dump` for WiFi or the tc qdisc counters
# for WAN. So exactly like those two paths, the RAW cumulative value is
# passed straight to easyconfig_statistics.uc, which does the delta
# against last_tx/last_rx itself - no extra state file needed here,
# unlike the conntrack path below.
#
# The tricky part on this hardware: br-lan's non-wifi lower device is a
# single VLAN interface (eth1.1) aggregating ALL physical LAN sockets,
# so brctl/port_no cannot tell which socket a wired MAC is actually
# plugged into - every wired MAC reports the same Linux bridge port
# number. The switch chip's own ARL/address-resolution table (swconfig
# "arl_table") doesn't have that problem: it reports the real physical
# switch port per MAC directly from hardware, which is exactly what's
# needed to pick the matching MIB counters.
#
# Direction: RxGoodByte on a port = bytes the switch received FROM the
# device on that port = client's upload/tx. TxGoodByte on a port = bytes
# the switch sent TO the device = client's download/rx. Verified against
# a live download test on this router; may differ on other switch chip
# revisions, worth a spot-check after deploying.
#
# Limitation: a MIB counter is per PORT, not per MAC. If ARL shows more
# than one MAC on the same port (WiFi radios funnel through shared ports
# this way, and so would an unmanaged hub/switch downstream of a LAN
# socket), the port total can't be split per device - those MACs fall
# back to the conntrack estimate below instead, same as before.
SWDEV=$(swconfig list 2>/dev/null | awk '{print $2; exit}')
[ -z "$SWDEV" ] && SWDEV="switch0"

get_port_mib_bytes() {
    # $1 = port id. Echoes "<rx_bytes> <tx_bytes>" (raw switch counters,
    # empty string for either if not available) - "0 0" is a real zero,
    # not "unavailable", so callers should treat empty as unavailable.
    local portid="$1" out rx tx
    out=$(swconfig dev "$SWDEV" port "$portid" get mib 2>/dev/null)
    if [ -z "$out" ]; then
        out=$(swconfig dev "$SWDEV" show 2>/dev/null | awk -v p="Port ${portid}:" '
            $0==p {f=1; next} /^Port [0-9]+:/{f=0} f')
    fi
    # ar8xxx_mib_type=0 (basic) reports RxGoodByte/TxByte; mib_type=1
    # (extended) reports RxGoodByte/TxGoodByte - match both so this
    # doesn't silently fall back to conntrack depending on that setting.
    rx=$(echo "$out" | awk -F: '/^[[:space:]]*RxGoodByte/{print $2; exit}' | awk '{print $1}')
    tx=$(echo "$out" | awk -F: '/^[[:space:]]*Tx(Good)?Byte/{print $2; exit}' | awk '{print $1}')
    case "$rx" in ''|*[!0-9]*) rx="" ;; esac
    case "$tx" in ''|*[!0-9]*) tx="" ;; esac
    echo "$rx $tx"
}

# ARL table: "Port <N>: MAC <mac>" per line, one line per learned MAC.
# Queried once per script run and reused for every wired MAC below -
# it's a single swconfig call either way, no benefit to querying per MAC.
get_arl_table() {
    swconfig dev "$SWDEV" get arl_table 2>/dev/null
}

# Physical switch port for a given MAC, from the ARL table above.
# Echoes nothing if the MAC isn't currently in the table (e.g. aged out
# on an idle device) - callers must treat that as "unavailable" and fall
# back to conntrack, not as "port 0".
arl_lookup_port() {
    # $1 = ARL table text, $2 = mac (colon form, any case)
    echo "$1" | awk -v m="$2" '
        BEGIN { m = tolower(m) }
        tolower($0) ~ m { gsub(":", "", $2); print $2; exit }
    '
}

# --- Wired client byte counters: conntrack-based, not hardcoded 0 ---
#
# The original code never measured wired clients at all - it called
# easyconfig_statistics.uc with TX=0 RX=0 hardcoded for every wired MAC,
# so wired devices only ever showed "present" (via connected-time/type),
# never any actual byte count. WiFi clients get real numbers because
# `iw station dump` exposes a per-station hardware counter directly, but
# there's no equivalent per-switch-port byte counter available for wired
# clients on most switch/bridge setups.
#
# Fix: aggregate per-client bytes from /proc/net/nf_conntrack instead,
# same data source (and same NSS-offload-safety property - these counters
# keep advancing for offloaded flows, see luci.trafficchart) as the
# traffic-class chart, but grouped by LAN IP (resolved to MAC via the
# neighbour/ARP table) instead of by traffic class.
#
# CAVEAT (important, unlike the WiFi path): `iw station dump` and the tc
# qdisc counters above are true monotonic hardware counters - once
# measured, a byte is never "un-counted". Conntrack is different: it's a
# LIVE SNAPSHOT of currently-tracked flows. A short flow that opens AND
# fully closes between two cron runs of this script is invisible to both
# polls and contributes nothing to the total - this is the same
# fundamental limitation nlbwmon has (also conntrack/period-based). The
# shorter the "Data reading period" is set to in the app's config, the
# less traffic gets missed this way; a 1-2 minute period is recommended
# if wired-client accuracy matters to you, the default 10 minutes will
# undercount bursty/short-lived wired traffic more noticeably.
#
# Accumulation works via a persistent clamped-diff state file, the same
# pattern traffic_chart.js uses client-side for its own cumulative
# byte/packet counters (cumBytes/cumPackets) - each poll compares the
# current live conntrack byte sum per MAC against the last poll's live
# sum, adds the (never-negative) difference to a running total, and
# stores both back to disk. This is what turns a non-monotonic live
# snapshot into a monotonically increasing counter, matching what
# easyconfig_statistics.uc expects to receive (it computes its own delta
# again on top of that, same as it already does for WiFi/WAN).
get_wired_client_bytes() {
    # $1 = space-separated list of wired MAC addresses (lowercase, colons)
    local WIRED_MACS="$1"
    [ -r /proc/net/nf_conntrack ] || return 1
    [ -n "$WIRED_MACS" ] || return 0

    local STATE_FILE="/tmp/easyconfig_wired_state"
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"

    # IP -> MAC map from the neighbour table. STALE/DELAY/PROBE entries
    # are still usable for matching (they mean "not recently confirmed",
    # not "wrong MAC") - only FAILED is excluded. IPv4 only for now: v6
    # would need the same GUA-prefix handling luci.trafficchart already
    # does, deliberately left out here to keep this addition reviewable.
    local MACIP_MAP
    MACIP_MAP=$(ip neigh show 2>/dev/null | awk '
        $0 !~ /FAILED/ && NF >= 5 {
            ip = $1; mac = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "lladdr") { mac = tolower($(i + 1)); break }
            }
            if (mac != "" && ip !~ /:/) print mac, ip
        }
    ')

    awk -v macip="$MACIP_MAP" -v statefile="$STATE_FILE" -v wiredmacs="$WIRED_MACS" '
    BEGIN {
        n = split(macip, lines, "\n")
        for (i = 1; i <= n; i++) {
            split(lines[i], f, " ")
            if (f[1] == "") continue
            ip2mac[f[2]] = f[1]
        }
        m = split(wiredmacs, wm, " ")
        for (i = 1; i <= m; i++) known[wm[i]] = 1

        while ((getline sline < statefile) > 0) {
            split(sline, sf, " ")
            if (sf[1] == "") continue
            st_ltx[sf[1]] = sf[2] + 0
            st_lrx[sf[1]] = sf[3] + 0
            st_atx[sf[1]] = sf[4] + 0
            st_arx[sf[1]] = sf[5] + 0
        }
        close(statefile)
    }
    {
        osrc = ""; odst = ""; b1 = 0; b2 = 0; bcount = 0
        for (i = 1; i <= NF; i++) {
            tok = $i
            if (osrc == "" && tok ~ /^src=/) { split(tok, a, "="); osrc = a[2] }
            else if (odst == "" && tok ~ /^dst=/) { split(tok, a, "="); odst = a[2] }
            else if (tok ~ /^bytes=/) {
                bcount++; split(tok, a, "=")
                if (bcount == 1) b1 = a[2] + 0; else if (bcount == 2) b2 = a[2] + 0
            }
        }
        if (osrc == "") next
        smac = ip2mac[osrc]
        dmac = ip2mac[odst]
        # Only count flows where exactly one side resolves to one of our
        # known wired MACs (the other being WAN/remote) - LAN<->LAN flows
        # between two of your own devices are deliberately skipped, same
        # rationale as the direction heuristic in luci.trafficchart:
        # counting local-to-local traffic as "internet usage" would
        # double-count and misrepresent it.
        if (smac != "" && dmac == "" && (smac in known)) {
            live_tx[smac] += b1
            live_rx[smac] += b2
        } else if (dmac != "" && smac == "" && (dmac in known)) {
            live_rx[dmac] += b1
            live_tx[dmac] += b2
        }
    }
    END {
        for (i = 1; i <= m; i++) {
            mac = wm[i]
            ltx = live_tx[mac] + 0
            lrx = live_rx[mac] + 0
            dtx = ltx - st_ltx[mac]
            drx = lrx - st_lrx[mac]
            if (dtx < 0) dtx = 0
            if (drx < 0) drx = 0
            atx = st_atx[mac] + 0 + dtx
            arx = st_arx[mac] + 0 + drx
            printf "%s %d %d %d %d\n", mac, ltx, lrx, atx, arx > statefile
            printf "%s;%d;%d\n", mac, atx, arx
        }
    }
    ' /proc/net/nf_conntrack
}

MBACKUP=$(uci -q get easyconfig_transfer.traffic.external_backup)
MBACKUPATH=$(uci -q get easyconfig_transfer.traffic.external_path)
EXTERNAL_JSON="$MBACKUPATH/easyconfig_statistics.json"

if [ ! -e "$DB" ]; then
	if [ "$MBACKUP" = "1" ] && [ -n "$MBACKUPATH" ] && [ -e "$EXTERNAL_JSON" ] && [ -e "$SDB" ]; then
		TMP_GZ=/tmp/easyconfig_statistics_gz_tmp.json
		zcat "$SDB" > "$TMP_GZ" 2>/dev/null
		if [ -e "$TMP_GZ" ]; then
			EXT_SIZE=$(wc -c < "$EXTERNAL_JSON")
			GZ_SIZE=$(wc -c < "$TMP_GZ")
			if [ "$EXT_SIZE" -gt "$GZ_SIZE" ]; then
				cp "$EXTERNAL_JSON" "$DB"
			else
				cp "$TMP_GZ" "$DB"
				easyconfig_statistics.uc "init" "init" 0 0 0 "" 0
			fi
			rm -f "$TMP_GZ"
		else
			cp "$EXTERNAL_JSON" "$DB"
		fi
	elif [ "$MBACKUP" = "1" ] && [ -n "$MBACKUPATH" ] && [ -e "$EXTERNAL_JSON" ]; then
		cp "$EXTERNAL_JSON" "$DB"
	elif [ -e "$SDB" ]; then
		zcat "$SDB" > "$DB"
		easyconfig_statistics.uc "init" "init" 0 0 0 "" 0
	else
		mkdir -p $(dirname "$SDB")
		echo "{}" > "$DB"
	fi
else
	if [ "$MBACKUP" = "1" ] && [ -n "$MBACKUPATH" ] && [ -e "$EXTERNAL_JSON" ]; then
		EXT_SIZE=$(wc -c < "$EXTERNAL_JSON")
		DB_SIZE=$(wc -c < "$DB")
		if [ "$EXT_SIZE" -gt "$DB_SIZE" ]; then
			cp "$EXTERNAL_JSON" "$DB"
		fi
	fi
fi

# lan
BRIDGE=$(ubus call network.interface.lan status | jsonfilter -q -e @.l3_device)
if [ -e /sys/class/net/$BRIDGE/bridge ]; then
	# First pass: handle WiFi ports immediately (unchanged - real counters
	# from the driver), but for wired ports only collect MAC->IFNAME pairs
	# here. Byte accounting for ALL wired MACs is then done in a single
	# combined conntrack pass below - conntrack doesn't carry per-switch-
	# port information anyway, so there's nothing to gain from (and real
	# cost to) re-parsing the whole table once per port.
	WIRED_MAC_IFNAME=""
	for I in /sys/class/net/$BRIDGE/lower_*; do
		IFNAME=${I##*lower_}
		if [ -e $I/phy80211 ]; then
			STATIONS=$(iw dev "$IFNAME" station dump | awk -v IFNAME="$IFNAME" '{if($1 == "Station") {MAC=$2;station[MAC]=1} if($0 ~ /rx bytes:/) {rx[MAC]=$3} if($0 ~ /tx bytes:/) {tx[MAC]=$3} if($0 ~ /connected time:/) {connected[MAC]=$3}} END {for (w in station) {printf "%s;%s;%s;%s;%s\n", w, IFNAME, rx[w], tx[w], connected[w]}}')
			for S in $STATIONS; do
				DHCPNAME=$(awk '/'$(echo "$S" | cut -f1 -d";")'/{if ($4 != "*") {print $4}}' /var/lib/odhcpd/dhcp.leases)
#				easyconfig_statistics.uc $(echo "$S" | cut -f1 -d";") $(echo "$S" | cut -f2 -d";") $(echo "$S" | cut -f3 -d";") $(echo "$S" | cut -f4 -d";") $(echo "$S" | cut -f5 -d";") "$DHCPNAME" 2
				easyconfig_statistics.uc ${S//;/ } "$DHCPNAME" 2
			done
		else
			PORTID=$(printf "%d" $(cat /sys/class/net/$BRIDGE/brif/$IFNAME/port_no))
			STATIONS=$(brctl showmacs $BRIDGE 2>/dev/null | awk '/^\s*'$PORTID'\s.*no/{print $2}')
			for S in $STATIONS; do
				WIRED_MAC_IFNAME="${WIRED_MAC_IFNAME}${S};${IFNAME}
"
			done
		fi
	done

	if [ -n "$WIRED_MAC_IFNAME" ]; then
		WIRED_MACS=$(echo "$WIRED_MAC_IFNAME" | cut -f1 -d";" | tr '[:upper:]' '[:lower:]' | sort -u | tr '\n' ' ')
		# Still computed unconditionally - needed as fallback for any
		# MAC whose switch port carries more than one MAC, or that
		# isn't (currently) in the ARL table at all.
		WIRED_BYTES=$(get_wired_client_bytes "$WIRED_MACS")

		ARL_TABLE=$(get_arl_table)
		# How many MACs the ARL table currently shows behind each
		# physical port - MIB is only usable 1:1 when that count is
		# exactly 1 for the port a given wired MAC resolves to.
		PORT_MAC_COUNT=$(echo "$ARL_TABLE" | awk '/^Port [0-9]+: MAC/{gsub(":","",$2); c[$2]++} END{for (p in c) print p, c[p]}')

		echo "$WIRED_MAC_IFNAME" | while IFS=";" read -r S IFNAME; do
			[ -n "$S" ] || continue
			DHCPNAME=$(awk '/'$S'/{if ($4 != "*") {print $4}}' /var/lib/odhcpd/dhcp.leases)
			MACLC=$(echo "$S" | tr '[:upper:]' '[:lower:]')
			WTX=""
			WRX=""
			PORTID=$(arl_lookup_port "$ARL_TABLE" "$MACLC")
			if [ -n "$PORTID" ]; then
				MACS_ON_PORT=$(echo "$PORT_MAC_COUNT" | awk -v p="$PORTID" '$1==p{print $2}')
				if [ "$MACS_ON_PORT" = "1" ]; then
					MIB=$(get_port_mib_bytes "$PORTID")
					PRX=$(echo "$MIB" | cut -d' ' -f1)
					PTX=$(echo "$MIB" | cut -d' ' -f2)
					# switch RxGoodByte = client upload, switch TxGoodByte = client download
					[ -n "$PRX" ] && WTX="$PRX"
					[ -n "$PTX" ] && WRX="$PTX"
				fi
			fi
			if [ -z "$WTX" ] || [ -z "$WRX" ]; then
				ROW=$(echo "$WIRED_BYTES" | grep -i "^${MACLC};")
				if [ -n "$ROW" ]; then
					WTX=$(echo "$ROW" | cut -f2 -d";")
					WRX=$(echo "$ROW" | cut -f3 -d";")
				else
					WTX=0
					WRX=0
				fi
			fi
			easyconfig_statistics.uc "$S" "$IFNAME" "$WTX" "$WRX" 999 "$DHCPNAME" 1
		done
	fi
fi

# wan
WNAME=$(uci -q get easyconfig_transfer.global.network)

IFNAME=$(ubus call network.interface.$WNAME status | jsonfilter -q -e @.l3_device)
[ -n "$IFNAME" ] && easyconfig_statistics.uc "wan" "$IFNAME" "$(get_wan_bytes tx)" "$(get_wan_bytes rx)" 999 "" 0

PERIOD=$(uci -q get easyconfig_transfer.global.datarec_period)
[ -z "$PERIOD" ] && PERIOD=0
if [ "$PERIOD" = "0" ]; then
	lock -u $LOCK
	exit 0
fi
NOW=$(date +%s)
if [ -e "$SDB" ]; then
	DBTS=$(date +%s -r "$SDB")
	WRITETS=$((DBTS + (PERIOD * 60)))
else
	WRITETS=$((NOW - 1))
fi
if [ $WRITETS -le $NOW ]; then
	gzip -k "$DB"
	mv "$DB.gz" "$SDB"
	sync
fi
if [ "$MBACKUP" = "1" ]; then
	sleep 10
	cp "$DB" "$MBACKUPATH/easyconfig_statistics.json"
fi

lock -u $LOCK

exit 0
