import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.Signature;
import java.security.spec.RSAPublicKeySpec;
import java.util.Base64;

/**
 * Self-test / verifier for a generated identity + license.
 *
 *   java Verify --cert agent-cert.der --ca-modulus <decimal> [--key product.key]
 *
 * Expected output:
 *   without agent: cert-signature-verifies-with-CA-key = false, license = true
 *   with agent   : cert-signature-verifies-with-CA-key = true,  license = true
 */
public final class Verify {

    public static void main(String[] a) throws Exception {
        String certPath = null, ca = null, keyPath = null;
        for (int i = 0; i < a.length - 1; i++) {
            if ("--cert".equals(a[i])) certPath = a[i + 1];
            if ("--ca-modulus".equals(a[i])) ca = a[i + 1];
            if ("--key".equals(a[i])) keyPath = a[i + 1];
        }
        byte[] cert = Files.readAllBytes(Paths.get(certPath));
        byte[] tbs = tbs(cert);
        byte[] sig = signature(cert);
        BigInteger[] own = publicKey(cert);

        PublicKey caKey = rsa(new BigInteger(ca), BigInteger.valueOf(65537));
        System.out.println("cert-signature-verifies-with-CA-key  = " + verify("SHA256withRSA", caKey, tbs, sig));
        System.out.println("cert-signature-verifies-with-own-key = " + verify("SHA256withRSA", rsa(own[0], own[1]), tbs, sig));

        if (keyPath != null) {
            String text = new String(Files.readAllBytes(Paths.get(keyPath)), StandardCharsets.UTF_16LE);
            int i = text.indexOf("<certificate-key>");
            String blob = text.substring(i + "<certificate-key>".length()).trim();
            String[] p = blob.split("-");
            byte[] json = Base64.getDecoder().decode(p[1]);
            byte[] lsig = Base64.getDecoder().decode(p[2]);
            byte[] lcert = Base64.getDecoder().decode(p[3]);
            BigInteger[] pk = publicKey(lcert);
            System.out.println("license-signature-verifies           = " + verify("SHA1withRSA", rsa(pk[0], pk[1]), json, lsig));
            System.out.println("license-json                          = " + new String(json, StandardCharsets.UTF_8));
        }
    }

    private static boolean verify(String alg, PublicKey key, byte[] data, byte[] sig) throws Exception {
        Signature v = Signature.getInstance(alg);
        v.initVerify(key);
        v.update(data);
        return v.verify(sig);
    }

    private static PublicKey rsa(BigInteger n, BigInteger e) throws Exception {
        return KeyFactory.getInstance("RSA").generatePublic(new RSAPublicKeySpec(n, e));
    }

    /* ------------------------------------------------------------- DER walking */

    private static final class Tlv {
        int tag, off, hdr, len;
        int start() { return off + hdr; }
        int end() { return off + hdr + len; }
    }

    private static Tlv read(byte[] b, int off) {
        Tlv t = new Tlv();
        t.off = off;
        t.tag = b[off] & 0xFF;
        int first = b[off + 1] & 0xFF;
        if ((first & 0x80) == 0) {
            t.hdr = 2;
            t.len = first;
        } else {
            int n = first & 0x7F, len = 0;
            for (int i = 0; i < n; i++) len = (len << 8) | (b[off + 2 + i] & 0xFF);
            t.hdr = 2 + n;
            t.len = len;
        }
        return t;
    }

    private static byte[] tbs(byte[] cert) {
        Tlv outer = read(cert, 0);
        Tlv t = read(cert, outer.hdr);
        byte[] out = new byte[t.hdr + t.len];
        System.arraycopy(cert, t.off, out, 0, out.length);
        return out;
    }

    private static byte[] signature(byte[] cert) {
        Tlv outer = read(cert, 0);
        int p = outer.hdr;
        Tlv t = read(cert, p);
        p = t.end();
        Tlv alg = read(cert, p);
        p = alg.end();
        Tlv sig = read(cert, p);
        byte[] out = new byte[sig.len - 1];
        System.arraycopy(cert, sig.start() + 1, out, 0, out.length);
        return out;
    }

    /** returns {modulus, exponent} parsed out of SubjectPublicKeyInfo */
    private static BigInteger[] publicKey(byte[] cert) {
        Tlv outer = read(cert, 0);
        Tlv tbs = read(cert, outer.hdr);
        int p = tbs.start();
        int end = tbs.end();

        Tlv spki = null;
        while (p < end) {
            Tlv t = read(cert, p);
            if (t.tag == 0xA0 || t.tag == 0x02 || t.tag == 0x30 || t.tag == 0x17 || t.tag == 0x18 || t.tag == 0x31) {
                // version / serial / alg / issuer / validity / subject are walked in order;
                // SPKI is the first 0x30 whose child is a SEQUENCE containing an OID
                if (t.tag == 0x30 && isSpki(cert, t)) {
                    spki = t;
                    break;
                }
            }
            p = t.end();
        }
        if (spki == null) throw new IllegalStateException("spki not found");

        Tlv alg = read(cert, spki.start());
        Tlv bits = read(cert, alg.end());
        Tlv rsaSeq = read(cert, bits.start() + 1); // skip unused-bits byte
        Tlv mod = read(cert, rsaSeq.start());
        Tlv exp = read(cert, mod.end());
        return new BigInteger[] {
                new BigInteger(1, slice(cert, mod.start(), mod.len)),
                new BigInteger(1, slice(cert, exp.start(), exp.len))
        };
    }

    private static boolean isSpki(byte[] cert, Tlv t) {
        Tlv alg = read(cert, t.start());
        if (alg.tag != 0x30) return false;
        Tlv oid = read(cert, alg.start());
        return oid.tag == 0x06 && oid.len == 9 && (cert[oid.start() + 8] & 0xFF) == 0x01;
    }

    private static byte[] slice(byte[] b, int off, int len) {
        byte[] out = new byte[len];
        System.arraycopy(b, off, out, 0, len);
        return out;
    }
}
