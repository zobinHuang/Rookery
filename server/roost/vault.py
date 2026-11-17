import base64
import secrets
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from roost.errors import ConfigError


class SecretVault:
    """Seals the owner's credentials, such as an account's refresh token, before they go into the database,
    and opens them again: AES-256-GCM under the server's secrets key, which lives in its configuration rather
    than beside the database. Each sealed value carries its own nonce, and what it is sealed for, so a value
    copied to another row does not open there."""

    VAULT_NONCE_BYTES = 12
    VAULT_PREFIX = "v1:"

    def __init__(self, key: bytes) -> None:
        self._cipher = AESGCM(key)

    def seal(self, plaintext: str, purpose: str) -> str:
        """Seal a secret for one use.

        Args:
            plaintext: the secret
            purpose: what it is for, such as `account:<id>:refresh_token`, bound into the seal

        Returns:
            the sealed value, text
        """
        nonce = secrets.token_bytes(self.VAULT_NONCE_BYTES)
        sealed = self._cipher.encrypt(nonce, plaintext.encode("utf-8"), purpose.encode("utf-8"))
        return self.VAULT_PREFIX + base64.b64encode(nonce + sealed).decode("ascii")

    def open(self, sealed: str, purpose: str) -> str:
        """Open a sealed secret.

        Args:
            sealed: what `seal` returned
            purpose: what it was sealed for

        Returns:
            the secret

        Raises:
            ConfigError: if it was sealed under another key or for another purpose, or is damaged
        """
        if not sealed.startswith(self.VAULT_PREFIX):
            raise ConfigError("a sealed secret has an unknown format")
        try:
            raw = base64.b64decode(sealed[len(self.VAULT_PREFIX):], validate=True)
            plaintext = self._cipher.decrypt(
                raw[: self.VAULT_NONCE_BYTES],
                raw[self.VAULT_NONCE_BYTES:],
                purpose.encode("utf-8"),
            )
        except (ValueError, InvalidTag) as err:
            raise ConfigError("a sealed secret does not open with this server's key") from err
        return plaintext.decode("utf-8")
