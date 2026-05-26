"""RFC 3161 timestamp provider abstraction — non-blocking, pluggable.

Mirrors the Provider/StubProvider pattern from mals_capture.py.

Architecture:
  TimestampProvider (ABC)  ← interface commune
    FreeTSAProvider         ← implémentation freetsa.org
    [futur : OpenTimestamps, DigiCert, BatchedProvider, ...]

PRINCIPE NON BLOQUANT (PRINCIPE B) :
  timestamp() lève TimestampError en cas d'échec réseau ou TSA.
  C'est l'APPELANT qui décide quoi faire (logger tsa_status='failed',
  réessayer, etc.). Cette primitive ne détruit jamais une itération.

Utilisation typique dans le capteur session-signed :
    try:
        tsr_bytes = provider.timestamp(digest_hex)
        tsa_status = "anchored"
        ts_token_b64 = base64.b64encode(tsr_bytes).decode()
    except TimestampError:
        tsa_status = "failed"
        ts_token_b64 = None
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from abc import ABC, abstractmethod
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


class TimestampError(Exception):
    """Levée quand une demande d'horodatage échoue (réseau, timeout, TSA).

    L'appelant doit enregistrer tsa_status='failed' et continuer —
    cet échec ne bloque jamais l'existence de l'itération.
    """


class TimestampProvider(ABC):
    """Interface commune pour les fournisseurs d'horodatage RFC 3161."""

    provider_name: str

    @abstractmethod
    def timestamp(self, digest_hex: str) -> bytes:
        """Demande un jeton RFC 3161 pour digest_hex (SHA-256, hex minuscule).

        Retourne les octets bruts du TSR (TimeStampResponse).
        Lève TimestampError en cas d'échec — jamais de crash silencieux.
        L'appelant décide du comportement de repli (PRINCIPE NON BLOQUANT).

        Args:
            digest_hex: hash SHA-256 à ancrer, 64 caractères hex minuscule.

        Returns:
            bytes : contenu brut du fichier .tsr

        Raises:
            TimestampError: réseau, timeout, réponse TSA invalide ou vide.
        """


class FreeTSAProvider(TimestampProvider):
    """Horodatage RFC 3161 via freetsa.org.

    Réplique l'approche de scripts/timestamp-bundle.sh :
      1. openssl ts -query -digest <hex> -sha256 -cert → TSQ bytes
      2. HTTP POST vers TSA_URL → TSR bytes
    Le token retourné peut être vérifié avec :
      openssl ts -verify -digest <hex> -sha256 -in req.tsr
                 -CAfile tsa/freetsa-cacert.pem -untrusted tsa/freetsa-tsa.crt

    Args:
        timeout: délai réseau en secondes (défaut 10). Après ce délai, TimestampError.
        url: URL du point d'horodatage TSA (défaut freetsa.org). Paramétrable pour les tests.
    """

    provider_name = "freetsa"
    _DEFAULT_URL = "https://freetsa.org/tsr"

    def __init__(self, timeout: int = 10, url: str | None = None) -> None:
        self.timeout = timeout
        self._url = url or self._DEFAULT_URL

    def timestamp(self, digest_hex: str) -> bytes:
        """Obtient un jeton RFC 3161 de freetsa.org pour digest_hex."""
        if len(digest_hex) != 64 or not all(c in "0123456789abcdef" for c in digest_hex):
            raise TimestampError(
                f"digest_hex invalide : attendu 64 caractères hex minuscule, reçu {digest_hex!r}"
            )
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                tsq_path = os.path.join(tmpdir, "req.tsq")

                # Étape 1 : construire la requête TSQ avec openssl
                result = subprocess.run(
                    [
                        "openssl", "ts", "-query",
                        "-digest", digest_hex,
                        "-sha256",
                        "-cert",
                        "-out", tsq_path,
                    ],
                    capture_output=True,
                    timeout=self.timeout,
                )
                if result.returncode != 0:
                    raise TimestampError(
                        f"openssl ts -query a échoué (code {result.returncode}): "
                        f"{result.stderr.decode(errors='replace').strip()}"
                    )

                tsr_path = os.path.join(tmpdir, "resp.tsr")

                # Étape 2 : envoyer la TSQ à la TSA via curl (identique à timestamp-bundle.sh).
                # curl utilise le magasin SSL système, évitant les problèmes de CA Python/macOS.
                curl_result = subprocess.run(
                    [
                        "curl", "--silent", "--show-error",
                        "--request", "POST", self._url,
                        "--header", "Content-Type: application/timestamp-query",
                        "--data-binary", f"@{tsq_path}",
                        "--output", tsr_path,
                        "--max-time", str(self.timeout),
                    ],
                    capture_output=True,
                    timeout=self.timeout + 5,
                )
                if curl_result.returncode != 0:
                    raise TimestampError(
                        f"curl a échoué vers {self._url} (code {curl_result.returncode}): "
                        f"{curl_result.stderr.decode(errors='replace').strip()}"
                    )

                if not os.path.exists(tsr_path) or os.path.getsize(tsr_path) == 0:
                    raise TimestampError(f"Réponse vide reçue de la TSA ({self._url})")

                with open(tsr_path, "rb") as f:
                    tsr_bytes = f.read()

                return tsr_bytes

        except TimestampError:
            raise
        except subprocess.TimeoutExpired as exc:
            raise TimestampError(
                f"Timeout ({self.timeout}s) lors de la construction de la TSQ"
            ) from exc
        except Exception as exc:
            raise TimestampError(
                f"Erreur inattendue lors de l'horodatage : {exc}"
            ) from exc
