import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;
import java.util.Base64;

/**
 * Offline identity + license minter for the local ja-netfilter setup.
 *
 * What it does:
 *   1) creates (once) a 4096-bit RSA identity and an X.509 certificate whose
 *      issuer DN is "CN=JetProfile CA" but which is signed by that identity;
 *   2) derives the single [Result] rule that makes the JVM's RSA verification
 *      of that certificate return the correct PKCS#1 DigestInfo block;
 *   3) mints <product>.key files signed by the identity (SHA1withRSA).
 *
 * No network access, no embedded secrets: everything is generated locally.
 * Java 8+ compatible.
 */
public final class Mint {

    private static final String ISSUER_CN = "JetProfile CA";
    private static final String METADATA = "0120230914PSAX000005";
    private static final String DI_SHA256_PREFIX = "3031300D060960864801650304020105000420";
    private static final String OID_RSA = "1.2.840.113549.1.1.1";
    private static final String OID_SHA256_RSA = "1.2.840.113549.1.1.11";
    private static final String OID_CN = "2.5.4.3";

    public static void main(String[] argv) throws Exception {
        Map<String, String> o = parseArgs(argv);
        if (o.containsKey("help") || argv.length == 0) {
            usage();
            return;
        }
        Path dir = Paths.get(required(o, "dir"));
        Files.createDirectories(dir);

        Path keyPath = dir.resolve("agent-key.pk8");
        Path certPath = dir.resolve("agent-cert.der");
        boolean force = o.containsKey("force");

        PrivateKey priv;
        byte[] certDer;
        byte[] tbs;
        if (!force && Files.exists(keyPath) && Files.exists(certPath)) {
            priv = loadPrivateKey(keyPath);
            certDer = Files.readAllBytes(certPath);
            tbs = extractTbs(certDer);
            log("identity: reused " + certPath);
        } else {
            String cn = o.containsKey("subject") ? o.get("subject") : "JetBrains Helper";
            KeyPair kp = generateKeyPair();
            priv = kp.getPrivate();
            Cert cert = buildCertificate(kp, cn);
            certDer = cert.der;
            tbs = cert.tbs;
            Files.write(keyPath, priv.getEncoded());
            Files.write(certPath, certDer);
            log("identity: created 4096-bit RSA, subject=CN=" + cn + ", issuer=CN=" + ISSUER_CN);
        }

        String rule = null;
        if (o.containsKey("power-conf")) {
            String caMod = readCaModulus(o);
            rule = buildRule(certDer, tbs, caMod);
            Path out = Paths.get(o.get("power-conf"));
            if (out.getParent() != null) {
                Files.createDirectories(out.getParent());
            }
            Files.write(out, ("[Result]\n" + rule).getBytes(StandardCharsets.US_ASCII));
            log("power.conf: wrote " + out + " (" + rule.length() + " chars)");
        }

        if (o.containsKey("license-out")) {
            String name = o.containsKey("license-name") ? o.get("license-name") : "local";
            String assignee = o.containsKey("assignee") ? o.get("assignee") : "";
            String expiry = o.containsKey("expiry") ? o.get("expiry") : "2099-12-31";
            String codes = o.containsKey("product-codes") ? o.get("product-codes") : "II,PCWMP,PSI";
            String id = o.containsKey("license-id") ? o.get("license-id") : randomLicenseId();
            String json = licenseJson(id, name, assignee, expiry, codes);
            byte[] sig = signSha1Rsa(priv, json.getBytes(StandardCharsets.UTF_8));
            String blob = id + "-" + b64(json.getBytes(StandardCharsets.UTF_8)) + "-" + b64(sig) + "-" + b64(certDer);
            Path out = Paths.get(o.get("license-out"));
            if (out.getParent() != null) {
                Files.createDirectories(out.getParent());
            }
            // The IDE expects UTF-16LE, a leading U+FFFF, "<certificate-key>", LF, then the 4 segments.
            Files.write(out, ("\uFFFF<certificate-key>\n" + blob).getBytes(StandardCharsets.UTF_16LE));
            log("license: " + out + "  id=" + id + "  products=" + codes + "  paidUpTo=" + expiry);
        }

        if (o.containsKey("print-rule")) {
            if (rule == null) {
                rule = buildRule(certDer, tbs, readCaModulus(o));
            }
            System.out.println(rule);
        }
    }

    /* ------------------------------------------------------------------ args */

    private static Map<String, String> parseArgs(String[] argv) {
        Map<String, String> m = new LinkedHashMap<String, String>();
        List<String> flags = new ArrayList<String>();
        flags.add("force");
        flags.add("help");
        flags.add("print-rule");
        for (int i = 0; i < argv.length; i++) {
            String a = argv[i];
            if (!a.startsWith("--")) {
                continue;
            }
            String k = a.substring(2);
            if (flags.contains(k)) {
                m.put(k, "true");
            } else if (i + 1 < argv.length) {
                m.put(k, argv[++i]);
            }
        }
        return m;
    }

    private static String required(Map<String, String> o, String k) {
        String v = o.get(k);
        if (v == null || v.isEmpty()) {
            throw new IllegalArgumentException("missing --" + k);
        }
        return v;
    }

    private static String readCaModulus(Map<String, String> o) throws Exception {
        if (o.containsKey("ca-modulus")) {
            return o.get("ca-modulus").replaceAll("[^0-9]", "");
        }
        if (o.containsKey("ca-modulus-file")) {
            String s = new String(Files.readAllBytes(Paths.get(o.get("ca-modulus-file"))), StandardCharsets.US_ASCII);
            return s.replaceAll("[^0-9]", "");
        }
        throw new IllegalArgumentException("need --ca-modulus or --ca-modulus-file");
    }

    private static void usage() {
        System.out.println("Mint - offline identity + license minter\n");
        System.out.println("  --dir DIR                 state directory (agent-key.pk8 / agent-cert.der)");
        System.out.println("  --subject CN              certificate subject CN (default: JetBrains Helper)");
        System.out.println("  --force                   regenerate identity");
        System.out.println("  --power-conf FILE         write ja-netfilter power.conf");
        System.out.println("  --ca-modulus DECIMAL      JetBrains license-CA modulus");
        System.out.println("  --ca-modulus-file FILE    ... or read it from a file");
        System.out.println("  --license-out FILE        write <product>.key");
        System.out.println("  --license-name NAME       licenseeName / assigneeName default 'local'");
        System.out.println("  --assignee NAME           assigneeName (default empty)");
        System.out.println("  --expiry YYYY-MM-DD       paidUpTo / fallbackDate (default 2099-12-31)");
        System.out.println("  --product-codes CODES     e.g. II,PCWMP,PSI");
        System.out.println("  --license-id ID           10 hex chars (default random)");
        System.out.println("  --print-rule              print the [Result] rule");
    }

    /* --------------------------------------------------------------- identity */

    private static KeyPair generateKeyPair() throws Exception {
        KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
        g.initialize(4096, new SecureRandom());
        return g.generateKeyPair();
    }

    private static PrivateKey loadPrivateKey(Path p) throws Exception {
        byte[] der = Files.readAllBytes(p);
        return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(der));
    }

    private static final class Cert {
        byte[] der;
        byte[] tbs;
    }

    private static Cert buildCertificate(KeyPair kp, String subjectCn) throws Exception {
        RSAPublicKey pub = (RSAPublicKey) kp.getPublic();
        byte[] serial = new byte[8];
        new SecureRandom().nextBytes(serial);
        serial[0] &= 0x7F;
        if (serial[0] == 0) {
            serial[0] = 1;
        }
        BigInteger serialInt = new BigInteger(1, serial);

        Date notBefore = new Date(System.currentTimeMillis() - 86400000L);
        Date notAfter = date(2125, 5, 31);

        byte[] alg = seq(oid(OID_SHA256_RSA), nul());
        byte[] issuer = name(ISSUER_CN);
        byte[] subject = name(subjectCn);
        byte[] validity = seq(utcTime(notBefore), genTime(notAfter));
        byte[] spki = seq(seq(oid(OID_RSA), nul()),
                bitString(seq(integer(pub.getModulus()), integer(pub.getPublicExponent()))));

        byte[] tbs = seq(
                ctx0(integer(BigInteger.valueOf(2))),
                integer(serialInt),
                alg,
                issuer,
                validity,
                subject,
                spki);

        Signature s = Signature.getInstance("SHA256withRSA");
        s.initSign(kp.getPrivate());
        s.update(tbs);
        byte[] sig = s.sign();

        Cert c = new Cert();
        c.tbs = tbs;
        c.der = seq(tbs, alg, bitString(sig));
        return c;
    }

    private static Date date(int year, int month, int day) {
        Calendar0 cal = new Calendar0();
        return cal.make(year, month, day);
    }

    /** tiny helper so we do not depend on java.util.Calendar timezone quirks */
    private static final class Calendar0 {
        Date make(int year, int month, int day) {
            java.util.Calendar c = java.util.Calendar.getInstance(TimeZone.getTimeZone("UTC"));
            c.clear();
            c.set(year, month - 1, day, 0, 0, 0);
            return c.getTime();
        }
    }

    /* ------------------------------------------------------------------- rule */

    private static String buildRule(byte[] certDer, byte[] tbs, String caModulusDecimal) throws Exception {
        BigInteger ca = new BigInteger(caModulusDecimal);
        int k = (ca.bitLength() + 7) / 8;

        byte[] digest = MessageDigest.getInstance("SHA-256").digest(tbs);
        byte[] di = concat(hex(DI_SHA256_PREFIX), digest);

        byte[] em = new byte[k];
        em[0] = 0x00;
        em[1] = 0x01;
        int padEnd = k - di.length - 1;
        for (int i = 2; i < padEnd; i++) {
            em[i] = (byte) 0xFF;
        }
        em[padEnd] = 0x00;
        System.arraycopy(di, 0, em, padEnd + 1, di.length);

        BigInteger sigInt = new BigInteger(1, extractSignature(certDer));
        BigInteger result = new BigInteger(1, em);
        return "EQUAL," + sigInt.toString() + ",65537," + ca.toString() + "->" + result.toString();
    }

    /* ---------------------------------------------------------------- license */

    private static String licenseJson(String id, String name, String assignee, String expiry, String codes) {
        StringBuilder sb = new StringBuilder();
        sb.append("{\"licenseId\":\"").append(esc(id)).append("\"");
        sb.append(",\"licenseeName\":\"").append(esc(name)).append("\"");
        sb.append(",\"assigneeName\":\"").append(esc(assignee)).append("\"");
        sb.append(",\"products\":[");
        String[] list = codes.split(",");
        for (int i = 0; i < list.length; i++) {
            String code = list[i].trim();
            if (code.isEmpty()) {
                continue;
            }
            if (i > 0) {
                sb.append(",");
            }
            sb.append("{\"code\":\"").append(esc(code)).append("\"");
            sb.append(",\"fallbackDate\":\"").append(esc(expiry)).append("\"");
            sb.append(",\"paidUpTo\":\"").append(esc(expiry)).append("\"}");
        }
        sb.append("],\"metadata\":\"").append(METADATA).append("\"}");
        return sb.toString();
    }

    private static byte[] signSha1Rsa(PrivateKey key, byte[] data) throws Exception {
        Signature s = Signature.getInstance("SHA1withRSA");
        s.initSign(key);
        s.update(data);
        return s.sign();
    }

    private static String randomLicenseId() {
        byte[] b = new byte[5];
        new SecureRandom().nextBytes(b);
        StringBuilder sb = new StringBuilder();
        for (byte x : b) {
            sb.append(String.format("%02X", x & 0xFF));
        }
        return sb.toString();
    }

    private static String esc(String s) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        return sb.toString();
    }

    private static String b64(byte[] b) {
        return Base64.getEncoder().encodeToString(b);
    }

    /* --------------------------------------------------------------- DER bits */

    private static final class Tlv {
        int tag;
        int off;
        int hdr;
        int len;
        int start() { return off + hdr; }
        int end() { return off + hdr + len; }
    }

    private static Tlv tlv(byte[] b, int off) {
        Tlv t = new Tlv();
        t.off = off;
        t.tag = b[off] & 0xFF;
        int first = b[off + 1] & 0xFF;
        if ((first & 0x80) == 0) {
            t.hdr = 2;
            t.len = first;
            return t;
        }
        int n = first & 0x7F;
        int len = 0;
        for (int i = 0; i < n; i++) {
            len = (len << 8) | (b[off + 2 + i] & 0xFF);
        }
        t.hdr = 2 + n;
        t.len = len;
        return t;
    }

    private static byte[] extractTbs(byte[] cert) {
        Tlv outer = tlv(cert, 0);
        Tlv tbs = tlv(cert, outer.hdr);
        byte[] out = new byte[tbs.hdr + tbs.len];
        System.arraycopy(cert, tbs.off, out, 0, out.length);
        return out;
    }

    private static byte[] extractSignature(byte[] cert) throws Exception {
        Tlv outer = tlv(cert, 0);
        int p = outer.hdr;
        Tlv tbs = tlv(cert, p);
        p = tbs.end();
        Tlv alg = tlv(cert, p);
        p = alg.end();
        Tlv sig = tlv(cert, p);
        if (sig.tag != 0x03) {
            throw new IllegalStateException("unexpected certificate layout");
        }
        // first content byte is the number of unused bits (0)
        int start = sig.start() + 1;
        int len = sig.len - 1;
        byte[] out = new byte[len];
        System.arraycopy(cert, start, out, 0, len);
        return out;
    }

    private static byte[] seq(byte[]... parts) {
        return tlvBytes(0x30, concatAll(parts));
    }

    private static byte[] set(byte[]... parts) {
        return tlvBytes(0x31, concatAll(parts));
    }

    private static byte[] ctx0(byte[] inner) {
        return tlvBytes(0xA0, inner);
    }

    private static byte[] tlvBytes(int tag, byte[] value) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(tag);
        int n = value.length;
        if (n < 0x80) {
            out.write(n);
        } else if (n < 0x100) {
            out.write(0x81);
            out.write(n);
        } else if (n < 0x10000) {
            out.write(0x82);
            out.write((n >> 8) & 0xFF);
            out.write(n & 0xFF);
        } else {
            out.write(0x83);
            out.write((n >> 16) & 0xFF);
            out.write((n >> 8) & 0xFF);
            out.write(n & 0xFF);
        }
        out.write(value, 0, value.length);
        return out.toByteArray();
    }

    private static byte[] integer(BigInteger v) {
        return tlvBytes(0x02, v.toByteArray());
    }

    private static byte[] oid(String dotted) {
        String[] p = dotted.split("\\.");
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(Integer.parseInt(p[0]) * 40 + Integer.parseInt(p[1]));
        for (int i = 2; i < p.length; i++) {
            long v = Long.parseLong(p[i]);
            if (v < 0x80) {
                out.write((int) v);
            } else {
                byte[] tmp = new byte[8];
                int idx = 8;
                tmp[--idx] = (byte) (v & 0x7F);
                v >>= 7;
                while (v > 0) {
                    tmp[--idx] = (byte) ((v & 0x7F) | 0x80);
                    v >>= 7;
                }
                out.write(tmp, idx, 8 - idx);
            }
        }
        return tlvBytes(0x06, out.toByteArray());
    }

    private static byte[] utf8(String s) {
        return tlvBytes(0x0C, s.getBytes(StandardCharsets.UTF_8));
    }

    private static byte[] nul() {
        return new byte[] {0x05, 0x00};
    }

    private static byte[] bitString(byte[] v) {
        byte[] body = new byte[v.length + 1];
        body[0] = 0x00;
        System.arraycopy(v, 0, body, 1, v.length);
        return tlvBytes(0x03, body);
    }

    private static byte[] name(String cn) {
        return seq(set(seq(oid(OID_CN), utf8(cn))));
    }

    private static byte[] utcTime(Date d) {
        SimpleDateFormat f = new SimpleDateFormat("yyMMddHHmmss'Z'");
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return tlvBytes(0x17, f.format(d).getBytes(StandardCharsets.US_ASCII));
    }

    private static byte[] genTime(Date d) {
        SimpleDateFormat f = new SimpleDateFormat("yyyyMMddHHmmss'Z'");
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return tlvBytes(0x18, f.format(d).getBytes(StandardCharsets.US_ASCII));
    }

    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static byte[] concatAll(byte[]... parts) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] p : parts) {
            out.write(p, 0, p.length);
        }
        return out.toByteArray();
    }

    private static void log(String s) {
        System.out.println("[mint] " + s);
    }
}
