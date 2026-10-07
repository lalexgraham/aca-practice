"""Reads the demo secret from Azure Key Vault.

Authentication is DefaultAzureCredential, so there is no password or key in
the code or the environment: in Azure it uses the Container App's
user-assigned managed identity (selected by the AZURE_CLIENT_ID env var), and
locally it falls back to your `az login` session.
"""
import os
import threading
import time

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# Short enough that a rotated secret shows up within a minute, long enough
# that a busy page isn't a Key Vault request per hit (vaults throttle).
CACHE_SECONDS = 60

_lock = threading.Lock()
_client = None
_cached = {"value": None, "fetched_at": 0.0}


class KeyVaultNotConfigured(Exception):
    pass


def _get_client():
    # Built once and reused: the credential caches its token, so creating a
    # new client per request would re-authenticate every time.
    global _client
    if _client is None:
        vault_url = os.environ.get("KEY_VAULT_URL")
        if not vault_url:
            raise KeyVaultNotConfigured("KEY_VAULT_URL is not set")
        _client = SecretClient(vault_url=vault_url, credential=DefaultAzureCredential())
    return _client


def get_demo_secret():
    name = os.environ.get("KEY_VAULT_SECRET_NAME", "demo-secret")
    with _lock:
        if _cached["value"] is not None and time.monotonic() - _cached["fetched_at"] < CACHE_SECONDS:
            return _cached["value"]
        _cached["value"] = _get_client().get_secret(name).value
        _cached["fetched_at"] = time.monotonic()
        return _cached["value"]

