chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'fetchSDK') {
    fetch('http://localhost:8080/sdk/replayiq.js')
      .then(r => r.text())
      .then(source => sendResponse({ source }))
      .catch(e => {
        console.error('Failed to fetch SDK:', e);
        sendResponse({ error: e.message });
      });
    return true; // Keep channel open for async response
  }

  if (request.action === 'initSDK') {
    const rrwebUrl = chrome.runtime.getURL('rrweb.min.js');
    chrome.scripting.executeScript({
      target: { tabId: sender.tab.id, frameIds: [sender.frameId] },
      world: 'MAIN',
      func: (rrwebUrl) => {
        // Runs in the page's main world, which has no access to chrome.*
        // APIs. Network calls are bridged back to the (isolated-world)
        // content script via postMessage, which fetches directly - that
        // context's fetch is exempt from the host page's CSP, same as a
        // background fetch would be, without the payload-size ceiling of
        // also relaying through chrome.runtime.sendMessage.
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

        if (window.ReplayIQ) {
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
        } else {
          console.error('[ReplayIQ] window.ReplayIQ not found after script load');
        }
      },
      args: [rrwebUrl]
    }).catch((e) => console.error('[ReplayIQ] executeScript failed:', e));
  }
});
