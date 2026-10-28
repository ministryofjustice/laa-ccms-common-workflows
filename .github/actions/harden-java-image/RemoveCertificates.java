import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.KeyStore;
import java.security.cert.Certificate;
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

public final class RemoveCertificates {
    private static final Set<String> ROOT_NAMES = new HashSet<String>(Arrays.asList(
        "emSign Root CA - G1",
        "emSign Root CA - G2",
        "emSign ECC Root CA - G3",
        "AAA Certificate Services"
    ));

    private RemoveCertificates() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2 || (!"remove".equals(args[0]) && !"verify".equals(args[0]))) {
            System.err.println("Usage: RemoveCertificates <remove|verify> <keystore>");
            System.exit(2);
        }

        String mode = args[0];
        String path = args[1];
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
