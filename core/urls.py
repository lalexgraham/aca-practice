"""
URL configuration for core project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/4.2/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
import logging

from django.contrib import admin
from django.urls import path
from django.http import HttpResponse
from azure.core.exceptions import AzureError

from core.keyvault import KeyVaultNotConfigured, get_demo_secret

logger = logging.getLogger(__name__)


def home(request):
    return HttpResponse("Hello from Azure Container Apps, pipeline test 2")

def show_secret(request):
    # DEMO ONLY: this prints a secret to anyone who can reach the URL, which
    # defeats the point of a vault. Use a dummy value, and delete this view
    # (and its route) once the end to end flow is proven. A real app uses the
    # secret (a DB password, an API key) and never displays it.
    try:
        value = get_demo_secret()
    except KeyVaultNotConfigured:
        return HttpResponse("Key Vault is not configured for this environment.", status=503)
    except AzureError:
        # Details go to the container logs, not the page.
        logger.exception("Could not read the secret from Key Vault")
        return HttpResponse("Could not read the secret from Key Vault.", status=503)
    return HttpResponse(f"The secret from Azure Key Vault is: {value}", content_type="text/plain")


urlpatterns = [
    path("admin/", admin.site.urls),
    path("secret/", show_secret),
    path("", home),
]
