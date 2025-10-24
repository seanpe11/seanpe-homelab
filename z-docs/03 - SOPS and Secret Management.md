# SOPS and Secret Management

SOPS is a tool that allows you to encrypt and decrypt secrets in plain text. More accurately, it allows you to commit files that has text that should be kept secret to git. Documentation on SOPS can be found [here](https://github.com/mozilla/sops).

I use age as the encryption tool for SOPS. Installed using age-keygen, and the age keypair is stored both in the server that I use, added as a secret to kubernetes, and the local machine I work in to configure this repository.

## Encrypting a secret

To encrypt a secret, I use the following command:

```bash
sops --encrypt --in-place <file>
```

This will encrypt the file and replace the original file with the encrypted version.
