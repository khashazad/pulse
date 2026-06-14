"""FastMCP server definition exposing diet-tracking tools to MCP clients.

Provides :func:`build_mcp`, the factory that wires up the ``FastMCP`` instance
with optional GitHub-OAuth / service-token authentication and the complete tool
suite. The tools themselves are defined in the focused ``mcp/tools/*.py``
modules (food, meals, custom foods, containers, memory, targets/summary); this
file constructs the shared :class:`ToolContext` and calls each module's
``register`` so the registration order and behavior stay identical to the prior
monolith. The MCP request/response models live in :mod:`mcp.models`; the shared
helpers live in :mod:`mcp.context`.

Sits at the top of the MCP layer: the tool modules pull in repositories under
``repositories/`` and orchestration services under ``services/`` so the MCP
surface mirrors the REST surface and shares the same single-tenant
``LEGACY_USER_KEY`` data. The ``WORKFLOW_INSTRUCTIONS`` constant is the prompt
the FastMCP server ships to clients describing the canonical food-logging
workflow.
"""

from __future__ import annotations

from zoneinfo import ZoneInfo

from fastmcp import FastMCP

from pulse_server.config import SERVICE_TOKEN_LOGIN, get_settings
from pulse_server.mcp.auth import GitHubAllowlistMiddleware
from pulse_server.mcp.context import ToolContext
from pulse_server.mcp.tools import (
    container_tools,
    custom_food_tools,
    food_tools,
    meal_tools,
    memory_tools,
    targets_summary_tools,
    weight_tools,
)

WORKFLOW_INSTRUCTIONS = """
Diet tracking workflow. Follow this order on every food-related interaction:

1) MEALS FIRST. Call `list_meals` once early in the conversation. If anything the user
   says matches a saved meal name (be liberal — "my breakfast", "the wrap", etc.), call
   `log_meal` with that meal_id and stop. Meals log all their ingredients at the original
   quantities; do not scale.

2) MEMORY NEXT. For each individual food the user mentions, call `resolve_food(name)`
   FIRST. If it returns `type != "none"`, use the returned macros and basis to scale to
   the user's quantity, then call `log_food` (passing `fdc_id` for memory_usda hits or
   `custom_food_id` for custom_food hits). Skip `search_food`.

3) USDA SEARCH FALLBACK. Only when memory misses, call `search_food` and pick a candidate.

4) AUTO-REMEMBER ON CORRECTIONS. If the user corrects your USDA pick (different food, or
   you got the macros wrong), after logging the corrected version call `remember_food`
   with the corrected fdc_id, basis, and per-basis macros so this user's next mention of
   the same name resolves directly. For corrections backed by a photo or user-provided
   macros (no USDA equivalent), call `save_custom_food` which auto-remembers.

5) AUTO-ALIAS ON NAME DRIFT. When the user refers to an existing memory entry or saved
   meal under a phrasing that didn't exact-match (you matched it from `list_meals` /
   `list_remembered_foods` context, not from `resolve_food` / `get_meal` returning it
   directly), call `add_meal_alias` or `add_food_alias` with the user's phrasing after
   logging. Skip if the phrasing is generic ("breakfast", "lunch", "the usual") or if
   the user explicitly disambiguated this turn. Skip if you're not confident the
   phrasing should always map to the same entity.

6) PHOTO / MANUAL MACROS. When the user provides macros directly (via photo or text)
   without a USDA reference, call `save_custom_food` with `basis="per_serving"` (default
   for photo-derived foods) — this creates the custom food and writes memory in one step.
   Then call `log_food` with the returned `custom_food_id`.

7) BACKDATE / FUTURE-DATE. `log_food` and `log_meal` accept a single optional
   `consumed_at` for non-today logging. Pass `YYYY-MM-DD` for a date-only ("tomorrow's
   breakfast", "Wednesday's lunch") — the server expands it to noon of that day. Pass
   a full ISO-8601 timestamp when the user gives an explicit time. Without `consumed_at`
   the entry stamps now. Resolve relative dates ("tomorrow", "Wednesday") to absolute
   YYYY-MM-DD before calling. Past, present, and future days are all allowed.

8) EDIT / DELETE ON ANY DAY. `delete_entry(entry_id)` is date-agnostic — the UUID
   already identifies the row regardless of when it was logged. To act on a past or
   future day, call `get_day(date)` first to discover the entry's id, then pass it to
   `delete_entry`. Same pattern for "replace yesterday's eggs": `get_day` → `delete_entry`
   → `log_food(..., consumed_at="<that day>")`.

9) READING BACK. For a single day's individual entries (e.g. to find an entry id to
   edit/delete), use `get_day(date)`. For any weekly or multi-day macro summary, use
   `get_range(start, end)` — it returns one row per day with target, consumed totals, and
   per-meal subtotals (no individual entries), so a week is one cheap call instead of
   seven `get_day` calls. For body-weight over a range, use `get_weights(from_date,
   to_date)`; `get_weight(date)` is the single-day form.

`forget_food(name)` and `list_remembered_foods()` let the user audit memory.
""".strip()


def _build_static_token_verifier(service_token: str):
    """Build a fastmcp ``StaticTokenVerifier`` for the configured service token.

    Synthesizes a GitHub-style ``login`` claim equal to
    :data:`SERVICE_TOKEN_LOGIN` so :class:`GitHubAllowlistMiddleware` can gate
    service-token calls with the same machinery as real GitHub OAuth users.

    **Inputs:**
    - service_token (str): The shared secret accepted as a bearer token.

    **Outputs:**
    - StaticTokenVerifier: Verifier mapping the token to a single client
      identity carrying the service login claim.
    """
    from fastmcp.server.auth.providers.jwt import StaticTokenVerifier

    # MultiAuth inherits required_scopes from GitHubProvider (defaults to ["user"])
    # and enforces them on every verified token regardless of source. The service
    # token represents a fully-authorized principal, so mirror the GitHub scope
    # to clear the global check.
    return StaticTokenVerifier(
        tokens={
            service_token: {
                "client_id": SERVICE_TOKEN_LOGIN,
                "scopes": ["user"],
                "login": SERVICE_TOKEN_LOGIN,
            }
        }
    )


def _build_auth_provider(settings):
    """Assemble the MCP auth provider from configured GitHub OAuth and/or service token.

    Combinations:

    - GitHub OAuth only → ``GitHubProvider`` directly.
    - Service token only → ``StaticTokenVerifier`` directly (no OAuth metadata routes).
    - Both → ``MultiAuth`` with GitHub as the server (owning routes/metadata) and the
      static verifier as a fallback verifier.
    - Neither → ``None``; the caller decides whether unauth is permitted.

    The GitHub provider receives a persistent encrypted ``client_storage`` and
    explicit ``jwt_signing_key`` when ``MCP_STORAGE_ENCRYPTION_KEY`` /
    ``MCP_JWT_SIGNING_KEY`` are configured, so OAuth state and JWT signing survive
    redeploys without re-auth; both are no-ops when unset (local dev).

    **Inputs:**
    - settings (Settings): Application settings carrying both auth configurations.

    **Outputs:**
    - AuthProvider | None: Configured provider, or ``None`` when no auth is set.
    """
    static_verifier = (
        _build_static_token_verifier(settings.mcp_service_token)
        if settings.mcp_service_token_enabled
        else None
    )

    if settings.mcp_oauth_enabled:
        from fastmcp.server.auth.providers.github import GitHubProvider

        from pulse_server.mcp.storage import build_client_storage

        github_provider = GitHubProvider(
            client_id=settings.github_client_id,
            client_secret=settings.github_client_secret,
            base_url=settings.public_base_url.rstrip("/"),
            # Pin the JWT signing key and persist OAuth state (client
            # registrations + upstream tokens) in Postgres so the claude.ai
            # connector survives redeploys without re-auth / re-consent.
            # Both are no-ops when the env vars are unset (local dev).
            jwt_signing_key=settings.mcp_jwt_signing_key or None,
            client_storage=build_client_storage(settings),
        )
        if static_verifier is None:
            return github_provider
        from fastmcp.server.auth import MultiAuth

        return MultiAuth(server=github_provider, verifiers=[static_verifier])

    return static_verifier


def build_mcp(usda_getter) -> FastMCP:
    """Construct the FastMCP server and register every diet-tracking tool.

    Indirection through ``usda_getter`` lets callers bind to
    ``usda_provider.get_usda_client`` after lifespan startup without import
    cycles. The
    auth provider is assembled by :func:`_build_auth_provider` from any
    combination of GitHub OAuth (``GITHUB_CLIENT_ID``/``SECRET`` +
    ``PUBLIC_BASE_URL``) and a static service token (``MCP_SERVICE_TOKEN``).
    :class:`GitHubAllowlistMiddleware` runs when ``ALLOWED_GITHUB_USERS`` is
    non-empty; the service-token synthetic login is auto-included in that
    allowlist. With no auth configured the server is refused outside local env
    unless ``MCP_ALLOW_UNAUTH=true``.

    **Inputs:**
    - usda_getter: Zero-arg callable returning the live ``USDAClient``;
      consulted lazily inside the ``search_food`` tool.

    **Outputs:**
    - FastMCP: Fully wired MCP server with all food/meal/target/container tools
      registered, ready to be mounted by ``app.py``.

    **Exceptions:**
    - RuntimeError: Refused to build an unauthenticated MCP outside local env
      when ``MCP_ALLOW_UNAUTH`` is not set (belt-and-suspenders guard for
      callers that bypass Settings validation).
    """
    settings = get_settings()
    tz = ZoneInfo(settings.timezone)

    # Belt-and-suspenders: Settings._require_github_allowlist_with_oauth already
    # rejects this combo, but guard here too for callers that bypass Settings
    # validation (e.g. tests constructing the server directly). An empty
    # allowlist puts GitHubAllowlistMiddleware in open-mode, so GitHub OAuth
    # outside local would otherwise admit any GitHub account.
    if (
        settings.mcp_oauth_enabled
        and not settings.github_users_allowlist
        and not settings.is_local_env
    ):
        raise RuntimeError(
            "Refusing to build MCP with GitHub OAuth enabled and an empty "
            "ALLOWED_GITHUB_USERS allowlist outside local env: the allowlist is "
            "the only owner check on the OAuth path."
        )

    auth_provider = _build_auth_provider(settings)
    if auth_provider is not None:
        mcp = FastMCP(name="diet", instructions=WORKFLOW_INSTRUCTIONS, auth=auth_provider)
        if settings.allowed_github_users_set:
            mcp.add_middleware(GitHubAllowlistMiddleware(settings.allowed_github_users_set))
    else:
        # Settings.model_validator already rejects this combo outside local; this is a
        # belt-and-suspenders guard for callers that bypass Settings (e.g. tests).
        if not settings.is_local_env and not settings.mcp_allow_unauth:
            raise RuntimeError(
                "Refusing to build unauthenticated MCP outside local env. "
                "Set GITHUB_CLIENT_ID/SECRET + PUBLIC_BASE_URL, MCP_SERVICE_TOKEN, "
                "or MCP_ALLOW_UNAUTH=true."
            )
        mcp = FastMCP(name="diet", instructions=WORKFLOW_INSTRUCTIONS)

    # Match REST surface so data created via either path lives in the same tenant.
    ctx = ToolContext(user_key=settings.legacy_user_key, tz=tz, usda_getter=usda_getter)

    food_tools.register(mcp, ctx)
    targets_summary_tools.register(mcp, ctx)
    custom_food_tools.register(mcp, ctx)
    container_tools.register(mcp, ctx)
    memory_tools.register(mcp, ctx)
    meal_tools.register(mcp, ctx)
    weight_tools.register(mcp, ctx)

    return mcp
