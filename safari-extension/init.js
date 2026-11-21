// Injected by content.js as a <script src> pointing at this web-accessible
// file, so it runs in the page's main world (where window.ReplayIQ lives)
// without chrome.scripting.executeScript - Safari often can't resolve a tab
// id for that (sender.tab.id === -1). Extension-origin scripts aren't subject
// to the page's CSP. The main world has no chrome.* APIs, so content.js hands
// over the rrweb URL via a data attribute.
(() => {
  const rrwebUrl = document.currentScript && document.currentScript.dataset.rrwebUrl;

  // Network calls are bridged back to the (isolated-world) content script via
  // postMessage, which fetches directly - that context's fetch is exempt from
  // the host page's CSP and has no message payload-size ceiling.
  function transport(url, options) {
    return new Promise((resolve, reject) => {
      const id = Math.random().toString(36).slice(2);
      function handleResponse(event) {
        if (event.source !== window || !event.data || event.data.source !== 'replayiq-transport-response' || event.data.id !== id) return;
        window.removeEventListener('message', handleResponse);
        if (event.data.error) reject(new Error(event.data.error));
        else resolve();
      }
      window.addEventListener('message', handleResponse);
      window.postMessage({ source: 'replayiq-transport-request', id, url, options }, '*');
    });
  }

  if (!window.ReplayIQ) {
    console.error('[ReplayIQ] window.ReplayIQ not found after script load');
    return;
  }
  console.log('[ReplayIQ] Initializing SDK...');
  window.ReplayIQ.init({
    endpoint: 'http://localhost:8080',
    projectId: 'demo',
    rrwebUrl,
    transport,
    debug: true, // surface transport/flush failures instead of swallowing them
  }).then((instance) => {
    console.log('[ReplayIQ] Init successful! Session:', instance?.getSessionId?.());
  }).catch((err) => {
    console.error('[ReplayIQ] Init failed:', err);
  });
})();
