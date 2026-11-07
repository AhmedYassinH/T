"""Generate disposable lab PKI with the playground's OpenSSL, without pip packages."""

import datetime as dt
import os
from pathlib import Path
import subprocess


def generate(directory):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)

    def run(*args):
        process = subprocess.run(["openssl", *map(str, args)], cwd=directory,
                                 capture_output=True, text=True, timeout=90)
        if process.returncode:
            raise RuntimeError("OpenSSL fixture generation failed: " + process.stderr)

    def write(name, text):
        path = directory / name
        path.write_text(text, encoding="utf-8")
        return path

    def csr(name, common_name):
        run("req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-subj", f"/CN={common_name}", "-keyout", f"{name}.key", "-out", f"{name}.csr")

    def root(name, common_name):
        run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
            "-subj", f"/CN={common_name}", "-keyout", f"{name}.key", "-out", f"{name}.crt",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:1",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash")

    root("root", "Training Root CA")
    root("alternate-root", "Alternate Training Root CA")
    csr("intermediate", "Training Intermediate CA")
    write("intermediate.ext", "basicConstraints=critical,CA:TRUE,pathlen:0\n"
          "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
          "authorityKeyIdentifier=keyid,issuer\n")
    run("x509", "-req", "-in", "intermediate.csr", "-CA", "root.crt", "-CAkey", "root.key",
        "-CAcreateserial", "-days", "730", "-sha256", "-extfile", "intermediate.ext",
        "-out", "intermediate.crt")

    def extensions(name, dns):
        return write(f"{name}.ext", "[server]\nbasicConstraints=critical,CA:FALSE\n"
                     "keyUsage=critical,digitalSignature,keyEncipherment\n"
                     "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\n"
                     f"authorityKeyIdentifier=keyid,issuer\nsubjectAltName=DNS:{dns}\n")

    for name, dns, issuer, days in (
        ("current", "portal.lab.test", "intermediate", "30"),
        ("renewed", "portal.lab.test", "intermediate", "90"),
        ("wrong-name", "old-portal.lab.test", "intermediate", "30"),
        ("api", "api.lab.test", "root", "90"),
    ):
        csr(name, dns)
        extensions(name, dns)
        run("x509", "-req", "-in", f"{name}.csr", "-CA", f"{issuer}.crt",
            "-CAkey", f"{issuer}.key", "-CAcreateserial", "-days", days, "-sha256",
            "-extensions", "server", "-extfile", f"{name}.ext", "-out", f"{name}.crt")

    csr("expired", "portal.lab.test")
    extensions("expired", "portal.lab.test")
    (directory / "issued").mkdir()
    write("index.txt", "")
    write("ca-serial", "1000\n")

    def quoted(path):
        return '"' + str(path).replace("\\", "\\\\").replace('"', '\\"') + '"'

    config = "[ca]\ndefault_ca=issuer\n[issuer]\n"
    for key, name in (("database", "index.txt"), ("new_certs_dir", "issued"),
                      ("serial", "ca-serial"), ("certificate", "intermediate.crt"),
                      ("private_key", "intermediate.key")):
        config += f"{key}={quoted(directory / name)}\n"
    config += "default_md=sha256\ndefault_days=30\npolicy=policy_any\nunique_subject=no\n"
    config += "[policy_any]\ncommonName=supplied\n"
    write("issuer.cnf", config)
    now = dt.datetime.now(dt.timezone.utc)
    run("ca", "-batch", "-notext", "-config", "issuer.cnf", "-in", "expired.csr",
        "-out", "expired.crt", "-extensions", "server", "-extfile", "expired.ext",
        "-startdate", (now - dt.timedelta(days=10)).strftime("%Y%m%d%H%M%SZ"),
        "-enddate", (now - dt.timedelta(days=1)).strftime("%Y%m%d%H%M%SZ"))
    run("genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", "unrelated.key")

    for name in ("current", "renewed", "wrong-name", "expired"):
        write(f"{name}.fullchain.crt", (directory / f"{name}.crt").read_text()
              + (directory / "intermediate.crt").read_text())
    for path in directory.iterdir():
        if path.is_file():
            os.chmod(path, 0o600)
