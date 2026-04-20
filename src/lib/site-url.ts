function getConfiguredSiteUrl() {
  const rawSiteUrl = import.meta.env.VITE_SITE_URL;

  if (typeof rawSiteUrl === "string" && rawSiteUrl.trim()) {
    return rawSiteUrl.trim();
  }

  if (typeof window !== "undefined") {
    return window.location.origin;
  }

  return "";
}

export function getAppUrl(path = "") {
  const baseUrl = getConfiguredSiteUrl();
  const normalizedPath = path.replace(/^\/+/, "");

  if (!baseUrl) {
    return normalizedPath ? `/${normalizedPath}` : "/";
  }

  try {
    const normalizedBaseUrl = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
    return new URL(normalizedPath, normalizedBaseUrl).toString();
  } catch {
    if (typeof window !== "undefined") {
      return normalizedPath ? `${window.location.origin}/${normalizedPath}` : window.location.origin;
    }

    return normalizedPath ? `/${normalizedPath}` : "/";
  }
}
