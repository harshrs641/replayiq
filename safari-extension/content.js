(async () => {
  try {
    console.log('[ReplayIQ] Content script loaded');

    // Bridge: the SDK's network calls run in the page's main world (no
    // chrome.* API access) and post a request here via window.postMessage,
    // the one channel that crosses the isolated/main world boundary. Fetch
    // directly from this content script (isolated-world fetch is exempt
    // from the page's CSP, same as a background fetch would be) rather
    // than relaying through chrome.runtime.sendMessage to the background
    // worker - that hop has a real payload-size ceiling that was silently
    // dropping large batches (e.g. rrweb full-snapshot events), and a
    // synchronous throw there left the page-side promise hanging forever
    // with no visible error.
    window.addEventListener('message', (event) => {
      if (event.source !== window || !event.data || event.data.source !== 'replayiq-transport-request') return;
      const { id, url, options } = event.data;
      fetch(url, options)
        .then(() => {
          window.postMessage({ source: 'replayiq-transport-response', id }, '*');
        })
        .catch((e) => {
          console.error('[ReplayIQ] transport fetch failed:', e);
          window.postMessage({ source: 'replayiq-transport-response', id, error: e.message }, '*');
        });
    });

    // Load SDK from backend (allowed by CSP as http://localhost:*)
    const sdkUrl = 'http://localhost:8080/sdk/replayiq.js';
    console.log('[ReplayIQ] Loading SDK from:', sdkUrl);
    
    const script = document.createElement('script');
    script.src = sdkUrl;
    script.type = 'text/javascript';
    script.async = false;  // Make sure it's not async
    
    // The SDK script tag executes in the page's main world, so window.ReplayIQ
    // exists there, not in this isolated world. Init runs from init.js, a
    // web-accessible extension script (exempt from the page's CSP) injected
    // the same way, so it also lands in the main world.
    script.onload = () => {
      console.log('[ReplayIQ] SDK script onload fired, injecting init in main world');
      const init = document.createElement('script');
      init.src = chrome.runtime.getURL('init.js');
      init.dataset.rrwebUrl = chrome.runtime.getURL('rrweb.min.js');
      init.onload = () => init.remove();
      init.onerror = (err) => console.error('[ReplayIQ] init.js load error:', err);
      document.documentElement.appendChild(init);
    };
    
    script.onerror = (err) => {
      console.error('[ReplayIQ] Script load error:', err);
    };
    
    // Try appending to different locations
    console.log('[ReplayIQ] document.readyState:', document.readyState);
    console.log('[ReplayIQ] Appending script to documentElement...');
    document.documentElement.appendChild(script);
    console.log('[ReplayIQ] Script appended');
  } catch (e) {
    console.error('[ReplayIQ] Content script error:', e);
  }
})();
