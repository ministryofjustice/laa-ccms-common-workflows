import java.io.ByteArrayInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import javax.security.auth.x500.X500Principal;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class RemoveCertificates {
    private static final Pattern PEM_CERTIFICATE = Pattern.compile(
        "-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----[\\t ]*(?:\\r?\\n)?",
        Pattern.DOTALL
    );
    private static final Set<String> ROOT_NAMES = new HashSet<String>(Arrays.asList(
        "emSign Root CA - G1",
        "emSign Root CA - G2",
        "emSign ECC Root CA - G3",
        "AAA Certificate Services"
    ));

    private RemoveCertificates() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            usage();
            System.exit(2);
        }

        String mode = args[0];
        String path = args[1];
        if ("remove-pem".equals(mode) || "verify-pem".equals(mode)) {
            processPemBundle(mode, path);
            return;
        }
        if (!"remove".equals(mode) && !"verify".equals(mode)) {
            usage();
            System.exit(2);
        }

        LoadedKeyStore loaded = load(path);
        KeyStore keyStore = loaded.keyStore;
        List<String> matchingAliases = findMatchingAliases(keyStore);

        if ("verify".equals(mode)) {
            if (!matchingAliases.isEmpty()) {
                System.err.println("Affected root certificates remain under aliases: " + matchingAliases);
                System.exit(1);
            }
            return;
        }

        for (String alias : matchingAliases) {
            String commonName = commonName((X509Certificate) keyStore.getCertificate(alias));
            keyStore.deleteEntry(alias);
            System.out.println("REMOVED\t" + alias + "\t" + commonName);
        }

        FileOutputStream output = new FileOutputStream(path);
        try {
            keyStore.store(output, loaded.password);
        } finally {
            output.close();
        }

        if (!findMatchingAliases(keyStore).isEmpty()) {
            throw new IllegalStateException("Affected root certificates remain after removal");
        }
        System.out.println("REMOVED_COUNT\t" + matchingAliases.size());
    }

    private static void usage() {
        System.err.println(
            "Usage: RemoveCertificates <remove|verify|remove-pem|verify-pem> <file>"
        );
    }

    private static void processPemBundle(String mode, String path) throws Exception {
        byte[] bytes = Files.readAllBytes(Paths.get(path));
        String contents = new String(bytes, StandardCharsets.ISO_8859_1);
        Matcher matcher = PEM_CERTIFICATE.matcher(contents);
        StringBuilder filtered = new StringBuilder(contents.length());
        List<String> matchingNames = new ArrayList<String>();
        int previousEnd = 0;

        while (matcher.find()) {
            String block = matcher.group();
            X509Certificate certificate = parseCertificate(block);
            filtered.append(contents, previousEnd, matcher.start());
            String name = commonName(certificate);
            if (ROOT_NAMES.contains(name)) {
                matchingNames.add(name);
            } else {
                filtered.append(block);
            }
            previousEnd = matcher.end();
        }
        filtered.append(contents, previousEnd, contents.length());

        if ("verify-pem".equals(mode)) {
            if (!matchingNames.isEmpty()) {
                System.err.println(
                    "Affected root certificates remain in PEM bundle: " + matchingNames
                );
                System.exit(1);
            }
            return;
        }

        for (String name : matchingNames) {
            System.out.println("REMOVED_PEM\t" + name);
        }
        Files.write(
            Paths.get(path),
            filtered.toString().getBytes(StandardCharsets.ISO_8859_1)
        );
        System.out.println("REMOVED_COUNT\t" + matchingNames.size());
    }

    private static X509Certificate parseCertificate(String block) throws Exception {
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        ByteArrayInputStream input = new ByteArrayInputStream(
            block.getBytes(StandardCharsets.ISO_8859_1)
        );
        return (X509Certificate) factory.generateCertificate(input);
    }

    private static LoadedKeyStore load(String path) throws Exception {
        Exception lastFailure = null;
        for (String type : Arrays.asList("JKS", "PKCS12")) {
            for (char[] password : Arrays.asList("changeit".toCharArray(), new char[0])) {
                try {
                    KeyStore keyStore = KeyStore.getInstance(type);
                    FileInputStream input = new FileInputStream(path);
                    try {
                        keyStore.load(input, password);
                    } finally {
                        input.close();
                    }
                    return new LoadedKeyStore(keyStore, password);
                } catch (Exception failure) {
                    lastFailure = failure;
                }
            }
        }
        throw lastFailure;
    }

    private static List<String> findMatchingAliases(KeyStore keyStore) throws Exception {
        List<String> aliases = new ArrayList<String>();
        Enumeration<String> entries = keyStore.aliases();
        while (entries.hasMoreElements()) {
            String alias = entries.nextElement();
            Certificate certificate = keyStore.getCertificate(alias);
            if (certificate instanceof X509Certificate
                && ROOT_NAMES.contains(commonName((X509Certificate) certificate))) {
                aliases.add(alias);
            }
        }
        return aliases;
    }

    private static String commonName(X509Certificate certificate) throws Exception {
        LdapName name = new LdapName(
            certificate.getSubjectX500Principal().getName(X500Principal.RFC2253)
        );
        for (Rdn component : name.getRdns()) {
            if ("CN".equalsIgnoreCase(component.getType())) {
                return String.valueOf(component.getValue());
            }
        }
        return "";
    }

    private static final class LoadedKeyStore {
        private final KeyStore keyStore;
        private final char[] password;

        private LoadedKeyStore(KeyStore keyStore, char[] password) {
            this.keyStore = keyStore;
            this.password = password;
        }
    }
}
