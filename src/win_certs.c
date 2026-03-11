// Load trusted root CA certificates from the Windows certificate store
// and return them as a concatenated PEM string suitable for
// natsOptions_SetCATrustedCertificates().

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "crypt32.lib")

// Base64-encode raw bytes into dst. Returns number of chars written.
static int base64_encode(const unsigned char *src, int src_len, char *dst, int dst_size) {
    DWORD out_len = (DWORD)dst_size;
    if (!CryptBinaryToStringA(src, (DWORD)src_len,
            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, dst, &out_len))
        return 0;
    return (int)out_len;
}

// Returns a malloc'd null-terminated string containing PEM-encoded root CAs
// from the Windows "ROOT" certificate store, or NULL on failure.
// Caller must free() the returned pointer.
char *win_load_system_roots(void) {
    HCERTSTORE store = CertOpenSystemStoreA(0, "ROOT");
    if (!store)
        return NULL;

    // First pass: calculate total size needed
    size_t total = 0;
    PCCERT_CONTEXT ctx = NULL;
    while ((ctx = CertEnumCertificatesInStore(store, ctx)) != NULL) {
        // PEM: header(28) + base64(ceil(n/3)*4) + footer(27) + newlines(3)
        int b64_len = ((ctx->cbCertEncoded + 2) / 3) * 4;
        total += 28 + b64_len + 27 + 3;
    }

    if (total == 0) {
        CertCloseStore(store, 0);
        return NULL;
    }

    char *buf = (char *)malloc(total + 1);
    if (!buf) {
        CertCloseStore(store, 0);
        return NULL;
    }

    // Second pass: write PEM certs
    size_t pos = 0;
    ctx = NULL;
    while ((ctx = CertEnumCertificatesInStore(store, ctx)) != NULL) {
        int b64_max = ((ctx->cbCertEncoded + 2) / 3) * 4 + 64;
        char *b64 = (char *)malloc(b64_max);
        if (!b64) continue;

        int b64_len = base64_encode(ctx->pbCertEncoded, ctx->cbCertEncoded, b64, b64_max);
        if (b64_len > 0) {
            memcpy(buf + pos, "-----BEGIN CERTIFICATE-----\n", 28); pos += 28;
            memcpy(buf + pos, b64, b64_len); pos += b64_len;
            if (b64_len > 0 && buf[pos - 1] != '\n') { buf[pos++] = '\n'; }
            memcpy(buf + pos, "-----END CERTIFICATE-----\n\n", 27); pos += 27;
        }
        free(b64);
    }
    buf[pos] = '\0';

    CertCloseStore(store, 0);
    return buf;
}
