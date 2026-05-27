"""RAIN session-signed iteration builder and chain verifier.

── Contrat canonique du message signé (v0.1) ────────────────────────────────
Pour chaque itération, le message signé est la chaîne UTF-8 :

    "{seq}|{input_hash}|{output_hash}|{prev_sig_hash}|{local_time}"

Séparateur : pipe '|' (U+007C).
Champs dans cet ordre EXACT :
    seq           — entier en décimal, ex. "1", "2", "3"
    input_hash    — SHA-256 hex, 64 caractères minuscules
    output_hash   — SHA-256 hex, 64 caractères minuscules
    prev_sig_hash — SHA-256 hex (64 chars) des octets bruts de la sig de
                    l'itération précédente (base64-décodée) ; valeur de
                    genèse pour seq=1 : "0000…0000" (64 zéros)
    local_time    — ISO 8601 UTC, ex. "2026-05-26T14:47:12Z"

Le vérificateur DOIT reproduire cette construction à l'octet près.
Ne PAS utiliser de sérialisation JSON : l'ordre des clés serait ambigu.

── Digest TSA ───────────────────────────────────────────────────────────────
Le digest envoyé à la TSA est SHA-256 des 64 octets bruts de la signature
Ed25519 (AVANT encodage base64). La signature commit déjà à tous les champs
du message ; ancrer la signature est donc suffisant et forme une preuve
compacte : "cette signature précise existait à cet instant".

── Compatibilité ────────────────────────────────────────────────────────────
La primitive Ed25519 de la lib `cryptography` (sans pré-hachage) est
identique à `openssl pkeyutl -sign -rawin`. Le vérificateur peut utiliser
l'une ou l'autre.
"""

from __future__ import annotations

import base64
import hashlib
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.x509 import load_pem_x509_certificate

from .timestamp_provider import TimestampError, TimestampProvider

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

GENESIS_PREV_SIG_HASH = "0" * 64
CANONICAL_SEPARATOR = "|"


# ── Helpers internes ──────────────────────────────────────────────────────────

def _canonical_message(
    seq: int,
    input_hash: str,
    output_hash: str,
    prev_sig_hash: str,
    local_time: str,
) -> bytes:
    """Construit le message signé canonique en bytes UTF-8.

    Format : "{seq}|{input_hash}|{output_hash}|{prev_sig_hash}|{local_time}"
    Voir le contrat canonique en tête de module.
    """
    return CANONICAL_SEPARATOR.join(
        [str(seq), input_hash, output_hash, prev_sig_hash, local_time]
    ).encode("utf-8")


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sig_to_prev_hash(sig_b64: str) -> str:
    """Calcule prev_sig_hash = SHA-256 des octets bruts de la signature."""
    return _sha256_hex(base64.b64decode(sig_b64))


def _load_private_key(key_path: Path):
    pem = key_path.read_bytes()
    return load_pem_private_key(pem, password=None)


def _load_public_key_from_cert(cert_pem: bytes | str):
    if isinstance(cert_pem, str):
        cert_pem = cert_pem.encode()
    return load_pem_x509_certificate(cert_pem).public_key()


def _sign(message: bytes, private_key) -> bytes:
    """Signe message avec la clé Ed25519 — sans pré-hachage (identique à -rawin)."""
    return private_key.sign(message)


def _verify_sig(message: bytes, sig_bytes: bytes, public_key) -> bool:
    try:
        public_key.verify(sig_bytes, message)
        return True
    except InvalidSignature:
        return False


# ── Résultat de vérification ──────────────────────────────────────────────────

@dataclass
class ChainVerifyResult:
    valid: bool
    error: Optional[str] = None
    failed_seq: Optional[int] = None

    def __bool__(self) -> bool:
        return self.valid


# ── API publique ──────────────────────────────────────────────────────────────

def build_signed_iterations(
    iterations_data: list[dict],
    *,
    signer_key_path: Optional[Path] = None,
    timestamp_provider: Optional[TimestampProvider] = None,
) -> list[dict]:
    """Construit la liste des itérations session-signed à partir de données brutes.

    Args:
        iterations_data: liste de dicts, chacun avec au minimum :
            seq (int), input_hash (str), output_hash (str).
            Champs optionnels transmis tels quels : action, provider, model.
        signer_key_path: chemin vers pki/signer-key.pem (défaut : pki/ du repo).
        timestamp_provider: instance de TimestampProvider. Si None → tsa_status="pending".

    Returns:
        Liste de dicts session-signed conformes au schéma mals-log v0.1.2.
        Chaque itération contient en plus des champs sources :
            local_time, prev_sig_hash, sig, tsa_status, [ts_token si anchored].

    PRINCIPE NON BLOQUANT : un échec TimestampError n'interrompt pas la
    construction de la chaîne. L'itération est produite avec tsa_status="failed".
    """
    if signer_key_path is None:
        signer_key_path = REPO_ROOT / "pki" / "signer-key.pem"

    private_key = _load_private_key(signer_key_path)

    result: list[dict] = []
    prev_sig_b64: Optional[str] = None  # None → genèse (seq=1)

    for raw in iterations_data:
        seq: int = raw["seq"]
        input_hash: str = raw["input_hash"]
        output_hash: str = raw["output_hash"]
        action: str = raw.get("action", "generate")

        local_time = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        prev_sig_hash = (
            GENESIS_PREV_SIG_HASH
            if prev_sig_b64 is None
            else _sig_to_prev_hash(prev_sig_b64)
        )

        message = _canonical_message(seq, input_hash, output_hash, prev_sig_hash, local_time)
        sig_bytes = _sign(message, private_key)
        sig_b64 = base64.b64encode(sig_bytes).decode()

        # ── Ancrage TSA — NON BLOQUANT ────────────────────────────────────────
        # Le digest ancré est SHA-256 des octets bruts de la signature.
        if timestamp_provider is None:
            tsa_status = "pending"
            ts_token_b64: Optional[str] = None
        else:
            tsa_digest = _sha256_hex(sig_bytes)
            try:
                tsr_bytes = timestamp_provider.timestamp(tsa_digest)
                tsa_status = "anchored"
                ts_token_b64 = base64.b64encode(tsr_bytes).decode()
            except TimestampError:
                # Échec TSA : l'itération existe quand même. On continue.
                tsa_status = "failed"
                ts_token_b64 = None

        # ── Construction de l'itération ───────────────────────────────────────
        iteration: dict = {
            "seq": seq,
            "action": action,
            "input_hash": input_hash,
            "output_hash": output_hash,
            "ts": local_time,
            "local_time": local_time,
            "prev_sig_hash": prev_sig_hash,
            "sig": sig_b64,
            "tsa_status": tsa_status,
        }
        if ts_token_b64 is not None:
            iteration["ts_token"] = ts_token_b64

        # Champs multi-fournisseur optionnels
        for optional_key in ("provider", "model"):
            if optional_key in raw:
                iteration[optional_key] = raw[optional_key]

        result.append(iteration)
        prev_sig_b64 = sig_b64

    return result


def verify_signed_chain(
    iterations: list[dict],
    signer_cert_pem: bytes | str,
) -> ChainVerifyResult:
    """Vérifie les signatures et le chaînage d'une liste d'itérations session-signed.

    Pour chaque itération (dans l'ordre de la liste) :
      1. Reconstruit le message canonique depuis les champs de l'itération.
      2. Vérifie la signature Ed25519 avec la clé publique du certificat.
      3. Vérifie que prev_sig_hash == SHA-256(sig_bytes de l'itération précédente),
         ou == GENESIS_PREV_SIG_HASH pour seq=1.

    Args:
        iterations: liste de dicts session-signed (contiennent sig, prev_sig_hash, etc.)
        signer_cert_pem: certificat signataire PEM (bytes ou str). La clé publique
                         est extraite du certificat — le même cert que dans pki/signer-cert.pem.

    Returns:
        ChainVerifyResult(valid=True) si tout est correct.
        ChainVerifyResult(valid=False, error=..., failed_seq=N) à la première rupture.
    """
    public_key = _load_public_key_from_cert(signer_cert_pem)

    prev_sig_b64: Optional[str] = None  # None → on attend le hash de genèse

    for iteration in iterations:
        seq: int = iteration["seq"]

        # ── 1. Vérification de la signature ───────────────────────────────────
        try:
            sig_b64: str = iteration["sig"]
            sig_bytes = base64.b64decode(sig_b64)
        except (KeyError, Exception) as exc:
            return ChainVerifyResult(
                valid=False,
                error=f"seq={seq} : champ 'sig' absent ou invalide ({exc})",
                failed_seq=seq,
            )

        try:
            prev_sig_hash_claimed: str = iteration["prev_sig_hash"]
            local_time: str = iteration["local_time"]
            input_hash: str = iteration["input_hash"]
            output_hash: str = iteration["output_hash"]
        except KeyError as exc:
            return ChainVerifyResult(
                valid=False,
                error=f"seq={seq} : champ obligatoire absent : {exc}",
                failed_seq=seq,
            )

        message = _canonical_message(
            seq, input_hash, output_hash, prev_sig_hash_claimed, local_time
        )

        if not _verify_sig(message, sig_bytes, public_key):
            return ChainVerifyResult(
                valid=False,
                error=(
                    f"seq={seq} : signature Ed25519 invalide — "
                    "l'itération a été altérée ou signée avec une autre clé"
                ),
                failed_seq=seq,
            )

        # ── 2. Vérification du chaînage ───────────────────────────────────────
        expected_prev = (
            GENESIS_PREV_SIG_HASH
            if prev_sig_b64 is None
            else _sig_to_prev_hash(prev_sig_b64)
        )

        if prev_sig_hash_claimed != expected_prev:
            return ChainVerifyResult(
                valid=False,
                error=(
                    f"seq={seq} : rupture du chaînage — "
                    f"prev_sig_hash attendu {expected_prev[:16]}…, "
                    f"déclaré {prev_sig_hash_claimed[:16]}…"
                ),
                failed_seq=seq,
            )

        prev_sig_b64 = sig_b64

    return ChainVerifyResult(valid=True)
