const signInPaths = new Set([
  "/healthz", "/signin", "/signin/web", "/oauth/callback", "/api/web/session", "/api/web/logout",
  "/api/device/start", "/api/device/poll", "/api/entitlement",
]);

export default {
  fetch(request, env) {
    if (signInPaths.has(new URL(request.url).pathname)) {
      return env.DEAD_ROUTE_SIGN_IN.fetch(request);
    }
    return env.ASSETS.fetch(request);
  },
};
