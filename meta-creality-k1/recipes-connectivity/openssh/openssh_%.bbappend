# Datel OS: persistent host keys and authorized keys on /usr/data (the root is read-only).
# Root logs in with a key or with the stock password (set in k1-image.bb), as on stock.
# sshd takes the FIRST value of each keyword, and poky's stock sshd_config already
# sets AuthorizedKeysFile, so the Datel OS block goes in front of the stock file.
# With read-only-rootfs poky starts sshd with -f sshd_config_readonly, so both
# files get the block.
do_install:append() {
    for f in ${D}${sysconfdir}/ssh/sshd_config ${D}${sysconfdir}/ssh/sshd_config_readonly; do
    [ -f $f ] || continue
    mv $f $f.stock
    cat > $f <<'CONF'
# --- Datel OS ---
HostKey /usr/data/k1os/ssh/ssh_host_ed25519_key
HostKey /usr/data/k1os/ssh/ssh_host_ecdsa_key
AuthorizedKeysFile .ssh/authorized_keys /usr/data/k1os/ssh/authorized_keys
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
# --- stock config follows; first value of a keyword wins ---
CONF
    cat $f.stock >> $f
    rm -f $f.stock
    # poky's read-only variant ends with HostKey lines for /var/run/ssh, a tmpfs:
    # sshd_check_keys would generate those keys on every boot (the RSA one takes
    # 40 s of one core on the X2000, right while Klipper and Moonraker start).
    # The persistent keys above are the only ones.
    sed -i '/^HostKey \/var\/run\/ssh\//d' $f
    done
}
