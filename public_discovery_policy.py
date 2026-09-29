"""Validated public-page build policy shared by provisioning and release readers."""

LANGUAGES = frozenset(("en", "fr", "de", "tr", "it", "ar", "nl", "es", "ru", "zh"))


def public_discovery_policy(tenant):
    """Unreviewed tenants remain usable but non-indexable until their content audit."""
    enabled = tenant.get("public_indexing", False)
    if not isinstance(enabled, bool):
        raise ValueError("public_indexing must be a YAML boolean")
    default = tenant.get("public_default_locale", "en")
    if default not in LANGUAGES:
        raise ValueError("public_default_locale must be a supported language code")

    def languages(field):
        value = tenant.get(field, [default])
        if (not isinstance(value, list) or not value
                or any(not isinstance(language, str) or language not in LANGUAGES for language in value)
                or len(value) != len(set(value))):
            raise ValueError(f"{field} must be a nonempty list of unique supported language codes")
        return value

    home = languages("public_home_locales")
    menu = languages("public_menu_locales")
    if default not in home or default not in menu:
        raise ValueError("public_default_locale must be present in both public locale lists")
    if enabled and any(field not in tenant for field in
                       ("public_default_locale", "public_home_locales", "public_menu_locales")):
        raise ValueError("public_indexing requires an explicit audited public locale policy")
    return {"public_default_locale": default, "public_home_locales": ",".join(home),
            "public_menu_locales": ",".join(menu), "public_indexing": str(enabled).lower()}
