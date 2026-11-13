import { createServer } from "node:http";
import { createHandler } from "./auth-service.mjs";

const server = createServer(createHandler());
server.listen(Number(process.env.PORT || process.env.WALLET_PORT || 8787),
  process.env.WALLET_BIND || (process.env.PORT ? "0.0.0.0" : "127.0.0.1"), () => {
  console.log(`Dead Route sign-in listening for ${process.env.WALLET_PUBLIC_URL || "http://127.0.0.1:8787"}.`);
});
