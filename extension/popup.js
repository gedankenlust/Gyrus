async function saveBookmark() {
  const statusContainer = document.getElementById('status-container');
  const statusIcon = document.getElementById('status-icon');
  const statusText = document.getElementById('status-text');
  const pageTitle = document.getElementById('page-title');

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 3000); // 3s timeout

  try {
    // 1. Get current tab info
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) throw new Error('Kein aktiver Tab gefunden');

    pageTitle.textContent = tab.title;

    // 2. Send to Gyrus Backend
    const response = await fetch('http://127.0.0.1:8080/api/bookmarks', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: tab.title,
        url: tab.url,
        source: 'extension'
      }),
      signal: controller.signal
    });

    clearTimeout(timeoutId);

    if (!response.ok) {
      if (response.status === 409) {
        throw new Error('Bereits gespeichert');
      }
      throw new Error('Gyrus Fehler: ' + response.status);
    }

    // 3. Update UI to Success
    statusContainer.className = 'status success';
    statusIcon.textContent = '✓';
    statusText.textContent = 'In Inbox gespeichert!';

    // 4. Auto-close after 2s
    setTimeout(() => window.close(), 2000);

  } catch (error) {
    statusContainer.className = 'status error';
    statusIcon.textContent = '✕';
    if (error.name === 'AbortError') {
      statusText.textContent = 'Timeout: Gyrus nicht bereit';
    } else {
      statusText.textContent = error.message;
    }
  }
}

document.addEventListener('DOMContentLoaded', saveBookmark);
