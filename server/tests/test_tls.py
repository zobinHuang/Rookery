import http.client
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from rookd.config import ServerConfig
from rookd.http import RookdServer
from rookd.store import SessionStore


@unittest.skipUnless(shutil.which("openssl"), "openssl is needed to make a test certificate")
class TlsTest(unittest.TestCase):
    """Serving HTTPS: one client that never finishes its handshake must not hold up the others."""

    TEST_TOKEN = "test-token"
    TEST_TIMEOUT_SECONDS = 5

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        path_cert = root / "cert.pem"
        path_key = root / "key.pem"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=127.0.0.1", "-keyout", str(path_key), "-out", str(path_cert),
            ],
            check=True,
            capture_output=True,
        )
        config = ServerConfig(
            data_root=root / "data",
            host="127.0.0.1",
            port=0,
            token=self.TEST_TOKEN,
            max_body_bytes=1024,
            tls_cert=path_cert,
            tls_key=path_key,
        )
        self.server = RookdServer(config=config, store=SessionStore(config.data_root))
        self.port = self.server.bound_port()
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, self.TEST_TIMEOUT_SECONDS)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)

    def test_a_silent_client_does_not_block_the_next_one(self) -> None:
        silent = socket.create_connection(("127.0.0.1", self.port))
        self.addCleanup(silent.close)
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        connection = http.client.HTTPSConnection(
            "127.0.0.1",
            self.port,
            timeout=self.TEST_TIMEOUT_SECONDS,
            context=context,
        )
        self.addCleanup(connection.close)
        connection.request("GET", "/v1/healthz")
        self.assertEqual(connection.getresponse().status, 200)


if __name__ == "__main__":
    unittest.main()
