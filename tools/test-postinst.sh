#!/bin/bash
# test-postinst.sh: runs layout/DEBIAN/postinst on the Mac with a stand-in helper and launchctl (they only log what they were asked), /var/jb pointing
# into a scratch folder, and checks which steps run.
set -u
cd "$(dirname "$0")/.."
W=$(mktemp -d "${TMPDIR:-/tmp}/msbd-postinst.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root/var/jb"
mkdir -p "$R/usr/bin" "$R/usr/libexec" "$R/Library/LaunchDaemons"
cat > "$R/usr/libexec/sshtoggled" <<EOF
#!/bin/sh
echo "helper \$*" >> "$W/calls"
exit \$(cat "$W/helper-rc")
EOF
cat > "$R/usr/bin/launchctl" <<EOF
#!/bin/sh
echo "launchctl \$*" >> "$W/calls"
EOF
chmod +x "$R/usr/libexec/sshtoggled" "$R/usr/bin/launchctl"
: > "$R/Library/LaunchDaemons/com.besiktasliseba.sshtoggled.plist"
sed "s#/var/jb#$R#g" layout/DEBIAN/postinst > "$W/postinst"; chmod +x "$W/postinst"

pass=0; fail=0
run() {   # run <name> <helper exit code> <expected: setup|nosetup> <postinst args...>
    local name="$1" rc="$2" want="$3"; shift 3
    echo "$rc" > "$W/helper-rc"; : > "$W/calls"
    out=$("$W/postinst" "$@" 2>&1); prc=$?
    local setup=nosetup
    grep -q -- "--after-install" "$W/calls" && grep -q "launchctl load .*com.besiktasliseba.sshtoggled.plist" "$W/calls" && setup=setup
    if [ "$setup" = "$want" ] && [ "$prc" = 0 ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
    else fail=$((fail+1)); printf 'FAIL  %s (got %s, postinst exit %s)\n%s\n' "$name" "$setup" "$prc" "$(sed 's/^/        /' "$W/calls")"; fi
}
run "configure, helper ok (0): full setup"                          0   setup   configure ""
run "configure, helper failed (1): full setup"                     1   setup   configure 1.0.0
run "configure, helper crashed (139): full setup"                   139 setup   configure 1.0.0
run "configure, helper killed (137): full setup"                    137 setup   configure 1.0.0
for a in abort-upgrade abort-remove abort-deconfigure; do
    echo 0 > "$W/helper-rc"; : > "$W/calls"; "$W/postinst" $a 1.0.1 >/dev/null 2>&1; prc=$?
    if [ "$prc" = 0 ] && grep -q "launchctl load .*com.besiktasliseba.sshtoggled.plist" "$W/calls" && ! grep -q "^helper" "$W/calls"; then pass=$((pass+1)); echo "ok    $a: helper started again, nothing else run"
    else fail=$((fail+1)); echo "FAIL  $a: $(tr '\n' ';' < "$W/calls")"; fi
done
: > "$W/calls"; "$W/postinst" triggered >/dev/null 2>&1
[ ! -s "$W/calls" ] && { pass=$((pass+1)); echo "ok    other actions do nothing"; } || { fail=$((fail+1)); echo "FAIL  another action ran: $(cat "$W/calls")"; }
echo "postinst: $pass passed, $fail failed"
[ "$fail" = 0 ]
