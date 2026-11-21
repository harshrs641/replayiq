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
});

