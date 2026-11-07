# Mainsail provides the only site; drop nginx's own default server on port 80.
do_install:append() {
    rm -f ${D}${sysconfdir}/nginx/sites-enabled/default_server
}
