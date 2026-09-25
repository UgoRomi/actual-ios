// A minimal OpenID provider for tests. It approves every sign-in at once as
// one user, and checks the client, redirect address and PKCE like a real one.
const http = require("node:http");
const crypto = require("node:crypto");

const [port, clientId, clientSecret, redirectURI] = process.argv.slice(2);
const issuer = `http://127.0.0.1:${port}`;
const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const key = { ...publicKey.export({ format: "jwk" }), kid: "test", alg: "RS256", use: "sig" };
const user = {
  sub: "native-openid-user",
  preferred_username: "native-owner",
  email: "owner@example.com",
  name: "Native Owner",
};
const challenges = new Map();
const accessTokens = new Set();

const base64url = (value) => Buffer.from(value).toString("base64url");
function idToken() {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT", kid: key.kid }));
  const claims = base64url(
    JSON.stringify({ iss: issuer, sub: user.sub, aud: clientId, iat: now, exp: now + 300 }),
  );
  const signature = crypto.sign("sha256", Buffer.from(`${header}.${claims}`), privateKey);
  return `${header}.${claims}.${signature.toString("base64url")}`;
}
function json(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}
function clientAuthenticated(req, form) {
  const basic = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
  return (
    req.headers.authorization === `Basic ${basic}` ||
    (form.get("client_id") === clientId && form.get("client_secret") === clientSecret)
  );
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, issuer);
    switch (url.pathname) {
      case "/.well-known/openid-configuration":
        return json(res, 200, {
          issuer,
          authorization_endpoint: `${issuer}/authorize`,
          token_endpoint: `${issuer}/token`,
          userinfo_endpoint: `${issuer}/userinfo`,
          jwks_uri: `${issuer}/jwks`,
          response_types_supported: ["code"],
          subject_types_supported: ["public"],
          id_token_signing_alg_values_supported: ["RS256"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
        });
      case "/jwks":
        return json(res, 200, { keys: [key] });
      case "/authorize": {
        const query = url.searchParams;
        if (
          query.get("client_id") !== clientId ||
          query.get("redirect_uri") !== redirectURI ||
          query.get("code_challenge_method") !== "S256" ||
          !query.get("code_challenge")
        )
          return json(res, 400, { error: "invalid_request" });
        const code = crypto.randomUUID();
        challenges.set(code, query.get("code_challenge"));
        const next = new URL(redirectURI);
        next.searchParams.set("code", code);
        next.searchParams.set("state", query.get("state") ?? "");
        next.searchParams.set("iss", issuer);
        res.writeHead(302, { Location: next.toString() });
        return res.end();
      }
      case "/token": {
        let body = "";
        for await (const chunk of req) body += chunk;
        const form = new URLSearchParams(body);
        if (!clientAuthenticated(req, form)) return json(res, 401, { error: "invalid_client" });
        const challenge = challenges.get(form.get("code"));
        challenges.delete(form.get("code"));
        const verifier = form.get("code_verifier") ?? "";
        if (
          !challenge ||
          form.get("redirect_uri") !== redirectURI ||
          crypto.createHash("sha256").update(verifier).digest("base64url") !== challenge
        )
          return json(res, 400, { error: "invalid_grant" });
        const accessToken = crypto.randomUUID();
        accessTokens.add(accessToken);
        return json(res, 200, {
          access_token: accessToken,
          token_type: "Bearer",
          expires_in: 300,
          id_token: idToken(),
        });
      }
      case "/userinfo": {
        const token = (req.headers.authorization ?? "").replace(/^Bearer /, "");
        return accessTokens.has(token) ? json(res, 200, user) : json(res, 401, { error: "invalid_token" });
      }
      default:
        return json(res, 404, { error: "not_found" });
    }
  })
  .listen(Number(port), "127.0.0.1", () => console.log(`OpenID provider listening on ${issuer}`));
