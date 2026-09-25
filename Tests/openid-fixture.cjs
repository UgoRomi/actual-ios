// Turns on OpenID for the disposable server from sync-fixture.cjs, as Actual's
// Settings → Authentication does.
const fs = require("node:fs");
const path = require("node:path");

const [dir, issuer, clientId, clientSecret] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(path.join(dir, "fixture.json"), "utf8"));

async function post(route, body, token) {
  const res = await fetch(fixture.url + route, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { "X-ACTUAL-TOKEN": token } : {}) },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  if (json.status !== "ok") throw new Error(`${route}: ${JSON.stringify(json)}`);
  return json.data;
}

(async () => {
  const { token } = await post("/account/login", { password: fixture.password });
  await post(
    "/openid/enable",
    {
      openId: {
        issuer,
        client_id: clientId,
        client_secret: clientSecret,
        server_hostname: fixture.url,
      },
    },
    token,
  );
  console.log("OpenID enabled on the disposable server");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
