// Pages serves the gzipped engine as an opaque asset. Decode it here so
// startup does not depend on Cloudflare's Content-Encoding negotiation.
(() => {
  const wasm = new URL("index.wasm", document.baseURI).href;
  const payload = new URL("__ENGINE_PAYLOAD__", document.baseURI);
  const fetchAsset = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const address = input instanceof Request ? input.url : input;
    if (new URL(address, document.baseURI).href !== wasm) {
      return fetchAsset(input, init);
    }
    const response = await fetchAsset(payload, init);
    if (!response.ok) return response;
    return new Response(response.body.pipeThrough(new DecompressionStream("gzip")), {
      headers: { "Content-Type": "application/wasm" },
    });
  };
})();
