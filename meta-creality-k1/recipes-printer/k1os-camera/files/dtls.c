/* The DTLS handshake of WebRTC on mbedtls, behind an interface small enough to
 * declare by hand in Zig: mbedtls' own types are structs whose layout only its
 * headers know. Everything else in k1os-camera is Zig.
 *
 * WebRTC uses DTLS for one thing: to agree on the SRTP keys (RFC 5764). Each
 * side shows a self-signed certificate, and the other compares its SHA-256
 * fingerprint with the one in the SDP.
 *
 * This side is always the DTLS client. mbedtls 3.6 as a DTLS server refuses a
 * ClientHello that spans several datagrams, and Chrome's does.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ecp.h>
#include <mbedtls/entropy.h>
#include <mbedtls/md.h>
#include <mbedtls/pk.h>
#include <mbedtls/ssl.h>
#include <mbedtls/timing.h>
#include <mbedtls/x509_crt.h>

#define FINGERPRINT_LEN 95 /* 32 bytes as "AA:BB:..." */
#define KEYS_LEN 60        /* two 16 byte keys, then two 14 byte salts */

/* Sends one datagram to the peer of `user`; implemented in main.zig. */
extern int camera_dtls_send(void *user, const uint8_t *data, size_t len);

struct dtls {
    mbedtls_ssl_context ssl;
    mbedtls_timing_delay_context timer;
    void *user;
    const uint8_t *in; /* the datagram being fed, during dtls_step() */
    size_t in_len;
    uint8_t keys[KEYS_LEN];
    int have_keys;
    int done;
};

static mbedtls_entropy_context entropy;
static mbedtls_ctr_drbg_context rng;
static mbedtls_ssl_config conf;
static mbedtls_x509_crt cert;
static mbedtls_pk_context key;

static void fingerprint_of(const mbedtls_x509_crt *crt, char out[FINGERPRINT_LEN + 1])
{
    unsigned char digest[32];
    mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), crt->raw.p, crt->raw.len, digest);
    for (int i = 0; i < 32; i++)
        snprintf(out + 3 * i, 4, "%02X:", digest[i]);
    out[FINGERPRINT_LEN] = 0;
}

/* The peer's certificate is not signed by anyone we know, and is not meant to
 * be: it is checked by fingerprint once the handshake is over. */
static int accept_any(void *ctx, mbedtls_x509_crt *crt, int depth, uint32_t *flags)
{
    (void)ctx, (void)crt, (void)depth;
    *flags = 0;
    return 0;
}

/* One key and certificate for the life of the process, shared by all viewers.
 * Writes the certificate's fingerprint; returns 0, or an mbedtls error. */
int dtls_global_init(char fingerprint[FINGERPRINT_LEN + 1])
{
    static const mbedtls_ssl_srtp_profile profiles[] = {
        MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80, MBEDTLS_TLS_SRTP_UNSET};
    static unsigned char der[1024];
    mbedtls_x509write_cert write;
    unsigned char serial[8];
    int ret, len;

    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&rng);
    mbedtls_ssl_config_init(&conf);
    mbedtls_x509_crt_init(&cert);
    mbedtls_pk_init(&key);
    if ((ret = mbedtls_ctr_drbg_seed(&rng, mbedtls_entropy_func, &entropy, (const unsigned char *)"k1os-camera", 6)))
        return ret;

    /* ECDSA on P-256: generated in milliseconds, where an RSA key would take
     * the K1 seconds. */
    if ((ret = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY))))
        return ret;
    if ((ret = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key), mbedtls_ctr_drbg_random, &rng)))
        return ret;

    mbedtls_x509write_crt_init(&write);
    mbedtls_x509write_crt_set_version(&write, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&write, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&write, &key);
    mbedtls_x509write_crt_set_issuer_key(&write, &key);
    mbedtls_ctr_drbg_random(&rng, serial, sizeof(serial));
    serial[0] = (serial[0] & 0x7f) | 0x01; /* positive, no leading zero */
    ret = mbedtls_x509write_crt_set_subject_name(&write, "CN=k1os-camera");
    if (!ret) ret = mbedtls_x509write_crt_set_issuer_name(&write, "CN=k1os-camera");
    if (!ret) ret = mbedtls_x509write_crt_set_serial_raw(&write, serial, sizeof(serial));
    /* Browsers do not look at the dates of a WebRTC certificate, and the
     * printer's clock may not be set when this runs. */
    if (!ret) ret = mbedtls_x509write_crt_set_validity(&write, "20250101000000", "20550101000000");
    /* the DER is written at the end of the buffer */
    len = ret ? ret : mbedtls_x509write_crt_der(&write, der, sizeof(der), mbedtls_ctr_drbg_random, &rng);
    mbedtls_x509write_crt_free(&write);
    if (len < 0)
        return len;
    if ((ret = mbedtls_x509_crt_parse_der(&cert, der + sizeof(der) - len, len)))
        return ret;
    fingerprint_of(&cert, fingerprint);

    if ((ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_DATAGRAM,
                                           MBEDTLS_SSL_PRESET_DEFAULT)))
        return ret;
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &rng);
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_OPTIONAL);
    mbedtls_ssl_conf_verify(&conf, accept_any, NULL);
    if ((ret = mbedtls_ssl_conf_own_cert(&conf, &cert, &key)))
        return ret;
    if ((ret = mbedtls_ssl_conf_dtls_srtp_protection_profiles(&conf, profiles)))
        return ret;
    mbedtls_ssl_conf_srtp_mki_value_supported(&conf, MBEDTLS_SSL_DTLS_SRTP_MKI_UNSUPPORTED);
    /* first retransmission after 200 ms instead of a second: on a local
     * network a lost handshake datagram should not cost a visible wait */
    mbedtls_ssl_conf_handshake_timeout(&conf, 200, 4000);
    return 0;
}

static int bio_send(void *ctx, const unsigned char *buf, size_t len)
{
    struct dtls *d = ctx;
    return camera_dtls_send(d->user, buf, len) < 0 ? MBEDTLS_ERR_SSL_WANT_WRITE : (int)len;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len)
{
    struct dtls *d = ctx;
    if (!d->in_len)
        return MBEDTLS_ERR_SSL_WANT_READ;
    size_t n = d->in_len < len ? d->in_len : len;
    memcpy(buf, d->in, n);
    d->in_len = 0;
    return (int)n;
}

/* RFC 5764 4.2: the SRTP keys are exported from the TLS master secret. */
static void export_keys(void *ctx, mbedtls_ssl_key_export_type type, const unsigned char *secret, size_t secret_len,
                        const unsigned char client_random[32], const unsigned char server_random[32],
                        mbedtls_tls_prf_types prf)
{
    struct dtls *d = ctx;
    unsigned char randoms[64];
    if (type != MBEDTLS_SSL_KEY_EXPORT_TLS12_MASTER_SECRET)
        return;
    memcpy(randoms, client_random, 32);
    memcpy(randoms + 32, server_random, 32);
    d->have_keys = !mbedtls_ssl_tls_prf(prf, secret, secret_len, "EXTRACTOR-dtls_srtp", randoms, sizeof(randoms),
                                        d->keys, sizeof(d->keys));
}

struct dtls *dtls_new(void *user)
{
    struct dtls *d = calloc(1, sizeof(*d));
    if (!d)
        return NULL;
    d->user = user;
    mbedtls_ssl_init(&d->ssl);
    if (mbedtls_ssl_setup(&d->ssl, &conf) || mbedtls_ssl_set_hostname(&d->ssl, NULL)) {
        mbedtls_ssl_free(&d->ssl);
        free(d);
        return NULL;
    }
    mbedtls_ssl_set_mtu(&d->ssl, 1200);
    mbedtls_ssl_set_bio(&d->ssl, d, bio_send, bio_recv, NULL);
    mbedtls_ssl_set_timer_cb(&d->ssl, &d->timer, mbedtls_timing_set_delay, mbedtls_timing_get_delay);
    mbedtls_ssl_set_export_keys_cb(&d->ssl, export_keys, d);
    return d;
}

void dtls_free(struct dtls *d)
{
    if (!d)
        return;
    mbedtls_ssl_free(&d->ssl);
    free(d);
}

/* Moves the connection along: with a datagram from the peer, or with none
 * (in = NULL) to start the handshake and to let it resend what got lost.
 * Returns 0 while the handshake runs, 1 once it is done, and a negative
 * mbedtls error when it failed or the peer closed the connection. */
int dtls_step(struct dtls *d, const uint8_t *in, size_t len)
{
    int ret;
    d->in = in;
    d->in_len = in ? len : 0;
    if (!d->done) {
        ret = mbedtls_ssl_handshake(&d->ssl);
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
            return 0;
        if (ret)
            return ret;
        if (!d->have_keys || !mbedtls_ssl_get_peer_cert(&d->ssl))
            return MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE;
        d->done = 1;
        return 1;
    }
    if (d->in_len) {
        /* nothing is sent over DTLS itself; this is where a close arrives */
        unsigned char discard[64];
        ret = mbedtls_ssl_read(&d->ssl, discard, sizeof(discard));
        if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
            return MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY;
        if (ret < 0 && ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE)
            return ret;
    }
    return 1;
}

/* After dtls_step() returned 1: the key material (client key, server key,
 * client salt, server salt) and the fingerprint of the peer's certificate. */
void dtls_result(struct dtls *d, uint8_t keys[KEYS_LEN], char fingerprint[FINGERPRINT_LEN + 1])
{
    memcpy(keys, d->keys, KEYS_LEN);
    fingerprint_of(mbedtls_ssl_get_peer_cert(&d->ssl), fingerprint);
}
